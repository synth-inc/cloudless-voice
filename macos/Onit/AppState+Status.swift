// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppState+Status.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import AppKit
import Combine
import Defaults
import Foundation

// MARK: - App Status Types

/// Status dot color in the menu bar
enum AppStatusDotColor {
    case red      // Critical error (accessibility, microphone missing)
    case orange   // Warning (model loading, app disabled)
    case gray     // All features disabled
    case green    // All good

    /// Converts to NSColor for the UI
    var nsColor: NSColor {
        switch self {
        case .red:
            return NSColor.red500
        case .orange:
            return NSColor.orange500
        case .gray:
            return NSColor.gray200
        case .green:
            return NSColor.lime400
        }
    }
}

/// Main app status (first line of the menu)
enum AppStatusMessage: Equatable {
    // Dev build coexistence (priority -1, highest)
    case devBuildRunning

    // Global status (priority 0)
    case accessibilityRequired

    // Microphone status (priority 1)
    case microphonePermissionRequired

    // Transcription model downloading (priority 3.6) - Swift is downloading model files
    case transcriptionModelDownloading

    // Transcription model loading (priority 3.6) - files downloaded, loading into memory
    case transcriptionModelLoading

    // Warmup failures (priority 3.6) - provider failed, user can retry from menu
    case warmupFailed(provider: String)

    // Scoring model downloading (priority 3.7) - Swift is downloading Llama model
    case scoringModelDownloading

    // Scoring model loading (priority 3.7) - files downloaded, loading into memory
    case scoringModelLoading

    // All features disabled (priority 5)
    case allFeaturesDisabled

    case running

    /// Text to display in the menu
    @MainActor
    var displayText: String {
        switch self {
        case .devBuildRunning:
            return String.localized("A dev version is running")
        case .accessibilityRequired:
            return String.localized("Grant Accessibility →")
        case .microphonePermissionRequired:
            return String.localized("Allow Microphone →")
        case .transcriptionModelDownloading:
            return String.localized("Hang tight while we set you up...")
        case .transcriptionModelLoading:
            return String.localized("Hang tight while we set you up...")
        case .warmupFailed(let provider):
            switch provider {
            case "parakeet":
                return String.localized("Dictation unavailable - Retry")
            case "scoring":
                return String.localized("Smart Cleanup unavailable - Retry")
            case "vad":
                return String.localized("Silence detection unavailable - Retry")
            case "improvementLLM":
                return String.localized("Backtracking unavailable - Retry")
            default:
                return String.localized("Service unavailable - Retry")
            }
        case .scoringModelDownloading:
            return String.localized("Hang tight while we set you up...")
        case .scoringModelLoading:
            return String.localized("Hang tight while we set you up...")

        case .allFeaturesDisabled:
            return String.localized("All features disabled")

        case .running:
            return String.localized("Running")
        }
    }

    /// Is the item clickable?
    var isActionable: Bool {
        switch self {
        case .accessibilityRequired,
             .microphonePermissionRequired,
             .warmupFailed,
             .allFeaturesDisabled:
            return true
        default:
            return false
        }
    }

    /// Requires a countdown for remaining seconds
    var requiresCountdown: Bool {
        return false
    }
}

// MARK: - App Status Extension

extension AppState {

    // MARK: - Status Setup

