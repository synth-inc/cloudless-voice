// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelsViewModel.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Combine
import Foundation

// MARK: - Protocol for testability

/// Narrow read-side seam so the view model can be unit-tested without touching
/// `ASRModelDownloadManager` (which depends on the filesystem and WhisperKit).
@MainActor
protocol ASRModelInstallStateReading: AnyObject {
    func installState(for model: ASRModel) -> ModelInstallState
}

extension ASRModelDownloadManager: ASRModelInstallStateReading {}

// MARK: - Card State

extension ASRModelsViewModel {

    /// Visual state of a single model row, mapped to the Figma states:
    /// Active / Downloaded (Use + delete) / Downloading (Cancel + progress) /
    /// Available (Download) / Failed.
    ///
    /// NOTE - the Figma comp also has a "Switching…" pill for the post-select
    /// warmup hand-off. Not implemented: `select(_:)` flips `selectedASRModelId`
    /// synchronously and the model-status pill in Settings is the only feedback
    /// the user sees during warmup. Wiring `.switching` would require
    /// subscribing to `WarmupCoordinator.warmupState` here.
    enum CardState: Equatable {
        case active
        case downloaded
        case downloading
        case available
        case failed(String)
    }
}

// MARK: - View Model

@MainActor
final class ASRModelsViewModel: ObservableObject {

    // MARK: - Inputs

    private let reader: any ASRModelInstallStateReading
    private let config: TranscriptionConfig

    // MARK: - Init

    init(reader: any ASRModelInstallStateReading = ASRModelDownloadManager.shared,
         config: TranscriptionConfig = .shared) {
        self.reader = reader
        self.config = config
    }

    // MARK: - Catalog partition

    var models: [ASRModel] { ASRModel.catalog.filter(\.isAvailableForCurrentOS) }

    /// Non-experimental models. The "Downloaded" / "More models" groups only
    /// ever list these - experimental entries live in their own section
    /// (`experimentalModels`) regardless of install state so the quality
    /// warning always travels with them.
    private var standardModels: [ASRModel] { models.filter { !$0.isExperimental } }

    /// Models with install state `.installed`, ordered to match the catalog.
    /// The active model floats to the top inside this group so the user sees
    /// "what's currently used" first.
    var downloadedModels: [ASRModel] {
        let installed = standardModels.filter { reader.installState(for: $0) == .installed }
        return installed.sorted { lhs, rhs in
            if lhs.id == config.selectedASRModelId { return true }
            if rhs.id == config.selectedASRModelId { return false }
            return false
        }
    }

    /// Models not yet on disk, grouped under "More models" in the sheet.
    var availableModels: [ASRModel] {
        standardModels.filter {
            switch reader.installState(for: $0) {
            case .installed, .downloading: return false
            case .notInstalled, .failed:   return true
            }
        }
    }

    /// Models currently being downloaded, surfaced alongside "Downloaded" in the
    /// Figma "downloading" state.
    var downloadingModels: [ASRModel] {
        standardModels.filter { reader.installState(for: $0) == .downloading }
    }

    /// Experimental models, shown in their own picker section with a warning
    /// regardless of install state. Ordered to match the catalog.
    var experimentalModels: [ASRModel] {
        models.filter(\.isExperimental)
    }

    // MARK: - Per-row state

    func cardState(for model: ASRModel) -> CardState {
        let install = reader.installState(for: model)
        let isSelected = config.selectedASRModelId == model.id

        switch install {
        case .downloading:
            return .downloading
        case .failed(let message):
            return .failed(message)
        case .notInstalled:
            return .available
        case .installed:
            return isSelected ? .active : .downloaded
        }
    }

    // MARK: - Actions

    /// Select an installed model as the active one. No-op if the target is not
    /// yet installed - the picker should disable the Use button in that case.
    func select(_ model: ASRModel) {
        guard reader.installState(for: model) == .installed else { return }
        config.selectedASRModelId = model.id
    }
}
