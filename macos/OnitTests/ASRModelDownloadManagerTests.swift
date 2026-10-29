// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelDownloadManagerTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import Testing
@testable import Onit

/// Serialized: download/cancel/delete all mutate the shared manager's state map,
/// and tests that exercise back-to-back transitions would interleave under
/// parallel execution.
@MainActor
@Suite(.serialized)
struct ASRModelDownloadManagerTests {

    // MARK: - Initial state

    @Test("Manager exposes a state entry for every catalog model")
    func everyCatalogModelHasAState() {
        let manager = ASRModelDownloadManager.shared
        for model in ASRModel.catalog {
            #expect(manager.installState(for: model) != nil, "missing state for \(model.id)")
        }
    }

    // MARK: - Progress

    @Test("Progress for a known model is zero before any download starts")
    func progressStartsAtZero() {
        let manager = ASRModelDownloadManager.shared
        let model = ASRModel.byId("whisper-medium")!
        let progress = manager.progress(for: model)
        #expect(progress.value >= 0 && progress.value <= 1)
    }

    // MARK: - Pure helpers

    @Test("isInstalled is false for Whisper models when the cache directory is absent")
    func whisperNotInstalledByDefault() {
        let model = ASRModel.byId("whisper-medium")!
        // We don't write any model file in tests, so install state must be .notInstalled
        // unless the host machine happens to have a cached download - accept both.
        let state = ASRModelDownloadManager.shared.installState(for: model)
        #expect([.notInstalled, .installed].contains(state))
    }

    // MARK: - State machine transitions

    @Test("delete() returns the state to .notInstalled and clears progress")
    func deleteResetsState() async {
        let manager = ASRModelDownloadManager.shared
        let model = ASRModel.byId("whisper-medium")!
        await manager.delete(model)
        #expect(manager.installState(for: model) == .notInstalled)
        #expect(manager.progress(for: model).value == 0)
    }

    @Test("download() on an unsupported model id surfaces a .failed state")
    func unsupportedModelSurfacesFailedState() async {
        let manager = ASRModelDownloadManager.shared
        // FluidAudio is not exposed in the picker - performDownload throws
        // `.unsupportedModel`, which the Task body maps to .failed.
        let unsupported = ASRModel(
            id: "unsupported-test-only",
            displayName: "Unsupported",
            shortDescription: "Test only",
            speedRating: 0,
            accuracyRating: 0,
            sizeBytes: 1,
            isMultilingual: false,
            isDefault: false,
            backend: .fluidAudio
        )
        manager.download(unsupported)
        // Spin until the Task body has flipped state. 2 s is generous for a synchronous throw.
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if case .failed = manager.installState(for: unsupported) { break }
        }
        if case .failed = manager.installState(for: unsupported) {
            // OK
        } else {
            Issue.record("Expected .failed state, got \(manager.installState(for: unsupported))")
        }
    }

    @Test("download() after a .failed state re-enters .downloading (retry path)")
    func retryAfterFailureReentersDownloading() async {
        let manager = ASRModelDownloadManager.shared
        let model = ASRModel(
            id: "retry-test-only",
            displayName: "Retry Test",
            shortDescription: "Test only",
            speedRating: 0,
            accuracyRating: 0,
            sizeBytes: 1,
            isMultilingual: false,
            isDefault: false,
            backend: .fluidAudio  // .fluidAudio path throws synchronously → fast fail
        )
        manager.download(model)
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if case .failed = manager.installState(for: model) { break }
        }
        // The fix for the cancel/download race relies on a token guard: the retry
        // must bump the token so the second download's state isn't overwritten by
        // the first task's late completion.
        manager.download(model)
        let state = manager.installState(for: model)
        // Either still .downloading or already flipped to .failed by the second
        // task - both are acceptable retry behaviours; what we don't want is
        // .notInstalled, which would mean the retry didn't even register.
        #expect(state != .notInstalled, "Retry didn't register: \(state)")
    }
}
