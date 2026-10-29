// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ParakeetCoreMLASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

@preconcurrency import AVFoundation
import Defaults
import Foundation

/// Service for transcribing audio using Parakeet CoreML models via the on-device Swift engine.
/// Operates in batch mode: accumulates audio during recording, transcribes when finished.
@MainActor
final class ParakeetCoreMLASRService: ObservableObject, ASRBackendService {

    // MARK: - Singleton

    static let shared = ParakeetCoreMLASRService()

    // MARK: - Configuration

    /// Target sample rate for Parakeet CoreML transcription (16kHz)
    private let targetSampleRate: Double = 16000

    // MARK: - Published Properties

    /// Whether the model is loaded and ready
    @Published private(set) var isModelReady = false

    /// Whether the model is currently being loaded
    @Published private(set) var isLoading = false

    /// Error message if loading/transcription fails
    @Published private(set) var errorMessage: String?

    // MARK: - Private Properties

    /// Accumulated audio samples (float32, 16kHz mono)
    private var audioBuffer: [Float] = []

    /// Source format (from input); kept only to detect format changes across buffers.
    private var sourceFormat: AVAudioFormat?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Mark the model as ready (called after engine warmup completes).
    func markAsReady() {
        isModelReady = true
        isLoading = false
        errorMessage = nil
    }

    /// Ensure the CoreML engine is resident. Idempotent (the engine early-returns
    /// when loaded), so cheap on the hot path; only pays the reload cost after an
    /// idle-unload. Leaves `isModelReady` untouched - the user-facing warmup state
    /// is deliberately preserved across an idle-unload.
    func ensureEngineLoaded() async throws {
        try await ParakeetCoreMLEngine.shared.ensureLoaded()
    }

    /// Drop the four resident CoreML models to reclaim ANE/CPU memory after
    /// inactivity. Does NOT clear `isModelReady`; the next transcribe reloads
    /// transparently (~80 ms, the cheapest backend to evict).
    func unloadEngine() async {
        await ParakeetCoreMLEngine.shared.unload()
    }

    /// Warmup the Parakeet CoreML engine. Call this at app launch to preload the models.
    func warmup() async throws {
        guard !isModelReady && !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await ParakeetCoreMLEngine.shared.ensureLoaded()
            isModelReady = true
            isLoading = false
            log.info("ParakeetCoreMLASRService: Engine loaded successfully")
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            log.error("ParakeetCoreMLASRService: Warmup failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Append audio from AVAudioPCMBuffer to the internal buffer.
    /// Handles resampling from source sample rate to 16kHz.
    /// - Parameter buffer: PCM audio buffer from microphone
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if sourceFormat == nil {
            sourceFormat = buffer.format
        }

        // Get mono audio (use first channel)
        let sourceData = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))

        // Resample if needed (shared linear-interp implementation)
        let resampledData = AudioResampling.linear(sourceData, from: buffer.format.sampleRate, to: targetSampleRate)

