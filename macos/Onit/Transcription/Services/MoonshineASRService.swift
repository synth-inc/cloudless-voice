// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MoonshineASRService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-19.
//

import Foundation

/// Service for transcribing audio with the Moonshine (Useful Sensors) ONNX engine.
///
/// Most of the logic lives in `ASRService`. Moonshine is English-only so the
/// language argument is ignored at the engine level and `resolveForcedLanguage`
/// always returns nil - the user's multi-language setting has no effect here.
@MainActor
final class MoonshineASRService: ASRService {

    static let shared = MoonshineASRService()

    private override init() { super.init() }

    override var serviceName: String { "MoonshineASRService" }

    override func warmupEngine(modelId: String) async throws {
        try await MoonshineEngine.shared.ensureLoaded(modelId: modelId)
    }

    override func transcribeAudio(samples: [Float], language: String?) async throws -> String {
        // Engine ignores `language` - Moonshine Base is English-only.
        try await MoonshineEngine.shared.transcribe(samples: samples, language: nil)
    }

    override func unloadEngine() async {
        await MoonshineEngine.shared.unload()
    }

    override func resolveForcedLanguage() -> String? { nil }
}
