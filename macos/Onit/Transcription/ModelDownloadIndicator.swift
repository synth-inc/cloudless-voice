// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ModelDownloadIndicator.swift
//  Onit
//
//  Created by Loyd Kim on 6/10/26.
//

/*
 * Cases
 * Display
 * Gates: Dictation
 * Gates: Smart Cleanup
 * Gates: Aggregate
 * Gates: Demo Readiness
 */

import Defaults
import Foundation

/// Single source of truth for the onboarding model-preparation indicators (Hint pill, entry toast,
/// menu-bar row) and the Dictation Demo entry gate.
///
/// It covers the **whole** "not ready" window - both the network **download** and the in-memory
/// **warmup/load** that follows - so the indicators are visible exactly while the demo is gated
/// (no gap; this is what makes a relaunch, where models are already on disk and only warming, show
/// status instead of a silent skip). It also distinguishes the two user-facing buckets:
///   - **dictation** - the ASR model (Parakeet).
///   - **smartCleanup** - the Smart Cleanup stack: the perplexity-gating model (Llama) and the
///     fine-tuned backtracking / N-best model (`improvementLLM`, ~680 MB). The demo's steps 2–6
///     exercise this stack (step 3 needs the backtracking model), so they share one bucket.
@MainActor
enum ModelDownloadIndicator {
    case dictationDownloading(progress: Double)
    case dictationLoading
    case smartCleanupDownloading(progress: Double)
    case smartCleanupLoading

    // MARK: - Display

    /// The active preparation phase, dictation prioritized. `nil` once everything required is warmed.
    static var current: ModelDownloadIndicator? {
        if isDictationDownloading {
            return .dictationDownloading(progress: activeDictationProgress)
        }
        if isDictationPreparing {
            return .dictationLoading
        }
        if isSmartCleanupDownloading {
            return .smartCleanupDownloading(progress: smartCleanupDownloadProgress)
        }
        if isSmartCleanupPreparing {
            return .smartCleanupLoading
        }
        return nil
    }

    /// Reactive, phase-accurate base label - each surface appends its own "Don't quit" suffix.
    var label: String {
        switch self {
        case .dictationDownloading:
            return String.localized("Downloading local dictation model…", table: "MenuBar")
        case .dictationLoading:
            return String.localized("Loading local dictation model…", table: "MenuBar")
        case .smartCleanupDownloading:
            return String.localized("Downloading Smart Cleanup model…", table: "MenuBar")
        case .smartCleanupLoading:
            return String.localized("Loading Smart Cleanup model…", table: "MenuBar")
        }
    }

    /// Download fraction (0.0–1.0), or `nil` during the warmup/load phase (no determinate progress).
    var progress: Double? {
        switch self {
        case .dictationDownloading(let progress), .smartCleanupDownloading(let progress):
            return progress
        case .dictationLoading, .smartCleanupLoading:
            return nil
        }
    }

    // MARK: - Gates: Dictation

    /// The dictation model is whichever ASR backend is *active* - not necessarily Parakeet. Readiness
    /// (`isInitialized`) is already backend-agnostic (it flips for whatever backend warms up), so we
    /// map the active backend to its failed-provider key + downloader state/progress rather than
    /// hardcoding Parakeet. Backends the downloader publishes a state for (Parakeet/FluidAudio →
    /// `parakeetState`, MLX models → `mlxModelState`) get a determinate `%`; Whisper/Moonshine don't
    /// surface one through this channel, so they show the indeterminate "Loading…" form throughout.

    /// Failed-provider key for the active backend (the same registry dispatch
    /// `TranscriptionManager.initializeASRBackend` uses).
    private static var activeDictationProviderId: String {
        return ASRBackendRegistry.descriptor(for: TranscriptionConfig.shared.backend).providerId
    }

    /// The active backend's published download state, or `nil` if the downloader doesn't surface one.
    private static var activeDictationDownloadState: ModelDownloadState? {
        switch TranscriptionConfig.shared.backend {
        case .parakeetCoreML, .fluidAudio: return HuggingFaceModelDownloader.shared.parakeetState
        case .mlx:                         return HuggingFaceModelDownloader.shared.mlxModelState
        case .whisperCoreML, .moonshineONNX, .canaryCoreML: return nil
        }
    }

    private static var activeDictationProgress: Double {
        switch TranscriptionConfig.shared.backend {
        case .parakeetCoreML, .fluidAudio: return HuggingFaceModelDownloader.shared.parakeetProgress.value
        case .mlx:                         return HuggingFaceModelDownloader.shared.mlxModelProgress.value
        case .whisperCoreML, .moonshineONNX, .canaryCoreML: return 0
        }
    }

