// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarHintSnooze.swift
//  Onit
//
//  Created by Kévin Naudin on 8/28/26.
//

import Combine
import Defaults
import AppKit

/// Menu bar entry that starts a Hint snooze. Both this row and `MenuBarHintSnoozeStatus` are always
///     in the menu, each hiding itself so exactly one shows: the menu is only rebuilt on
///     `menuWillOpen`, so a snooze that starts or lapses while it is open has to be handled by
///     toggling `isHidden`, not by picking one row at build time.
@MainActor
final class MenuBarHintSnooze: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.action = nil
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = String.localized("Hide hint for", table: "MenuBar")
        self.populateDropdownSubmenu()
        self.updateVisibility()

        Defaults.publisher(.hintSnoozedUntil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &self.cancellables)

        Defaults.publisher(.alwaysHideHint)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility()
            }
            .store(in: &self.cancellables)
    }

    /// Mirrors `MenuBarHintSnoozeStatus.removeSubscriptions()`, called from `menuDidClose`.
    func removeSubscriptions() {
        self.cancellables.removeAll()
    }

    // MARK: - States

    private var cancellables = Set<AnyCancellable>()
    private var dropdownSubmenu = NSMenu()

    // MARK: - Private Functions: Visibility

    /// Hidden while a snooze runs (the status row takes over) and while the Hint is always hidden,
    ///     where starting a snooze would be a no-op.
    private func updateVisibility() {
        let isSnoozed = Defaults[.hintSnoozedUntil].map { $0 > Date() } ?? false

        self.isHidden = isSnoozed || Defaults[.alwaysHideHint]
    }

    // MARK: - Private Functions

    private func populateDropdownSubmenu() {
        self.dropdownSubmenu.removeAllItems()

        for duration in HintSnoozeDuration.allCases {
            let item = NSMenuItem(
                title: duration.title(table: "MenuBar"),
                action: #selector(self.snoozeHint(_:)),
                keyEquivalent: ""
            )

            item.target = self
            item.representedObject = duration.rawValue

            self.dropdownSubmenu.addItem(item)
        }

        self.submenu = self.dropdownSubmenu
    }

    @objc private func snoozeHint(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let duration = HintSnoozeDuration(rawValue: rawValue)
        else {
            return
        }

        HintManager.shared.snoozeHint(duration)
    }
}
