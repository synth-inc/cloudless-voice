// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictationDemoLauncher.swift
//  Onit
//
//  Created by Kévin Naudin on 11/08/2026.
//

import Combine
import Defaults
import Foundation

/// The single entry point for opening the dictation demo outside the onboarding flow (App Home's
/// "Try it now", Settings → Setup's "Complete Demo").
///
/// It owns the three things every caller was getting wrong on its own:
///
/// 1. **Prerequisites.** The demo showcases Smart Cleanup, so it's made the active cleanup
///    provider when another one (or none) is.
///    Backtracking (its own demo step) is deliberately *not* switched on: it pulls a ~680 MB
///    improvement LLM, which the readiness wait below would then block on and the restore would
///    throw away. That step degrades instead. Enabling backtracking by default is a product call.
/// 2. **Restore.** Those switches are *borrowed*, not taken: whatever was forced on is put back the
///    way the user had it once the demo window closes, so a user who deliberately disabled Smart
///    Cleanup doesn't silently get it back on every later dictation.
/// 3. **Readiness.** Turning Smart Cleanup on starts a model download; presenting the demo right
///    away would show steps that can't transcribe or can't clean up. The launch waits for
///    `ModelDownloadIndicator.demoModelsReady`, and gives up if a required model fails.
@MainActor
final class DictationDemoLauncher: ObservableObject {

    // MARK: - Singleton

    static let shared = DictationDemoLauncher()

    private init() {}

    // MARK: - Published

    /// True while a launch is waiting on model preparation. Callers surface their own progress UI
    /// from this (the Home card keeps its card visible and shows the download bar).
    @Published private(set) var isWaitingForModels = false

    // MARK: - Private

    /// Undo closures for the settings this launcher forced on, run when the demo window closes.
    /// Empty when nothing was forced (the user already had everything enabled).
    private var restoreActions: [() -> Void] = []

    private var pollTimer: Timer?

    /// Slower than the Home card's 0.15 s progress poll: this one only flips a boolean gate, and the
    /// wait it covers is a multi-second model download.
    private static let pollInterval: TimeInterval = 0.25

    // MARK: - Public

    /// Whether this launch, once it actually presents the demo, should permanently dismiss the App
    /// Home setup card. True for the card's own "Try it now" (a one-shot offer), false for the
    /// Settings → Setup entry, which must leave the card's offer intact if the user abandons the demo.
    private var dismissesHomeCardOnPresent = false

    /// Opens the demo, waiting for the models if needed. Safe to call repeatedly: a second call
    /// while waiting retries any failed warmup rather than stacking timers.
    ///
    /// - Parameter dismissesHomeCard: pass true from the App Home card's "Try it now".
    func launch(dismissesHomeCard: Bool = false) {
        dismissesHomeCardOnPresent = dismissesHomeCard
        // A fully open build has no Smart Cleanup to switch to (`SmartCleanupAvailability`),
        // so the demo runs with whatever cleanup the user chose.
        if SmartCleanupAvailability.isCompiledIn {
            enablePrerequisites()
        }

        if ModelDownloadIndicator.demoModelsReady {
            present()
            return
        }

        // A previous preparation attempt may have failed - retry just those providers, otherwise the
        // readiness gate stays false and we would wait forever. Targeted rather than
        // `retryAllWarmups()`, which resets *every* provider and would unload a perfectly healthy ASR
        // engine because a cleanup model failed.
        for identifier in WarmupCoordinator.shared.failedProviders.keys {
            WarmupCoordinator.shared.retryWarmup(for: identifier)
        }

        isWaitingForModels = true
        startPolling()
    }

    /// Abandons a pending launch (e.g. the user dismissed the surface that started it) and restores
    /// anything that was forced on for it.
    func cancel() {
        stopPolling()
        isWaitingForModels = false
        dismissesHomeCardOnPresent = false
        restoreForcedSettings()
    }

    /// Puts back every setting this launcher forced on. Called when the demo window closes, and on
    /// `cancel()`. A no-op when nothing was forced, so it's safe to call unconditionally.
    func restoreForcedSettings() {
        guard !restoreActions.isEmpty else { return }
        restoreActions.forEach { $0() }
        restoreActions = []
    }

    // MARK: - Private Functions

    /// Switches on what the demo needs to have anything to show, remembering how to undo it.
    ///
    /// Always through `TranscriptionConfig`, never `Defaults` directly: the config's `didSet` is what
    /// notifies `WarmupCoordinator.featureStateChanged()`. Writing the key behind its back flips the
    /// warmup provider's `isEnabled` without ever starting the warmup, so readiness would never
    /// arrive and the demo would wait forever.
    ///
    /// Backtracking (which has its own demo step) is deliberately left alone: switching it on pulls a
    /// ~680 MB improvement LLM that the readiness wait would block on and the restore would throw
    /// away. That step degrades instead. Enabling backtracking by default is a product call.
    private func enablePrerequisites() {
        if let restore = Self.borrowSmartCleanup(from: TranscriptionConfig.shared) {
            restoreActions.append(restore)
        }
    }

    /// Switches `config` to Smart Cleanup alone, returning how to put back what the
    /// user had (no cleanup, and/or their Rewrite), or nil when nothing had to
    /// change. The demo shows Smart Cleanup: a rewrite with the user's own prompt
    /// (translate, reformat) would hide it.
    static func borrowSmartCleanup(from config: some CleanupProviderSelecting) -> (() -> Void)? {
        let previousProvider = config.cleanupProviderID
        let previousRewrite = config.rewriteEnabled
        guard previousProvider != CleanupProviderID.smart || previousRewrite else { return nil }
        config.cleanupProviderID = CleanupProviderID.smart
        config.rewriteEnabled = false
        return { [weak config] in
            config?.cleanupProviderID = previousProvider
            config?.rewriteEnabled = previousRewrite
        }
    }

    private func present() {
        isWaitingForModels = false
        // Only now - not when "Try it now" was clicked. While the launch is still waiting on a
        // download, the card is that wait's only status surface, so it has to stay on screen.
        if dismissesHomeCardOnPresent {
            Defaults[.appHomeSetupCardDismissed] = true
            dismissesHomeCardOnPresent = false
        }
        OnboardingWindowManager.shared.showDemoOnly()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        // `.common` so the poll keeps running during menu tracking: one of the entry points is the
        // "Try Cloudless" button inside the menu-bar popover, and on the default mode the demo would
        // not open until the popover closed.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard isWaitingForModels else {
            stopPolling()
            return
        }

        // Readiness can never flip true once a required model failed - bail out instead of spinning
        // forever. Pressing the entry point again retries the failed warmups.
        if ModelDownloadIndicator.isDemoModelPreparationFailed {
            cancel()
            return
        }

        if ModelDownloadIndicator.demoModelsReady {
            stopPolling()
            present()
        }
    }
}
