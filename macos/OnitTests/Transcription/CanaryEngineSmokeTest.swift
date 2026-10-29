// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CanaryEngineSmokeTest.swift
//  OnitTests
//
//  Diagnostic: load the Canary CoreML engine against the real on-disk models and
//  run one transcription, to pinpoint whether the "stuck loading" is a model-load
//  failure or a CoreML I/O feature-name mismatch. Requires the model already
//  downloaded at ~/Library/Application Support/Onit/Models/canary-1b-v2-coreml.
//

import Foundation
import Testing
@testable import Onit

@Suite("Canary engine smoke")
struct CanaryEngineSmokeTest {

    @Test("load + transcribe 1s silence (surfaces load / I-O errors)")
    func loadAndTranscribe() async throws {
        // Diagnostic only - needs the 573 MB int4 bundle already downloaded to the
        // shared model cache. Skip (don't fail) when it's absent (CI / fresh Mac).
        let modelDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models/canary-1b-v2-coreml/EncoderInt4.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            print("CANARY-SMOKE: model not downloaded - skipping")
            return
        }

        let engine = CanaryCoreMLEngine.shared
        do {
            try await engine.ensureLoaded()
            print("CANARY-SMOKE: ensureLoaded OK, isLoaded=\(await engine.isLoaded)")
        } catch {
            Issue.record("CANARY-SMOKE: ensureLoaded THREW: \(error)")
            throw error
        }

        do {
            let silence = [Float](repeating: 0, count: 16_000)  // 1 s @ 16 kHz
            let text = try await engine.transcribe(silence, language: nil)
            print("CANARY-SMOKE: transcribe OK, output='\(text)'")
        } catch {
            Issue.record("CANARY-SMOKE: transcribe THREW: \(error)")
            throw error
        }
    }
}
