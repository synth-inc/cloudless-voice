// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperCoreMLWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Defaults
import Foundation
import PostHog

/// Warmup provider for the Whisper CoreML ASR transcription service.
/// Delegates download + load to `WhisperCoreMLEngine` (which wraps WhisperKit).
@MainActor
final class WhisperCoreMLWarmupProvider: WarmupProvider, ObservableObject {

    static let shared = WhisperCoreMLWarmupProvider()

    let identifier = "whisper"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled] && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .whisperCoreML
    }

    @Published private(set) var isWarmedUp = false

    /// In-flight teardown spawned by `reset()`; see `MLXWarmupProvider` for
    /// the rationale - protects against a warmup that races a still-in-flight
    /// unload to the actor's queue.
    private var pendingTeardown: Task<Void, Never>?

    private init() {}

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        let modelId = TranscriptionConfig.shared.selectedASRModelId
        let isFirstTime = !Defaults[.whisperWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("WhisperCoreMLWarmupProvider: Starting warmup for \(modelId) (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            // Fail fast with a clean disk-space message rather than letting
            // WhisperKit's download crash mid-transfer (worst case is ~1.5 GB
            // for Whisper Medium).
            if let model = ASRModel.byId(modelId), !ASRModelDownloadManager.isInstalledOnDisk(model) {
                try ASRModelDownloadManager.precheckDiskSpace(for: model)
            }
            // Auto-recover from a missing-files state (e.g. user trashed the
            // model dir between sessions). Parity with Parakeet / Moonshine /
            // Qwen3 warmup providers. `downloadWhisperIfNeeded` gates on
            // `isModelComplete`, so a complete bundle costs nothing here and an
            // incomplete one is re-fetched.
            try await HuggingFaceModelDownloader.shared.downloadWhisperIfNeeded(modelId: modelId)
            try await WhisperCoreMLEngine.shared.ensureLoaded(modelId: modelId)
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs, error: error.localizedDescription)
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        Defaults[.whisperWarmupCompletedOnce] = true
        WhisperCoreMLASRService.shared.markAsReady()
        log.info("WhisperCoreMLWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs)
    }

    func reset() {
        isWarmedUp = false
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await WhisperCoreMLEngine.shared.unload()
        }
    }
}
