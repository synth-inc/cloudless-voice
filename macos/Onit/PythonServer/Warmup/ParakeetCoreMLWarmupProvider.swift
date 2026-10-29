// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ParakeetCoreMLWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

import Defaults
import Foundation
import PostHog

/// Warmup provider for the Parakeet CoreML ASR transcription service.
/// Downloads models via HuggingFace, then loads them into the on-device Swift engine.
@MainActor
final class ParakeetCoreMLWarmupProvider: WarmupProvider, ObservableObject {

    // MARK: - Singleton

    static let shared = ParakeetCoreMLWarmupProvider()

    // MARK: - WarmupProvider

    let identifier = "parakeet"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled] && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .parakeetCoreML
    }

    @Published private(set) var isWarmedUp = false

    /// In-flight teardown spawned by `reset()`; see `MLXWarmupProvider` for
    /// the rationale.
    private var pendingTeardown: Task<Void, Never>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        let isFirstTime = !Defaults[.parakeetWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("ParakeetCoreMLWarmupProvider: Starting warmup (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        // Phase 1: Download models via Swift (with progress tracking)
        do {
            // Fail fast on disk-space pressure before the 700 MB transfer starts.
            let parakeetModelId = ASRModel.parakeetV3Id
            if let model = ASRModel.byId(parakeetModelId), !ASRModelDownloadManager.isInstalledOnDisk(model) {
                try ASRModelDownloadManager.precheckDiskSpace(for: model)
            }
            try await HuggingFaceModelDownloader.shared.downloadParakeetIfNeeded()
        } catch {
            log.warning("ParakeetCoreMLWarmupProvider: Swift download failed: \(error.localizedDescription)")
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs, error: error.localizedDescription)
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        // Phase 2: Load CoreML models into the Swift engine
        do {
            try await ParakeetCoreMLEngine.shared.ensureLoaded()
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs, error: error.localizedDescription)
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        // Phase 3 (Silero VAD) is handled by `SileroVADWarmupProvider` - registered as a
        // standalone provider so its failures surface in the menu bar with a retry button.

        // Phase 4: Load Whisper-base CoreML for multi-language detection. Only needed
        // when the user has ≥2 candidate languages configured; load eagerly so the
        // first multi-lang recording doesn't pay the ~2 s load cost inline.
        // Non-fatal on error - multi-lang falls back to auto when the model isn't ready.
        if TranscriptionConfig.shared.transcriptionLanguages.count >= 2 {
            do {
                try await WhisperLanguageDetector.shared.ensureLoaded()
            } catch {
                log.warning("ParakeetCoreMLWarmupProvider: Whisper language detector setup failed: \(error.localizedDescription) - multi-language recordings will fall back to auto")
            }
        }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        Defaults[.parakeetWarmupCompletedOnce] = true
        ParakeetCoreMLASRService.shared.markAsReady()
        // Keep-alive pings are now driven centrally by `ASRModelLifecycleService`
        // (per-backend policy), which also handles unload-on-idle. It picks up the
        // newly-warmed model on its next tick - nothing to start here.
        log.info("ParakeetCoreMLWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(model: identifier, isFirstTime: isFirstTime, durationMs: durationMs)
    }

    /// Reset the warmup state (used when models are re-downloaded or the user
    /// switches to a different ASR backend). Unloading the engine drops the four
    /// resident `MLModel`s (Preprocessor + Encoder + Decoder + JointDecision, plus
    /// the lazily-loaded JointDecisionv3) - without this, ~700 MB of CoreML model
    /// memory stays allocated even after the backend is no longer active.
    func reset() {
        isWarmedUp = false
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await ParakeetCoreMLEngine.shared.unload()
        }
    }
}
