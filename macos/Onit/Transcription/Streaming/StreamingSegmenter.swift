// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StreamingSegmenter.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-07-20.
//

import Foundation

/// Classifies a short fixed-length frame of 16 kHz mono float32 PCM as
/// silent (`true`) or containing speech/sound (`false`). Injectable so tests
/// and future VAD backends (e.g. a streaming Silero export) can replace the
/// default energy detector.
typealias SilenceClassifier = @Sendable (ArraySlice<Float>) -> Bool

/// Tuning knobs for `StreamingSegmenter`. All durations in seconds.
///
/// - `sampleRate`: PCM sample rate. The ASR contract is 16 kHz.
/// - `minSegmentSeconds`: Minimum distance between cuts. Short segments decode
///   measurably worse than single-shot (less in-segment acoustic context), so
///   pauses closer than this to the previous cut are skipped and the phrase
///   keeps accumulating.
/// - `maxSegmentSeconds`: Hard cap on segment length. When no qualifying pause
///   appears for this long, a fixed cut is made mid-speech. Mid-speech cuts are
///   the measured source of boundary word damage, so the cap is deliberately
///   long (12 s ≈ 2 s of worker time at the measured rate - still comfortably
///   ahead of real time): waiting longer for a pause beats cutting through
///   speech.
/// - `overlapSeconds`: Lead-in cap. After a silence-aligned cut the next
///   segment's lead-in extends back only through the silence (never into
///   speech - a speech lead-in re-decodes a clipped word onset, the measured
///   "So we n…" → "So when." artifact). After a fixed (mid-speech) cut the full
///   lead-in is re-sent speech, the safety net for words straddling the cut;
///   the stitcher dedupes the doubled words.
/// - `frameSeconds`: Silence-classification granularity.
/// - `minSilenceSeconds`: Silence-run length that fires a cut. 600 ms is a
///   strong inter-phrase pause - well past plosive gaps and hesitation
///   micro-dips, so cuts land between phrases and every word's acoustic
///   evidence stays inside one segment (the zero-word-diff requirement; the
///   4-clip replay sweep showed 0.6 s edging out 0.4/0.5/0.7 s on total word
///   diffs vs single-shot).
/// - `silenceThresholdDbfs`: Default energy detector: a frame whose RMS is
///   below this dBFS level is silent. -45 dBFS sits well below conversational
///   speech (~-20 to -35) and above typical room-noise floors.
struct StreamingSegmenterOptions: Sendable {
    var sampleRate: Int = 16_000
    var minSegmentSeconds: Double = 4.0
    var maxSegmentSeconds: Double = 12.0
    var overlapSeconds: Double = 0.5
    var frameSeconds: Double = 0.1
    var minSilenceSeconds: Double = 0.6
    var silenceThresholdDbfs: Double = -45.0

    static let `default` = StreamingSegmenterOptions()

    /// Tuning for a recorded file (`TranscriptionManager.transcribeInSegments`), where
    /// latency does not matter:
    /// - segments of at least 8 s, cut at the first 0.2 s pause. The live 0.6 s threshold
    ///   waits for phrase breaks that fluent recordings may never have, and every cut then
    ///   becomes a fixed mid-word cut ("Everyone pre. Everyone preferred", measured on
    ///   0.2-0.3 s sentence pauses);
    /// - a silence threshold that follows the recording's level: -45 dBFS, or 25 dB under
    ///   its speech level when that is lower, and never under ``quietestUsefulDbfs``.
    ///   With a fixed -45 dBFS a recording made at low gain reads as silence from end to
    ///   end and never reaches the ASR; with no floor, a file holding only room tone
    ///   reads as speech from end to end and the model hallucinates a transcript.
    ///   Speech level is the 90th percentile frame, not the loudest: one door slam would
    ///   otherwise put the threshold back where it started.
    /// Scans the whole clip: call it off the main actor.
    static func offline(for samples: [Float]) -> StreamingSegmenterOptions {
        var options = StreamingSegmenterOptions(minSegmentSeconds: 8, minSilenceSeconds: 0.2)
        let frameLength = max(1, Int(options.frameSeconds * Double(options.sampleRate)))
        var frameDbfs: [Double] = []
        frameDbfs.reserveCapacity(samples.count / frameLength + 1)
        var frameStart = 0
        while frameStart + frameLength <= samples.count {
            var sum: Float = 0
            for sample in samples[frameStart ..< frameStart + frameLength] {
                sum += sample * sample
            }
            frameDbfs.append(10 * log10(Double(max(sum / Float(frameLength), 1e-12))))
            frameStart += frameLength
        }
        guard !frameDbfs.isEmpty else { return options }

        frameDbfs.sort()
        let speechDbfs = frameDbfs[min(frameDbfs.count - 1, Int(Double(frameDbfs.count) * 0.9))]
        options.silenceThresholdDbfs = min(
            options.silenceThresholdDbfs,
            max(quietestUsefulDbfs, speechDbfs - 25))
        return options
    }

    /// Floor for the level-relative threshold above: under it, a recording holds no
    /// speech worth sending to a model that hallucinates on near-silence.
    static let quietestUsefulDbfs: Double = -65
}

