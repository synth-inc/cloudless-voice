// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Subscriptions.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Functions
 * Private Functions: Defaults Subscriptions
 * Private Functions: Publisher Subscriptions
 * Private Functions: Observer Subscriptions
 */

import AppKit
import Defaults
import Foundation
import SwiftUI

extension HintManager {
    // MARK: - Public Functions
    
    func setupSubscriptions() {
        setupDefaultsSubscriptions()
        setupPublisherSubscriptions()
        setupObserverSubscriptions()
        setupDictationPaywallSubscriptions()

        // Hide the Hint while the frontmost app is playing media in fullscreen.
        ImmersiveModeMonitor.shared.startMonitoring()
        ImmersiveModeMonitor.shared.$isImmersive
            .removeDuplicates()
            /// Load-bearing, do not remove: `@Published` fires from `willSet`, and
            /// `shouldShowHint` reads the stored property rather than the emitted value. A
            /// synchronous sink would evaluate one transition behind, permanently.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] immersive in
                guard let self = self else { return }
                if immersive {
                    self.screenBeforeImmersive = self.currentScreen
                }
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        
        // Observe dev build detection (Release builds only)
        #if !DEBUG
        DevBuildDetectionService.shared.$isDevBuildRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        #endif
    }
    
    // MARK: - Private Functions: Defaults Subscriptions
    
    private func setupDefaultsSubscriptions() {
        Defaults.publisher(.mainOnboardingCompleted)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        Defaults.publisher(.currentOnboardingStep)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        
        Defaults.publisher(.transcriptionEnabled)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        Defaults.publisher(.alwaysHideHint)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        
        /// The publisher emits on subscription too, so an expired snooze left over from a previous
        ///     launch is cleared here without an extra call at setup.
        Defaults.publisher(.hintSnoozedUntil)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.rearmSnoozeExpiry()
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        Defaults.publisher(.showHintAccessibilityAlert)
              .removeDuplicates()
              .sink { [weak self] _ in
                  guard let self = self else { return }
                  self.updateActivePopUpType()
                  self.evaluateVisibility()
              }
              .store(in: &cancellables)

        /// Commented out for now until non-AX becomes the default state.
//        Defaults.publisher(.showHintScreenRecordingAlert)
//          .removeDuplicates()
//          .sink { [weak self] _ in
//              guard let self = self else { return }
//              self.updateActivePopUpType()
//              self.evaluateVisibility()
//          }
//          .store(in: &cancellables)

        Defaults.publisher(.showHintMicrophonePermissionAlert)
          .removeDuplicates()
          .sink { [weak self] _ in
              guard let self = self else { return }
              self.updateActivePopUpType()
              self.evaluateVisibility()
          }
          .store(in: &cancellables)

        Defaults.publisher(.showHintUpdateAvailableAlert)
          .removeDuplicates()
          .sink { [weak self] _ in
              guard let self = self else { return }
              self.updateActivePopUpType()
              self.evaluateVisibility()
          }
          .store(in: &cancellables)

        Defaults.publisher(.dismissedUpdateAlertVersion)
          .removeDuplicates()
          .sink { [weak self] _ in
              guard let self = self else { return }
              self.updateActivePopUpType()
              self.evaluateVisibility()
          }
          .store(in: &cancellables)
    }
    
    // MARK: - Private Functions: Publisher Subscriptions
    
    private func setupPublisherSubscriptions() {
        AccessibilityPermissionManager.shared.$accessibilityPermissionStatus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
  
        /// Commented out for now until non-AX becomes the default state.
//        ScreenRecordingPermissionManager.shared.$isScreenRecordingEnabled
//            .removeDuplicates()
//            .receive(on: DispatchQueue.main)
//            .sink { [weak self] _ in
//                guard let self = self else { return }
//                self.updateActivePopUpType()
//                self.evaluateVisibility()
//            }
//            .store(in: &cancellables)
        
        MicrophoneInputManager.shared.$hasPermission
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        
        OnboardingWindowManager.shared.$onboardingWindowIsVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        // Demo-only mode (post-completion "Try it now" / auto-launched skipped demo) flips on an
        // already-visible window, so `$onboardingWindowIsVisible` doesn't change - observe it
        // directly, otherwise the demo Hint doesn't surface until some unrelated event re-evaluates.
        OnboardingWindowManager.shared.$demoOnly
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        TranscriptionManager.shared.$isTranscribing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)
        
