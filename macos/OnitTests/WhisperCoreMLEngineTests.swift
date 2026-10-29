// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperCoreMLEngineTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import Testing
@testable import Onit

/// Engine wrapper for WhisperKit. The bulk of the inference is delegated to the
/// upstream package, so these tests cover the pure surface: the model-id ↔
/// WhisperKit variant mapping, default state, and the throw-when-not-loaded
/// contract. Integration tests that actually load a `.mlpackage` belong in a
/// separate, opt-in suite and intentionally are not included here.
struct WhisperCoreMLEngineTests {

    // MARK: - Variant Mapping

    @Test("ASRModel ids map to the matching WhisperKit variant strings")
    func variantMappingForKnownModels() {
        // NB: the large-v3 turbo variant uses an underscore before `turbo`, not a
        // hyphen - must match the folder name on `argmaxinc/whisperkit-coreml`.
        #expect(WhisperCoreMLEngine.whisperKitVariant(for: "whisper-large-turbo-v3") == "openai_whisper-large-v3_turbo")
        #expect(WhisperCoreMLEngine.whisperKitVariant(for: "whisper-medium") == "openai_whisper-medium")
    }

    @Test("Unknown / non-Whisper ids yield no variant")
    func variantMappingForUnknownModels() {
        #expect(WhisperCoreMLEngine.whisperKitVariant(for: "parakeet-v3") == nil)
        #expect(WhisperCoreMLEngine.whisperKitVariant(for: "does-not-exist") == nil)
    }

    // MARK: - Storage location

    @Test("Whisper weights live under Application Support, never in ~/Documents")
    func downloadBaseLivesInApplicationSupport() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(WhisperCoreMLEngine.downloadBase.path.hasPrefix(appSupport.path))
        #expect(!WhisperCoreMLEngine.downloadBase.path.hasPrefix(documents.path))
    }

    /// The migration is what stands between an existing install and a 1.5 GB
    /// (Medium) or ~3 GB (large-v3-turbo) re-download, so it gets an actual move
    /// on disk rather than a hand-written layout: the legacy tree is rebuilt from
    /// the same production constants the engine resolves its paths from.
    @Test("A legacy install is moved whole: weights and tokenizer snapshots alike")
    func legacyInstallIsMigrated() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whisper-migration-\(UUID().uuidString)")
        let legacyBase = root.appendingPathComponent("legacy")
        let base = root.appendingPathComponent("new")
        defer { try? fileManager.removeItem(at: root) }

        let variant = try #require(WhisperCoreMLEngine.whisperKitVariant(for: ASRModel.whisperMediumId))
        let component = WhisperCoreMLEngine.modelRepoPath + "/" + variant + "/AudioEncoder.mlmodelc"
        let tokenizer = WhisperCoreMLEngine.tokenizerRepoParent + "/whisper-medium"
        for relativePath in [component, tokenizer] {
            let directory = legacyBase.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: directory.appendingPathComponent("marker"))
        }

        // Both repos are discovered, the tokenizer one by enumeration.
        let relativePaths = WhisperCoreMLEngine.whisperRepoRelativePaths(in: legacyBase)
        #expect(relativePaths.sorted() == [WhisperCoreMLEngine.modelRepoPath, tokenizer].sorted())

        #expect(WhisperCoreMLEngine.migrateLegacyStorage(from: legacyBase, to: base))

        for relativePath in relativePaths {
            #expect(!fileManager.fileExists(atPath: legacyBase.appendingPathComponent(relativePath).path))
        }
        // Contents travelled, not just the directories.
        for relativePath in [component, tokenizer] {
            let marker = base.appendingPathComponent(relativePath).appendingPathComponent("marker")
            #expect(fileManager.fileExists(atPath: marker.path))
        }
        // The emptied legacy tree is gone, not left as a bare `huggingface` folder.
        #expect(!fileManager.fileExists(atPath: legacyBase.path))
        // Idempotent: nothing left to move on the next launch.
        #expect(WhisperCoreMLEngine.migrateLegacyStorage(from: legacyBase, to: base) == false)
    }

    @Test("An install already at the destination is never overwritten")
    func destinationInstallWins() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whisper-migration-\(UUID().uuidString)")
        let legacyBase = root.appendingPathComponent("legacy")
        let base = root.appendingPathComponent("new")
        defer { try? fileManager.removeItem(at: root) }

        for parent in [legacyBase, base] {
            let directory = parent.appendingPathComponent(WhisperCoreMLEngine.modelRepoPath)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(parent.lastPathComponent.utf8).write(to: directory.appendingPathComponent("marker"))
        }

        #expect(WhisperCoreMLEngine.migrateLegacyStorage(from: legacyBase, to: base) == false)
        let marker = base.appendingPathComponent(WhisperCoreMLEngine.modelRepoPath)
            .appendingPathComponent("marker")
        #expect(try Data(contentsOf: marker) == Data("new".utf8))
    }

    // MARK: - State

    @Test("A fresh engine instance reports as not loaded")
    func freshEngineIsNotLoaded() async {
        let engine = WhisperCoreMLEngine.makeForTesting()
        let loaded = await engine.isLoaded
        #expect(loaded == false)
    }

    @Test("Transcribe throws .modelNotLoaded before ensureLoaded is called")
    func transcribeWithoutLoadThrows() async {
        let engine = WhisperCoreMLEngine.makeForTesting()
        await #expect(throws: WhisperCoreMLError.modelNotLoaded) {
            _ = try await engine.transcribe(samples: [], language: nil)
        }
    }
}
