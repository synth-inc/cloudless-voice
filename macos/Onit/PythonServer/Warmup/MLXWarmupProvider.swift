// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Defaults
import Foundation

/// Single warmup provider for every MLX-based ASR model. Delegates download +
/// load to `HuggingFaceModelDownloader` + `MLXASREngine`. Keeps the
/// `pendingTeardown` serialization so a fresh `warmup()` never races an
/// in-flight `reset()` unload.
@MainActor
final class MLXWarmupProvider: WarmupProvider, ObservableObject {

    static let shared = MLXWarmupProvider()

    let identifier = "mlxasr"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled] && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .mlx
    }

    @Published private(set) var isWarmedUp = false

    /// The model id the current warmup loaded. Used to detect an intra-`.mlx`
    /// model switch (e.g. Granite → Qwen): `isEnabled` stays true so the
    /// coordinator's enable/disable check alone would never reload - `isStale`
    /// closes that gap.
    private(set) var warmedModelId: String?

    /// True once warmed for a model that is no longer selected - triggers a reset
    /// + re-warm so the engine swaps to the new model and frees the old one.
    var isStale: Bool {
        isWarmedUp && warmedModelId != TranscriptionConfig.shared.selectedASRModelId
    }

    private var pendingTeardown: Task<Void, Never>?

    private init() {}

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        let modelId = TranscriptionConfig.shared.selectedASRModelId
        let isFirstTime = !Defaults[.mlxWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("MLXWarmupProvider: Starting warmup for \(modelId) (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            if let model = ASRModel.byId(modelId), !ASRModelDownloadManager.isInstalledOnDisk(model) {
                try ASRModelDownloadManager.precheckDiskSpace(for: model)
            }
            try await HuggingFaceModelDownloader.shared.downloadMLXModelIfNeeded(modelId: modelId)
            try await MLXASREngine.shared.ensureLoaded(modelId: modelId)
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs, error: error.localizedDescription)
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        // A cancellation landing mid-load must not mark a now-disabled provider
        // as warmed up - the multi-GB model would linger resident until the next
        // featureStateChanged / memory-pressure pass.
        guard !Task.isCancelled else { throw WarmupError.cancelled }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        warmedModelId = modelId
        Defaults[.mlxWarmupCompletedOnce] = true
        MLXASRService.shared.markAsReady()
        log.info("MLXWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs)
    }

    func reset() {
        isWarmedUp = false
        warmedModelId = nil
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await MLXASREngine.shared.unload()
        }
    }
}