/// One emitted audio segment. `startSample`/`endSample` are absolute offsets
/// into the recording; `samples` includes the lead-in (silence-only after a
/// pause cut, re-sent speech after a fixed cut), i.e. it starts at
/// `startSample` which lies at or before the previous segment's end.
struct StreamingAudioSegment: Sendable {
    let samples: [Float]
    let startSample: Int
    let endSample: Int
    let containsSpeech: Bool

    /// `true` when this segment's lead-in re-sends speech already covered by the
    /// previous segment (fixed mid-speech cut) - the stitcher must then dedupe
    /// the doubled boundary words. `false` when the lead-in is silence-only
    /// (pause cut) or absent (first segment): no spoken word is re-decoded, so
    /// the stitcher must NOT dedupe, or it would drop a word genuinely repeated
    /// across the pause ("Paris. [pause] Paris is…").
    let hasSpeechOverlap: Bool
}

/// Turns a live stream of 16 kHz float frames into disjoint (small-overlap)
/// ASR segments cut at strong silence boundaries, for chunked-streaming
/// dictation.
///
/// Cut points are a pure function of the audio - NOT of worker timing: a cut
/// fires the moment a silence run crosses `minSilenceSeconds`, provided the
/// previous cut is at least `minSegmentSeconds` back, with a fixed mid-speech
/// cut only after `maxSegmentSeconds` without a pause. Deterministic
/// segmentation makes replays reproducible and keeps segments long enough to
/// decode as well as a single shot (validated: worker-timing-driven cuts
/// produced many short segments and 13 word diffs vs single-shot on the 47 s
/// bench clip). Emitted segments queue up for the ASR worker (`tryTakeSegment`);
/// the queue absorbs worker latency bursts.
///
/// (The chunked scheme itself - disjoint segments, never growing re-sends - is
/// fixed by the audio encoder's full-window attention: prefix caching can never
/// fire across different audio.)
///
/// Thread model: `append` is called on the audio-capture thread,
/// `tryTakeSegment`/`takeTail` on the ASR worker. All public members lock
/// internally, so segmentation stays a pure function of the audio content,
/// independent of how buffers are chunked on append.
final class StreamingSegmenter: @unchecked Sendable {
    private let options: StreamingSegmenterOptions
    private let isSilent: SilenceClassifier
    private let lock = NSLock()

    private var buffer: [Float] = []
    private var silentFrames: [Bool] = []
    private var pending: [StreamingAudioSegment] = []

    // Absolute sample offset of the last cut (= first sample not yet part of an
    // emitted segment, lead-ins aside).
    private var lastCut = 0

    // Absolute start of the NEXT segment's lead-in. After a silence-aligned cut
    // this reaches back only through silence (capped at overlapSeconds); after a
    // fixed cut it reaches overlapSeconds into re-sent speech.
    private var nextSegmentStart = 0

    // Whether the NEXT segment's lead-in re-sends speech (fixed cut) rather than
    // being silence-only (pause cut) or absent (recording start). Set together
    // with `nextSegmentStart` and carried onto the emitted segment so the
    // stitcher only dedupes overlap that is actually re-decoded speech.
    private var nextSegmentHasSpeechOverlap = false

    // Consecutive silent frames ending at the classification frontier.
    private var trailingSilentFrames = 0

    private let frameLen: Int
    private let minSegmentSamples: Int
    private let maxSegmentSamples: Int
    private let overlapSamples: Int
    private let minSilenceFrames: Int

    init(options: StreamingSegmenterOptions = .default, silenceClassifier: SilenceClassifier? = nil) {
        precondition(options.sampleRate > 0, "SampleRate must be positive.")
        self.options = options
        self.isSilent = silenceClassifier
            ?? StreamingSegmenter.makeEnergyClassifier(thresholdDbfs: options.silenceThresholdDbfs)

        frameLen = max(1, Int(options.frameSeconds * Double(options.sampleRate)))
        minSegmentSamples = Int(options.minSegmentSeconds * Double(options.sampleRate))
        maxSegmentSamples = Int(options.maxSegmentSeconds * Double(options.sampleRate))
        overlapSamples = Int(options.overlapSeconds * Double(options.sampleRate))
        minSilenceFrames = max(1, Int((options.minSilenceSeconds / options.frameSeconds).rounded(.toNearestOrEven)))
    }

    /// Total samples appended so far (for end-of-recording sanity checks).
    var totalSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Absolute offset of the last cut - audio after it is not yet in any
    /// emitted segment.
    var cursor: Int {
        lock.lock()
        defer { lock.unlock() }
        return lastCut
    }

    /// Append live PCM. Called on the capture thread. Cut detection runs here
    /// (segments queue up for the worker), so segmentation is deterministic for
    /// a given audio stream.
    func append<C: Collection>(_ samples: C) where C.Element == Float {
        if samples.isEmpty { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        classifyAndCutLocked()
    }

    /// Dequeue the next ready segment, if any.
    func tryTakeSegment() -> StreamingAudioSegment? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty { return nil }
        return pending.removeFirst()
    }

