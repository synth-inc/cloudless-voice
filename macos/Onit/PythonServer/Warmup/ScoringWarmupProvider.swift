// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-25.
//

import Defaults
import Foundation
import MLX
import PostHog

/// Warmup provider for the scoring-scored cleanup pipeline.
///
/// Warmup phases:
///   1. Download Llama 3.2 1B model weights + tokenizer via HuggingFaceModelDownloader
///   2. Load the model into MLXScoringEngine via MLX Swift (GPU-accelerated)
@MainActor
final class ScoringWarmupProvider: WarmupProvider, ObservableObject {

    // MARK: - Singleton

    static let shared = ScoringWarmupProvider()

    // MARK: - WarmupProvider

    let identifier = "scoring"
    let priority = 3

    /// Enabled when at least one consumer of the scoring LLM is on. We deliberately
    /// do NOT include `transcriptionEnabled` as a master gate here - that flag is on
    /// for almost every user, but most of them never enable smart formatting or LM
    /// conditioning. Including it loaded Llama 3.2 1B (~1.25 GB GPU/MLX) at startup
    /// for everyone, accounting for the bulk of Onit's reported 2-6 GB RAM footprint.
    ///
    /// Consumers (audit before adding or removing a flag):
    ///   - `smartFormatting` → `TranscriptionManager` cleanup pipeline (scoring-gated)
    ///   - `lmConditioning` → scoring-driven LM conditioning of ASR rescoring
    ///   - `customDictionary` → `CustomDictionaryScoreGate` / `ProxySelector` / `CalibrationManager`
    ///     all call `tokenScores` / `topKNext`. Without this clause the dictionary degrades
    ///     to a silent no-op ("rejecting conservatively") for users who toggle smart
    ///     formatting off but keep their dictionary on.
    var isEnabled: Bool {
        // No MLX, nothing to warm. Without this the provider stays "enabled but
        // never warmed" forever on Intel, and every readiness surface built on
        // it (`ModelDownloadIndicator.isSmartCleanupPreparing`) spins for good.
        guard MLXRuntime.isSupported else { return false }
        return TranscriptionConfig.isSmartCleanupSelected
            || Defaults[Defaults.Keys.TranscriptionConfigKeys.lmConditioningEnabled]
            || dictionaryNeedsGate
    }

    /// The dictionary consumes Llama through the NLL gate, which only produces
    /// work on the Parakeet KWS audio path or the opt-in Layer A text path. On
    /// other backends with Layer A off, the dictionary operates purely via
    /// prompt biasing (Layer B) - loading ~1.25 GB of Llama for it would be
    /// resident memory with no consumer.
    private var dictionaryNeedsGate: Bool {
        guard Defaults[.customDictionaryEnabled] else { return false }
        return Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .parakeetCoreML
            || Defaults[.customDictionaryRescoreEnabled]
    }

    @Published private(set) var isWarmedUp = false
    @Published private(set) var errorMessage: String?

    /// In-flight teardown spawned by `reset()`; see `MLXWarmupProvider` for
    /// the rationale. Particularly important here because Llama 3.2 1B is
    /// large (~1.25 GB MLX/GPU) and the consumer-toggle path (smart formatting
    /// / dictionary / LM conditioning flips) can fire rapid resets back-to-back.
    private var pendingTeardown: Task<Void, Never>?

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func warmup() async throws {
        guard !isWarmedUp else { return }
        await pendingTeardown?.value
        pendingTeardown = nil

        errorMessage = nil
        let isFirstTime = !Defaults[.scoringWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("ScoringWarmupProvider: Starting warmup (first_time=\(isFirstTime)) - model=\(ScoringModel.selected.id)")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            // Phase 1: Ensure Llama 3.2 1B weights + tokenizer are downloaded
            try await HuggingFaceModelDownloader.shared.downloadLlamaIfNeeded()

            // Phase 2: Load model via MLX Swift (GPU-accelerated batch inference)
            try await MLXScoringEngine.shared.ensureLoaded()

        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            errorMessage = error.localizedDescription
            AnalyticsManager.Transcription.warmupFailed(
                model: identifier, isFirstTime: isFirstTime,
                durationMs: durationMs, error: error.localizedDescription
            )
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        Defaults[.scoringWarmupCompletedOnce] = true
        // Register periodic keep-alive pings so Llama 3.2 1B stays resident on the GPU.
        KeepAliveService.shared.register(.init(
            identifier: identifier,
            isActive: { await MLXScoringEngine.shared.isLoaded },
            ping: {
                // A single short token exercises the MLX pipeline without doing real work.
                _ = try await MLXScoringEngine.shared.tokenScores("test")
            }
        ))
        log.info("ScoringWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(
            model: identifier, isFirstTime: isFirstTime, durationMs: durationMs
        )
    }

    /// Reset the warmup state and free the Llama 3.2 1B model. Triggered when the
    /// user disables smart formatting / LM conditioning so the ~1.25 GB of GPU
    /// memory held by the MLX container goes back to the system instead of
    /// staying resident until app exit.
    func reset() {
        isWarmedUp = false
        errorMessage = nil
        KeepAliveService.shared.deregister(identifier)
        let prior = pendingTeardown
        pendingTeardown = Task {
            await prior?.value
            await MLXScoringEngine.shared.unload()
            // `unload()` drops the model container but MLX keeps a Metal buffer pool
            // around for reuse - without flushing it, GPU memory stays allocated and
            // the IOAccelerator footprint doesn't budge.
            MLXRuntime.clearCache()
        }
    }

    /// Switch the active scoring model to the current `ScoringModel.selected`:
    /// tear down the loaded model, then re-warm - which downloads the newly
    /// selected weights if they aren't cached yet and reloads the engine. Call
    /// after changing `Defaults[.selectedScoringModelId]`. No-op-safe if smart
    /// formatting is disabled (warmup guards on `isEnabled` upstream).
    func switchToSelectedModel() async {
        reset()
        await pendingTeardown?.value
        try? await warmup()
    }
}
