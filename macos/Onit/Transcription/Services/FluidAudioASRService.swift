// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FluidAudioASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 27/01/2026.
//

@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Service for transcribing audio using FluidAudio framework.
/// Operates in batch mode: accumulates audio during recording, transcribes when finished.
/// Note: FluidAudio doesn't support N-best hypotheses, so it returns a single result.
@MainActor
final class FluidAudioASRService: ObservableObject, ASRBackendService {

    // MARK: - Singleton

    static let shared = FluidAudioASRService()

    // MARK: - Configuration

    /// Target sample rate for FluidAudio (16kHz)
    private let targetSampleRate: Double = 16000

    // MARK: - Published Properties

    /// Whether the model is loaded and ready
    @Published private(set) var isModelReady = false

    /// Whether the model is currently being loaded
    @Published private(set) var isLoading = false

    /// Error message if loading/transcription fails
    @Published private(set) var errorMessage: String?

    // MARK: - Private Properties

    /// FluidAudio ASR manager (wrapped for sendability)
    private let asrManagerWrapper = AsrManagerWrapper()

    /// Accumulated audio samples (float32, 16kHz mono)
    private var audioBuffer: [Float] = []

    /// Source format (from input)
    private var sourceFormat: AVAudioFormat?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// One-shot transcription on a pre-recorded audio buffer (16 kHz mono float).
    /// Bypasses the service's accumulator state so it can be used safely while
    /// a live recording session is in progress (e.g. for the Re-transcribe action).
    func transcribe(_ samples: [Float]) async throws -> String {
        try await asrManagerWrapper.transcribe(samples)
    }

    /// Warmup/initialize the FluidAudio model.
    /// Call this at app launch to preload the model.
    func warmup() async throws {
        guard !isModelReady && !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            log.info("FluidAudioASRService: Downloading and loading models...")
            let startTime = Date()

            // Download and load models (v3 for multilingual support)
            let models = try await AsrModels.downloadAndLoad(version: .v3)

            // Initialize the ASR manager via wrapper
            try await asrManagerWrapper.initialize(models: models)

            isModelReady = true
            isLoading = false

            let duration = Date().timeIntervalSince(startTime)
            log.info("FluidAudioASRService: Model loaded successfully in \(Int(duration * 1000))ms")

        } catch {
            isLoading = false
            isModelReady = false
            errorMessage = error.localizedDescription
            log.error("FluidAudioASRService: Warmup failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Initialize with pre-downloaded models (called by FluidAudioWarmupProvider after downloading).
    func initialize(models: AsrModels) async throws {
        guard !isModelReady else { return }
        isLoading = true
        do {
            try await asrManagerWrapper.initialize(models: models)
            isModelReady = true
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Mark the model as ready (for external initialization)
    func markAsReady() {
        isModelReady = true
        isLoading = false
        errorMessage = nil
    }

    /// Drop the loaded `AsrManager` + every accumulated audio sample, returning the
    /// service to a pre-warmup state. Called by `FluidAudioWarmupProvider.reset()`
    /// when the user switches away from this backend so the underlying CoreML/ANE
    /// models can be reclaimed by the system. Without this the manager held on to
    /// ~700 MB of model memory for the entire app session even after another
    /// backend took over.
    func unload() {
        asrManagerWrapper.unload()
        audioBuffer.removeAll(keepingCapacity: false)
        sourceFormat = nil
        isModelReady = false
        isLoading = false
        errorMessage = nil
    }

    /// Append audio from AVAudioPCMBuffer to the internal buffer.
    /// Handles resampling from source sample rate to 16kHz.
    /// - Parameter buffer: PCM audio buffer from microphone
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Store source format for reference
        if sourceFormat == nil {
            sourceFormat = buffer.format
        }

        // Get mono audio (use first channel)
        let sourceData = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))

        // Resample if needed
        let resampledData: [Float]
        if buffer.format.sampleRate != targetSampleRate {
            resampledData = resample(sourceData, from: buffer.format.sampleRate, to: targetSampleRate)
        } else {
            resampledData = sourceData
        }

        // Append to buffer
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

    /// Transcribe the accumulated audio.
    /// - Returns: Tuple of (hypotheses, detected ISO 639-1 language code or nil if auto, vad_suppressed flag)
    func transcribe() async throws -> ([NbestHypothesis], String?, Bool) {
        guard asrManagerWrapper.isLoaded else {
            throw FluidAudioASRError.modelNotLoaded
        }

        let audioData = audioBuffer

        guard !audioData.isEmpty else {
            return ([], nil, false)
        }

        let audioDuration = Double(audioData.count) / targetSampleRate
        // FluidAudio supports single-language forcing only; use first selected language if exactly one is chosen
        let languages = TranscriptionConfig.shared.transcriptionLanguages
        if languages.count > 1 {
            log.warning("FluidAudioASRService: Multi-language detection not supported. Using first language (\(languages[0])) only.")
        }
        let languageCode: String? = languages.count >= 1 ? languages[0] : nil
        log.info("FluidAudioASRService: Transcribing \(audioDuration)s of audio (language=\(languageCode ?? "auto"))")

        do {
            if let languageCode {
                log.warning("FluidAudioASRService: Language forcing (\(languageCode)) not supported by FluidAudio, using auto-detect")
            }

            let startTime = Date()
            let resultText = try await asrManagerWrapper.transcribe(audioData)
            let transcriptionTime = Date().timeIntervalSince(startTime)

            log.info("FluidAudioASRService: Transcription completed in \(Int(transcriptionTime * 1000))ms")

            // Return as single hypothesis with confidence 1.0
            return ([NbestHypothesis(text: resultText, score: 0.0, confidence: 1.0)], languageCode, false)

        } catch {
            log.error("FluidAudioASRService: Transcription failed: \(error.localizedDescription)")
            throw FluidAudioASRError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Reset the audio buffer for a new recording session.
    func reset() {
        audioBuffer.removeAll()
        sourceFormat = nil
    }

    /// Ensure the engine is resident. FluidAudio is framework-managed and not
    /// exposed in the model picker, so it is never the active backend the
    /// inactivity service unloads/re-arms; `warmup()` (idempotent) is the only
    /// load path and covers the rare case where this is invoked.
    func ensureEngineLoaded() async throws {
        try await warmup()
    }

    /// No-op: FluidAudio is never the active picker backend, so the inactivity
    /// service never targets it. (Its full teardown lives in `unload()`, which
    /// also clears the ready state - deliberately not what idle-unload wants.)
    func unloadEngine() async {}

    // MARK: - Private Methods

    /// Simple linear interpolation resampling
    private func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        let ratio = sourceRate / targetRate
        let outputLength = Int(Double(samples.count) / ratio)

        guard outputLength > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let sourceIndex = Double(i) * ratio
            let index0 = Int(sourceIndex)
            let index1 = min(index0 + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(index0))

            output[i] = samples[index0] * (1 - fraction) + samples[index1] * fraction
        }

        return output
    }
}

// MARK: - AsrManager Wrapper

/// Thread-safe wrapper for AsrManager to handle Swift concurrency
private final class AsrManagerWrapper: @unchecked Sendable {
    private var manager: AsrManager?

    var isLoaded: Bool { manager != nil }

    func initialize(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unload() {
        manager = nil
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager = manager else {
            throw FluidAudioASRError.modelNotLoaded
        }
        let result = try await manager.transcribe(samples)
        return result.text
    }
}

// MARK: - Errors

enum FluidAudioASRError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "FluidAudio model is not loaded. Please wait for initialization."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
