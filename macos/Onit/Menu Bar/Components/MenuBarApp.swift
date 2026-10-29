// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarApp.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import AppKit

final class MenuBarApp: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.action = #selector(openAppWindow)
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = String.localized("Home", table: "MenuBar")
    }

    // MARK: - Private Functions

    @MainActor
    @objc private func openAppWindow() {
        AppWindowManager.shared.showWindow()
    }
}
