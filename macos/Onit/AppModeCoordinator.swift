// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppModeCoordinator.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import Combine
import Defaults
import Foundation

/// Delegate protocol for AppModeCoordinator state changes
@MainActor
protocol AppModeCoordinatorDelegate: AnyObject {
    /// Called when Transcription mode state changes
    func appModeCoordinator(_ coordinator: AppModeCoordinator, didChangeTranscriptionState enabled: Bool)

    /// Called when Transcription model status changes
    func appModeCoordinatorDidUpdateTranscriptionModelStatus(_ coordinator: AppModeCoordinator)
}

/// Centralized coordinator for managing app modes (Transcription)
/// Handles lifecycle, service dependencies, and state synchronization
@MainActor
final class AppModeCoordinator: ObservableObject {

    // MARK: - Shared Instance

    static let shared = AppModeCoordinator()

    // MARK: - Delegate

    weak var delegate: AppModeCoordinatorDelegate?

    // MARK: - State

    /// Current Transcription enabled state
    var isTranscriptionEnabled: Bool {
        Defaults[.transcriptionEnabled]
    }

    // MARK: - Published State

    /// Published state for Transcription model initialization status
    @Published private(set) var isTranscriptionModelInitialized: Bool = false

    // MARK: - Services

    private var transcriptionCancellable: AnyCancellable?
    private var transcriptionModelCancellable: AnyCancellable?
    private var sessionRestoreCancellable: AnyCancellable?

    // MARK: - Initialization

    private init() {
        // Register warmup providers with the coordinator
        let coordinator = WarmupCoordinator.shared
        coordinator.registerProvider(ParakeetCoreMLWarmupProvider.shared)
        coordinator.registerProvider(CanaryCoreMLWarmupProvider.shared)
        coordinator.registerProvider(FluidAudioWarmupProvider.shared)
        coordinator.registerProvider(WhisperCoreMLWarmupProvider.shared)
        coordinator.registerProvider(MoonshineWarmupProvider.shared)
        coordinator.registerProvider(SileroVADWarmupProvider.shared)

        // The three MLX-backed providers are registered only where MLX can run.
        // Scoring and the improvement LLM are *not* tied to the ASR backend -
        // they warm up on their own, so on an Intel Mac they would reach MLX
        // and crash even with Parakeet selected (see `MLXRuntime`).
        if MLXRuntime.isSupported {
            coordinator.registerProvider(MLXWarmupProvider.shared)
            coordinator.registerProvider(ScoringWarmupProvider.shared)
            coordinator.registerProvider(ImprovementLLMWarmupProvider.shared)
        }

        // Touch the backtracking-markers manager at startup so disk-persisted
        // custom markers are compiled into the hot-path regex snapshot before
        // the first dictation. Otherwise the cleanup gate reads the
        // static snapshot (initialized from defaults) until the user opens
        // Smart Cleanup settings, silently ignoring their customizations.
        _ = BacktrackingMarkersManager.shared

        // Start tracking dictation inactivity so the resident ASR model is
        // unloaded after the configured idle period and reloaded on next use.
        ASRModelLifecycleService.shared.start()

        // Same idle-unload lifecycle for the Smart Cleanup LLMs (scoring +
        // improvement), the two resident MLX models that drive Onit's idle RAM.
        CleanupModelLifecycleService.shared.start()

        setupObservers()

        // Defer initialization of enabled features to next run loop
        // (observers use dropFirst, so they won't trigger for initial values)
        DispatchQueue.main.async { [weak self] in
            self?.initializeEnabledFeaturesAtStartup()
        }
    }

    /// Initialize features that were already enabled before app launch
    private func initializeEnabledFeaturesAtStartup() {
        if isTranscriptionEnabled {
            startTranscription()
        }
    }

    // MARK: - Public Interface

    /// Cleanup resources on app termination
    func cleanup() {
        transcriptionCancellable?.cancel()
        transcriptionModelCancellable?.cancel()
        if isTranscriptionEnabled {
            self.stopTranscription()
        }
    }

    // MARK: - Transcription Control

    /// Enable Transcription mode
    func enableTranscription() {
        guard !isTranscriptionEnabled else { return }
        Defaults[.transcriptionEnabled] = true
    }

    /// Disable Transcription mode
    func disableTranscription() {
        guard isTranscriptionEnabled else { return }
        Defaults[.transcriptionEnabled] = false
    }

    // MARK: - Status Queries

