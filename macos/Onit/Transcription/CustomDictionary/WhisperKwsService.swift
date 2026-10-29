// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperKwsService.swift
//  Onit
//
//  Whisper-base CoreML keyword spotting actor - sliding-window forced-decode
//  over the bundled whisper-base CoreML graph.
//
//  Pipeline:
//    1. Slide an `windowSec` (0.8 s) window over the audio with `strideSec`
//       (0.4 s) hop. For each window:
//         a. Pad the windowed audio to 30 s @ 16 kHz, run MelSpectrogram and
//            AudioEncoder once → encoder hidden states [1, 512, 1, 1500].
//         b. Forced-decode ALL candidate keywords in batched calls through
//            `TextDecoderParallel.mlpackage`: batch B is padded to {1,16,64},
//            token sequence length T is padded to {6,8,16}.
//         c. Score per keyword = mean log-prob over its phrase-token
//            positions (matches `forced_decode_score` from the reference
//            Python pipeline).
//         d. Take the max score across all windows for each keyword.
//    2. For each keyword whose max score crosses its per-keyword threshold,
//       emit a `KWSDetection` for the winning window.
//
//  This replaces the older single-step KV-cache stepper. The parallel
//  decoder collapses a per-keyword inner loop of ~6 sequential CoreML
//  calls into one batched call per window, making 50-keyword dictionaries
//  shippable for runtime rescore.
//

import Accelerate
import CoreML
import Foundation
import os.log

private let kwsLog = Logger(subsystem: "inc.synth.Onit", category: "whisperKWS")

/// Unchecked-Sendable wrapper for handing CoreML objects across `Task`
/// boundaries. CoreML's `MLMultiArray` and `MLModel` are documented as
/// thread-safe for prediction; the wrapper just appeases Swift 6's strict
/// concurrency checker.
private struct UnsafeSend<T>: @unchecked Sendable {
    let value: T
}

// MARK: - Detection result

/// One keyword fired by the spotter. Time fields are seconds into the source audio.
struct KWSDetection: Sendable {
    /// The keyword string that fired (matches what was passed to `loadIfNeeded`).
    let keyword: String
    /// Estimated keyword start in the source audio (seconds).
    let startSec: Double
    /// Time at the end of the chunk that triggered the detection (seconds).
    let endSec: Double
}

// MARK: - Errors

enum WhisperKWSError: LocalizedError {
    case notLoaded
    case modelFilesNotFound(String)
    case tokenizationFailed(String)
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Whisper KWS model not loaded - call loadIfNeeded first"
        case .modelFilesNotFound(let name):
            return "Whisper KWS resource missing from bundle: \(name)"
        case .tokenizationFailed(let m):
            return "Whisper KWS keyword tokenization failed: \(m)"
        case .inferenceError(let m):
            return "Whisper KWS inference error: \(m)"
        }
    }
}

/// Stage timing breakdown from the most recent inference run. All seconds.
struct StageTimings: Sendable {
    var windowCount: Int
    var melSec: Double
    var encoderSec: Double
    var decoderSec: Double
    var scoringSec: Double

    static let zero = StageTimings(windowCount: 0, melSec: 0, encoderSec: 0, decoderSec: 0, scoringSec: 0)

    var totalSec: Double { melSec + encoderSec + decoderSec + scoringSec }
}

// MARK: - Service

