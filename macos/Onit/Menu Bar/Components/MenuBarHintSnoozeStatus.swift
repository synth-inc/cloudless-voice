// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarHintSnoozeStatus.swift
//  Onit
//
//  Created by Kévin Naudin on 8/28/26.
//

import AppKit
import Combine
import Defaults

/// Menu bar row shown while the Hint is snoozed: an orange dot, the remaining time, and a click to
///     bring the Hint back. This is the only surface that stays reachable during a snooze, since the
///     Hint itself is hidden and therefore no longer clickable.
final class MenuBarHintSnoozeStatus: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.image = self.statusDot
        self.action = #selector(cancelSnooze)
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.setMenuItemTitle()

        Defaults.publisher(.hintSnoozedUntil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.hintSnoozedUntil = state.newValue

                if state.newValue == nil {
                    self?.stopTimerUpdateTask()
                } else {
                    self?.startTimerUpdateTaskIfNeeded()
                }

                self?.setMenuItemTitle()
            }
            .store(in: &self.cancellables)

        if self.hintSnoozedUntil != nil {
            self.startTimerUpdateTaskIfNeeded()
        }
    }

    deinit {
        self.timerUpdateTask?.cancel()
        self.timerUpdateTask = nil
    }

    // MARK: - States

    private var cancellables = Set<AnyCancellable>()
    private var hintSnoozedUntil: Date? = Defaults[.hintSnoozedUntil]
    private var timerUpdateTask: Task<Void, Never>? = nil
    private var currentTime: Date = Date()

    // MARK: - Private Variables

    private lazy var statusDot = self.drawStatusDot(NSColor.orange500)

    @MainActor
    private var remainingTimeString: String {
        guard let hintSnoozedUntil = self.hintSnoozedUntil else { return "" }

        let timeInterval = hintSnoozedUntil.timeIntervalSince(self.currentTime)
        if timeInterval <= 0 { return String.localized("Expired", table: "MenuBar") }

        /// Formatted rather than interpolated: the unit letters are localized (a hand-rolled
        ///     "42m 07s" stays English inside a French label), and an hours bucket keeps a one hour
        ///     snooze from reading "59m 58s". Two units at most, so the label stays short.
        return Duration.seconds(timeInterval).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds],
                width: .narrow,
                maximumUnitCount: 2
            )
        )
    }

    // MARK: - Private Functions

    @MainActor
    private func setMenuItemTitle() {
        guard self.hintSnoozedUntil != nil else {
            self.title = ""
            self.isHidden = true
            return
        }

        self.title = String.localized(" Hint hidden for %@", table: "MenuBar", remainingTimeString)
        self.isHidden = false
    }

    /// Refreshes the countdown label only. `HintManager.rearmSnoozeExpiry()` is the single writer of
    ///     `hintSnoozedUntil`, so this row never clears the key itself: two writers racing on the same
    ///     key is how a snooze ends up cancelled twice, or not at all.
    @MainActor
    private func startTimerUpdateTaskIfNeeded() {
        guard self.hintSnoozedUntil != nil,
              self.timerUpdateTask == nil
        else {
            return
        }

        self.timerUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                if Task.isCancelled {
                    break
                }

                guard let self = self else { return }

                await MainActor.run {
                    self.currentTime = Date()
                    self.setMenuItemTitle()
                }
            }
        }
    }

    /// Called by `MenuBarController` on `menuDidClose`, same contract as `MenuBarAppStatus`: the
    ///     item survives the menu closing (nothing repopulates until the next open), so without
    ///     this its 0.5 s loop would keep waking the main actor to rewrite a hidden label, for as
    ///     long as the snooze runs.
    @MainActor
    func removeSubscriptions() {
        self.stopTimerUpdateTask()
        self.cancellables.removeAll()
    }

    @MainActor
    private func stopTimerUpdateTask() {
        self.timerUpdateTask?.cancel()
        self.timerUpdateTask = nil
    }

    @MainActor
    @objc private func cancelSnooze() {
        HintManager.shared.cancelHintSnooze()
    }
}
