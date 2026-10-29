// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionConfigASRModelTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import Testing
import Defaults
@testable import Onit

/// Serialized because these tests mutate the `TranscriptionConfig.shared` singleton.
/// Parallel execution would interleave snapshot/restore and produce flaky results.
@MainActor
@Suite(.serialized)
struct TranscriptionConfigASRModelTests {

    private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

    // MARK: - Defaults Key

    @Test("selectedASRModelId Defaults key defaults to ASRModel.defaultModelId")
    func selectedModelDefaultKeyValue() {
        #expect(ConfigKeys.selectedASRModelId.defaultValue == ASRModel.defaultModelId)
    }

    // MARK: - TranscriptionConfig binding
    //
    // These tests exercise the singleton in-place because TranscriptionConfig
    // doesn't yet expose a Defaults-store seam for injection. We snapshot/restore
    // the two keys we touch so the suite is order-independent and doesn't leak
    // into the user's real preferences during local dev.

    private func withTemporarySelection(_ modelId: String, _ body: (TranscriptionConfig) throws -> Void) rethrows {
        let config = TranscriptionConfig.shared
        let previous = config.selectedASRModelId
        config.selectedASRModelId = modelId
        defer { config.selectedASRModelId = previous }
        try body(config)
    }

    @Test("selectedASRModel resolves to the matching catalog entry")
    func selectedModelResolvesToCatalogEntry() {
        withTemporarySelection("whisper-large-turbo-v3") { config in
            #expect(config.selectedASRModel.id == "whisper-large-turbo-v3")
        }
    }

    @Test("Backend is derived from the selected model")
    func backendIsDerivedFromSelectedModel() {
        withTemporarySelection("whisper-medium") { config in
            #expect(config.backend == .whisperCoreML)
        }
        withTemporarySelection("parakeet-v3") { config in
            #expect(config.backend == .parakeetCoreML)
        }
    }

    @Test("Selecting an unknown model id falls back to the default model")
    func unknownIdFallsBackToDefault() {
        withTemporarySelection("does-not-exist") { config in
            #expect(config.selectedASRModel.id == ASRModel.defaultModelId)
            #expect(config.backend == ASRModel.defaultModel.backend)
        }
    }

    @Test("resetToDefaults restores the default ASR model selection")
    func resetToDefaultsRestoresASRModel() {
        let config = TranscriptionConfig.shared
        let previous = config.selectedASRModelId
        config.selectedASRModelId = "whisper-medium"
        config.resetToDefaults()
        #expect(config.selectedASRModelId == ASRModel.defaultModelId)
        #expect(config.backend == ASRModel.defaultModel.backend)
        config.selectedASRModelId = previous
    }

    // MARK: - Critical invariant: legacy backend key sync
    //
    // Pinned because every warmup provider reads `Defaults[ConfigKeys.backend]`
    // directly (SileroVAD, ParakeetCoreML, FluidAudio, WhisperCoreML). If the
    // selectedASRModelId setter ever stops syncing this key, the providers will
    // silently pick the wrong backend until next launch - and there is no other
    // test that catches that regression.

    @Test("Setting selectedASRModelId writes the matching backend to Defaults[.backend]")
    func selectedModelMirrorsBackendToDefaults() {
        withTemporarySelection("whisper-medium") { _ in
            #expect(Defaults[ConfigKeys.backend] == .whisperCoreML)
        }
        withTemporarySelection("whisper-large-turbo-v3") { _ in
            #expect(Defaults[ConfigKeys.backend] == .whisperCoreML)
        }
        withTemporarySelection(ASRModel.defaultModelId) { _ in
            #expect(Defaults[ConfigKeys.backend] == .parakeetCoreML)
        }
    }
}
