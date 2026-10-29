// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CanaryCoreMLWarmupProvider.swift
//  Onit
//
//  Warmup provider for the Canary-1B-v2 CoreML ASR backend. Downloads the int4
//  bundle if needed, then loads it into `CanaryCoreMLEngine`. Mirrors
//  `ParakeetCoreMLWarmupProvider`.
//

import Defaults
import Foundation

@MainActor
final class CanaryCoreMLWarmupProvider: WarmupProvider, ObservableObject {

    static let shared = CanaryCoreMLWarmupProvider()

    let identifier = "canary"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled]
            && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .canaryCoreML
    }

    @Published private(set) var isWarmedUp = false

    private var pendingTeardown: Task<Void, Never>?

    private init() {}

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        log.info("CanaryCoreMLWarmupProvider: Starting warmup...")

        // Phase 1: download (no-op / offline-skip when already present).
        do {
            let downloader = HuggingFaceModelDownloader.shared
            let canaryModel = ASRModel.byId(ASRModel.canaryV2Id)
            if let model = canaryModel, !downloader.isCanaryDownloaded() {
                try ASRModelDownloadManager.precheckDiskSpace(for: model)
            }
            try await downloader.downloadCanaryIfNeeded(progress: AtomicProgress())
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            log.error("CanaryCoreMLWarmupProvider: download failed: \(error.localizedDescription)")
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        // Phase 2: load the CoreML models into the engine.
        do {
            try await CanaryCoreMLEngine.shared.ensureLoaded()
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            log.error("CanaryCoreMLWarmupProvider: load failed: \(error.localizedDescription)")
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        isWarmedUp = true
        CanaryCoreMLASRService.shared.markAsReady()
        log.info("CanaryCoreMLWarmupProvider: Warmup complete")
    }

    /// Reset warmup state and free the resident CoreML models. Called when the
    /// user switches away from the Canary backend.
    func reset() {
        isWarmedUp = false
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await CanaryCoreMLEngine.shared.unload()
        }
    }
}
