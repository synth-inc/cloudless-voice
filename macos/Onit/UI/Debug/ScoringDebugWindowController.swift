// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringDebugWindowController.swift
//  Onit
//

#if DEBUG && canImport(TranscriptionCleanup) // the scoring debug window shows Smart Cleanup decisions

import AppKit
import Defaults
import SwiftUI

@MainActor
final class ScoringDebugWindowController: NSObject, NSWindowDelegate {

    static let shared = ScoringDebugWindowController()

    private var window: CenteredWindow<ScoringDebugView>?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ScoringDebugView()
        let newWindow = CenteredWindow(
            rootView: view,
            windowLevel: .floating,
            hideTitleBar: false,
            canResize: true,
            canDrag: true,
            canCloseWithEsc: true,
            windowSize: (width: 960, height: 700)
        )
        newWindow.delegate = self
        newWindow.title = "Scoring Debug"
        newWindow.isReleasedWhenClosed = false

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        Defaults[.scoringDebugWindowOpen] = true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window?.cleanupObservers()
        window?.delegate = nil
        window = nil
        Defaults[.scoringDebugWindowOpen] = false
    }
}

#endif
