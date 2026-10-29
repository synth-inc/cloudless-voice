// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CanaryCoreMLASRService.swift
//  Onit
//
//  Batch ASR service for the Canary-1B-v2 CoreML backend. Accumulates 16 kHz mono
//  audio during recording and transcribes on finish via `CanaryCoreMLEngine`.
//  Simpler than the Parakeet service: Canary is a greedy attention encoder-decoder
//  with no per-token frame timestamps, so there's no dictation-repair / word-timing
//  path (a future addition). The user's selected transcription language is forced
//  via the decoder prompt (see `forcedLanguage` + `CanaryCoreMLEngine.transcribe`);
//  Canary is an AED model with no auto-detect, so "Auto"/none defaults to English.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class CanaryCoreMLASRService: ObservableObject, ASRBackendService {

    static let shared = CanaryCoreMLASRService()

    private let targetSampleRate: Double = 16_000

    @Published private(set) var isModelReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var audioBuffer: [Float] = []

    private init() {}

    func markAsReady() {
        isModelReady = true
        isLoading = false
        errorMessage = nil
    }

    func ensureEngineLoaded() async throws {
        try await CanaryCoreMLEngine.shared.ensureLoaded()
    }

    func unloadEngine() async {
        await CanaryCoreMLEngine.shared.unload()
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let sourceData = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        let resampled = AudioResampling.linear(sourceData, from: buffer.format.sampleRate, to: targetSampleRate)
        audioBuffer.append(contentsOf: resampled)
    }

    var accumulatedDuration: Double { Double(audioBuffer.count) / targetSampleRate }
    var accumulatedSamples: [Float] { audioBuffer }

    /// The single selected transcription language (ISO 639-1) forced on Canary, or
    /// nil when zero or multiple languages are selected - the engine maps nil to
    /// English. Mirrors the other backends' single-language forcing rule.
    @MainActor
    static func forcedLanguage() -> String? {
        let languages = TranscriptionConfig.shared.transcriptionLanguages
        return languages.count == 1 ? languages[0] : nil
    }

    func transcribe() async throws -> ([NbestHypothesis], String?, Bool) {
        let audioData = audioBuffer
        guard !audioData.isEmpty else { return ([], nil, false) }

        let audioDuration = Double(audioData.count) / targetSampleRate
        log.info("CanaryCoreMLASRService: Transcribing \(audioDuration)s of audio")

        // VAD gate: suppress accidental trigger clicks on short recordings.
        if FeatureFlagManager.shared.sileroVadEnabled, await SileroVADService.shared.isLoaded {
            if await SileroVADService.shared.isAudioSilent(audioData) {
                log.info("CanaryCoreMLASRService: VAD suppressed (no speech detected)")
                return ([], nil, true)
            }
        }

        // Self-heal: reload the engine if it was idle-unloaded (no-op when resident).
        try await ensureEngineLoaded()

        let start = Date()
        let text = try await CanaryCoreMLEngine.shared.transcribe(audioData, language: Self.forcedLanguage())
        let durationMs = Date().timeIntervalSince(start) * 1000
        log.info("CanaryCoreMLASRService: Transcription completed in \(String(format: "%.0f", durationMs))ms")

        let hypothesis = NbestHypothesis(text: text, score: 0.0, confidence: 1.0, wordTimestamps: nil)
        return ([hypothesis], nil, false)
    }

    func reset() {
        audioBuffer.removeAll()
    }
}
