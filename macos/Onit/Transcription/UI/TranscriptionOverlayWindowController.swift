// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionOverlayWindowController.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import AppKit
import SwiftUI

/// Window controller for the transcription overlay, positioned at bottom center of screen.
@MainActor
final class TranscriptionOverlayWindowController: NSObject, NSWindowDelegate {

    // MARK: - Singleton

    static let shared = TranscriptionOverlayWindowController()

    // MARK: - Properties

    private var overlayWindow: ToggleableKeyPanel?
    private var hostingController: NSHostingController<TranscriptionOverlayView>?
    private var clickOutsideMonitor: Any?

    private let bottomMargin: CGFloat = 80

    /// Whether the overlay is currently visible
    var isVisible: Bool {
        overlayWindow?.isVisible ?? false
    }

    /// Current frame of the overlay window (used for anchoring prompt list)
    var currentFrame: CGRect? {
        overlayWindow?.frame
    }

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    /// Preload the window to avoid delay on first show.
    /// Call this at app launch after models are initialized.
    func preload() {
        guard overlayWindow == nil else { return }

        createWindow()

        // Keep window hidden but fully initialized
        overlayWindow?.alphaValue = 0
        overlayWindow?.orderFront(nil)
        overlayWindow?.orderOut(nil)
    }

    /// Show the transcription overlay at bottom center of screen
    func show() {
        if overlayWindow == nil {
            createWindow()
        }

        guard let window = overlayWindow else { return }

        // Reset state
        disableEditMode()

        // Ensure alpha is 0 before showing (for fade-in animation)
        window.alphaValue = 0

        // Update size and position
        updateWindowSize()
        positionWindow()

        // Show window
        window.orderFront(nil)

        // Animate in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    /// Hide the transcription overlay
    func hide() {
        guard let window = overlayWindow else { return }

        stopClickOutsideMonitor()

        // Capture reference before async completion
        let windowToHide = window

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            windowToHide.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only clean up if this is still the current window (not replaced by a new show() call)
            guard self?.overlayWindow === windowToHide else { return }
            windowToHide.orderOut(nil)
            self?.overlayWindow = nil
            self?.hostingController = nil
        })
    }

    /// Update the overlay position (call when screen changes)
    func updatePosition() {
        positionWindow()
    }

    /// Update window size when content changes (e.g., switching to correction mode)
    func updateWindowSize() {
        guard let window = overlayWindow, let contentView = hostingController?.view else { return }

        // Force layout update
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize

        // Update size immediately and reposition
        window.setContentSize(fittingSize)
        positionWindow()
    }

    /// Enable text editing mode (for correction UI)
    func enableEditMode() {
        overlayWindow?.enableKeyStatus()
    }

    /// Disable text editing mode
    func disableEditMode() {
        overlayWindow?.disableKeyStatus()
    }

    /// Position the window near the mouse cursor, keeping it fully on screen
    func positionNearMouse() {
        guard let window = overlayWindow else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Position window centered horizontally on mouse, above the cursor
        var originX = mouseLocation.x - windowSize.width / 2
        var originY = mouseLocation.y + 20 // 20px above cursor

        // Keep window fully on screen
        originX = max(screenFrame.minX, min(originX, screenFrame.maxX - windowSize.width))
        originY = max(screenFrame.minY, min(originY, screenFrame.maxY - windowSize.height))

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    /// Start monitoring for clicks outside the overlay (dismisses correction UI)
    func startClickOutsideMonitor() {
        stopClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let window = self.overlayWindow,
                      window.isVisible else { return }

                // Check if click is outside the window
                let screenLocation = NSEvent.mouseLocation
                let windowFrame = window.frame

                if !windowFrame.contains(screenLocation) {
                    TranscriptionManager.shared.dismissOverlay()
                }
            }
        }
    }

    /// Stop monitoring for clicks outside
    func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Private Methods

    private func createWindow() {
        let contentView = TranscriptionOverlayView(state: TranscriptionManager.shared.state)
        hostingController = NSHostingController(rootView: contentView)

        let panel = ToggleableKeyPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.setup(delegate: self)
        panel.level = .floating
        panel.isMovableByWindowBackground = false

        overlayWindow = panel

        // Size to fit content
        if let contentView = hostingController?.view {
            contentView.layoutSubtreeIfNeeded()
            let fittingSize = contentView.fittingSize
            panel.setContentSize(fittingSize)
        }
    }

    private func positionWindow() {
        guard let window = overlayWindow else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        // Position at bottom center
        let originX = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let originY = screenFrame.origin.y + bottomMargin

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        Task { @MainActor in
            positionWindow()
        }
    }
}
