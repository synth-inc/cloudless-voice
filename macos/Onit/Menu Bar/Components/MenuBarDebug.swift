// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarDebug.swift
//  Onit
//

#if DEBUG && canImport(TranscriptionCleanup) // the scoring debug window shows Smart Cleanup decisions

import AppKit

final class MenuBarDebug: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.action = #selector(openDebugWindow)
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = "Debug"
    }

    // MARK: - Private Functions

    @MainActor
    @objc private func openDebugWindow() {
        ScoringDebugWindowController.shared.show()
    }
}

#endif