    /// Check if Transcription models are initialized (only relevant when Transcription is enabled)
    var isTranscriptionReady: Bool {
        guard isTranscriptionEnabled else { return true }
        return TranscriptionManager.shared.isInitialized
    }

    // MARK: - Private Helpers

    private func setupObservers() {
        // Observer for Transcription state changes
        transcriptionCancellable = Defaults.publisher(.transcriptionEnabled)
            .map(\.newValue)
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                Task { @MainActor in
                    guard let self = self else { return }
                    if enabled {
                        self.startTranscription()
                    } else {
                        self.stopTranscription()
                    }
                    self.delegate?.appModeCoordinator(self, didChangeTranscriptionState: enabled)
                }
            }
    }

    private func startTranscription() {
        // Track feature enabled
        AnalyticsManager.Transcription.enabled()

        // 1. Enable keyboard shortcut
        KeyboardShortcutsManager.enableTranscriptionShortcuts()

        // 2. Notify warmup coordinator that a feature state changed
        WarmupCoordinator.shared.featureStateChanged()

        // 3. Initialize models in background (downloads if needed)
        TranscriptionManager.shared.initializeModelsInBackground()

        // 4. Setup model status observer
        setupTranscriptionModelObserver()

        // 5. Onboarding
        launchOnboardingIfNeeded()
    }

    private func stopTranscription() {
        closeOnboardingIfNeeded()

        // Track feature disabled
        AnalyticsManager.Transcription.disabled()

        // Disable keyboard shortcut
        KeyboardShortcutsManager.disableTranscriptionShortcuts()

        // Stop any active transcription
        TranscriptionManager.shared.cleanup()

        // Teardown model status observer
        teardownTranscriptionModelObserver()

        // Remove HID remapping if no other feature needs it
        KeystrokeNotificationManager.shared.removeHIDRemappingIfNotNeeded()

        // Notify warmup coordinator of feature state change
        WarmupCoordinator.shared.featureStateChanged()
    }

    // MARK: - Onboarding Helpers

    /// Launches onboarding if not dismissed and not completed
    func launchOnboardingIfNeeded() {
        // Wait for the saved session to finish restoring before deciding. Until it resolves the user
        // looks logged-out, so `OnboardingStep.steps` would include `.auth` - which both flashes the
        // onboarding/auth window and clobbers a signed-in user's persisted `.complete` step (then
        // snaps it back, spuriously firing onboarding-complete). Re-run once restore resolves; it
        // always does - `AppDelegate.restoreSession()` runs unconditionally on launch.
        if AuthManager.shared.isRestoringSession {
            guard sessionRestoreCancellable == nil else { return }
            sessionRestoreCancellable = AuthManager.shared.$isRestoringSession
                .filter { !$0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.sessionRestoreCancellable = nil
                        self.launchOnboardingIfNeeded()
                    }
                }
            return
        }

        let onboardingDismissed = Defaults[.onboardingDismissed]
        let currentStep = Defaults[.currentOnboardingStep]

        // Safety check: if onboarding was marked as dismissed but step is not complete,
        // it means the app was force-quit.
        // Reset the dismissed flag to allow onboarding to resume.
        if onboardingDismissed && currentStep != .complete {
            Defaults[.onboardingDismissed] = false
        }

        // Safety check: if current step belongs to a disabled feature, skip to an appropriate step.
        // A nil step (fresh launch, or a removed legacy step that no longer decodes) starts at the first valid step.
        Defaults[.currentOnboardingStep] = currentStep?.getNextValidOnboardingStep() ?? OnboardingStep.steps.first

        guard !OnboardingStep.isOnboardingComplete else { return }

        OnboardingWindowManager.shared.showWindow()
    }

    private func closeOnboardingIfNeeded() {
        if OnboardingStep.isOnboardingComplete {
            OnboardingWindowManager.shared.closeWindow()
        }
    }

    // MARK: - Status Observers

    private func setupTranscriptionModelObserver() {
        guard transcriptionModelCancellable == nil else { return }

        transcriptionModelCancellable = TranscriptionManager.shared.$isInitialized
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isInitialized in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isTranscriptionModelInitialized = isInitialized
                    self.delegate?.appModeCoordinatorDidUpdateTranscriptionModelStatus(self)
                }
            }
    }

    private func teardownTranscriptionModelObserver() {
        transcriptionModelCancellable?.cancel()
        transcriptionModelCancellable = nil
    }
}
