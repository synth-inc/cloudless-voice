// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Visibility.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Variables
 * Functions: `shouldShowHint` Helpers
 * Functions: Snooze
 * Functions: Pop-Up Auto-Dismiss
 * Functions: Visibility Evaluation
 */

import AppKit
import Defaults

extension HintManager {
    // MARK: - Public Variables

    /// Whether the user temporarily silenced the Hint and the snooze hasn't elapsed yet.
    ///     Read against `.now` rather than trusting `snoozeExpiryTask` to have fired, so a stale
    ///     stored date (app was closed while the snooze ran out) never keeps the Hint hidden.
    var isHintSnoozed: Bool {
        guard let hintSnoozedUntil = Defaults[.hintSnoozedUntil] else { return false }

        return hintSnoozedUntil > .now
    }

    /// The resting Hint is hidden: always-hide, a snooze, or a fullscreen (immersive) app.
    ///     Special circumstances may still force it into view (`computeForceShowHint()`).
    var isHintHiddenByUser: Bool {
        Defaults[.alwaysHideHint] || isHintSnoozed || ImmersiveModeMonitor.shared.isImmersive
    }

    var shouldShowHint: Bool {
        // Production build defers to dev build when both are running
        #if !DEBUG
        if DevBuildDetectionService.shared.shouldDeferToDevBuild {
            return false
        }
        #endif

        /// A snooze, and immersive mode (a fullscreen window playing media), hide the Hint exactly
        ///     like `alwaysHideHint` does: the resting pill goes away, but special circumstances
        ///     (errors, permission loss, model preparation, an active dictation) still force it
        ///     back into view, over the fullscreen app when it comes to that.
        if isHintHiddenByUser {
            return computeForceShowHint() /// Showing hint under special circumstances, like surfacing an error.
        } else {
            return computeBaseVisibility()
        }
    }
    
    // MARK: - Functions: `shouldShowHint` Helpers
    
    private func computeBaseVisibility() -> Bool {
        if OnboardingWindowManager.shared.onboardingWindowIsVisible {
            /// During onboarding the Hint is normally reserved for the demo step, but it also
            /// surfaces across the earlier steps while any required model is being prepared
            /// (downloading or warming) so the pill (and its entry toast) can show. Reverts to
            /// demo-only once everything is warmed.
            return Defaults[.currentOnboardingStep] == .transcriptionDemo
                || OnboardingWindowManager.shared.demoOnly
                || isAnyModelPreparing
        } else {
            return Defaults[.transcriptionEnabled]
        }
    }
    
    /// The hint should be force-shown to the user in special circumstances.
    ///     For example, surfacing error messages or critical reminders (e.g. losing accessibility access, completing onboarding setups)
    private func computeForceShowHint() -> Bool {
        updateActivePopUpType()

        /// Hover doesn't currently count as a force-show.
        if activePopUpType != nil && activePopUpType != .hover {
            return true
        }

        /// Surface the model-preparation pill even when the user has the Hint set to always-hidden.
        if isAnyModelPreparing {
            return true
        }

        /// An upgrade card already on screen (or resumed after the sign-in handoff) and the
        /// success card stay in view until closed. A refused Smart Cleanup never pops the card
        /// over a hidden Hint in the first place (`smartCleanupRefused`).
        if pendingCleanupPaywallMode != nil || isShowingDictationSuccessCard {
            return true
        }

        /// Keep hint visible while a transcription alert is pending.
        ///     This is mostly useful for when the transcription overlay is in the middle of animating out.
        ///     We don't want the Hint to flicker during that small instant.
        ///     See `showTranscriptionAlert()` for more context.
        if activeTranscriptionAlert != nil {
            return true
        }
        
        /// Ensures the Hint shows when the transcription overlay is revealed.
        if transcriptionOverlayWindowIsVisible {
            return true
        }

        /// Keep hint expanded during active transcription (recording or processing)
        return isTranscriptionActive
    }
    
    func updateActivePopUpType() {
        /// Make it so that the transcription overlay ("Not quite, right?" and correction UI) takes precedence,
        ///     unless a transcription alert is pending (the overlay is in the process of animating out when hiding itself)
        ///     See `showTranscriptionAlert()` for more context.
        if transcriptionOverlayWindowIsVisible && activeTranscriptionAlert == nil {
            activePopUpType = nil
        } else if shouldShowModelDownloadingPopUpMessage {
            /// High priority during onboarding entry: the "Don't quit" download warning supersedes
            /// the permission prompts below (which are suppressed during onboarding anyway).
            activePopUpType = .modelDownloading
        } else if shouldShowAccessibilityLostPopUpMessage {
            activePopUpType = .accessibilityLost
        }
        /// Commented out for now until non-AX becomes the default state.
//        else if shouldShowScreenRecordingLostPopUpMessage {
//            activePopUpType = .screenRecordingLost
//        }
        else if shouldShowMicrophonePermissionLostPopUpMessage {
            activePopUpType = .microphonePermissionLost
        } else if shouldShowTranscriptionDemoPopUpMessage {
            activePopUpType = .transcriptionDemo
        } else if shouldShowTranscriptionSetupPopUpMessage {
            activePopUpType = .transcriptionSetup
        } else if let activeTranscriptionAlert = self.activeTranscriptionAlert {
            activePopUpType = activeTranscriptionAlert.popUpMessageType
        } else if shouldShowModelsReadyPopUpMessage {
            activePopUpType = .modelsReady
        } else if shouldShowUpdateAvailablePopUpMessage {
            activePopUpType = .updateAvailable
        } else {
            activePopUpType = nil
        }

        schedulePopUpAutoDismissIfNeeded()
    }
    