    /// Initializes observers for app status
    /// Must be called after AppState initialization
    func setupStatusObservers() {
        // Initial update
        updateStatus()

        // Accessibility
        AccessibilityPermissionManager.shared.$accessibilityPermissionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Microphone permission
        MicrophoneInputManager.shared.$hasPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Warmup coordinator state
        WarmupCoordinator.shared.$isFullyWarmedUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Transcription initialization - observe for transcription status
        TranscriptionManager.shared.$isInitialized
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Scoring model - observe so dot goes green once cleanup model finishes downloading
        ScoringWarmupProvider.shared.$isWarmedUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Backtracking / N-best model - observe so the header clears once the full Smart Cleanup
        // stack finishes preparing (it's now part of the "Hang tight…" status condition).
        ImprovementLLMWarmupProvider.shared.$isWarmedUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Model download states - update status text when downloads finish (downloading → loading)
        HuggingFaceModelDownloader.shared.$parakeetState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        HuggingFaceModelDownloader.shared.$llamaState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Warmup failures - observe so dot goes red/orange immediately when a provider fails
        WarmupCoordinator.shared.$failedProviders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Feature disable rules
        // Mode toggles
        Defaults.publisher(.transcriptionEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)

        // Dev build detection (Release builds only)
        #if !DEBUG
        DevBuildDetectionService.shared.$isDevBuildRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &statusObserverCancellables)
        #endif

