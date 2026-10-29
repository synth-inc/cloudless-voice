// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MoonshineWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-19.
//

import Defaults
import Foundation
import PostHog

/// Warmup provider for the Moonshine (Useful Sensors) ONNX ASR transcription
/// service. Delegates download + load to `MoonshineEngine`.
@MainActor
final class MoonshineWarmupProvider: WarmupProvider, ObservableObject {

    static let shared = MoonshineWarmupProvider()

    let identifier = "moonshine"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled] && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .moonshineONNX
    }

    @Published private(set) var isWarmedUp = false

    /// In-flight teardown spawned by `reset()`; see `MLXWarmupProvider` for
    /// the rationale.
    private var pendingTeardown: Task<Void, Never>?

    private init() {}

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        let modelId = TranscriptionConfig.shared.selectedASRModelId
        let isFirstTime = !Defaults[.moonshineWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("MoonshineWarmupProvider: Starting warmup for \(modelId) (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            // Fail fast with a clean disk-space message rather than letting the
            // 4 `.ort` downloads fail mid-transfer.
            if let model = ASRModel.byId(modelId), !ASRModelDownloadManager.isInstalledOnDisk(model) {
                try ASRModelDownloadManager.precheckDiskSpace(for: model)
            }
            // Auto-recover from a missing-files state (e.g. user trashed the
            // model dir between sessions). Parity with ParakeetCoreMLWarmupProvider
            // which always re-downloads before loading. Idempotent: no-op when
            // the 4 `.ort` files are already present on disk.
            try await HuggingFaceModelDownloader.shared.downloadMoonshineIfNeeded(modelId: modelId)
            try await MoonshineEngine.shared.ensureLoaded(modelId: modelId)
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs, error: error.localizedDescription)
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        Defaults[.moonshineWarmupCompletedOnce] = true
        MoonshineASRService.shared.markAsReady()
        log.info("MoonshineWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs)
    }

    func reset() {
        isWarmedUp = false
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await MoonshineEngine.shared.unload()
        }
    }
}
