// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Transcription.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Functions
 * Functions: Transcription Alerts
 * Private Functions
 */

import Defaults
import SwiftUI

extension HintManager {
    // MARK: - Public Functions
    
    func showTranscriptionOverlay(
        state: TranscriptionState,
        pastedTextDetectionResult: TranscriptionManager.PastedTextDetectionResult? = nil
    ) {
        /// Hide more menu / pop-ups when showing transcription overlay (a dictation card is
        /// re-presented from `hideTranscriptionOverlayIfNeeded()`).
        hideMoreMenu(force: true)

        createTranscriptionOverlayWindowIfNeeded(state: state)
        // Note: no global key monitor for ESC/Return - too risky to leave registered.
        // Overlay dismisses via auto-dismiss timer, scroll, typing, click-outside, or app switch.

        guard let overlayWindow = transcriptionOverlayWindow
        else {
            return
        }

        /// Reset to non-key mode initially.
        overlayWindow.disableKeyStatus()

        /// Initial positioning.
        ///
        /// Force-correction mode: position so the primary insert button lands under the mouse.
        if forceCorrectionUIMouseAnchor != nil {
            isCaretAnchoredOverlay = true
            repositionTranscriptionOverlayAtMouseAnchor(isInitialShow: true)
        }
        /// Position near the pasted text when detection succeeded (OCR or AX).
        else if let pastedTextDetectionResult {
            isCaretAnchoredOverlay = true
            repositionTranscriptionOverlayNearPastedText(
                pastedTextDetectionResult: pastedTextDetectionResult,
                isInitialShow: true
            )
        }
        /// Mouse mode with no detection result - position near the cursor.
        else if Defaults[.transcriptionOverlayPositioningMode] == .mouse {
            isCaretAnchoredOverlay = true
            repositionTranscriptionOverlayNearPastedText(
                pastedTextDetectionResult: .init(boundingBox: .zero),
                isInitialShow: true
            )
        }
        /// Otherwise, position near the Hint.
        else {
            isCaretAnchoredOverlay = false
            repositionTranscriptionOverlayIfNeeded(
                isInitialShow: true
            )
        }
    }

    func hideTranscriptionOverlayIfNeeded() {
        guard let overlayWindow = transcriptionOverlayWindow else { return }

        /// Reset positioning flags for next time overlay is shown.
        userHasManuallyPositionedOverlay = false
        isCaretAnchoredOverlay = false
        forceCorrectionUIMouseAnchor = nil

        overlayWindow.orderOut(nil)
        transcriptionOverlayWindow = nil
        transcriptionOverlayHostingController = nil

        /// Re-evaluate pop-up state after overlay is fully hidden.
        /// This allows pending pop-ups to re-surface (e.g., transcription alerts, accessibility lost, etc.).
        /// Putting this logic here, rather than in something like a timer, prevents potential race conditions and code complication.
        updateActivePopUpType()
        evaluateVisibility()

        /// A dictation card deferred by the overlay comes back now.
        reshowPendingDictationPaywallIfNeeded()
    }

    /// Enable text editing mode for the transcription overlay (makes window key)
    func enableTranscriptionOverlayEditMode() {
        transcriptionOverlayWindow?.enableKeyStatus()
    }

    /// Disable text editing mode for the transcription overlay
    func disableTranscriptionOverlayEditMode() {
        transcriptionOverlayWindow?.disableKeyStatus()
    }

    // MARK: - Functions: Smart Cleanup Paywall