        // Setup badge count observers (for properties not already observed above)
        setupBadgeCountObservers()
    }

    // MARK: - Status Update

    /// Notification sent when status changes
    static let statusDidChangeNotification = Notification.Name("AppStateStatusDidChange")

    private func updateStatus() {
        let newMessage = computeStatusMessage()
        let newDotColor = computeStatusDotColor(for: newMessage)

        let didChange = statusDotColor != newDotColor || statusMessage != newMessage

        statusDotColor = newDotColor
        statusMessage = newMessage

        if didChange {
            NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: nil)
        }

        // Also update badge count since many of the same conditions affect it
        updateSetupBadgeCount()
    }

    /// Derives dot color from status message to ensure consistency
    private func computeStatusDotColor(for message: AppStatusMessage) -> AppStatusDotColor {
        switch message {
        // GRAY: Dev build is running (production defers)
        case .devBuildRunning:
            return .gray

        // RED: Critical errors
        case .accessibilityRequired,
             .microphonePermissionRequired:
            return .red

        // RED: Parakeet warmup failed (dictation broken)
        case .warmupFailed(let provider) where provider == "parakeet":
            return .red

        // ORANGE: Model downloading / loading / non-critical warmup failure
        case .transcriptionModelDownloading,
             .transcriptionModelLoading,
             .scoringModelDownloading,
             .scoringModelLoading,
             .warmupFailed:
            return .orange

        // GRAY: All features disabled
        case .allFeaturesDisabled:
            return .gray

        // GREEN: All good
        case .running:
            return .green
        }
    }

    private var allFeaturesDisabled: Bool {
        let coordinator = AppModeCoordinator.shared
        return !coordinator.isTranscriptionEnabled
    }

    private func computeStatusMessage() -> AppStatusMessage {
        let coordinator = AppModeCoordinator.shared
        let accessibilityManager = AccessibilityPermissionManager.shared

        // PRIORITY -1: Dev build is running (Release/non-beta builds only)
        #if !DEBUG && !ONIT_BETA
        if DevBuildDetectionService.shared.isDevBuildRunning {
            return .devBuildRunning
        }
        #endif

        // PRIORITY 0: Accessibility not granted
        if accessibilityManager.accessibilityPermissionStatus != .granted {
            return .accessibilityRequired
        }

        // PRIORITY 1: Transcription enabled but microphone not granted
        if coordinator.isTranscriptionEnabled && !MicrophoneInputManager.shared.hasPermission {
            return .microphonePermissionRequired
        }

        // PRIORITY 3.5: Warmup failures - show the most critical failed provider
        let failedProviders = WarmupCoordinator.shared.failedProviders
        if !failedProviders.isEmpty {
            // Priority: the active ASR backend (dictation broken) > scoring (Smart Cleanup
            // broken) > improvementLLM (backtracking/N-best degraded) > vad
            // (silence detection degraded). The ASR slot is resolved through the registry rather
            // than hardcoded to "parakeet": a Whisper / Moonshine / MLX / Canary failure - including
            // the init watchdog's recorded timeout - would otherwise never surface here, leaving the
            // user with no error and no Retry.
            for providerKey in [activeASRProviderId, "scoring", "improvementLLM", "vad"] {
                if failedProviders[providerKey] != nil {
                    return .warmupFailed(provider: providerKey)
                }
            }
        }

        // PRIORITY 3.6: Transcription model initializing
        if coordinator.isTranscriptionEnabled {
            if !TranscriptionManager.shared.isInitialized {
                let dlState = HuggingFaceModelDownloader.shared.parakeetState
                if dlState == .downloading || dlState == .fetching {
                    return .transcriptionModelDownloading
                }
                return .transcriptionModelLoading
            }
        }

        // PRIORITY 3.7: Cleanup model still downloading/loading
        let scoringProvider = ScoringWarmupProvider.shared
        if scoringProvider.isEnabled && !scoringProvider.isWarmedUp {
            let dlState = HuggingFaceModelDownloader.shared.llamaState
            if dlState == .downloading || dlState == .fetching {
                return .scoringModelDownloading
            }
            return .scoringModelLoading
        }

        // PRIORITY 3.8: Backtracking / N-best (improvementLLM) model still preparing. Reuses the
        // (now-unified "Hang tight…") scoring-loading status so the header keeps signalling
        // "still setting up" through the full Smart Cleanup stack rather than flipping to "Running".
        // `isPreparing` (not `isWarmedUp`) so the idle-unload that reclaims RAM after 30 quiet
        // minutes doesn't pin the header back to "Hang tight…" on a fully-warmed app.
        if ImprovementLLMWarmupProvider.shared.isPreparing {
            return .scoringModelLoading
        }

        // PRIORITY 5: All features disabled
        if allFeaturesDisabled {
            return .allFeaturesDisabled
        }

        return .running
    }

    /// Action to execute when user clicks on the status
    func handleStatusAction() {
        switch statusMessage {
        case .accessibilityRequired:
            AccessibilityPermissionManager.shared.requestPermission()
        case .microphonePermissionRequired:
            Task {
                await MicrophoneInputManager.shared.requestPermissionOrOpenSettings()
            }
        case .warmupFailed(let provider):
            retryFailedProvider(provider)
        case .allFeaturesDisabled:
            AppWindowManager.shared.showWindow(settingsPage: .general)
        default:
            break
        }
    }

    /// The warmup-provider identifier of the ASR backend currently selected - the same registry
    /// dispatch `TranscriptionManager` and `ModelDownloadIndicator` use, so status and retry follow
    /// the user's backend instead of assuming Parakeet.
    private var activeASRProviderId: String {
        return ASRBackendRegistry.descriptor(for: TranscriptionConfig.shared.backend).providerId
    }

    /// Retry a specific failed warmup provider from the menu bar
    private func retryFailedProvider(_ provider: String) {
        let coordinator = WarmupCoordinator.shared
        coordinator.retryWarmup(for: provider)

        // Re-trigger TranscriptionManager initialization when the failed provider is the active ASR
        // backend. Matters now that the init watchdog's own timeout is recorded as a failure: that's
        // the main way this button becomes reachable, and without the re-init it would clear the
        // error without ever reloading the model.
        if provider == activeASRProviderId {
            TranscriptionManager.shared.initializeModelsInBackground()
        }
    }

    // MARK: - Badge Count

    private func setupBadgeCountObservers() {
        // Initial update
        updateSetupBadgeCount()

        // Note: Accessibility and microphone permissions are already observed by
        // setupStatusObservers() - they call updateStatus() which also updates the badge count.
    }

    private func updateSetupBadgeCount() {
        let accessibilityManager = AccessibilityPermissionManager.shared
        let microphoneInputManager = MicrophoneInputManager.shared

        var count = 0

        // The required permissions surfaced on the Settings → Setup page: Accessibility (always)
        // and Microphone (when dictation is on).
        if accessibilityManager.accessibilityPermissionStatus != .granted {
            count += 1
        }

        if Defaults[.transcriptionEnabled] && !microphoneInputManager.hasPermission {
            count += 1
        }

        setupBadgeCount = count == 0 ? nil : count
    }
}