        TranscriptionManager.shared.state.$isProcessing
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
            }
            .store(in: &cancellables)

        /// Model downloads: drive the pill's "X% ⟳" state, the entry toast, and onboarding
        /// visibility. The download surface tracks two buckets - dictation (Parakeet) and the Smart
        /// Cleanup stack (perplexity-gating Llama + the fine-tuned backtracking model) - so we
        /// observe every transition that flips `ModelDownloadIndicator`: the two downloader states,
        /// each warmup provider's `isWarmedUp`, and the backtracking model's load progress (coarsened
        /// to a downloading/idle bool so it fires on transitions, not on every byte).
        let refreshOnModelChange: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.refreshModelDownloadTracking()
            self.updateActivePopUpType()
            self.evaluateVisibility()
        }

        HuggingFaceModelDownloader.shared.$parakeetState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)

        HuggingFaceModelDownloader.shared.$llamaState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)

        TranscriptionManager.shared.$isInitialized
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)

        ScoringWarmupProvider.shared.$isWarmedUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)

        ImprovementLLMWarmupProvider.shared.$isWarmedUp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)

        TranscriptionLLMService.shared.$improvementLoadingProgress
            .map { $0 > 0 && $0 < 1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshOnModelChange() }
            .store(in: &cancellables)
    }
    
    // MARK: - Private Functions: Dictation Paywall Subscriptions

    private func setupDictationPaywallSubscriptions() {
        /// A lifetime seat became active (launch fetch / login) while a dictation was blocked:
        /// resolve to the success card so the text is recoverable rather than silently dropped.
        LifetimeActivationManager.shared.$activation
            .map { $0?.isActive ?? false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                guard let self, isActive else { return }
                self.resolvePendingPaywallIfEntitled()
            }
            .store(in: &cancellables)

        /// Logged-out user tapped "Upgrade": continue to checkout once they sign in.
        AuthManager.shared.$account
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loggedIn in
                guard let self, loggedIn, self.pendingDictationCheckoutAfterLogin else { return }
                self.pendingDictationCheckoutAfterLogin = false
                let generation = self.dictationPaywallGeneration
                Task { @MainActor in
                    /// Signing in may itself have granted entitlement (existing seat/subscription).
                    await LifetimeActivationManager.shared.fetchActivation()
                    await StripeManager.shared.fetchSubscriptionData()
                    /// Logged out again while we were fetching: drop the whole intent.
                    guard self.dictationPaywallGeneration == generation else { return }
                    guard !SmartCleanupEntitlement.shared.hasUnlimitedSmartCleanup else {
                        self.resolvePendingPaywallIfEntitled()
                        return
                    }
                    var error: String? = nil
                    if !AppState.shared.subscriptionNeedsBillingPortal {
                        error = await self.openDictationCheckout(OpenURLAction { url in
                            NSWorkspace.shared.open(url)
                            return .handled
                        })
                        guard error != nil else { return }
                    }
                    /// Don't end the upgrade silently: bring the paywall back, with the checkout
                    /// error, or in its Manage Subscription mode for an existing subscription
                    /// checkout would refuse ("Subscription already exists").
                    guard self.dictationPaywallGeneration == generation else { return }
                    self.pendingCleanupPaywallMode = self.pendingCleanupSuccessMode ?? "after_login"
                    self.evaluateVisibility()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.presentPendingDictationPaywall(error: error)
                    }
                }
            }
            .store(in: &cancellables)

        /// The auth window closed without a sign-in: forget the "upgrade after login" intent so a
        /// sign-in days later doesn't spontaneously open Stripe.
        OnboardingWindowManager.shared.$onboardingWindowIsVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self, !visible, !AuthManager.shared.userLoggedIn else { return }
                self.pendingDictationCheckoutAfterLogin = false
            }
            .store(in: &cancellables)

        /// Back from the browser: poll immediately (the background schedule keeps running anyway).
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let openedAt = self.dictationCheckoutOpenedAt,
                      Date().timeIntervalSince(openedAt) < self.checkoutPollWindow else { return }
                self.startCheckoutPolling()
            }
            .store(in: &cancellables)
    }

    // MARK: - Private Functions: Observer Subscriptions
    
    private func setupObserverSubscriptions() {
        observeUpdateAvailability()
    }
    
    private func observeUpdateAvailability() {
        withObservationTracking {
            _ = AppState.shared.isUpdateAvailable
        } onChange: {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.updateActivePopUpType()
                self.evaluateVisibility()
                self.observeUpdateAvailability()
            }
        }
    }
}
