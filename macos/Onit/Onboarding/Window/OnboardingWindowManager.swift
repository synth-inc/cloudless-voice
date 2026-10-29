// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingWindowManager.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import Defaults
import SwiftUI

@MainActor
class OnboardingWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    // MARK: - Singleton

    static let shared = OnboardingWindowManager()

    // MARK: - States

    @ObservationIgnored
    private var _window: OnboardingWindow? = nil

    /// Public accessor for the onboarding window
    var window: OnboardingWindow? { _window }
    
    @Published private(set) var onboardingWindowIsVisible: Bool = false

    /// When true, the window will close after successful authentication instead of continuing onboarding
    @Published private(set) var authOnly: Bool = false

    /// When true, the window shows ONLY the dictation demo (post-completion "Try it now" / Setup's
    /// "Complete Demo"), closing when the demo finishes instead of resuming the onboarding flow.
    /// Mirrors `authOnly`: the demo is dropped from `OnboardingStep.steps` once transcription
    /// onboarding is complete, so this flag is how it's presented standalone.
    @Published private(set) var demoOnly: Bool = false

    // MARK: - Public Functions

    func showWindow() {
        authOnly = false
        demoOnly = false
        Defaults[.onboardingAuthSkipped] = false
        if let existingWindow = _window {
            showExistingWindow(existingWindow)
        } else {
            createWindow()
        }
    }

    /// Shows onboarding starting from a specific step (for late feature activation)
    func showWindow(startingAt step: OnboardingStep) {
        authOnly = false
        Defaults[.currentOnboardingStep] = step
        showWindow()
    }

    /// Shows only the auth screen, closing the window after successful authentication.
    /// Does NOT modify currentOnboardingStep to preserve the user's onboarding progress.
    func showAuthOnly() {
        authOnly = true
        demoOnly = false
        if let existingWindow = _window {
            showExistingWindow(existingWindow)
        } else {
            createWindow()
        }
    }

    /// Shows only the dictation demo, closing the window when it completes (post-completion "Try it
    /// now" / Setup's "Complete Demo"). Does NOT modify currentOnboardingStep, preserving the user's
    /// onboarding progress.
    func showDemoOnly() {
        authOnly = false
        demoOnly = true
        if let existingWindow = _window {
            showExistingWindow(existingWindow)
        } else {
            createWindow()
        }
    }

    func closeWindow() {
        _window?.close()
    }

    // MARK: - Private Functions

    private func showExistingWindow(_ window: OnboardingWindow) {
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        onboardingWindowIsVisible = true
    }

    private func createWindow() {
        _window = OnboardingWindow()

        guard let window = _window else { return }

        window.delegate = self
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowIsVisible = true
    }

    // MARK: - NSWindowDelegate Protocol Conformance

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? OnboardingWindow,
              window === self._window
        else {
            return
        }

        // Belt-and-suspenders: ensure demo capture state can never linger past the onboarding window.
        TranscriptionManager.shared.resetDemoCaptureState()

        // Same treatment for the Shortcut step's test mode: it lives in globals cleared only by that
        // page's `.onDisappear`, and while it's on both key handlers return early - a leak would kill
        // dictation app-wide until relaunch. Idempotent, so it's safe when `.onDisappear` did run.
        KeyboardShortcutsManager.onTranscriptionShortcutDetected = nil
        KeyboardShortcutsManager.isTranscriptionShortcutTestModeActive = false
        // Same reasoning for the Shortcut step's "Custom selected but nothing recorded" state: the
        // user must not walk away from onboarding with no dictation shortcut bound.
        KeyboardShortcutsManager.restoreShortcutTypeIfCustomIsEmpty()

        // Cancel any pending demo launch AND give back the settings it borrowed. Cancel, not just
        // restore: restoring flips the readiness gate, and a still-running poll would then re-open
        // the window the user just closed. No-op when nothing was pending or borrowed.
        DictationDemoLauncher.shared.cancel()

        // Track onboarding dismissal (only if not in authOnly mode)
        if !authOnly {
            let currentStep = Defaults[.currentOnboardingStep]
            let stepName = currentStep?.rawValue ?? "unknown"
            let completed = currentStep == .complete

            AnalyticsManager.Onboarding.dismissed(step: stepName, completed: completed)
        }

        window.cleanupObservers()
        window.delegate = nil
        self._window = nil
        onboardingWindowIsVisible = false
        authOnly = false
        demoOnly = false
    }
}
