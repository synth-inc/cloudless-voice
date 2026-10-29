// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRBackendRegistryTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation
import Testing
@testable import Onit

/// Pins the single registration switch: every `TranscriptionBackend` resolves to
/// a descriptor whose warmup-provider identifier matches the value the routing
/// layers previously hardcoded (the migration must not silently re-map a
/// backend to the wrong provider).
@MainActor
struct ASRBackendRegistryTests {

    @Test("Each backend resolves to its expected warmup-provider id")
    func providerIdPerBackend() {
        let expected: [TranscriptionBackend: String] = [
            .fluidAudio: "fluidAudio",
            .parakeetCoreML: "parakeet",
            .whisperCoreML: "whisper",
            .moonshineONNX: "moonshine",
            .mlx: "mlxasr",
        ]
        for (backend, id) in expected {
            #expect(ASRBackendRegistry.descriptor(for: backend).providerId == id)
        }
    }

    @Test("MLX backend descriptor routes to the MLX service")
    func mlxDescriptorService() {
        let d = ASRBackendRegistry.descriptor(for: .mlx)
        #expect(d.service === MLXASRService.shared)
        #expect(d.warmupProvider.identifier == "mlxasr")
    }

    @Test("Install-on-disk dispatches per backend without crashing")
    func installCheckDispatches() {
        // A known MLX model id resolves through the MLX descriptor's per-file
        // check; a CoreML model resolves through directory existence. We only
        // assert the dispatch runs (the result depends on what's downloaded).
        if let granite = ASRModel.byId(ASRModel.graniteSpeechId) {
            _ = ASRBackendRegistry.descriptor(for: granite.backend).isInstalledOnDisk(granite)
        }
        if let parakeet = ASRModel.byId(ASRModel.parakeetV3Id) {
            _ = ASRBackendRegistry.descriptor(for: parakeet.backend).installDirectory(parakeet)
        }
    }
}