    /// A Smart Cleanup run was refused (free words used up, or no free tier in this build).
    /// The dictation was already pasted raw; this shows the upgrade prompt, at most once per
    /// `SmartCleanupUpgradePrompt.minimumInterval`.
    /// - Parameter mode: where it was triggered, for analytics (e.g. "after_dictation").
    func smartCleanupRefused(mode: String) {
        let reason = SmartCleanupEntitlement.shared.usage?.denialReason ?? .freeAllowanceUsed
        AnalyticsManager.SmartCleanupPaywall.cleanupRefused(reason: reason)
        /// Never interrupt a dictation that has already started again, never pop over
        /// onboarding, and never pop while the user keeps the Hint hidden or snoozed (or a
        /// fullscreen app hides it). None of these spend the daily slot: the next refusal with
        /// a visible Hint gets the prompt, and Settings always shows the meter.
        guard pendingCleanupPaywallMode == nil, !transcriptionOverlayWindowIsVisible,
              !TranscriptionManager.shared.isTranscribing, !isHintHiddenByUser,
              !OnboardingWindowManager.shared.onboardingWindowIsVisible,
              SmartCleanupUpgradePrompt.shouldShow(lastShownAt: Defaults[.smartCleanupUpgradePromptLastShownAt])
        else { return }
        Defaults[.smartCleanupUpgradePromptLastShownAt] = Date()
        /// Signed in but the library has no server answer it may trust (offline since updating,
        /// or for longer than its grace): possibly a subscriber, so explain instead of selling.
        if SmartCleanupEntitlement.shared.isSubscriptionUnconfirmed {
            showTranscriptionAlert(.cleanupUnconfirmed)
            return
        }
        showSmartCleanupPaywall(mode: mode)
    }

