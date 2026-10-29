// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ToggleableKeyPanel.swift
//  Onit
//
//  Created by Kévin Naudin on 12/10/2025.
//

import AppKit

/// A panel that can toggle between key-accepting and non-key modes.
/// By default, it doesn't accept key status (allowing keyboard shortcuts to pass through).
/// Call `enableKeyStatus()` when the panel needs to receive text input.
class ToggleableKeyPanel: NSPanel {

    /// Whether the panel should accept key status (for text input in AI-Edit mode)
    var acceptsKeyStatus: Bool = false

    override var canBecomeKey: Bool { acceptsKeyStatus }
    override var canBecomeMain: Bool { false }

    func setup(delegate: NSWindowDelegate? = nil) {
        styleMask = [.nonactivatingPanel, .borderless]
        isOpaque = false
        backgroundColor = NSColor.clear
        level = .screenSaver
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        self.delegate = delegate
    }

    /// Enable key status (for AI-Edit text input)
    func enableKeyStatus() {
        acceptsKeyStatus = true
        makeKey()
    }

    /// Disable key status (allow keyboard events to pass through to other windows)
    func disableKeyStatus() {
        acceptsKeyStatus = false
        resignKey()
    }
}