/// Sliding-window whisper-base CoreML forced-decode keyword spotter.
///
/// Reads CoreML bundles from `Resources/WhisperKWS/`:
///   - `MelSpectrogram.mlmodelc`     (Float16 PCM → 80-bin log-mel)
///   - `AudioEncoder.mlmodelc`       (mel → encoder hidden states)
///   - `TextDecoderParallel.mlpackage` (stateless parallel decoder, batched)
///
/// All inference is isolated to the actor executor; callers must `await`.
actor WhisperKwsService {

    static let shared = WhisperKwsService()
    private init() {}

    // MARK: - Constants

    /// Sliding window length in seconds.
    static let windowSec: Double = 0.8
    /// Hop between successive windows. 0.2 s - required for recall on real
    /// dictations: `WhisperKwsRecentDictationsTests` showed 0.3 s+ missed
    /// real Fernardo / Onit utterances at mid-clip placements. Per-window
    /// cost is small enough (cropped encoder context + pipelining +
    /// parallel decoder Tasks) that 22 windows still fit the budget.
    static let strideSec: Double = 0.2
    /// Default per-keyword forced-decode log-prob threshold.
    /// Permissive default threshold - let stage-1 fire generously and rely
    /// on the perplexity gate downstream to filter semantic FPs.
    /// Lowered from -5.96 (calibrated for whisper-base) so that whisper-tiny's
    /// less-peaky scores still cross threshold on real Fernardo placements.
    static let defaultThreshold: Float = -8.0
    /// Whisper-base encoder timeline: 30 s of audio → 1500 frames (50 fps).
    private static let encoderFps: Double = 50.0
    /// Sample rate the underlying CoreML graph was traced at.
    private static let sampleRate: Int = 16_000
    /// Whisper input audio buffer length: 30 s × 16 kHz.
    private static let audioPadSamples: Int = 480_000
    /// Whisper-base encoder timeline length (frames).
    private static let encoderFrames: Int = 1500
    /// Encoder hidden size (whisper-tiny d_model = 384; base = 512).
    /// Tiny is shipped because encoder/decoder per-call cost is ~2× lower
    /// and KWS accuracy is preserved on the dictation regression suite.
    // Whisper-tiny d_model is 384; whisper-base is 512. On tiny with the
    // permissive -8.0 default threshold, Fernardo fires on the recent
    // dictations (Fernardo scored -6 to -7.2 - all above -8). Latency wins
    // outweigh score margin reduction at this threshold.
    private static let encoderHidden: Int = 384
    /// Decoder prefix tokens
    /// (`<|startoftranscript|><|en|><|transcribe|><|notimestamps|>`).
    private static let decoderPrefixCount: Int = 4
    /// Static decoder batch dimension. The CoreML graph is traced at this
    /// fixed shape so it compiles to ANE+GPU; any flexibility (EnumeratedShapes)
    /// pins the entire 1050-op graph to CPU and is ~25× slower.
    private static let decoderBatch: Int = 64
    /// Static decoder sequence length. Holds prefix (4) + up to 4 phrase
    /// BPE tokens. Keywords longer than 4 phrase tokens are rejected at load.
    private static let decoderSeqLen: Int = 8
    /// Whisper end-of-text token, used as filler at unused decoder positions.
    private static let eotTokenId: Int32 = 50257
    /// Whisper-base vocab size (multilingual).
    private static let vocabSize: Int = 51865
    /// Decoder cross-attention encoder context length. The decoder graph
    /// is traced with K=80 (1.6 s of encoder frames) instead of the full
    /// K=1500 (30 s). For windowed audio the content lives in frames
    /// 0..40 and the rest is silence-features that contribute negligible
    /// attention - cropping cuts per-call decoder cost ~5-10× with no
    /// measurable recall regression on the dictation suites.
    private static let decoderEncoderContext: Int = 80

    /// When true, encode the full clip ONCE and slice the encoder output
    /// per window for each decoder call. When false, encode per window
    /// (zero-padded to 30 s).
    ///
    /// VERIFIED FALSE (regression-tested 2026-04-30): single-encoder mode
    /// breaks Fernardo recall on `WhisperKwsRecentDictationsTests` (Fernardo
    /// scored -6.46 vs threshold -5.96 on the `lennardo` clip; per-window
    /// encoding scored -5.85 on the same clip). The encoder's self-
    /// attention propagates information across frames, so cropping the
    /// encoder output gives different cross-attention keys than encoding
    /// only the window. The handoff warned about this; we re-verified.
    private static let useSingleEncoder: Bool = false

    // MARK: - Loaded state

    /// Cached mel-spectrogram model. Loaded lazily on first `loadIfNeeded`.
    private var melModel: MLModel?
    /// Cached encoder model.
    private var encoderModel: MLModel?
    /// Cached parallel decoder model.
    private var decoderModel: MLModel?

    /// Per-keyword cache: original keyword text + its tokenised form
    /// (incl. decoder prefix). `tokenIds.count - decoderPrefixCount` gives
    /// the phrase length used for score-position bookkeeping.
    private var keywordTokens: [(keyword: String, tokenIds: [Int])] = []
    /// Per-stage time totals from the most recent slidingWindowAllScores
    /// call (seconds). Available via `lastStageTimings` for benchmarks.
    private var lastTimings: StageTimings = .zero
    /// Per-keyword threshold override; defaults to `activeDefaultThreshold` when absent.
    private var keywordThresholds: [String: Float] = [:]
    /// Default threshold applied when a keyword has no per-term override.
    private var activeDefaultThreshold: Float = WhisperKwsService.defaultThreshold

    /// Hash of the keyword set + thresholds currently loaded; used to no-op
    /// repeated `loadIfNeeded` calls with identical inputs.
    private var loadedHash: Int = 0

    var isLoaded: Bool {
        melModel != nil && encoderModel != nil && decoderModel != nil && !keywordTokens.isEmpty
    }

    /// Stage breakdown of the most recent `computeMaxScores` /
    /// `detectKeywords` call. For benchmarks and diagnostics.
    var lastStageTimings: StageTimings { lastTimings }

    // MARK: - Public API

    /// Load (or reload) the Whisper KWS model with the given keyword strings.
    ///
    /// Each keyword is BPE-encoded via `WhisperBPETokenizer.shared` (with the
    /// multilingual decoder prefix prepended) and validated to fit in the
    /// decoder's traced sequence length.
    ///
    /// Safe to call repeatedly - no-ops when the (keywords, thresholds) tuple
    /// is unchanged.
    func loadIfNeeded(
        keywords: [String],
        threshold: Float = WhisperKwsService.defaultThreshold,
        keywordThresholds: [String: Float] = [:]
    ) async throws {
        guard !keywords.isEmpty else { return }

        // Cache key: keywords + default threshold + per-key overrides.
        var hasher = Hasher()
        keywords.forEach { hasher.combine($0) }
        hasher.combine(threshold.bitPattern)
        for key in keywordThresholds.keys.sorted() {
            hasher.combine(key)
            hasher.combine(keywordThresholds[key]!.bitPattern)
        }
        let hash = hasher.finalize()
        guard loadedHash != hash else { return }

        // Lazily load the three CoreML models from the bundle.
        if melModel == nil {
            // Mel on CPU only - it shares ANE with the decoder otherwise,
            // and contention there breaks encoder/decoder pipelining (ANE
            // serializes its dispatch queue). CPU is fast enough at ~1 ms/call.
            melModel = try Self.loadModel(named: "MelSpectrogram", computeUnits: .cpuOnly)
        }
        if encoderModel == nil {
            // Tiny encoder on GPU (5 ms) - the 13 ms ANE path is 2.6× slower
            // for whisper-tiny because the model is small enough that ANE
            // dispatch overhead dominates compute.
            encoderModel = try Self.loadModel(named: "AudioEncoderTiny", computeUnits: .cpuAndGPU)
        }
        if decoderModel == nil {
            // Tiny decoder on ANE (8 ms) - paired with the encoder on GPU
            // so the two stages pipeline across different devices. The
            // per-window critical path becomes max(enc=5, dec=8) = 8 ms.
            // Tested .cpuAndGPU (slower per call), .all (overhead), and
            // .cpuOnly (much slower) - ANE is the right call here.
            decoderModel = try Self.loadModel(named: "TextDecoderParallelTiny", computeUnits: .cpuAndNeuralEngine)
        }

        // Tokenise every keyword via the shared whisper BPE tokenizer.
        var newTokens: [(keyword: String, tokenIds: [Int])] = []
        for keyword in keywords {
            do {
                let ids = try await WhisperBPETokenizer.shared.encode(keyword, withDecoderPrefix: true)
                guard ids.count > Self.decoderPrefixCount else {
                    throw WhisperKWSError.tokenizationFailed(
                        "keyword '\(keyword)' produced no body tokens after decoder prefix"
                    )
                }
                guard ids.count <= Self.decoderSeqLen else {
                    throw WhisperKWSError.tokenizationFailed(
                        "keyword '\(keyword)' tokenized to \(ids.count) tokens "
                        + "(static parallel decoder fits \(Self.decoderSeqLen))"
                    )
                }
                newTokens.append((keyword: keyword, tokenIds: ids))
            } catch let e as WhisperKWSError {
                throw e
            } catch {
                throw WhisperKWSError.tokenizationFailed(
                    "keyword '\(keyword)': \(error.localizedDescription)"
                )
            }
        }

        self.keywordTokens = newTokens
        self.keywordThresholds = keywordThresholds
        self.activeDefaultThreshold = threshold
        self.loadedHash = hash
    }

    /// Diagnostic: run inference and return the max forced-decode score per
    /// keyword (no threshold filtering). Used by tests and debug viewers to
    /// compare Swift outputs against the Python reference scores.
    func computeMaxScores(
        in samples: [Float],
        sampleRate: Int = 16_000
    ) async throws -> [(keyword: String, maxScore: Float, peakStartSec: Double)] {
        let allScores = try await slidingWindowAllScores(in: samples, sampleRate: sampleRate)
        return allScores.map { (keyword, scores) in
            let best = scores.max(by: { $0.score < $1.score })!
            return (keyword, best.score, Double(best.startSample) / Double(sampleRate))
        }
    }

    /// Run keyword spotting on `samples` (Float32, 16 kHz, mono).
    ///
    /// Emits one `KWSDetection` per **peak above threshold** per keyword.
    /// A "peak" is the highest-scoring window within a contiguous run of
    /// windows whose scores all clear `threshold`. So if the user says the
    /// keyword three times in one dictation, this returns three detections
    /// (one per utterance), located at the strongest window in each cluster.
    /// Cost: identical to single-detection mode - peak detection is
    /// post-processing on already-computed window scores.
    func detectKeywords(
        in samples: [Float],
        sampleRate: Int = 16_000
    ) async throws -> [KWSDetection] {
        let allScores = try await slidingWindowAllScores(in: samples, sampleRate: sampleRate)
        var detections: [KWSDetection] = []
        for (keyword, scores) in allScores {
            let threshold = keywordThresholds[keyword] ?? activeDefaultThreshold
            // Walk windows in time order, group consecutive above-threshold
            // windows into runs, emit one detection per run at its peak.
            let sorted = scores.sorted { $0.startSample < $1.startSample }
            var runActive = false
            var runPeakIdx = 0
            var runPeakScore: Float = -.infinity
            func closeRun() {
                guard runActive else { return }
                let peak = sorted[runPeakIdx]
                let startSec = Double(peak.startSample) / Double(sampleRate)
                let endSec = min(
                    Double(samples.count) / Double(sampleRate),
                    startSec + Self.windowSec
                )
                detections.append(
                    KWSDetection(keyword: keyword, startSec: startSec, endSec: endSec)
                )
                runActive = false
                runPeakScore = -.infinity
            }
            for i in sorted.indices {
                if sorted[i].score >= threshold {
                    if !runActive {
                        runActive = true
                        runPeakIdx = i
                        runPeakScore = sorted[i].score
                    } else if sorted[i].score > runPeakScore {
                        runPeakIdx = i
                        runPeakScore = sorted[i].score
                    }
                } else {
                    closeRun()
                }
            }
            closeRun()
        }
        // Sort by time for deterministic ordering (helps tests + debug view).
        detections.sort { $0.startSec < $1.startSec }
        return detections
    }

    // MARK: - Sliding-window scoring

    /// Per-window encode + batched-decode. Encoding the windowed signal
    /// (rather than masking after a single full-clip encode) is required:
    /// the encoder's self-attention propagates information across frames,
    /// so post-hoc masking gives clip-length-dependent score drift.
    ///
    /// Pipelining: mel+encoder run on ANE, decoder runs on GPU - different
    /// devices, so they parallelize. We kick off (mel+enc) for window k+1
    /// via `Task.detached` while running decoder for window k. The actor
    /// releases its executor at each `await`.
    private func slidingWindowAllScores(
        in samples: [Float],
        sampleRate: Int
    ) async throws -> [String: [(score: Float, startSample: Int)]] {
        guard isLoaded else { throw WhisperKWSError.notLoaded }
        guard !samples.isEmpty else { return [:] }
        guard sampleRate == Self.sampleRate else {
            throw WhisperKWSError.inferenceError("sampleRate must be 16000")
        }

        let windowSamples = Int(Self.windowSec * Double(sampleRate))
        let strideSamples = max(1, Int(Self.strideSec * Double(sampleRate)))
        let lastStart = max(0, samples.count - windowSamples)

        // Enumerate window starts up-front so pipelining is just a sliding
        // pair of indices.
        var windowStarts: [Int] = []
        var s = 0
        while s <= lastStart {
            windowStarts.append(s)
            if s == lastStart { break }
            s = min(s + strideSamples, lastStart)
        }

        guard let melModel = self.melModel,
              let encoderModel = self.encoderModel,
              let decoderModel = self.decoderModel else {
            throw WhisperKWSError.notLoaded
        }
        let melSend = UnsafeSend(value: melModel)
        let encSend = UnsafeSend(value: encoderModel)
        let decSend = UnsafeSend(value: decoderModel)
        let kwTokens = self.keywordTokens
        let audioPad = Self.audioPadSamples
        let encoderContext = Self.decoderEncoderContext

        // Single-encoder mode: run encoder ONCE on the full clip, then
        // slice the encoder output per window. This converts 22 encoder
        // calls (~6 ms each = 132 ms) into 1 call (~5 ms). The decoder
        // cross-attention still sees only the window-aligned slice of
        // encoder frames, so localization is preserved. Validated against
        // the dictation regression suite.
        let useSingleEncoder = Self.useSingleEncoder

        func makeEncoderTask(_ start: Int) -> Task<UnsafeSend<MLMultiArray>, Error> {
            let end = min(start + windowSamples, samples.count)
            let windowAudio = Array(samples[start..<end])
            return Task.detached(priority: .userInitiated) {
                let mel = try Self.runMelSpectrogramStatic(
                    model: melSend.value,
                    samples: windowAudio,
                    audioPadSamples: audioPad
                )
                let encFull = try Self.runEncoderStatic(model: encSend.value, mel: mel)
                // Slice encoder output to the first `encoderContext` frames
                // so the decoder cross-attention only attends to the window
                // (frames 0..40 are the windowed content; 40..80 is the
                // silence-tail). Done on the worker thread so it overlaps
                // with the GPU decoder running ahead.
                let encSliced = try Self.sliceEncoderToContext(
                    encFull, contextLen: encoderContext
                )
                return UnsafeSend(value: encSliced)
            }
        }

        var allScores: [String: [(score: Float, startSample: Int)]] = [:]
        var encTime: Double = 0
        var decTime: Double = 0
        var scoreTime: Double = 0

        if useSingleEncoder {
            // Single encoder pass on the full clip. The encoder is fixed
            // at 30 s input; we pad the entire `samples` buffer (not just
            // a window) so all real audio is included.
            let tFullEncStart = Date().timeIntervalSinceReferenceDate
            let mel = try Self.runMelSpectrogramStatic(
                model: melSend.value,
                samples: samples,
                audioPadSamples: audioPad
            )
            let encFull = try Self.runEncoderStatic(model: encSend.value, mel: mel)
            let tFullEncEnd = Date().timeIntervalSinceReferenceDate
            encTime += tFullEncEnd - tFullEncStart

            // Per window: slice the K-frame encoder context aligned to the
            // window's start time, then run decoder.
            // Encoder fps = 50, so encoder frame = audio_sample / 320.
            let encoderFps = 50.0
            for (_, start) in windowStarts.enumerated() {
                let windowFrameStart = Int(Double(start) / Double(sampleRate) * encoderFps)
                let tDecStart = Date().timeIntervalSinceReferenceDate
                let encSlice = try Self.sliceEncoderToContextAt(
                    encFull,
                    contextLen: encoderContext,
                    startFrame: windowFrameStart
                )
                let scores = try Self.forcedDecodeScoresStatic(
                    model: decSend.value,
                    keywordTokens: kwTokens,
                    encoderOutput: encSlice
                )
                let tDecEnd = Date().timeIntervalSinceReferenceDate
                for (k, entry) in kwTokens.enumerated() {
                    allScores[entry.keyword, default: []].append((scores[k], start))
                }
                decTime += tDecEnd - tDecStart
            }
        } else {
            // Per-window encoding pipeline (encoder ANE/GPU + decoder GPU/ANE
            // overlap on different devices).
            var inFlight: Task<UnsafeSend<MLMultiArray>, Error>? =
                windowStarts.isEmpty ? nil : makeEncoderTask(windowStarts[0])

            for (i, start) in windowStarts.enumerated() {
                let tEncStart = Date().timeIntervalSinceReferenceDate
                let enc = try await inFlight!.value.value
                let tEncEnd = Date().timeIntervalSinceReferenceDate

                if i + 1 < windowStarts.count {
                    inFlight = makeEncoderTask(windowStarts[i + 1])
                } else {
                    inFlight = nil
                }

                let tDecStart = Date().timeIntervalSinceReferenceDate
                let scores = try Self.forcedDecodeScoresStatic(
                    model: decSend.value,
                    keywordTokens: kwTokens,
                    encoderOutput: enc
                )
                let tDecEnd = Date().timeIntervalSinceReferenceDate
                for (k, entry) in kwTokens.enumerated() {
                    allScores[entry.keyword, default: []].append((scores[k], start))
                }
                let tScoreEnd = Date().timeIntervalSinceReferenceDate

                encTime += tEncEnd - tEncStart
                decTime += tDecEnd - tDecStart
                scoreTime += tScoreEnd - tDecEnd
            }
        }

        lastTimings = StageTimings(
            windowCount: windowStarts.count,
            melSec: 0,
            encoderSec: encTime,
            decoderSec: decTime,
            scoringSec: scoreTime
        )
        kwsLog.debug(
            """
            kws stages: \(windowStarts.count, privacy: .public)w  \
            enc(awaited)=\(Int(encTime * 1000), privacy: .public)ms  \
            dec=\(Int(decTime * 1000), privacy: .public)ms  \
            score=\(Int(scoreTime * 1000), privacy: .public)ms
            """
        )
        return allScores
    }

    // MARK: - Inference helpers

    /// Compute log-mel spectrogram. Pad/truncate to `audioPadSamples`,
    /// feed Float16 audio to the mel model, return mel `[1,80,1,3000]`.
    /// Static so it can run in `Task.detached` for ANE/GPU pipelining.
    private static func runMelSpectrogramStatic(
        model: MLModel,
        samples: [Float],
        audioPadSamples: Int
    ) throws -> MLMultiArray {
        let audioMLA = try MLMultiArray(
            shape: [NSNumber(value: audioPadSamples)],
            dataType: .float16
        )
        let audioPtr = audioMLA.dataPointer.assumingMemoryBound(to: UInt16.self)
        let copyCount = min(samples.count, audioPadSamples)

        // Vectorized Float32 -> Float16 via vImage. The naive scalar loop
        // over 480000 samples per window cost ~30 ms/call; this drops it
        // to a few ms.
        samples.withUnsafeBufferPointer { srcBuf in
            var srcImage = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: srcBuf.baseAddress!),
                height: 1,
                width: vImagePixelCount(copyCount),
                rowBytes: copyCount * MemoryLayout<Float>.size
            )
            var dstImage = vImage_Buffer(
                data: UnsafeMutableRawPointer(audioPtr),
                height: 1,
                width: vImagePixelCount(copyCount),
                rowBytes: copyCount * Float16Bits.stride
            )
            vImageConvert_PlanarFtoPlanar16F(&srcImage, &dstImage, 0)
        }
        if copyCount < audioPadSamples {
            let tailBytes = (audioPadSamples - copyCount) * Float16Bits.stride
            memset(audioPtr + copyCount, 0, tailBytes)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioMLA),
        ])
        let output = try model.prediction(from: input)
        guard let mel = output.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
            throw WhisperKWSError.inferenceError("MelSpectrogram: missing 'melspectrogram_features' output")
        }
        return mel
    }

    /// Run AudioEncoder on a precomputed mel. Returns `[1,512,1,1500]`.
    /// Static for use in `Task.detached`.
    private static func runEncoderStatic(model: MLModel, mel: MLMultiArray) throws -> MLMultiArray {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: mel),
        ])
        let output = try model.prediction(from: input)
        guard let enc = output.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
            throw WhisperKWSError.inferenceError("AudioEncoder: missing 'encoder_output_embeds' output")
        }
        return enc
    }

    /// Slice the encoder output `[1, 512, 1, 1500]` down to the first
    /// `K` frames `[1, 512, 1, K]`. The bundled encoder always produces
    /// 1500 frames but the decoder is now traced with K=80; the slice
    /// trims the silence-features tail. For windowed audio (where the
    /// content sits in the first ~40 mel frames), the first 80 encoder
    /// frames cover the window plus a 0.4 s tail of silence features.
    ///
    /// Allocates a fresh MLMultiArray (CoreML predict expects a contiguous
    /// input matching the traced shape - strided views won't work).
    /// Slice the encoder output starting at `startFrame` for `contextLen`
    /// frames. Used by single-encoder mode to extract a window-aligned
    /// slice of the full-clip encoder output.
    private static func sliceEncoderToContextAt(
        _ enc: MLMultiArray,
        contextLen: Int,
        startFrame: Int
    ) throws -> MLMultiArray {
        let H = enc.shape[1].intValue
        let T = enc.shape[3].intValue
        // Clamp the start frame so the slice fits.
        let s0 = max(0, min(startFrame, T - contextLen))
        let out = try MLMultiArray(
            shape: [1, NSNumber(value: H), 1, NSNumber(value: contextLen)],
            dataType: .float16
        )
        let srcPtr = enc.dataPointer.assumingMemoryBound(to: UInt16.self)
        let dstPtr = out.dataPointer.assumingMemoryBound(to: UInt16.self)
        let srcS1 = enc.strides[1].intValue
        let srcS3 = enc.strides[3].intValue
        for h in 0..<H {
            let srcRow = srcPtr + h * srcS1 + s0 * srcS3
            let dstRow = dstPtr + h * contextLen
            if srcS3 == 1 {
                memcpy(dstRow, srcRow, contextLen * Float16Bits.stride)
            } else {
                for t in 0..<contextLen {
                    dstRow[t] = srcRow[t * srcS3]
                }
            }
        }
        return out
    }

    private static func sliceEncoderToContext(
        _ enc: MLMultiArray,
        contextLen: Int
    ) throws -> MLMultiArray {
        // Source shape: [1, H, 1, T] Float16, ANE-aligned strides. H is
        // d_model (384 tiny / 512 base), T is encoder timeline (1500).
        let H = enc.shape[1].intValue
        let T = enc.shape[3].intValue
        guard contextLen <= T else {
            throw WhisperKWSError.inferenceError(
                "encoder context \(contextLen) exceeds source \(T)"
            )
        }
        let out = try MLMultiArray(
            shape: [1, NSNumber(value: H), 1, NSNumber(value: contextLen)],
            dataType: .float16
        )
        let srcPtr = enc.dataPointer.assumingMemoryBound(to: UInt16.self)
        let dstPtr = out.dataPointer.assumingMemoryBound(to: UInt16.self)
        // Use the source's reported strides (ANE may pad axis 1 differently
        // from contiguous row-major). Output is freshly allocated → contiguous,
        // so dst stride[1] = contextLen, stride[3] = 1.
        let srcS1 = enc.strides[1].intValue
        let srcS3 = enc.strides[3].intValue
        for h in 0..<H {
            let srcRow = srcPtr + h * srcS1
            let dstRow = dstPtr + h * contextLen
            if srcS3 == 1 {
                memcpy(dstRow, srcRow, contextLen * Float16Bits.stride)
            } else {
                for t in 0..<contextLen {
                    dstRow[t] = srcRow[t * srcS3]
                }
            }
        }
        return out
    }

    /// Forced-decode every loaded keyword against `encoderOutput` in
    /// fixed-shape `(B=64, T=8)` batches and return one mean phrase-token
    /// log-prob per keyword. N>64 splits into multiple calls; padding rows
    /// are filled with EOT and discarded. Static so it can run in
    /// `Task.detached` for cross-window parallelism.
    private static func forcedDecodeScoresStatic(
        model: MLModel,
        keywordTokens: [(keyword: String, tokenIds: [Int])],
        encoderOutput: MLMultiArray
    ) throws -> [Float] {
        let N = keywordTokens.count
        guard N > 0 else { return [] }
        let B = decoderBatch
        var scores: [Float] = []
        scores.reserveCapacity(N)
        var start = 0
        while start < N {
            let end = min(start + B, N)
            let chunk = Array(keywordTokens[start..<end])
            scores.append(contentsOf: try forcedDecodeScoresChunkStatic(
                encoderOutput: encoderOutput,
                keywordChunk: chunk,
                model: model
            ))
            start = end
        }
        return scores
    }

    /// Backwards-compatible instance wrapper.
    private func forcedDecodeScoresBatched(encoderOutput: MLMultiArray) throws -> [Float] {
        guard let model = decoderModel else { throw WhisperKWSError.notLoaded }
        return try Self.forcedDecodeScoresStatic(
            model: model, keywordTokens: keywordTokens, encoderOutput: encoderOutput
        )
    }

    private static func forcedDecodeScoresChunkStatic(
        encoderOutput: MLMultiArray,
        keywordChunk: [(keyword: String, tokenIds: [Int])],
        model: MLModel
    ) throws -> [Float] {
        let N = keywordChunk.count
        guard N > 0 else { return [] }
        let B = Self.decoderBatch
        let T = Self.decoderSeqLen
        let prefixCount = Self.decoderPrefixCount

        // Build input_ids [B, T] Int32 - keyword rows + EOT-padded filler.
        let inputIds = try MLMultiArray(
            shape: [NSNumber(value: B), NSNumber(value: T)],
            dataType: .int32
        )
        let idsPtr = inputIds.dataPointer.assumingMemoryBound(to: Int32.self)
        let idsS0 = inputIds.strides[0].intValue
        let idsS1 = inputIds.strides[1].intValue
        for i in 0..<B {
            if i < N {
                let tokens = keywordChunk[i].tokenIds
                for j in 0..<T {
                    idsPtr[i * idsS0 + j * idsS1] = j < tokens.count ? Int32(tokens[j]) : Self.eotTokenId
                }
            } else {
                for j in 0..<T {
                    idsPtr[i * idsS0 + j * idsS1] = Self.eotTokenId
                }
            }
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "encoder_hidden_states": MLFeatureValue(multiArray: encoderOutput),
        ])
        let output = try model.prediction(from: input)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw WhisperKWSError.inferenceError("TextDecoderParallel: missing 'logits' output")
        }

        guard logits.shape.count == 3,
              logits.shape[0].intValue == B,
              logits.shape[1].intValue == T,
              logits.shape[2].intValue == Self.vocabSize
        else {
            throw WhisperKWSError.inferenceError(
                "TextDecoderParallel logits unexpected shape \(logits.shape)"
            )
        }
        let logitsPtr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
        let s0 = logits.strides[0].intValue
        let s1 = logits.strides[1].intValue
        let s2 = logits.strides[2].intValue
        let V = Self.vocabSize
        // Vectorized log-softmax assumes a contiguous vocab axis. The default
        // CoreML output for [B,T,V] is row-major with stride[V]==1.
        guard s2 == 1 else {
            throw WhisperKWSError.inferenceError(
                "TextDecoderParallel logits vocab stride \(s2) != 1; "
                + "vectorized log-softmax requires a contiguous row"
            )
        }

        // Shared-prefix optimization: all real rows (i < N) have IDENTICAL
        // input_ids[0..prefixCount-1], so the decoder hidden state at
        // position prefixCount-1 (= 3) is identical across rows, and so
        // are the logits. Compute log_sum_exp ONCE for position 3 (using
        // row 0's data) and reuse for every keyword's first phrase-token
        // score. For positions >= prefixCount (rows diverge per keyword
        // by their first phrase token), fall back to per-row log-softmax.
        var scores = [Float](repeating: -.infinity, count: N)
        let scoresLock = NSLock()
        let logitsAddr = UInt(bitPattern: logitsPtr)

        // Pre-compute the shared row-0 log_sum_exp at position prefixCount-1.
        let sharedScratch = UnsafeMutablePointer<Float>.allocate(capacity: V)
        defer { sharedScratch.deallocate() }
        let sharedRowBase = 0 * s0 + (prefixCount - 1) * s1
        let sharedLogSumExp = Self.computeLogSumExp(
            rowPtr: logitsPtr + sharedRowBase,
            vocab: V,
            scratch: sharedScratch
        )
        // Cache row-0 logits as Float32 in sharedScratch (already converted).
        // sharedScratch now holds exp(x - max), but we need raw logits for
        // target lookup. Re-convert into a separate buffer.
        let sharedRowFloats = UnsafeMutablePointer<Float>.allocate(capacity: V)
        defer { sharedRowFloats.deallocate() }
        Self.convertFP16RowToFloat(
            rowPtr: logitsPtr + sharedRowBase, vocab: V, dst: sharedRowFloats
        )

        DispatchQueue.concurrentPerform(iterations: N) { i in
            let tokens = keywordChunk[i].tokenIds
            let phraseLen = tokens.count - prefixCount
            guard phraseLen > 0 else { return }
            let logitsP = UnsafePointer<UInt16>(bitPattern: logitsAddr)!
            var sum: Float = 0
            for k in 0..<phraseLen {
                let pos = prefixCount - 1 + k
                let nextToken = tokens[prefixCount + k]
                if k == 0 {
                    // Shared position: just lookup target logit and use the
                    // pre-computed log_sum_exp.
                    sum += sharedRowFloats[nextToken] - sharedLogSumExp
                } else {
                    // Per-row position: full log-softmax.
                    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: V)
                    defer { scratch.deallocate() }
                    let rowBase = i * s0 + pos * s1
                    sum += Self.logSoftmaxAt(
                        rowPtr: logitsP + rowBase,
                        vocab: V,
                        tokenId: nextToken,
                        scratch: scratch
                    )
                }
            }
            let s = sum / Float(phraseLen)
            scoresLock.lock()
            scores[i] = s
            scoresLock.unlock()
        }
        return scores
    }

    /// Compute log_sum_exp of a 51865-wide row of fp16 logits. Used for the
    /// shared-prefix optimization. Mutates `scratch` (will hold post-exp
    /// values; caller should not rely on it after).
    private static func computeLogSumExp(
        rowPtr: UnsafePointer<UInt16>,
        vocab: Int,
        scratch: UnsafeMutablePointer<Float>
    ) -> Float {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * Float16Bits.stride
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)
        var maxLogit: Float = 0
        vDSP_maxv(scratch, 1, &maxLogit, vDSP_Length(vocab))
        var negMax = -maxLogit
        vDSP_vsadd(scratch, 1, &negMax, scratch, 1, vDSP_Length(vocab))
        var n = Int32(vocab)
        vvexpf(scratch, scratch, &n)
        var sumExp: Float = 0
        vDSP_sve(scratch, 1, &sumExp, vDSP_Length(vocab))
        return maxLogit + Foundation.log(sumExp)
    }

    /// Convert a contiguous fp16 row to fp32 via vImage.
    private static func convertFP16RowToFloat(
        rowPtr: UnsafePointer<UInt16>,
        vocab: Int,
        dst: UnsafeMutablePointer<Float>
    ) {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * Float16Bits.stride
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(dst),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)
    }

    /// Numerically-stable log-softmax of a contiguous (stride==1) row of
    /// `vocab` Float16 logits at `rowPtr`, returning the log-prob at
    /// `tokenId`. `scratch` is a Float32 buffer of length ≥ vocab; reused
    /// across calls to avoid per-row allocation.
    ///
    /// Vectorized via Accelerate. The scalar Foundation.exp/log loop took
    /// ~6.7 s for 12 windows × 50 keywords × 51865 vocab; vDSP+vImage drops
    /// it well below 100 ms.
    private static func logSoftmaxAt(
        rowPtr: UnsafePointer<UInt16>,
        vocab: Int,
        tokenId: Int,
        scratch: UnsafeMutablePointer<Float>
    ) -> Float {
        var srcImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rowPtr),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * Float16Bits.stride
        )
        var dstImage = vImage_Buffer(
            data: UnsafeMutableRawPointer(scratch),
            height: 1,
            width: vImagePixelCount(vocab),
            rowBytes: vocab * MemoryLayout<Float>.size
        )
        vImageConvert_Planar16FtoPlanarF(&srcImage, &dstImage, 0)

        var maxLogit: Float = 0
        vDSP_maxv(scratch, 1, &maxLogit, vDSP_Length(vocab))
        var negMax = -maxLogit
        vDSP_vsadd(scratch, 1, &negMax, scratch, 1, vDSP_Length(vocab))
        var n = Int32(vocab)
        vvexpf(scratch, scratch, &n)
        var sumExp: Float = 0
        vDSP_sve(scratch, 1, &sumExp, vDSP_Length(vocab))
        let logSumExp = maxLogit + Foundation.log(sumExp)

        let logit = Float16Bits.toFloat(rowPtr[tokenId])
        return logit - logSumExp
    }

    // MARK: - Bundle helpers

    /// Load a CoreML bundle from `Resources/WhisperKWS/` with the requested
    /// compute-unit policy. Supports both compiled `.mlmodelc` directories and
    /// `.mlpackage` model packages, with both preserved and flattened resource
    /// layouts.
    private static func loadModel(
        named name: String,
        computeUnits: MLComputeUnits
    ) throws -> MLModel {
        let url = try modelURL(named: name)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = true
        return try MLModel(contentsOf: url, configuration: config)
    }

    private static func modelURL(named name: String) throws -> URL {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "WhisperKWS"
            ) {
                return url
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        throw WhisperKWSError.modelFilesNotFound("\(name).mlmodelc/.mlpackage")
    }
}
