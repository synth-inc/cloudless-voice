// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation

/// Single ASR service for every MLX-based model. Buffering, VAD, warmup state
/// and the transcribe envelope live in `ASRService`; this wires the generic
/// `MLXASREngine` and defers the forced-language policy to the model's kind.
@MainActor
final class MLXASRService: ASRService {

    static let shared = MLXASRService()

    private override init() { super.init() }

    override var serviceName: String { "MLXASRService" }

    override func warmupEngine(modelId: String) async throws {
        try await MLXASREngine.shared.ensureLoaded(modelId: modelId)
    }

    override func transcribeAudio(samples: [Float], language: String?) async throws -> String {
        try await MLXASREngine.shared.transcribe(samples: samples, language: language)
    }

    override func unloadEngine() async {
        await MLXASREngine.shared.unload()
    }

    /// Models that don't honor a forced language (e.g. Granite - auto-detect
    /// only) must report `nil` so the pipeline neither forces nor mis-records
    /// the language.
    override func resolveForcedLanguage() -> String? {
        let modelId = TranscriptionConfig.shared.selectedASRModelId
        if MLXModelRegistry.kind(for: modelId)?.honorsForcedLanguage == false {
            return nil
        }
        return super.resolveForcedLanguage()
    }
}
