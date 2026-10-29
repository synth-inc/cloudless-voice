// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelsViewModelTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import Testing
@testable import Onit

/// Serialized: every test mutates `TranscriptionConfig.shared.selectedASRModelId`,
/// which would interleave with `TranscriptionConfigASRModelTests` under parallel
/// execution.
@MainActor
@Suite(.serialized)
struct ASRModelsViewModelTests {

    /// Test-only state reader so we don't depend on the on-disk install state of the host.
    private final class StubReader: ASRModelInstallStateReading {
        var stateByModelId: [String: ModelInstallState] = [:]
        func installState(for model: ASRModel) -> ModelInstallState {
            stateByModelId[model.id] ?? .notInstalled
        }
    }

    private func makeViewModel(states: [String: ModelInstallState] = [:],
                               selected: String = ASRModel.defaultModelId) -> (ASRModelsViewModel, StubReader, () -> Void) {
        let reader = StubReader()
        reader.stateByModelId = states
        let config = TranscriptionConfig.shared
        let previous = config.selectedASRModelId
        config.selectedASRModelId = selected
        let viewModel = ASRModelsViewModel(reader: reader)
        let restore = { config.selectedASRModelId = previous }
        return (viewModel, reader, restore)
    }

    @Test("Selected + installed → .active")
    func selectedAndInstalledIsActive() {
        let (vm, _, restore) = makeViewModel(
            states: ["parakeet-v3": .installed],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let parakeet = ASRModel.byId("parakeet-v3")!
        #expect(vm.cardState(for: parakeet) == .active)
    }

    @Test("Installed but not selected → .downloaded (Use + delete)")
    func installedNotSelectedIsDownloaded() {
        let (vm, _, restore) = makeViewModel(
            states: ["whisper-medium": .installed],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let whisper = ASRModel.byId("whisper-medium")!
        #expect(vm.cardState(for: whisper) == .downloaded)
    }

    @Test("Not installed → .available (Download button)")
    func notInstalledIsAvailable() {
        let (vm, _, restore) = makeViewModel(
            states: ["whisper-medium": .notInstalled],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let whisper = ASRModel.byId("whisper-medium")!
        #expect(vm.cardState(for: whisper) == .available)
    }

    @Test("Downloading → .downloading (Cancel + progress bar)")
    func downloadingState() {
        let (vm, _, restore) = makeViewModel(
            states: ["whisper-large-turbo-v3": .downloading],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let whisper = ASRModel.byId("whisper-large-turbo-v3")!
        #expect(vm.cardState(for: whisper) == .downloading)
    }

    @Test("Failed install propagates message")
    func failedState() {
        let (vm, _, restore) = makeViewModel(
            states: ["whisper-medium": .failed("boom")],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let whisper = ASRModel.byId("whisper-medium")!
        #expect(vm.cardState(for: whisper) == .failed("boom"))
    }

    @Test("Sections: installed models on top, available below")
    func sectionsPartition() {
        let (vm, _, restore) = makeViewModel(
            states: [
                "parakeet-v3": .installed,
                "whisper-large-turbo-v3": .installed,
                "whisper-medium": .notInstalled,
            ],
            selected: "parakeet-v3"
        )
        defer { restore() }
        let downloaded = vm.downloadedModels.map(\.id)
        let more = vm.availableModels.map(\.id)
        #expect(downloaded.contains("parakeet-v3"))
        #expect(downloaded.contains("whisper-large-turbo-v3"))
        #expect(more.contains("whisper-medium"))
        #expect(!downloaded.contains("whisper-medium"))
    }
}
