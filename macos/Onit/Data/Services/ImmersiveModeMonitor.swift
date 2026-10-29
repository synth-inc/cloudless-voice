// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ImmersiveModeMonitor.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-08-28.
//

import AppKit
import ApplicationServices
import Combine
import IOKit.pwr_mgt

/// Detects "immersive mode": the frontmost app owns a fullscreen window AND that same process
/// holds a power assertion preventing display sleep, which is what media playback looks like.
///
/// Both conditions, same pid. Fullscreen alone is not enough (Xcode or Safari parked in
/// fullscreen keep the Hint), playback alone is not enough (a video in a regular window keeps
/// the Hint).
///
/// Fullscreen transitions are edge-driven (a fullscreen window gets its own Space, so
/// `activeSpaceDidChange` covers both switching into a fullscreen app and toggling fullscreen in
/// place). Power assertions emit no notification, so that half is polled - but only while a
/// fullscreen window is frontmost, never otherwise.
@MainActor
final class ImmersiveModeMonitor: ObservableObject {

    // MARK: - Singleton

    static let shared = ImmersiveModeMonitor()

    // MARK: - Constants

    private static let pollInterval: TimeInterval = 1

    /// Ticks the poll survives after a workspace change even when nothing is fullscreen:
    /// entering fullscreen animates, and the AX attribute can still read `false` when the Space
    /// notification lands.
    private static let settleTicks = 3

    /// Same cap as `TranscriptionInsertService`: an unresponsive app must not stall the main thread.
    private static let axMessagingTimeout: Float = 0.2

    /// Media players drop the display-sleep assertion on every pause and every scrub. Without a
    /// delay the Hint would pop over the video each time the user pauses, and tear its SwiftUI
    /// tree down again on resume. Only applies while the app stays fullscreen.
    private static let exitDebounce: TimeInterval = 2.5

    // MARK: - Published Properties

    @Published private(set) var isImmersive: Bool = false

    // MARK: - Private Properties

    private var pollTimer: Timer?
    private var exitTimer: Timer?
    private var settleTicksRemaining = 0
    private var observers: [NSObjectProtocol] = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Starts observing workspace changes. Idempotent.
    func startMonitoring() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter

        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ImmersiveModeMonitor.shared.workspaceDidChange()
                }
            }
            observers.append(observer)
        }

        workspaceDidChange()
    }

    // MARK: - Private Methods

    private func workspaceDidChange() {
        settleTicksRemaining = Self.settleTicks

        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
                Task { @MainActor in
                    ImmersiveModeMonitor.shared.evaluate()
                }
            }
        }

        evaluate()
    }

    private func evaluate() {
        guard let pid = frontmostFullScreenPid() else {
            /// Nothing fullscreen: keep ticking for a moment in case a transition is still
            /// animating, then stop. No always-on poll.
            if settleTicksRemaining > 0 {
                settleTicksRemaining -= 1
            } else {
                pollTimer?.invalidate()
                pollTimer = nil
            }
            /// Leaving fullscreen is a deliberate move, so the Hint comes back at once.
            cancelExitDebounce()
            isImmersive = false
            return
        }

        settleTicksRemaining = 0

        if Self.holdsDisplaySleepAssertion(pid: pid) {
            cancelExitDebounce()
            isImmersive = true
        } else if isImmersive {
            /// Still fullscreen, playback just stopped: could be a pause, could be a scrub.
            startExitDebounce()
        }
    }

    private func startExitDebounce() {
        guard exitTimer == nil else { return }

        exitTimer = Timer.scheduledTimer(withTimeInterval: Self.exitDebounce, repeats: false) { _ in
            Task { @MainActor in
                ImmersiveModeMonitor.shared.exitTimer = nil
                ImmersiveModeMonitor.shared.isImmersive = false
            }
        }
    }

    private func cancelExitDebounce() {
        exitTimer?.invalidate()
        exitTimer = nil
    }

    /// The frontmost app's pid when its focused window is fullscreen, `nil` otherwise.
    ///
    /// Returns `nil` without Accessibility permission, which is the safe default: the Hint keeps
    /// showing instead of silently disappearing for non-AX users.
    private func frontmostFullScreenPid() -> pid_t? {
        guard AccessibilityPermissionManager.shared.accessibilityPermissionStatus == .granted,
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }

        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.axMessagingTimeout)

        guard let window = appElement.focusedWindow() ?? appElement.mainWindow() else { return nil }

        /// The timeout is per-object and is not inherited by the elements an object returns, so
        /// the window needs its own cap or the read below runs under the process-global timeout.
        /// Same reason as `TranscriptionInsertService` capping its focused element separately.
        AXUIElementSetMessagingTimeout(window, Self.axMessagingTimeout)

        guard window.isFullScreen() == true else { return nil }

        return pid
    }

    /// Whether `pid` holds an assertion that keeps the display awake, which is how media players
    /// signal active playback. Public IOKit call, no permission and no entitlement needed.
    ///
    /// ponytail: matches the assertion owner's pid exactly. Apps that hold the assertion from a
    /// helper process (some browsers spawn a separate media process) will not be detected; if that
    /// shows up in practice, resolve the helper's parent/responsible pid before comparing.
    private static func holdsDisplaySleepAssertion(pid: pid_t) -> Bool {
        var assertionsByProcess: Unmanaged<CFDictionary>?

        guard IOPMCopyAssertionsByProcess(&assertionsByProcess) == kIOReturnSuccess,
              let byProcess = assertionsByProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let assertions = byProcess[NSNumber(value: pid)]
        else { return false }

        return assertions.contains { assertion in
            guard let type = assertion[kIOPMAssertionTypeKey] as? String else { return false }
            return type == kIOPMAssertionTypePreventUserIdleDisplaySleep
                || type == kIOPMAssertionTypeNoDisplaySleep
        }
    }
}