    /// Shows the Smart Cleanup upgrade card next to the hint.
    /// - Parameter mode: Where the paywall was triggered, for analytics (e.g. "after_dictation").
    func showSmartCleanupPaywall(mode: String) {
        activeTranscriptionAlert = nil
        pendingCleanupPaywallMode = mode
        pendingCleanupSuccessMode = mode
        dictationPaywallShownLogged = false
        /// The server may already entitle this user (webhook landed after the checkout poll
        /// ended, subscribed on another Mac): `entitlementAnswerArrived()` then turns the card
        /// into the success card.
        if AuthManager.shared.userLoggedIn {
            Task { @MainActor in
                await StripeManager.shared.refreshSubscriptionState()
                await LifetimeActivationManager.shared.fetchActivation()
            }
        }
        hideTranscriptionOverlayIfNeeded()
        /// Keeps the Hint in view while the card is up (see `computeForceShowHint()`). The
        /// unsolicited prompt only gets here with a visible Hint (`smartCleanupRefused`).
        evaluateVisibility()

        if !hintWindowIsVisible {
            log.warning("[paywall] Hint cannot be shown (immersive/onboarding/dev-build deferral); paywall deferred until it can")
        }

        /// Small delay to let the overlay finish hiding before showing the popup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.presentPendingDictationPaywall()
        }
    }

    /// Re-presents the paywall from `pendingCleanupPaywallMode` (initial show, after the hint
    /// moves screens, after the Hint's own menu closes). No-op if nothing is pending; resolves
    /// to the success card if the user became entitled meanwhile.
    /// - Parameter error: a checkout error to surface on the card (sign-in handoff failures).
    func presentPendingDictationPaywall(error: String? = nil) {
        guard let mode = pendingCleanupPaywallMode else { return }
        guard !SmartCleanupEntitlement.shared.hasUnlimitedSmartCleanup else {
            resolvePendingPaywallIfEntitled()
            return
        }
        let shouldLog = !dictationPaywallShownLogged
        showMoreMenu(swiftUIView: SmartCleanupPaywallView(
            mode: mode,
            onDismiss: { [weak self] in
                /// Only clear the re-show mode; `pendingCleanupSuccessMode` stays alive
                /// so we can still show the success dialog if they subscribe later.
                self?.pendingCleanupPaywallMode = nil
                self?.hideMoreMenu(force: true)
                /// Let a hidden/snoozed Hint go away again.
                self?.evaluateVisibility()
            },
            initialError: error,
            logShown: shouldLog
        ), isDictationCard: true)
        if dictationCardIsPresented { dictationPaywallShownLogged = true }
    }

    /// Called whenever an entitlement answer arrives (seat, subscription, or the Smart Cleanup
    /// library's cache). If the user became entitled after an upgrade prompt, show the success
    /// card. A success card already shown but force-hidden comes back even if entitlement
    /// dropped since: it is only closed by the user.
    func resolvePendingPaywallIfEntitled() {
        guard SmartCleanupEntitlement.shared.hasUnlimitedSmartCleanup || isShowingDictationSuccessCard else { return }
        guard pendingCleanupSuccessMode != nil else { return }
        guard !(isShowingDictationSuccessCard && dictationCardIsPresented) else { return }
        if dictationCheckoutOpenedAt != nil {
            AnalyticsManager.SmartCleanupPaywall.paywallConversion()
        }
        showDictationPaywallSuccess()
    }

    /// Shows the post-purchase celebration card. It stays until the user closes it: a forced
    /// hide (transcription overlay, Hint going away) re-presents it from
    /// `pendingCleanupSuccessMode`.
    func showDictationPaywallSuccess() {
        let mode = pendingCleanupSuccessMode
        pendingCleanupPaywallMode = nil
        dictationCheckoutOpenedAt = nil
        checkoutPollTask?.cancel()
        checkoutPollTask = nil
        isShowingDictationSuccessCard = true
        evaluateVisibility()

        let generation = dictationPaywallGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.dictationPaywallGeneration == generation else { return }
            self.showMoreMenu(swiftUIView: SmartCleanupPaywallView(
                mode: mode ?? "unknown",
                onDismiss: { [weak self] in
                    self?.pendingCleanupSuccessMode = nil
                    self?.isShowingDictationSuccessCard = false
                    self?.hideMoreMenu(force: true)
                    self?.evaluateVisibility()
                },
                initialShowSuccess: true
            ), isDictationCard: true)
            if !self.dictationCardIsPresented {
                /// Could not present (Hint hidden, overlay up, immersive mode): the pending
                /// card and the force-show flag are kept; `hideTranscriptionOverlayIfNeeded` / the next
                /// entitlement answer retries.
                log.warning("[paywall] success card deferred, could not present")
            }
        }
    }

    /// Logout: nothing pending belongs to the next account.
    func resetDictationPaywallState() {
        dictationPaywallGeneration += 1
        pendingDictationCheckoutAfterLogin = false
        dictationCheckoutOpenedAt = nil
        checkoutPollTask?.cancel()
        checkoutPollTask = nil
        forgetPendingDictation()
    }

    /// Drops a pending upgrade prompt or success card and lets a hidden or snoozed Hint go
    /// away again. Logout.
    func forgetPendingDictation() {
        pendingCleanupPaywallMode = nil
        pendingCleanupSuccessMode = nil
        isShowingDictationSuccessCard = false
        if dictationCardIsPresented { hideMoreMenu(force: true) }
        evaluateVisibility()
    }

    /// Opens Stripe Checkout for the dictation plan. Returns an error message on failure.
    func openDictationCheckout(_ openURL: OpenURLAction) async -> String? {
        let error = await Stripe.openSubscriptionForm(openURL, plan: DictationPlan.checkoutPlan)
        if error == nil {
            dictationCheckoutOpenedAt = Date()
            startCheckoutPolling()
        }
        return error
    }

    /// Background poll for the webhook-created subscription: every 5s for the first minute,
    /// then every 20s until `checkoutPollWindow` elapses or the user is entitled. Runs without
    /// needing an app activation; the `onit://payment-success` deep link just makes it immediate.
    /// Also started by that deep link on a cold launch: the first answers are dropped until
    /// the session is restored, the next ones land.
    func startCheckoutPolling() {
        checkoutPollTask?.cancel()
        let generation = dictationPaywallGeneration
        let startedAt = Date()
        checkoutPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.dictationPaywallGeneration == generation,
                  Date().timeIntervalSince(startedAt) < self.checkoutPollWindow {
                await StripeManager.shared.refreshSubscriptionState()
                if SmartCleanupEntitlement.shared.hasUnlimitedSmartCleanup {
                    self.resolvePendingPaywallIfEntitled()
                    return
                }
                let interval: Double = Date().timeIntervalSince(startedAt) < 60 ? 5 : 20
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Functions: Transcription Alerts

    func showTranscriptionAlert(_ alertType: TranscriptionAlertPopUpMessageType) {
        guard checkTranscriptionAlertEnabled(for: alertType) else { return }

        cancelPopUpAutoDismissTask()
        activeTranscriptionAlert = alertType

        /// If the transcription overlay is still visible, hide it first.
        /// Then, handle showing the transcription alert after it finishes hiding.
        if transcriptionOverlayWindowIsVisible {
            hideTranscriptionOverlayIfNeeded()
        }
        /// If the transcription overlay isn't already visible, just immediately show the transcription alert pop-up.
        else {
            updateActivePopUpType()
            evaluateVisibility()
        }
    }

    // MARK: - Private Functions: Key Monitor

    // MARK: - Private Functions

    private func checkTranscriptionAlertEnabled(for alertType: TranscriptionAlertPopUpMessageType) -> Bool {
        switch alertType {
        case .failed:
            return Defaults[.showHintTranscriptionFailedAlert]
        case .silent:
            return Defaults[.showHintTranscriptionSilentAlert]
        case .cancelled:
            return Defaults[.showHintTranscriptionCancelledAlert]
        case .inputDeviceFailed:
            return Defaults[.showHintTranscriptionInputDeviceFailedAlert]
        case .inputDeviceUnplugged:
            return Defaults[.showHintTranscriptionInputDeviceUnpluggedAlert]
        case .detectedNewInputDevice:
            return Defaults[.showHintTranscriptionDetectedNewInputDeviceAlert]
        case .cleanupModelLoading, .cleanupUnconfirmed, .rewriteFailed:
            return true
        }
    }

    /// Called when user drags the transcription overlay window.
    @objc private func transcriptionOverlayDidMove(_ notification: Notification) {
        /// Ignore moves that we explicitly initiated programmatically, rather than through explicit user interaction.
        guard !isProgrammaticallyPositioningOverlay else { return }

        /// The AppKit window movement notifications are quite spurious, so they can result in a lot of false-positive setting of `userHasManuallyPositionedOverlay = true`.
        /// This leads to buggy behavior with the Transcription Overlay's positioning.
        /// By intrinsically guarding `userHasManuallyPositionedOverlay = true` behind an explicit user click, we can ensure that the overlay window movement was indeed user driven.
        let isLeftMouseDown = NSEvent.pressedMouseButtons & (1 << 0) != 0
        
        guard isLeftMouseDown,
              let overlayWindow = transcriptionOverlayWindow,
              overlayWindow.frame.contains(NSEvent.mouseLocation)
        else {
            return
        }

        /// Mark that user has manually positioned the overlay. This prevents auto-repositioning from snapping it back.
        userHasManuallyPositionedOverlay = true
    }

    private func createTranscriptionOverlayWindowIfNeeded(state: TranscriptionState) {
        if transcriptionOverlayWindow == nil {
            let contentView = TranscriptionOverlayView(state: state)
            let hostingController = NSHostingController(rootView: contentView)
            hostingController.sizingOptions = .intrinsicContentSize
            transcriptionOverlayHostingController = hostingController

            let panel = ToggleableKeyPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )

            panel.contentViewController = hostingController
            panel.setup(delegate: nil)
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.isMovable = true

            /// Observe when user drags the window.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(transcriptionOverlayDidMove),
                name: NSWindow.didMoveNotification,
                object: panel
            )

            transcriptionOverlayWindow = panel

            /// Size to fit content.
            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            panel.setContentSize(fittingSize)
        } else {
            /// Update the existing view's state reference.
            let contentView = TranscriptionOverlayView(state: state)
            transcriptionOverlayHostingController?.rootView = contentView
        }
    }
}