    /// Dictation enabled but not yet warmed (covers both download and the warmup tail).
    static var isDictationPreparing: Bool {
        return
            Defaults[.transcriptionEnabled] &&
            !TranscriptionManager.shared.isInitialized &&
            WarmupCoordinator.shared.failedProviders[activeDictationProviderId] == nil
    }

    static var isDictationDownloading: Bool {
        guard isDictationPreparing, let state = activeDictationDownloadState else { return false }
        return state == .downloading || state == .fetching
    }

    // MARK: - Gates: Smart Cleanup

    /// Whether Smart Cleanup is switched on at all. The demo showcases Smart Cleanup, so it's a
    /// prerequisite - when disabled, the demo is intentionally not "ready" (it's offered later from
    /// Home via "Try it now", which re-enables the feature).
    ///
    /// Deliberately *not* the same question as "are its models enabled". Where MLX
    /// cannot run (Intel, see `MLXRuntime`) both providers report disabled, yet
    /// Smart Cleanup still runs its deterministic generators - so the user setting
    /// is what counts. On Apple Silicon the setting is already implied by both
    /// providers, so this reads exactly as before.
    static var isSmartCleanupEnabled: Bool {
        return TranscriptionConfig.isSmartCleanupSelected
            || ScoringWarmupProvider.shared.isEnabled
            || ImprovementLLMWarmupProvider.shared.isEnabled
    }

    static var isSmartCleanupReady: Bool {
        let scoring = ScoringWarmupProvider.shared
        // `isPreparing`, not `isWarmedUp`: the latter mirrors residency, so the idle-unload that
        // reclaims RAM after 30 quiet minutes would drag every readiness surface back to "preparing"
        // on an app that is fully set up.
        let improvementPreparing = ImprovementLLMWarmupProvider.shared.isPreparing
        return (!scoring.isEnabled || scoring.isWarmedUp) && !improvementPreparing
    }

    private static var isSmartCleanupFailed: Bool {
        let failed = WarmupCoordinator.shared.failedProviders
        return failed["scoring"] != nil || failed["improvementLLM"] != nil
    }

    /// The Smart Cleanup stack is enabled but not yet fully warmed (download + warmup tail).
    static var isSmartCleanupPreparing: Bool {
        return isSmartCleanupEnabled && !isSmartCleanupReady && !isSmartCleanupFailed
    }

    static var isSmartCleanupDownloading: Bool {
        return isScoringDownloading || isImprovementLLMDownloading
    }

    private static var isScoringDownloading: Bool {
        let provider = ScoringWarmupProvider.shared
        let state = HuggingFaceModelDownloader.shared.llamaState
        return
            provider.isEnabled &&
            !provider.isWarmedUp &&
            WarmupCoordinator.shared.failedProviders["scoring"] == nil &&
            (state == .downloading || state == .fetching)
    }

    private static var isImprovementLLMDownloading: Bool {
        let provider = ImprovementLLMWarmupProvider.shared
        let progress = TranscriptionLLMService.shared.improvementLoadingProgress
        return
            provider.isPreparing &&
            WarmupCoordinator.shared.failedProviders["improvementLLM"] == nil &&
            progress > 0 && progress < 1
    }

    private static var smartCleanupDownloadProgress: Double {
        if isScoringDownloading {
            return HuggingFaceModelDownloader.shared.llamaProgress.value
        }
        return TranscriptionLLMService.shared.improvementLoadingProgress
    }

    // MARK: - Gates: Aggregate

    /// True while any required model is still being prepared (downloading *or* warming).
    static var isAnyModelPreparing: Bool {
        return current != nil
    }

    // MARK: - Gates: Demo Readiness

    /// The Dictation Demo can only run once the dictation model AND the full Smart Cleanup stack are
    /// warmed. Gates the Shortcut → Demo step and the demo-page re-entry redirect.
    ///
    /// A fully open build (`SmartCleanupAvailability`) has no Smart Cleanup to wait for, and
    /// `isSmartCleanupEnabled` is usually false there, so it only requires the stack to be
    /// settled: whatever of it the user's settings still load (N-best, the dictionary gate).
    static var demoModelsReady: Bool {
        return
            TranscriptionManager.shared.isInitialized &&
            (isSmartCleanupEnabled || !SmartCleanupAvailability.isCompiledIn) &&
            isSmartCleanupReady
    }

    /// True when a model the demo depends on (the active dictation backend or any part of the Smart
    /// Cleanup stack) has *failed* to prepare. While failed, `demoModelsReady` can never flip true -
    /// callers waiting on readiness (e.g. the Home card's pending demo launch) should bail out or
    /// retry the warmup instead of polling forever.
    static var isDemoModelPreparationFailed: Bool {
        return
            WarmupCoordinator.shared.failedProviders[activeDictationProviderId] != nil ||
            isSmartCleanupFailed
    }
}
