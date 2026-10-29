// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ParakeetBundleValidationTests.swift
//  OnitTests
//
//  Regression tests for the partial-load wedge (fix/parakeet-partial-load-wedge).
//
//  Production failure: an interrupted first-run download left a partial Parakeet
//  bundle (Preprocessor.mlmodelc present, later pieces missing). The old
//  `ensureLoaded()` only checked the bundle DIRECTORY, loaded the preprocessor,
//  then threw on the encoder - leaving `preprocessorModel` non-nil so every later
//  `ensureLoaded()` early-returned "loaded" and every transcribe call threw
//  "Parakeet CoreML models are not loaded" until app restart.
//
//  `validateModelBundle(at:)` is the up-front gate: it must throw the retryable
//  `.modelsNotFound` for any incomplete bundle so the engine never half-loads.
//  Pure filesystem checks - no real CoreML models needed.
//

import Foundation
import Testing
@testable import Onit

struct ParakeetBundleValidationTests {

    private static let modelNames = ["Preprocessor", "Encoder", "Decoder", "JointDecision"]

    /// Build a temp bundle dir containing the given `.mlmodelc` dirs and vocab files.
    private func makeBundle(models: [String], vocabFiles: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-bundle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for model in models {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("\(model).mlmodelc"),
                withIntermediateDirectories: true)
        }
        for vocab in vocabFiles {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(vocab))
        }
        return dir
    }

    private func expectModelsNotFound(_ dir: URL, _ comment: Comment) {
        do {
            try ParakeetCoreMLEngine.validateModelBundle(at: dir)
            Issue.record(comment)
        } catch let error as ParakeetCoreMLError {
            guard case .modelsNotFound = error else {
                Issue.record("expected .modelsNotFound, got \(error) - \(comment)")
                return
            }
        } catch {
            Issue.record("expected ParakeetCoreMLError.modelsNotFound, got \(error) - \(comment)")
        }
    }

    @Test("complete bundle passes validation")
    func completeBundlePasses() throws {
        let dir = try makeBundle(models: Self.modelNames, vocabFiles: ["parakeet_v3_vocab.json"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try ParakeetCoreMLEngine.validateModelBundle(at: dir)
    }

    @Test("legacy vocab filename also passes")
    func legacyVocabPasses() throws {
        let dir = try makeBundle(models: Self.modelNames, vocabFiles: ["parakeet_vocab.json"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try ParakeetCoreMLEngine.validateModelBundle(at: dir)
    }

    @Test("missing bundle directory throws modelsNotFound")
    func missingDirectoryThrows() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-bundle-test-nonexistent-\(UUID().uuidString)")
        expectModelsNotFound(dir, "nonexistent dir must throw the retryable modelsNotFound")
    }

    @Test(
        "partial bundle (interrupted download) throws modelsNotFound for each missing model",
        arguments: ["Preprocessor", "Encoder", "Decoder", "JointDecision"]
    )
    func partialBundleThrows(missing: String) throws {
        // The production wedge: Preprocessor present, later models missing.
        let dir = try makeBundle(
            models: Self.modelNames.filter { $0 != missing },
            vocabFiles: ["parakeet_v3_vocab.json"])
        defer { try? FileManager.default.removeItem(at: dir) }
        expectModelsNotFound(dir, "bundle missing \(missing).mlmodelc must throw modelsNotFound")
    }

    @Test("missing vocab file throws modelsNotFound")
    func missingVocabThrows() throws {
        let dir = try makeBundle(models: Self.modelNames, vocabFiles: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        expectModelsNotFound(dir, "bundle with all models but no vocab must throw modelsNotFound")
    }
}
