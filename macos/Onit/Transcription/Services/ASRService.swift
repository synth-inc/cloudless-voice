// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-19.
//

@preconcurrency import AVFoundation
import Foundation

/// Shared base for the per-backend ASR services that wrap a single engine
/// (Whisper / Moonshine / Qwen3-ASR). Owns the audio buffer accumulation,
/// resampling, VAD gating, warmup state, and the standardised transcribe
/// envelope that returns `([NbestHypothesis], language, vadSuppressed)`.
///
/// **What subclasses provide.** Two hooks:
/// - `warmupEngine(modelId:)` - load the underlying engine into memory.
/// - `transcribeAudio(samples:language:)` - run the actual inference and
///   return the raw text.
///
/// Optionally subclasses can override `resolveForcedLanguage()` if their
/// engine ignores the language argument (e.g. Moonshine is English-only).
///
/// **Who does NOT inherit from this.** `ParakeetCoreMLASRService` and
/// `FluidAudioASRService` keep their own implementation because they carry
/// backend-specific logic (Parakeet's dictation-gap repair / N-best handling,
/// FluidAudio's framework-managed buffer). Extracting a single base for the
/// simple wrappers gives us most of the dedup benefit without forcing those
/// two odd-shapes through the same mold.
@MainActor
class ASRService: ObservableObject, ASRBackendService {

    // MARK: - Configuration

    /// 16 kHz mono float32 - every ASR backend we ship expects this.
    let targetSampleRate: Double = 16_000

    // MARK: - Published state

    @Published private(set) var isModelReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    // MARK: - Buffer

    private var audioBuffer: [Float] = []
    private var sourceFormat: AVAudioFormat?

    init() {}

    // MARK: - Hooks (override in subclasses)

    /// Identifier used in log prefixes. Subclasses can override to provide a
    /// human-readable name; default is the runtime type name.
    var serviceName: String { String(describing: type(of: self)) }

    /// Load the underlying engine for the given model id. Must be idempotent.
    /// Default implementation traps - subclasses must override.
    func warmupEngine(modelId: String) async throws {
        preconditionFailure("\(serviceName) must override warmupEngine(modelId:)")
    }

    /// Run inference against `samples` and return the raw transcribed text.
    /// Default implementation traps - subclasses must override.
    func transcribeAudio(samples: [Float], language: String?) async throws -> String {
        preconditionFailure("\(serviceName) must override transcribeAudio(samples:language:)")
    }

    /// Drop the underlying engine's weights to reclaim RAM. Default implementation
    /// traps - subclasses must override to call their engine's `unload()`.
    func unloadEngine() async {
        preconditionFailure("\(serviceName) must override unloadEngine()")
    }

    /// Resolve the language to force at inference time. Default: when the user
    /// has configured a single candidate, force it; otherwise nil (auto/English
    /// depending on backend). Override to ignore the user choice entirely
    /// (Moonshine does this - it's English-only).
    func resolveForcedLanguage() -> String? {
        let languages = TranscriptionConfig.shared.transcriptionLanguages
        return languages.count == 1 ? languages[0] : nil
    }

    // MARK: - Lifecycle

    /// Mark the service as ready post-warmup. Used by the matching warmup
    /// provider after `ensureLoaded` succeeds so the UI flips out of "Loading".
    func markAsReady() {
        isModelReady = true
        isLoading = false
        errorMessage = nil
    }

    /// Ensure the engine for the currently-selected model is resident. Idempotent
    /// (the engine's own `ensureLoaded` early-returns when loaded), so this is
    /// cheap on the hot path and only pays the reload cost after an idle-unload.
    /// Does NOT touch `isModelReady`/`isLoading` - those track the user-facing
    /// warmup state, which an idle-unload deliberately leaves untouched.
    func ensureEngineLoaded() async throws {
        let modelId = TranscriptionConfig.shared.selectedASRModelId
        try await warmupEngine(modelId: modelId)
    }

    /// Eagerly load the engine that matches the currently selected ASR model.
    /// Idempotent - early-returns once `isModelReady`.
    func warmup() async throws {
        guard !isModelReady && !isLoading else { return }
        let modelId = TranscriptionConfig.shared.selectedASRModelId
        isLoading = true
        errorMessage = nil
        do {
            try await warmupEngine(modelId: modelId)
            isModelReady = true
            isLoading = false
            log.info("\(serviceName): Engine loaded for \(modelId)")
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            log.error("\(serviceName): Warmup failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Audio buffer

    /// Append a PCM buffer from the microphone. Resamples to 16 kHz mono if needed.
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if sourceFormat == nil {
            sourceFormat = buffer.format
        }

        let sourceData = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        let resampledData = AudioResampling.linear(
            sourceData,
            from: buffer.format.sampleRate,
            to: targetSampleRate
        )
        audioBuffer.append(contentsOf: resampledData)
    }

    var accumulatedDuration: Double {
        Double(audioBuffer.count) / targetSampleRate
    }

    var accumulatedSamples: [Float] {
        audioBuffer
    }

    /// Drop the accumulated audio and the format snapshot. Called between recording sessions.
    func reset() {
        audioBuffer.removeAll()
        sourceFormat = nil
    }

    // MARK: - Transcribe

    /// Run the standardised transcribe envelope:
    /// 1. Short-circuit on empty buffer.
    /// 2. Silero VAD gate to suppress accidental short clicks.
    /// 3. Forced-language resolution (subclasses can override).
    /// 4. Delegate to `transcribeAudio(samples:language:)`.
    /// 5. Wrap the result in a single `NbestHypothesis`.
    ///
    /// Returns `([NbestHypothesis], language, vadSuppressed)`.
    func transcribe() async throws -> ([NbestHypothesis], String?, Bool) {
        let audioData = audioBuffer
        guard !audioData.isEmpty else { return ([], nil, false) }

        let durationSec = Double(audioData.count) / targetSampleRate
        log.info("\(serviceName): Transcribing \(durationSec)s of audio")

        // VAD gate - same intent across backends: suppress accidental clicks.
        if FeatureFlagManager.shared.sileroVadEnabled, await SileroVADService.shared.isLoaded {
            if await SileroVADService.shared.isAudioSilent(audioData) {
                log.info("\(serviceName): VAD suppressed (no speech detected)")
                return ([], nil, true)
            }
        }

        let forcedLanguage = resolveForcedLanguage()

        // Self-heal: if the model was unloaded after inactivity, reload it before
        // inference. No-op (~0 ms) when already resident. The dictation-start
        // re-arm usually completed this concurrently with the user speaking; this
        // is the guarantee for the case where speech was shorter than the reload.
        try await ensureEngineLoaded()

        let transcribeStart = Date()
        let text = try await transcribeAudio(samples: audioData, language: forcedLanguage)
        let durationMs = Date().timeIntervalSince(transcribeStart) * 1000
        log.info("\(serviceName): Transcription completed in \(String(format: "%.0f", durationMs))ms")

        let hypothesis = NbestHypothesis(text: text, score: 0.0, confidence: 1.0, wordTimestamps: nil)
        return ([hypothesis], forcedLanguage, false)
    }
}
