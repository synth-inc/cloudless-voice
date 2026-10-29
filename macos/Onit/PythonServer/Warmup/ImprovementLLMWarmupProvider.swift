// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ImprovementLLMWarmupProvider.swift
//  Onit
//

import Combine
import Defaults
import Foundation
import MLX
import PostHog

/// Warmup provider for the fine-tuned improvement LLM
/// (`getonit/transcription-cleanup-llama3.2-1b`, ~680MB).
///
/// One model, two consumers: N-best hypothesis selection and the Smart
/// Cleanup backtracking correction pass. Both go through
/// `TranscriptionLLMService.shared`, which owns the `ModelContainer`.
@MainActor
final class ImprovementLLMWarmupProvider: WarmupProvider, ObservableObject {

    // MARK: - Singleton

    static let shared = ImprovementLLMWarmupProvider()

    // MARK: - WarmupProvider

    let identifier = "improvementLLM"
    /// Runs after the Cleanup model (priority 3). Not on the
    /// critical path for first-keystroke transcription.
    let priority = 4

    /// Enabled when transcription is on AND at least one consumer is enabled:
    ///   - N-best hypothesis selection (`nbestSelectionEnabled`), or
    ///   - Smart Cleanup with backtracking (`smartFormattingEnabled && sfBacktrackingEnabled`).
    ///
    /// Without the `transcriptionEnabled` master-flag gate we would download
    /// ~680MB of weights for users who don't use transcription at all but
    /// happen to have N-best/Smart Cleanup defaults-on.
    var isEnabled: Bool {
        // See `ScoringWarmupProvider.isEnabled`: no MLX, nothing to warm, and
        // `isPreparing` must not latch true forever on Intel.
        guard MLXRuntime.isSupported else { return false }
        guard Defaults[.transcriptionEnabled] else { return false }
        let nbest = Defaults[Defaults.Keys.TranscriptionConfigKeys.nbestSelectionEnabled]
        let smartFormatting = TranscriptionConfig.isSmartCleanupSelected
        let backtracking = Defaults[Defaults.Keys.TranscriptionConfigKeys.sfBacktrackingEnabled]
        return nbest || (smartFormatting && backtracking)
    }

    @Published private(set) var isWarmedUp = false
    @Published private(set) var errorMessage: String?

    /// True once this session's warmup succeeded, and **stays** true when `CleanupModelLifecycleService`
    /// drops the weights on idle to reclaim RAM. `isWarmedUp` deliberately mirrors residency (see the
    /// subscription in `init`) so a re-load can be re-triggered - which makes it wrong for *UI*
    /// readiness: a routine 30-minute idle unload would otherwise put every "still setting up" surface
    /// (Hint pill, menu-bar "Don't quit the app" row, Home setup card, status header) back on screen for
    /// a fully-warmed app, contradicting the lifecycle service's own contract that unloading must not
    /// flip user-visible warmup status. Ask `isPreparing` in UI code, not `isWarmedUp`. Cleared by `reset()`.
    @Published private(set) var hasWarmedUpThisSession = false

    /// Whether the model is enabled but has never finished warming up in this session - the question
    /// every readiness surface actually wants answered.
    var isPreparing: Bool {
        return isEnabled && !isWarmedUp && !hasWarmedUpThisSession
    }

    // MARK: - Private

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    private init() {
        // Mirror the service's loaded-state for the lifetime of the provider.
        // The service is the source of truth for the underlying ModelContainer -
        // when TranscriptionManager.cleanup() (or any future path) calls
        // unloadModel(), this subscription flips isWarmedUp back to false so
        // a subsequent featureStateChanged() actually triggers a re-load instead
        // of skipping the provider on a stale "already warm" flag.
        let service = TranscriptionLLMService.shared
        isWarmedUp = service.isImprovementModelLoaded
        service.$isImprovementModelLoaded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loaded in
                guard let self else { return }
                if self.isWarmedUp != loaded {
                    self.isWarmedUp = loaded
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - WarmupProvider

    func warmup() async throws {
        guard !isWarmedUp else { return }

        errorMessage = nil
        let isFirstTime = !Defaults[.improvementLLMWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("ImprovementLLMWarmupProvider: Starting warmup (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            try await TranscriptionLLMService.shared.loadImprovementModel()
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
        hasWarmedUpThisSession = true
        Defaults[.improvementLLMWarmupCompletedOnce] = true
        // Register periodic keep-alive pings so the fine-tuned Llama stays resident.
        // The `isActive` check mirrors `isEnabled`: the model can be resident from a
        // prior session even after the user turns its consumers off, and we don't want
        // to burn GPU time inferring for a feature that won't fire.
        KeepAliveService.shared.register(.init(
            identifier: identifier,
            isActive: {
                guard Defaults[.transcriptionEnabled] else { return false }
                let nbest = Defaults[Defaults.Keys.TranscriptionConfigKeys.nbestSelectionEnabled]
                let smartFormatting = TranscriptionConfig.isSmartCleanupSelected
                let backtracking = Defaults[Defaults.Keys.TranscriptionConfigKeys.sfBacktrackingEnabled]
                guard nbest || (smartFormatting && backtracking) else { return false }
                return TranscriptionLLMService.shared.isImprovementModelLoaded
            },
            ping: {
                // Tiny prompt; output discarded. 5s timeout matches the production
                // correction path so a cold first inference isn't logged as an error.
                _ = try await TranscriptionLLMService.shared.generateWithImprovementModel(
                    userPrompt: "x", timeoutSeconds: 5.0)
            }
        ))
        log.info("ImprovementLLMWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(
            model: identifier, isFirstTime: isFirstTime, durationMs: durationMs
        )
    }

    /// Reset the warmup state and free the fine-tuned Llama 3.2 1B cleanup model.
    /// Triggered when the user disables N-best selection / Smart Cleanup backtracking
    /// so the ~680 MB of GPU memory held by `TranscriptionLLMService` goes back to
    /// the system. The Combine subscription on `isImprovementModelLoaded` flips
    /// `isWarmedUp` back to false once the service finishes its teardown.
    func reset() {
        isWarmedUp = false
        hasWarmedUpThisSession = false
        errorMessage = nil
        KeepAliveService.shared.deregister(identifier)
        TranscriptionLLMService.shared.unloadModel()
        // Drop the MLX buffer pool - same rationale as `ScoringWarmupProvider.reset()`.
        // Safe to call here even if other MLX models are still resident; only the
        // recyclable cache buffers are freed.
        MLXRuntime.clearCache()
    }
}
