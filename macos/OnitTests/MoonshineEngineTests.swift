// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MoonshineEngineTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-19.
//

import Foundation
import Testing
@testable import Onit

/// Engine wrapper for Moonshine (Useful Sensors) ONNX models. The bulk of the
/// inference is delegated to the upstream runtime, so these tests cover the pure
/// surface: the model-id ↔ HuggingFace variant mapping, default state, and the
/// throw-when-not-loaded contract. Integration tests that actually load `.onnx`
/// files belong in a separate, opt-in suite and intentionally are not included
/// here.
struct MoonshineEngineTests {

    // MARK: - Variant Mapping

    @Test("ASRModel ids map to the matching Moonshine HuggingFace variant strings")
    func variantMappingForKnownModels() {
        #expect(MoonshineEngine.huggingFaceVariant(for: "moonshine-base") == "moonshine-base")
    }

    @Test("Unknown / non-Moonshine ids yield no variant")
    func variantMappingForUnknownModels() {
        #expect(MoonshineEngine.huggingFaceVariant(for: "parakeet-v3") == nil)
        #expect(MoonshineEngine.huggingFaceVariant(for: "whisper-medium") == nil)
        #expect(MoonshineEngine.huggingFaceVariant(for: "does-not-exist") == nil)
    }

    // MARK: - State

    @Test("A fresh engine instance reports as not loaded")
    func freshEngineIsNotLoaded() async {
        let engine = MoonshineEngine.makeForTesting()
        let loaded = await engine.isLoaded
        #expect(loaded == false)
    }

    @Test("Transcribe throws .modelNotLoaded before ensureLoaded is called")
    func transcribeWithoutLoadThrows() async {
        let engine = MoonshineEngine.makeForTesting()
        await #expect(throws: MoonshineEngineError.modelNotLoaded) {
            _ = try await engine.transcribe(samples: [], language: nil)
        }
    }

    @Test("ensureLoaded with an unknown model id throws .unsupportedModel")
    func ensureLoadedWithUnknownIdThrows() async {
        let engine = MoonshineEngine.makeForTesting()
        await #expect(throws: MoonshineEngineError.unsupportedModel(id: "does-not-exist")) {
            try await engine.ensureLoaded(modelId: "does-not-exist")
        }
    }

    // MARK: - Teardown

    @Test("unloadIfCurrent is a no-op for an unknown model id")
    func unloadIfCurrentWithUnknownIdIsNoOp() async {
        let engine = MoonshineEngine.makeForTesting()
        await engine.unloadIfCurrent(modelId: "does-not-exist")
        let loaded = await engine.isLoaded
        #expect(loaded == false)
    }
}
