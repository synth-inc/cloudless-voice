// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StreamingDictationSession.swift
//  Onit
//
//  Created by Kévin Naudin on 20/07/2026.
//

import Foundation

/// The assembled output of one chunked-streaming dictation: the stitched
/// transcript plus, when every speech segment carried per-word timings, the
/// absolute (recording-relative) word timeline the custom-dictionary rescore
/// consumes.
///
/// `wordTimestamps` is `nil` unless the timeline is complete and 1:1 with
/// `text`'s words - a partial or misaligned timeline is worse than none (the
/// rescore's `alignedWordTimeRanges` requires an exact per-word count, so it
/// silently skips the audio path on any mismatch). See
/// `StreamingDictationSession` for how the run degrades to `nil`.
struct StreamingDictationResult: Sendable {
    let text: String
    let wordTimestamps: [WordTimestamp]?
}

/// One dictation's worth of chunked-streaming state: a `StreamingSegmenter` fed
/// live 16 kHz mic frames, a single background worker that transcribes segments
/// as they emerge, and a `TranscriptStitcher` assembling the result - so at key
/// release only the short final tail remains to transcribe (the streaming win
/// over single-shot). Port of the Windows `StreamingDictationSession` seam.
///
/// **Fail-soft by design.** Any thrown engine error, a dropped-frame shortfall,
/// or a finish that overruns its deadline flips the session to *failed*: `finish`
/// returns `nil` and the caller must single-shot the full capture buffer. User
/// cancellation (`cancel`) aborts the worker with nothing to salvage.
///
/// ## Isolation - why an `actor`
///
/// The session is an `actor`, chosen so that the *non-thread-safe*
/// `TranscriptStitcher` is provably confined: `stitcher` is an actor-isolated
/// stored property, **mutated only** inside `applySegmentResult(_:segment:)` -
/// a synchronous, actor-isolated method reached only from the single
/// `runWorker` task - and **read** only from `finish()` *after* the worker has
/// fully exited (`workerCompleted == true`, established happens-before). There
/// is exactly one worker task, so its stitcher writes are serialized both by
/// actor isolation and by there being a single logical writer; no other code
/// path touches the stitcher. The `StreamingSegmenter` is `@unchecked Sendable`
/// (internally locked) and is additionally only touched from actor-isolated
/// methods. The engine reference is `sending` into the actor at init and only
/// invoked from the worker.
///
/// The worker is a long-lived `Task` that strongly retains the session while it
/// loops; `finish()` or `cancel()` **must** be called to terminate it, else it
/// parks forever holding the session alive.
actor StreamingDictationSession {

    /// Allowed shortfall between what the streaming feed has seen and what the
    /// capture buffer holds before the session distrusts itself (dropped frames
    /// → missing words → single-shot is the only safe answer). 250 ms @ 16 kHz.
    private static let maxMissingSamples = 16_000 / 4

    /// The ASR sample-rate contract - every segment is handed to the engine at
    /// 16 kHz, and word timings are re-offset against this rate.
    private static let sampleRate = 16_000

    /// Default bound on `finish()`. Sized generously on purpose: on macOS the
    /// engine compute is *synchronous inside the engine actor* (Parakeet/MLX),
    /// and Swift cooperative cancellation does **not** preempt it - an in-flight
    /// segment always runs to completion. So the deadline must comfortably clear
    /// one in-flight segment plus the final tail of compute; it exists only to
    /// bound a genuinely hung engine, never to interrupt legitimate work. When it
    /// does trip, the caller's single-shot fallback still queues behind the
    /// unstoppable in-flight segment on the engine actor - the generous size is
    /// what keeps that from happening under normal load.
    static let defaultFinishDeadline: Duration = .seconds(20)

    // MARK: Owned collaborators

    private let segmenter: StreamingSegmenter
    /// Worker-confined (see the isolation note above). Never touched off the
    /// worker except by `finish()` after the worker has exited.
    private let stitcher = TranscriptStitcher()
    /// Released (set `nil`) on `cancel`/timeout so the fallback path isn't gated
    /// behind this session's reference. `sending` in - owned for the dictation.
    private var engine: (any StreamingASRCapable)?
    private let language: String?
    private let finishDeadline: Duration

    // MARK: State

    /// Set by any worker error, a dropped-frame shortfall, or a finish overrun.
    /// Once set the session is inert and the caller must single-shot.
    private var failed = false
    /// Set by `finish()`; tells the worker to process the tail and exit.
    private var finishing = false
    /// Re-entrancy guard: a second `finish()` returns `nil` instead of overwriting
    /// `finishContinuation` and orphaning the first waiter.
    private var finishInvoked = false
    /// Set by `cancel()`; the dictation is discarded, nothing to salvage.
    private var cancelled = false

    /// The final tail segment, handed to the worker by `finish()` for FIFO
    /// processing after all cut segments (keeps the stitcher worker-confined).
    private var pendingTail: StreamingAudioSegment?

    /// Absolute (recording-relative) word timeline, accumulated in stitch order.
    /// Reported only while `timestampsUsable`.
    private var absoluteTimestamps: [WordTimestamp] = []
    /// Flips to `false` the moment a speech segment yields no timings (MLX) or a
    /// word/timing count that can't be aligned 1:1 - a partial timeline would
    /// misalign the whole rescore, so the entire run's timestamps degrade to nil.
    private var timestampsUsable = true

    private var segmentCount = 0

    // MARK: Worker plumbing

    private var workerTask: Task<Void, Never>?
    private var workerCompleted = false

    /// One-slot wake for the parked worker; `pendingWake` closes the race where a
    /// wake arrives after a drain but before the worker parks.
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var pendingWake = false

    /// Resumed once the worker exits (`true`) or the finish deadline fires
    /// (`false`); single-resume, first writer wins.
    private var finishContinuation: CheckedContinuation<Bool, Never>?

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - engine: The streaming-capable engine (an `actor`), owned for the
    ///     dictation. `sending`: the caller transfers it in.
    ///   - language: Resolved language hint (ISO 639-1), or `nil` for auto.
    ///   - segmenterOptions: Segmentation tuning; defaults to `.default`.
    ///   - finishDeadline: Bound on `finish()`; see `defaultFinishDeadline`.
    init(
        engine: any StreamingASRCapable,
        language: String?,
        segmenterOptions: StreamingSegmenterOptions = .default,
        finishDeadline: Duration = StreamingDictationSession.defaultFinishDeadline
    ) {
        self.engine = engine
        self.language = language
        self.segmenter = StreamingSegmenter(options: segmenterOptions)
        self.finishDeadline = finishDeadline
    }

    /// Lazily start the single worker task. It can't be launched from `init`: an
    /// actor's nonisolated initializer may not store into actor-isolated state.
    /// Started instead on the first actor-isolated entry point (`append`/`finish`).
    /// Idempotent, and never restarts once cancelled, so the "exactly one worker"
    /// invariant holds.
    private func ensureWorkerStarted() {
        guard workerTask == nil, !cancelled else { return }
        workerTask = Task { [self] in
            await runWorker()
        }
    }

    /// `true` once any streaming step failed - the dictation must single-shot.
    var isFailed: Bool { failed }

    // MARK: - Producer surface

    /// Feed one chunk of live 16 kHz mono float32 samples plus the capture
    /// buffer's running total (`absoluteSampleCount`). Called by the producer
    /// per incoming buffer; must precede `finish()`.
    ///
    /// The segmenter observes a **copy** of `samples` (`[Float]` is a value; the
    /// segmenter appends its contents) - never the service's live accumulation
    /// buffer. A missing-samples sanity check runs here: if the feed has fallen
    /// more than 250 ms behind the capture buffer, frames were dropped → the
    /// session fails and the caller single-shots. A small excess is fine (a final
    /// buffer can reach the segmenter before the service count catches up).
    func append(samples: [Float], absoluteSampleCount: Int) {
        if failed || cancelled || finishing { return }

        ensureWorkerStarted()
        segmenter.append(samples)

        if segmenter.totalSamples < absoluteSampleCount - Self.maxMissingSamples {
            failed = true
            log.warning(
                "[streaming] feed saw \(segmenter.totalSamples) samples but capture holds "
                + "\(absoluteSampleCount) - falling back to single-shot")
            // Wake a parked worker so it observes `failed` and exits rather than
            // leaking (pairs with the deadline-bounded finish).
            wakeWorker()
            return
        }

        wakeWorker()
    }

    /// Flush the final tail into the worker's queue, wait for the worker to fully
    /// drain (the streaming analogue of the load-bearing `audioStreamTask` drain -
    /// losing it drops the last phrase), then return the assembled transcript.
    ///
    /// Returns `nil` when the session failed, was cancelled, produced no text, or
    /// overran `finishDeadline` (treated as failed). Bounded so a hung engine
    /// can't stall the dictation forever; on timeout the engine reference is
    /// released and the worker cancelled *before* the caller falls back, though
    /// the unstoppable in-flight segment (sync-in-actor) still finishes on its
    /// own. Call once, after the last `append`.
    func finish() async -> StreamingDictationResult? {
        if cancelled || finishInvoked { return nil }
        finishInvoked = true
        ensureWorkerStarted()
        finishing = true

        // Already failed (append sanity check or an earlier worker error): stop
        // the worker and let the caller single-shot.
        if failed {
            teardownWorker()
            return nil
        }

        // Hand the tail to the worker (kept out of the stitcher off-worker) and
        // wake it so it drains any remaining cut segments, then the tail, in
        // order.
        pendingTail = segmenter.takeTail()
        wakeWorker()

        let drained = await awaitWorkerBounded()
        if !drained {
            log.warning(
                "[streaming] finish exceeded \(finishDeadline) - treating as failed, "
                + "falling back to single-shot")
            failed = true
            teardownWorker()
            return nil
        }
        if failed || cancelled {
            teardownWorker()
            return nil
        }

        // Worker has fully exited here - reading the stitcher is race-free.
        let text = stitcher.text
        guard !text.isEmpty else { return nil }

        let timestamps = timestampsUsable ? absoluteTimestamps : nil
        log.info(
            "[streaming] assembled \(stitcher.wordCount) word(s) across \(segmentCount) "
            + "segment(s); timestamps=\(timestamps != nil ? "yes" : "no")")
        return StreamingDictationResult(text: text, wordTimestamps: timestamps)
    }

    /// Abort the dictation (user cancelled): stop the worker, reset state, and
    /// release the engine reference so the fallback path isn't gated behind it.
    /// An in-flight segment (sync-in-actor) still finishes on its own.
    func cancel() {
        if cancelled { return }
        cancelled = true
        pendingTail = nil
        teardownWorker()
    }

    // MARK: - Worker

    private func runWorker() async {
        await workerLoop()
        signalWorkerCompleted()
    }

    private func workerLoop() async {
        while true {
            // Drain every currently-ready cut segment in FIFO order.
            while let segment = segmenter.tryTakeSegment() {
                await process(segment)
                if failed || cancelled { return }
            }
            if failed || cancelled { return }

            // Finish requested: cut segments are drained above; process the tail
            // (if any) once, then exit.
            if finishing {
                if let tail = pendingTail {
                    pendingTail = nil
                    await process(tail)
                }
                return
            }

            await park()
        }
    }

    /// Transcribe one segment and merge it. Silent segments skip ASR entirely
    /// (near-silent clips measurably hallucinate). Order is guaranteed by the
    /// single worker + FIFO drain, which the stitcher and the timeline both
    /// depend on.
    private func process(_ segment: StreamingAudioSegment) async {
        segmentCount += 1
        let index = segmentCount
        let fromSec = Double(segment.startSample) / Double(Self.sampleRate)
        let toSec = Double(segment.endSample) / Double(Self.sampleRate)

        guard segment.containsSpeech else {
            log.debug(
                "[streaming] segment #\(index) "
                + "[\(String(format: "%.2f", fromSec))s–\(String(format: "%.2f", toSec))s] "
                + "no speech - skipping ASR")
            return
        }

        guard let engine else { return } // released by cancel/timeout

        do {
            // Shared with the file transcription and the re-transcription: one
            // inference at a time on the engines (see `ASREngineGate`).
            await ASREngineGate.asr.acquire(jumpQueue: true)
            // Re-read after the wait: a cancel or the finish deadline may have torn the
            // session down while this worker was parked behind another inference.
            guard !cancelled, !failed, let engine = self.engine else {
                await ASREngineGate.asr.release()
                return
            }
            let result: StreamingSegmentResult
            do {
                result = try await engine.transcribeSegment(
                    samples: segment.samples,
                    sampleRate: Self.sampleRate,
                    language: language)
                await ASREngineGate.asr.release()
            } catch {
                await ASREngineGate.asr.release()
                throw error
            }
            if cancelled || failed { return } // discarded mid-compute (cancel/timeout)
            // Qwen echoes the glossary prompt on near-silent segments that scrape
            // past the energy gate. In batch that echo is the whole clip and is
            // caught downstream; per-segment it would land in the MIDDLE of the
            // assembled transcript, so drop it here before stitching.
            if ASRPromptContext.isPromptEcho(result.text) {
                log.debug(
                    "[streaming] segment #\(index) is glossary-prompt echo - skipping")
                return
            }
            applySegmentResult(result, segment: segment)
            log.debug(
                "[streaming] segment #\(index) "
                + "[\(String(format: "%.2f", fromSec))s–\(String(format: "%.2f", toSec))s] "
                + "transcribed (\(result.text.count) chars)")
        } catch {
            if !cancelled {
                failed = true
                log.warning(
                    "[streaming] segment #\(index) transcription failed: "
                    + "\(error.localizedDescription) - falling back to single-shot")
            }
        }
    }

    /// Merge one segment's text and timings. Synchronous and actor-isolated -
    /// the only stitcher writer.
    ///
    /// The absolute timeline is kept 1:1 with the stitched text by trimming the
    /// same overlap words the stitcher drops: `TranscriptStitcher.findOverlap`
    /// (a pure function) is evaluated against the pre-append assembly, and the
    /// leading `overlap` per-word timings are dropped before the rest are
    /// re-offset to absolute coordinates. A speech segment with no timings (MLX)
    /// or a word/timing count that can't align 1:1 degrades the *whole* run's
    /// timestamps to nil - a partial timeline would misalign the rescore.
    private func applySegmentResult(_ result: StreamingSegmentResult, segment: StreamingAudioSegment) {
        let incomingWords = result.text.split(whereSeparator: \.isWhitespace).map(String.init)

        if timestampsUsable {
            if let segTimings = result.wordTimestamps, segTimings.count == incomingWords.count {
                let assembledWords = stitcher.text.split(whereSeparator: \.isWhitespace).map(String.init)
                // Mirror the stitcher: only a fixed-cut segment re-sends speech,
                // so only then are leading words dropped. Keep text and timeline
                // trimming identical or the absolute timeline desyncs.
                let overlap = segment.hasSpeechOverlap
                    ? TranscriptStitcher.findOverlap(
                        assembled: assembledWords,
                        incoming: incomingWords,
                        cap: TranscriptStitcher.maxOverlapWords)
                    : 0
                let offsetSec = Float(segment.startSample) / Float(Self.sampleRate)
                for timing in segTimings[overlap...] {
                    absoluteTimestamps.append(WordTimestamp(
                        word: timing.word,
                        startSec: timing.startSec + offsetSec,
                        endSec: timing.endSec + offsetSec))
                }
            } else {
                timestampsUsable = false
            }
        }

        // Text assembly is the source of truth; the stitcher recomputes the same
        // (pure) overlap internally and appends the deduped words.
        stitcher.append(result.text, hasSpeechOverlap: segment.hasSpeechOverlap)
    }

    // MARK: - Teardown

    private func teardownWorker() {
        engine = nil
        workerTask?.cancel()
        // Wake a parked worker so it observes the failed/cancelled flag and exits.
        wakeWorker()
    }

    private func signalWorkerCompleted() {
        workerCompleted = true
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(returning: true)
        }
    }

    // MARK: - Wake / bounded wait primitives

    private func wakeWorker() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            pendingWake = true
        }
    }

    /// Park the worker until woken. `pendingWake` is checked first so a wake that
    /// landed while the worker was busy (continuation not yet installed) isn't
    /// lost. The continuation is installed synchronously under actor isolation,
    /// so no wake can slip between the check and the suspend.
    private func park() async {
        if pendingWake {
            pendingWake = false
            return
        }
        if failed || cancelled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.wakeContinuation = continuation
        }
        self.wakeContinuation = nil
    }

    /// Wait for the worker to fully drain, bounded by `finishDeadline`. Returns
    /// `true` if the worker exited in time, `false` on timeout.
    ///
    /// Deliberately does **not** race `workerTask.value`: awaiting a
    /// non-throwing task's value ignores the awaiter's cancellation, so a plain
    /// task-group race couldn't actually unblock on timeout. Instead the worker
    /// resumes `finishContinuation(true)` when it exits and a detached timer
    /// resumes `finishContinuation(false)` at the deadline; first writer wins.
    private func awaitWorkerBounded() async -> Bool {
        if workerCompleted { return true }

        let deadline = finishDeadline
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            await self?.onFinishTimeout()
        }
        defer { timeoutTask.cancel() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if workerCompleted {
                continuation.resume(returning: true)
            } else {
                self.finishContinuation = continuation
            }
        }
    }

    private func onFinishTimeout() {
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(returning: false)
        }
    }
}
