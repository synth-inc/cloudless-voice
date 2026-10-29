// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperCoreMLASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation

/// Service for transcribing audio with the Whisper CoreML engine via WhisperKit.
///
/// Most of the logic lives in `ASRService` (audio buffer, VAD gate, warmup state,
/// transcribe envelope). This subclass only wires the two engine hooks. The pipeline
/// is intentionally simpler than Parakeet's: no dictation-gap repair, no logit
/// boosting, no multi-language detection (WhisperKit handles language auto-detect
/// internally).
@MainActor
final class WhisperCoreMLASRService: ASRService {

    static let shared = WhisperCoreMLASRService()

    private override init() { super.init() }

    override var serviceName: String { "WhisperCoreMLASRService" }

    override func warmupEngine(modelId: String) async throws {
        try await WhisperCoreMLEngine.shared.ensureLoaded(modelId: modelId)
    }

    override func transcribeAudio(samples: [Float], language: String?) async throws -> String {
        try await WhisperCoreMLEngine.shared.transcribe(samples: samples, language: language)
    }

    override func unloadEngine() async {
        await WhisperCoreMLEngine.shared.unload()
    }
}