    /// Take everything after the last cut (plus lead-in) as the final tail
    /// segment. Returns `nil` when no audio remains past the last cut.
    /// `containsSpeech` is `false` when every frame past the cut is silent -
    /// callers can then skip the ASR call entirely (near-silent tails
    /// measurably hallucinate).
    func takeTail() -> StreamingAudioSegment? {
        lock.lock()
        defer { lock.unlock() }
        let total = buffer.count
        if total - lastCut <= 0 { return nil }

        let tail = buildSegmentLocked(end: total)
        lastCut = total
        nextSegmentStart = total
        return tail
    }

    // MARK: - Internals

    /// Classify newly complete frames and fire cuts. Two triggers, checked per
    /// frame in order:
    /// 1. A silence run crossing `minSilenceFrames` → cut in the middle of that
    ///    run-so-far (≈ minSilence/2 into the pause: enough trailing quiet for
    ///    the segment, and the pause's remainder becomes the next segment's
    ///    silence-only lead-in). Skipped when the cut would land closer than
    ///    minSegment to the previous cut.
    /// 2. `maxSegmentSamples` since the last cut without a pause → fixed
    ///    mid-speech cut at exactly maxSegment.
    private func classifyAndCutLocked() {
        let completeFrames = buffer.count / frameLen
        for f in silentFrames.count ..< completeFrames {
            let frameStart = f * frameLen
            let frame = buffer[frameStart ..< frameStart + frameLen]
            let silent = isSilent(frame)
            silentFrames.append(silent)
            trailingSilentFrames = silent ? trailingSilentFrames + 1 : 0

            let frontier = (f + 1) * frameLen // classified samples so far

            if silent && trailingSilentFrames == minSilenceFrames {
                let runStart = frontier - minSilenceFrames * frameLen
                let cut = runStart + (minSilenceFrames * frameLen) / 2
                if cut - lastCut >= minSegmentSamples {
                    // Silence-aligned cut: the next lead-in stays inside the
                    // pause - it must never re-enter speech, or the next segment
                    // starts on a clipped word onset. Silence-only lead-in means
                    // no re-decoded speech, so the next segment must not dedupe.
                    emitLocked(
                        cut: cut,
                        nextStart: max(runStart, cut - overlapSamples),
                        nextHasSpeechOverlap: false)
                    continue
                }
            }

            if frontier - lastCut >= maxSegmentSamples {
                // No qualifying pause for maxSegment - fixed mid-speech cut with
                // the full speech overlap as the stitcher's safety net.
                let cut = lastCut + maxSegmentSamples
                emitLocked(cut: cut, nextStart: cut - overlapSamples, nextHasSpeechOverlap: true)
            }
        }
    }

    private func emitLocked(cut: Int, nextStart: Int, nextHasSpeechOverlap: Bool) {
        pending.append(buildSegmentLocked(end: cut))
        lastCut = cut
        nextSegmentStart = nextStart
        nextSegmentHasSpeechOverlap = nextHasSpeechOverlap
    }

    private func buildSegmentLocked(end: Int) -> StreamingAudioSegment {
        // Lead-in decided when the PREVIOUS cut fired (silence-only after a
        // pause cut, full overlap after a fixed cut); clamped so a degenerate
        // state can never produce a negative-length segment. `hasSpeechOverlap`
        // was decided by the same previous cut, alongside `nextSegmentStart`.
        let start = min(max(nextSegmentStart, 0), lastCut)
        let samples = Array(buffer[start ..< end])

        return StreamingAudioSegment(
            samples: samples,
            startSample: start,
            endSample: end,
            containsSpeech: spanContainsSpeechLocked(from: lastCut, to: end),
            hasSpeechOverlap: nextSegmentHasSpeechOverlap)
    }

    /// `true` when any classified frame overlapping `[from, to)` is non-silent,
    /// or when a trailing partial frame (never classified) is non-silent by a
    /// direct check. Errs toward `true` so real speech is never dropped.
    private func spanContainsSpeechLocked(from: Int, to: Int) -> Bool {
        let firstFrame = from / frameLen
        let lastCompleteFrame = min(silentFrames.count, to / frameLen)
        var f = firstFrame
        while f < lastCompleteFrame {
            if !silentFrames[f] { return true }
            f += 1
        }

        // Trailing partial frame (or span shorter than one frame).
        let partialStart = max(from, lastCompleteFrame * frameLen)
        if partialStart < to {
            let partial = buffer[partialStart ..< to]
            if !isSilent(partial) { return true }
        }
        return false
    }

    /// RMS-energy silence check against `silenceThresholdDbfs`.
    private static func makeEnergyClassifier(thresholdDbfs: Double) -> SilenceClassifier {
        return { frame in
            if frame.isEmpty { return true }
            var sumSq = 0.0
            for s in frame {
                sumSq += Double(s) * Double(s)
            }
            let rms = (sumSq / Double(frame.count)).squareRoot()
            let dbfs = 20.0 * log10(max(rms, 1e-9))
            return dbfs < thresholdDbfs
        }
    }
}
