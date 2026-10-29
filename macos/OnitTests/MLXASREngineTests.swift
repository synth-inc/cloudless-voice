// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXASREngineTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation
import Testing
@testable import Onit

/// The generic MLX ASR backend. The inference path (mlx-swift) isn't exercised
/// here - these pin the pure surface the routing layer depends on: the
/// `MLXModelRegistry` id → repo / directory mapping (across Qwen3 and Granite),
/// and the engine's not-loaded contract.
struct MLXASREngineTests {

    // MARK: - Registry mapping

    @Test("ASRModel ids resolve to the matching HuggingFace repo")
    func repoMappingForKnownModels() {
        func repo(_ id: String) -> String? { MLXModelRegistry.kind(for: id)?.hubRepo(id) }
        #expect(repo("qwen3-asr-0.6b") == "mlx-community/Qwen3-ASR-0.6B-4bit")
        #expect(repo("qwen3-asr-1.7b-4bit") == "mlx-community/Qwen3-ASR-1.7B-4bit")
        #expect(repo("qwen3-asr-1.7b-8bit") == "mlx-community/Qwen3-ASR-1.7B-8bit")
        #expect(repo("granite-speech-4.1-2b") == "ibm-granite/granite-speech-4.1-2b")
    }

    @Test("expectedDirectory derives distinct dirs per model and is nil for non-MLX")
    func expectedDirectoryIsDistinct() throws {
        let dir06b = MLXModelRegistry.expectedDirectory(for: "qwen3-asr-0.6b")
        let dir17b4 = MLXModelRegistry.expectedDirectory(for: "qwen3-asr-1.7b-4bit")
        let dir17b8 = MLXModelRegistry.expectedDirectory(for: "qwen3-asr-1.7b-8bit")
        let granite = MLXModelRegistry.expectedDirectory(for: "granite-speech-4.1-2b")
        let unknown = MLXModelRegistry.expectedDirectory(for: "parakeet-v3")

        try #require(dir06b != nil)
        try #require(dir17b4 != nil)
        try #require(granite != nil)
        #expect(unknown == nil)
        #expect(dir06b != dir17b4)
        #expect(dir17b4 != dir17b8)
        #expect(dir06b?.lastPathComponent == "Qwen3-ASR-0.6B-4bit")
        #expect(dir17b8?.lastPathComponent == "Qwen3-ASR-1.7B-8bit")
        #expect(granite?.lastPathComponent == "granite-speech-4.1-2b")
    }

    @Test("Unknown / non-MLX ids resolve to no kind")
    func registryRejectsUnknownModels() {
        #expect(MLXModelRegistry.kind(for: "parakeet-v3") == nil)
        #expect(MLXModelRegistry.kind(for: "whisper-medium") == nil)
        #expect(MLXModelRegistry.kind(for: "does-not-exist") == nil)
        #expect(MLXModelRegistry.isMLXModel("qwen3-asr-0.6b") == true)
        #expect(MLXModelRegistry.isMLXModel("parakeet-v3") == false)
    }

    @Test("Forced-language policy differs per kind (Qwen3 honors, Granite auto-detects)")
    func forcedLanguagePolicy() {
        #expect(MLXModelRegistry.kind(for: "qwen3-asr-0.6b")?.honorsForcedLanguage == true)
        #expect(MLXModelRegistry.kind(for: "granite-speech-4.1-2b")?.honorsForcedLanguage == false)
    }

    // MARK: - Engine state

    @Test("A fresh engine reports as not loaded")
    func freshEngineIsNotLoaded() async {
        let engine = MLXASREngine.makeForTesting()
        #expect(await engine.isLoaded == false)
    }

    @Test("Transcribe throws .modelNotLoaded before ensureLoaded is called")
    func transcribeWithoutLoadThrows() async {
        let engine = MLXASREngine.makeForTesting()
        await #expect(throws: MLXASRError.modelNotLoaded) {
            _ = try await engine.transcribe(samples: [0.1, 0.2, 0.3], language: nil)
        }
    }
}