    // MARK: - Functions: Snooze

    /// Both snooze surfaces (Hint more menu, Settings > General) only write the Default.
    ///     The `hintSnoozedUntil` subscription then re-arms the expiry and re-evaluates visibility,
    ///     so there is a single code path no matter where the snooze was started or cancelled.
    func snoozeHint(_ duration: HintSnoozeDuration) {
        Defaults[.hintSnoozedUntil] = duration.expiryDate
    }

    func cancelHintSnooze() {
        Defaults[.hintSnoozedUntil] = nil
    }

    /// (Re)schedules clearing the stored snooze date so the Hint comes back on its own, without
    ///     needing a relaunch or an unrelated event to re-evaluate visibility.
    func rearmSnoozeExpiry() {
        snoozeExpiryTask?.cancel()
        snoozeExpiryTask = nil

        guard let hintSnoozedUntil = Defaults[.hintSnoozedUntil] else { return }

        let remainingSeconds = hintSnoozedUntil.timeIntervalSinceNow

        /// Snooze ran out while the app was closed (or between two launches): clear the stale date.
        guard remainingSeconds > 0 else {
            cancelHintSnooze()
            return
        }

        snoozeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remainingSeconds))
            guard !Task.isCancelled else { return }
            self?.cancelHintSnooze()
        }
    }

    // MARK: - Functions: Pop-Up Auto-Dismiss

    private func schedulePopUpAutoDismissIfNeeded() {
        guard let autoDismissDuration = activePopUpType?.autoDismissDuration
        else {
            cancelPopUpAutoDismissTask()
            return
        }

        /// Don't start the timer while the transcription overlay is still animating out.
        guard !transcriptionOverlayWindowIsVisible else { return }

        /// Don't restart the timer if one is already running.
        guard popUpAutoDismissTask == nil else { return }

        popUpAutoDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: autoDismissDuration)
            guard !Task.isCancelled else { return }
            self.dismissPopUp()
        }
    }

    func cancelPopUpAutoDismissTask() {
        popUpAutoDismissTask?.cancel()
        popUpAutoDismissTask = nil
    }

    func dismissPopUp() {
        guard let activePopUpType = self.activePopUpType else { return }

        switch activePopUpType {
        case .transcriptionSetup:
            sessionDismissedPopUps.insert(activePopUpType)
        case .modelsReady:
            Defaults[.appHomeReadyToastShown] = true
        case .updateAvailable:
            Defaults[.dismissedUpdateAlertVersion] = AppState.shared.availableUpdateVersion ?? ""
        case .accessibilityLost,
            /// Commented out for now until non-AX becomes the default state.
//                .screenRecordingLost,
                .microphonePermissionLost,
                .modelDownloading,
                .transcriptionDemo,
                .hover:
            break
        case .transcriptionFailed,
                .transcriptionSilent,
                .transcriptionCancelled,
                .transcriptionInputDeviceFailed,
                .transcriptionInputDeviceUnplugged,
                .transcriptionDetectedNewInputDevice,
                .transcriptionCleanupLoading,
                .transcriptionCleanupUnconfirmed,
                .transcriptionRewriteFailed:
            activeTranscriptionAlert = nil
        }

        hideMoreMenu()
        refreshPopUp()
    }

    func refreshPopUp() {
        cancelPopUpAutoDismissTask()
        updateActivePopUpType()
        evaluateVisibility()
    }
    
    // MARK: - Functions: Visibility Evaluation
    
    func evaluateVisibility() {
        if shouldShowHint {
            guard !hintWindowIsVisible else { return }
            requestShowHint()
        } else {
            hideHint()
        }
    }

    private func requestShowHint() {
        showHintWindow()
    }

    func hideHint() {
        showDebounceTimer = nil
        currentScreen = nil

        stopHoverTracking()
        
        hideTranscriptionOverlayIfNeeded()
        hideMoreMenu(force: true)

        /// Remove frame change observer before clearing content view.
        /// See `configureFrameChangeObserver()`.
        if let contentView = hintWindow.contentView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: contentView
            )
        }
        hintWindow.orderOut(nil)
        hintWindow.contentView = nil
    }
}
