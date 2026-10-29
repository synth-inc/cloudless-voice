// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringModelValidationTests.swift
//  OnitTests
//
//  Guards the PRO "add a custom scoring model" MLX-format check: an MLX repo is
//  accepted; GGUF, LoRA adapters, and non-model repos are rejected with a clear
//  reason - so the app never tries to download a model it can't load.
//

import Foundation
import Testing
@testable import Onit

@Suite("ScoringModel MLX validation")
struct ScoringModelValidationTests {

    private func f(_ names: [String], sizeMB: Int64 = 1) -> [(path: String, size: Int64)] {
        names.map { (path: $0, size: sizeMB * 1_000_000) }
    }

    @Test("MLX safetensors model is accepted")
    func acceptsMLXModel() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["config.json", "model.safetensors", "tokenizer.json"], sizeMB: 1300))
        if case .ok(let mb) = check { #expect(mb == 1300) } else { Issue.record("expected .ok, got \(check)") }
        #expect(check.errorMessage == nil)
    }

    @Test("sharded MLX model sums size across shards")
    func acceptsShardedModel() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["config.json", "model-00001-of-00002.safetensors",
               "model-00002-of-00002.safetensors", "tokenizer.json"], sizeMB: 500))
        if case .ok(let mb) = check { #expect(mb == 1000) } else { Issue.record("expected .ok") }
    }

    @Test("GGUF is rejected")
    func rejectsGGUF() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["config.json", "model-q8_0.gguf"]))
        #expect(check == .gguf)
        #expect(check.errorMessage?.contains("GGUF") == true)
    }

    @Test("LoRA adapter (no full model) is rejected")
    func rejectsAdapter() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["adapter_config.json", "adapter_model.safetensors", "tokenizer.json"]))
        #expect(check == .adapterOnly)
        #expect(check.errorMessage?.contains("adapter") == true)
    }

    @Test("adapter alongside a full model IS accepted")
    func acceptsModelWithAdapter() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["config.json", "model.safetensors", "adapter_config.json", "adapter_model.safetensors"]))
        if case .ok = check {} else { Issue.record("expected .ok, got \(check)") }
    }

    @Test("missing config.json is rejected")
    func rejectsNoConfig() {
        #expect(HuggingFaceModelDownloader.classifyMLXRepo(f(["model.safetensors"])) == .noConfig)
    }

    @Test("no safetensors (pytorch .bin only) is rejected")
    func rejectsNoSafetensors() {
        let check = HuggingFaceModelDownloader.classifyMLXRepo(
            f(["config.json", "pytorch_model.bin", "tokenizer.json"]))
        #expect(check == .noSafetensors)
    }
}
