// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelLifecycleTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-06-15.
//
//  Integration test for the unload-on-idle / reload-on-dictation contract
//  (feat/asr-keep-alive). Verifies, against the real Parakeet CoreML engine
//  (the default backend, already on disk), that:
//    1. `ASRBackendService.unloadEngine()` frees the engine WITHOUT clearing the
//       user-facing `isModelReady` flag (so the menu-bar/Settings status doesn't
//       flip to "loading").
//    2. `ensureEngineLoaded()` reloads it (idempotent).
//    3. The `transcribe()` path self-heals: it reloads an idle-unloaded engine
//       instead of throwing `.modelNotLoaded`.
//
//  Opt-in: `touch /tmp/run_lifecycle_test` (loads the ~460 MB Parakeet model and
//  runs real inference). Skipped otherwise.
//

import AVFoundation
import Foundation
import Testing
@testable import Onit

@MainActor
struct ASRModelLifecycleTests {

    private static let markerPath = "/tmp/run_lifecycle_test"

    @Test(
        "unloadEngine frees the engine but keeps isModelReady; transcribe self-heals",
        .enabled(if: FileManager.default.fileExists(atPath: markerPath))
    )
    func unloadReloadSelfHeal() async throws {
        let service = ParakeetCoreMLASRService.shared

        // MARK: - Warm up the real engine
        try await service.warmup()
        let loaded = await ParakeetCoreMLEngine.shared.isLoaded
        #expect(loaded, "Engine should be loaded after warmup")
        #expect(service.isModelReady, "Service should report ready after warmup")

        // MARK: - Idle-unload frees the engine but preserves the ready flag
        await service.unloadEngine()
        let unloaded = await ParakeetCoreMLEngine.shared.isLoaded
        #expect(!unloaded, "Engine weights should be freed after unloadEngine()")
        #expect(service.isModelReady,
                "isModelReady must stay true after an idle-unload (no menu/Settings 'loading' regression)")

        // MARK: - ensureEngineLoaded reloads (idempotent)
        try await service.ensureEngineLoaded()
        let reloaded = await ParakeetCoreMLEngine.shared.isLoaded
        #expect(reloaded, "ensureEngineLoaded() should reload the engine")

        // MARK: - transcribe() self-heals after an unload
        // Build a speech buffer; prefer the spike's pre-generated wav, fall back
        // to a loud tone (Parakeet has no hard VAD gate so a tone still runs).
        let samples = Self.speechSamples()
        guard let buffer = Self.makeBuffer(from: samples) else {
            Issue.record("Could not build audio buffer")
            return
        }
        await service.unloadEngine()
        #expect(!(await ParakeetCoreMLEngine.shared.isLoaded), "Precondition: engine unloaded")

        service.reset()
        service.appendAudio(buffer)
        // The assertion is that this does NOT throw .modelNotLoaded: the transcribe
        // envelope reloads the idle-unloaded engine first. The `try` carries that;
        // reaching the next line at all means self-heal worked.
        _ = try await service.transcribe()
        #expect(await ParakeetCoreMLEngine.shared.isLoaded,
                "transcribe() should have reloaded the idle-unloaded engine")
    }

    @Test(
        "every picker backend declares a keep-alive policy; Parakeet ping keeps it resident",
        .enabled(if: FileManager.default.fileExists(atPath: markerPath))
    )
    func keepAlivePolicyAndPing() async throws {
        // Every user-selectable backend must declare a keep-alive policy; the
        // framework-managed FluidAudio is exempt.
        for backend in [TranscriptionBackend.parakeetCoreML, .whisperCoreML, .moonshineONNX, .mlx] {
            #expect(ASRBackendRegistry.descriptor(for: backend).keepAlivePolicy != nil,
                    "\(backend.rawValue) should declare a keep-alive policy")
        }
        #expect(ASRBackendRegistry.descriptor(for: .fluidAudio).keepAlivePolicy == nil,
                "FluidAudio is not in the picker - no keep-alive")

        // A Parakeet keep-alive ping (via the raw reTranscribe path) must run on a
        // resident model without throwing and must leave it resident.
        let descriptor = ASRBackendRegistry.descriptor(for: .parakeetCoreML)
        let policy = try #require(descriptor.keepAlivePolicy)
        try await ParakeetCoreMLASRService.shared.ensureEngineLoaded()
        #expect(await ParakeetCoreMLEngine.shared.isLoaded)

        _ = try await descriptor.reTranscribe(policy.makeClip())
        #expect(await ParakeetCoreMLEngine.shared.isLoaded,
                "keep-alive ping must leave the model resident")
    }

    @Test(
        "unloadEngine actually reclaims the MLX model's memory (not just flips isLoaded)",
        .enabled(if: FileManager.default.fileExists(atPath: markerPath)
                 && MLXModelRegistry.expectedDirectory(for: ASRModel.qwen3ASR17B8bitId)
                    .map { FileManager.default.fileExists(atPath: $0.path) } == true)
    )
    func unloadReclaimsMLXMemory() async throws {
        let modelId = ASRModel.qwen3ASR17B8bitId
        // MLX weights are lazy - `ensureLoaded` mmaps but doesn't materialize.
        // Run one inference so the weights are actually resident before measuring.
        let baselineActive = MLXASREngine.mlxMemory().active
        try await MLXASREngine.shared.ensureLoaded(modelId: modelId)
        _ = try await MLXASREngine.shared.transcribe(
            samples: ASRKeepAlivePolicy.tone(seconds: 1.0, amplitude: 0.2), language: nil)

        let loadedActive = MLXASREngine.mlxMemory().active
        let loadedIsLoaded = await MLXASREngine.shared.isLoaded
        #expect(loadedIsLoaded)
        #expect(loadedActive - baselineActive > 1_000_000_000,
                "model should hold >1 GB of MLX active memory once materialized")

        // The real path the lifecycle service uses on idle-unload.
        await MLXASRService.shared.unloadEngine()

        let unloadedActive = MLXASREngine.mlxMemory().active
        let unloadedCache = MLXASREngine.mlxMemory().cache
        let unloadedIsLoaded = await MLXASREngine.shared.isLoaded
        let reclaimed = loadedActive - unloadedActive
        print("[unload-mem] MLX active: \(Self.gb(baselineActive)) -> \(Self.gb(loadedActive)) -> \(Self.gb(unloadedActive)) | reclaimed \(Self.gb(reclaimed))")

        #expect(!unloadedIsLoaded, "engine should report unloaded")
        // The core guarantee: unload genuinely frees the weights, not just nils a flag.
        #expect(reclaimed > 1_000_000_000,
                "unloadEngine should reclaim >1 GB of MLX active memory")
        #expect(unloadedCache == 0, "MLX cache pool should flush to 0 after unload")
    }

    // MARK: - Helpers

    private static func gb(_ bytes: Int) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
    }

    private static func speechSamples() -> [Float] {
        if let clip = try? loadWav(path: "/tmp/keepalive_spike_speech.wav"), clip.count >= 16_000 {
            return clip
        }
        let sampleRate: Float = 16_000
        return (0..<32_000).map { 0.3 * sin(2 * .pi * 440 * Float($0) / sampleRate) }
    }

    private static func loadWav(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "lifecycle", code: 1)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw NSError(domain: "lifecycle", code: 2) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: ptr.count)
        }
        return buffer
    }
}