        // Append to buffer (we're on MainActor so no lock needed)
        audioBuffer.append(contentsOf: resampledData)
    }

    /// Get the current duration of accumulated audio in seconds.
    var accumulatedDuration: Double {
        Double(audioBuffer.count) / targetSampleRate
    }

    /// Get a copy of the accumulated audio samples for playback.
    /// Returns mono float32 samples at 16kHz.
    var accumulatedSamples: [Float] {
        audioBuffer
    }

    /// Transcribe the accumulated audio using greedy decoding.
    /// Returns a single hypothesis. Cleanup is handled post-transcription by the Smart Formatting pipeline.
    /// - Returns: Tuple of (hypotheses, detected ISO 639-1 language code or nil if auto, vad_suppressed flag)
    func transcribe() async throws -> ([NbestHypothesis], String?, Bool) {
        let audioData = audioBuffer

        guard !audioData.isEmpty else {
            return ([], nil, false)
        }

        let audioDuration = Double(audioData.count) / targetSampleRate
        log.info("ParakeetCoreMLASRService: Transcribing \(audioDuration)s of audio")

        // VAD gate: suppress accidental trigger clicks on short recordings. The service
        // internally gates by duration (only runs for <2s) and fails open on any error.
        if FeatureFlagManager.shared.sileroVadEnabled, await SileroVADService.shared.isLoaded {
            let suppressed = await SileroVADService.shared.isAudioSilent(audioData)
            if suppressed {
                log.info("ParakeetCoreMLASRService: VAD suppressed (no speech detected)")
                return ([], nil, true)
            }
        }

        // Determine language to force (nil = auto / single-language model default).
        // For ≥2 candidates, run Whisper-base CoreML on the first 3s to pick the best
        // match within the user's candidate list. Falls back to auto on any error.
        let languages = TranscriptionConfig.shared.transcriptionLanguages
        let language: String?
        switch languages.count {
        case 1:
            language = languages[0]
        case 2...:
            if await WhisperLanguageDetector.shared.isLoaded {
                language = await WhisperLanguageDetector.shared.detectLanguage(audio: audioData, candidates: languages)
            } else {
                language = nil
            }
        default:
            language = nil
        }

        // Onset silence prepend: prepend 3s of silence so the model's decoder has warm-up
        // time before the first spoken word, recovering words that start immediately at onset.
        let audioForTranscription: [Float]
        if Defaults[.TranscriptionConfigKeys.onsetSilencePrependEnabled] {
            let silenceSamples = [Float](repeating: 0, count: Int(3.0 * targetSampleRate))
            audioForTranscription = silenceSamples + audioData
        } else {
            audioForTranscription = audioData
        }

        // Self-heal: if the model was unloaded after inactivity, reload it before
        // inference. No-op (~0 ms) when resident; the dictation-start re-arm
        // usually completed this concurrently with the user speaking.
        try await ensureEngineLoaded()

        let transcribeStart = Date()

        // Single-shot for ≤15 s, chunked-with-timestamps for longer. Both
        // paths return absolute frame indices in the original recording's
        // timeline, so downstream `wordTimestamps` + dictionary KWS span
        // alignment work uniformly regardless of clip length.
        let (baselineText, tokenIds, timestamps) = try await ParakeetCoreMLEngine.shared
            .transcribeWithTimestamps(audioForTranscription, language: language)

        // Compute pre-repair per-word timings from the timestamped path.
        // When dictation repair fires it re-runs this with the gap segment's
        // word timings spliced in, so the final array stays count-aligned with
        // the post-repair text.
        let baselineWordTimings = await ParakeetCoreMLEngine.shared
            .wordTimestamps(tokenIds: tokenIds, frameTimestamps: timestamps)

        // Dictation repair is gated on ≤15 s - chunk boundaries inherently
        // produce ≥1-frame gaps in the concatenated `timestamps` that the
        // repair scanner would otherwise interpret as missing dictation
        // commands. Long-audio clips still get word timings, just no repair.
        let canRepair = audioForTranscription.count <= ParakeetCoreMLEngine.maxModelSamples
            && Defaults[.transcriptionDictationRepairEnabled]

        let text: String
        var wordTimings: [WordTimestamp]
        if canRepair {
            let repaired = await repairDictationGaps(
                samples: audioForTranscription,
                baseline: baselineText,
                tokenIds: tokenIds,
                timestamps: timestamps,
                originalWordTimings: baselineWordTimings,
                language: language
            )
            text = repaired.text
            wordTimings = repaired.wordTimings
        } else {
            text = baselineText
            wordTimings = baselineWordTimings
        }

        // Subtract the onset-silence prepend so timings are relative to the
        // original recording the dictionary KWS path also sees.
        let onsetOffsetSec: Float = Defaults[.TranscriptionConfigKeys.onsetSilencePrependEnabled] ? 3.0 : 0.0
        if onsetOffsetSec > 0 {
            wordTimings = wordTimings.map { WordTimestamp(
                word: $0.word,
                startSec: max(0, $0.startSec - onsetOffsetSec),
                endSec: max(0, $0.endSec - onsetOffsetSec)
            ) }
        }

        let durationMs = Date().timeIntervalSince(transcribeStart) * 1000
        log.info("ParakeetCoreMLASRService: Transcription completed in \(String(format: "%.0f", durationMs))ms")

        let hypothesis = NbestHypothesis(
            text: text, score: 0.0, confidence: 1.0,
            wordTimestamps: wordTimings.isEmpty ? nil : wordTimings
        )
        return ([hypothesis], language, false)
    }

    /// Reset the audio buffer for a new recording session.
    func reset() {
        audioBuffer.removeAll()
        sourceFormat = nil
    }

    // Resampling lives in `AudioResampling.linear(...)` - shared with WhisperCoreMLASRService.

    // MARK: - Dictation repair

    private static let dictationRepairGapThreshold = 12  // 960ms at 80ms/frame
    private static let samplesPerFrame = 1280  // 80ms @ 16kHz
    private static let vadContextSamples = 16_000  // 1s pre-gap context for VAD LSTM warmup

    private static let dictationCommands: Set<String> = [
        "period", "comma", "semicolon", "colon",
        "exclamation point", "question mark",
        "quote", "unquote", "end quote", "open quote", "close quote",
        "new line", "newline", "new paragraph", "dash", "hyphen",
    ]

    /// Checks for blank gaps ≥960ms in the token timestamps, confirms speech via VAD,
    /// re-runs TDT on each gap window, and inserts any recovered dictation commands.
    /// Returns the (possibly repaired) text alongside `[WordTimestamp]` updated to
    /// match the post-repair word count - gap-segment timings are converted to
    /// original-audio frame coordinates by adding the gap's start frame, then
    /// spliced into the original `wordTimestamps` at the correct word index.
    /// When no repair fires, returns (baseline, originalWordTimings).
    private func repairDictationGaps(
        samples: [Float],
        baseline: String,
        tokenIds: [Int],
        timestamps: [Int],
        originalWordTimings: [WordTimestamp],
        language: String?
    ) async -> (text: String, wordTimings: [WordTimestamp]) {
        guard timestamps.count >= 2 else { return (baseline, originalWordTimings) }

        // Find gaps ≥ threshold
        struct Gap { let afterTokenIdx: Int; let afterFrame: Int; let beforeFrame: Int }
        var gaps: [Gap] = []
        for i in 0..<(timestamps.count - 1) {
            let gf = timestamps[i + 1] - timestamps[i]
            if gf >= Self.dictationRepairGapThreshold {
                gaps.append(Gap(afterTokenIdx: i, afterFrame: timestamps[i], beforeFrame: timestamps[i + 1]))
            }
        }
        guard !gaps.isEmpty else { return (baseline, originalWordTimings) }

        // afterTokenIdx → (recovered text, recovered word timings in absolute audio frames).
        var textRepairs: [Int: String] = [:]
        var timingRepairs: [Int: [WordTimestamp]] = [:]

        for gap in gaps {
            // Include 1s pre-gap context so the VAD LSTM isn't starting from zero state
            let contextStart = max(0, gap.afterFrame * Self.samplesPerFrame - Self.vadContextSamples)
            // Gap audio offset within the full recording, in encoder frames. The +3
            // frame-offset matches `gapStart` below - gap-local frame 0 corresponds
            // to original-audio frame (afterFrame + 3).
            let gapStartFrameAbs = gap.afterFrame + 3
            let gapStart = gapStartFrameAbs * Self.samplesPerFrame
            let gapEnd = min((gap.beforeFrame + 2) * Self.samplesPerFrame, samples.count)
            guard gapStart < samples.count, gapStart < gapEnd else { continue }

            let vadWindow = Array(samples[contextStart..<gapEnd])
            let hasSpeech = !(await SileroVADService.shared.isAudioSilent(vadWindow))
            guard hasSpeech else { continue }

            let winSamples = Array(samples[gapStart..<gapEnd])
            // Use the timestamped path so we keep per-token frame indices and can
            // splice exact word timings back into the parent recording's
            // wordTimestamps array. Falls back to the throw-away text path on
            // any error.
            guard let gapDecode = try? await ParakeetCoreMLEngine.shared
                .transcribeSingleWithTimestamps(winSamples, language: language)
            else { continue }

            let recovered = gapDecode.text
            let normalized = recovered
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard Self.dictationCommands.contains(normalized) else { continue }

            // Offset gap-local frame indices into the original recording's
            // coordinate space, then group into per-word timings. These splice
            // into `originalWordTimings` directly with no further math.
            let absoluteFrames = gapDecode.timestamps.map { $0 + gapStartFrameAbs }
            let gapWordTimings = await ParakeetCoreMLEngine.shared
                .wordTimestamps(tokenIds: gapDecode.tokenIds, frameTimestamps: absoluteFrames)

            textRepairs[gap.afterTokenIdx] = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
            timingRepairs[gap.afterTokenIdx] = gapWordTimings
            log.info(
                "ParakeetCoreMLASRService: dictation repair inserted \(LogPrivacy.summary(recovered)) (gap=\(timestamps[gap.afterTokenIdx + 1] - timestamps[gap.afterTokenIdx])f, +\(gapWordTimings.count) words)"
            )
        }

        guard !textRepairs.isEmpty else { return (baseline, originalWordTimings) }

        // Reconstruct text + wordTimings at token granularity so each splice
        // lands in the correct word position.
        async let repairedText = ParakeetCoreMLEngine.shared
            .rebuildText(tokenIds: tokenIds, repairs: textRepairs)
        async let repairedTimings = ParakeetCoreMLEngine.shared
            .rebuildWordTimestamps(
                tokenIds: tokenIds,
                frameTimestamps: timestamps,
                repairs: timingRepairs
            )
        return await (text: repairedText, wordTimings: repairedTimings)
    }
}

// MARK: - Errors

enum ParakeetCoreMLASRError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String? = nil)
    case warmupFailed(String)
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from dictation server"
        case .serverError(let statusCode, let message):
            if let message = message {
                return "Dictation server error (\(statusCode)): \(message)"
            }
            return "Dictation server error (\(statusCode))"
        case .warmupFailed(let error):
            return "Failed to load dictation model: \(error)"
        case .modelNotReady:
            return "Dictation model is not ready. Please wait for initialization."
        }
    }
}
