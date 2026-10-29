// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Download.swift
//  Onit
//
//  Created by Loyd Kim on 6/10/26.
//

/*
 * Variables: Gates
 * Functions: Progress Timer
 * Functions: Tracking
 */

import Defaults
import Foundation

extension HintManager {
    // MARK: - Variables: Gates

    /// Whether any onboarding-relevant model (dictation or the Smart Cleanup stack) is still being
    /// prepared - downloading *or* warming into memory. Drives the Hint pill's indicator and the
    /// Hint's onboarding visibility. Delegates to the shared [[ModelDownloadIndicator]] so the pill,
    /// toast, and menu bar all flip together.
    var isAnyModelPreparing: Bool {
        return ModelDownloadIndicator.isAnyModelPreparing
    }

    /// The "Downloading/Loading … model … (Don't quit the app)" toast stays visible on *every*
    /// onboarding step while a model is being prepared, so the user is never left without the
    /// download status as they move through the flow. Its label is resolved reactively from
    /// `ModelDownloadIndicator` (and re-rendered via `modelDownloadLabel`).
    var shouldShowModelDownloadingPopUpMessage: Bool {
        return
            isAnyModelPreparing &&
            OnboardingWindowManager.shared.onboardingWindowIsVisible
    }

    // MARK: - Functions: Progress Timer

    /// Mirror the active model's download progress into the observable `modelDownloadProgress` so the
    /// Hint pill can render a live percentage. The dictation/Smart-Cleanup-gating models expose their
    /// progress via lock-free `AtomicProgress` (written off the main thread), so a poll is the
    /// sanctioned way to surface it - the same approach `MenuBarController` uses for its row.
    func startModelDownloadProgressTimer() {
        guard modelDownloadProgressTimer == nil else { return }

        modelDownloadProgress = ModelDownloadIndicator.current?.progress ?? 0
        modelDownloadLabel = ModelDownloadIndicator.current?.label ?? ""

        modelDownloadProgressTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15,
            repeats: true
        ) { _ in
            Task { @MainActor in
                HintManager.shared.tickModelDownloadProgress()
            }
        }
    }

    func stopModelDownloadProgressTimer() {
        /// `willSet` invalidates the existing timer.
        modelDownloadProgressTimer = nil
        // Reset stall bookkeeping here too (not only in the tick's `current == nil` branch): a
        // direct stop from `refreshModelDownloadTracking` can race the tick, and stale state must
        // not carry a "stalled" flag or a high-water mark into the next preparation cycle.
        modelDownloadStalled = false
        lastDownloadProgressValue = -1
    }

    /// One poll tick: refresh the displayed percentage (0 during the warmup phase, which renders as a
    /// spinner), and stop the timer once nothing is being prepared (so the pill reverts / Hint hides).
    /// Publishing `modelDownloadProgress` each tick also re-renders the pill so a download → warmup
    /// phase change flips it from "% ⟳" to a spinner.
    private func tickModelDownloadProgress() {
        guard let current = ModelDownloadIndicator.current else {
            stopModelDownloadProgressTimer()
            modelDownloadLabel = ""
            modelDownloadStalled = false
            lastDownloadProgressValue = -1
            return
        }

        // Stall detection is only meaningful in the determinate download phase - the warmup
        // phase reports `nil` progress and renders as a spinner anyway.
        if let progress = current.progress {
            // Any *change* counts as progress - not just an increase - so handing off from one
            // determinate download to the next (dictation → Smart Cleanup, whose % resets lower)
            // re-arms the timer instead of being mistaken for a stall.
            if progress != lastDownloadProgressValue {
                lastDownloadProgressValue = progress
                lastDownloadProgressAdvance = Date()
                if modelDownloadStalled { modelDownloadStalled = false }
            } else if lastDownloadProgressValue > 0,
                      Date().timeIntervalSince(lastDownloadProgressAdvance) > Self.downloadStallThreshold {
                // Only after real bytes have flowed - a determinate 0% (e.g. the `.fetching`
                // metadata phase) sitting for a few seconds is not a stalled transfer.
                if !modelDownloadStalled { modelDownloadStalled = true }
            }
        } else {
            modelDownloadStalled = false
            lastDownloadProgressValue = -1
        }

        modelDownloadProgress = current.progress ?? 0
        // Surface the stall honestly in the pop-up copy too, so the expanded Hint doesn't sit on
        // "Downloading…" while the transfer is actually paused between resume attempts.
        modelDownloadLabel = modelDownloadStalled
            ? String.localized("Reconnecting…", table: "MenuBar")
            : current.label
    }

    // MARK: - Functions: Tracking

    /// Start/stop the progress poll to match the current preparation state. Called from the
    /// model-state subscriptions so the timer only runs while there's something to show.
    func refreshModelDownloadTracking() {
        if isAnyModelPreparing {
            startModelDownloadProgressTimer()
        } else {
            stopModelDownloadProgressTimer()
        }
    }
}
