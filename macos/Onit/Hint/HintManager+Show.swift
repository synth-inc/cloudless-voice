// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Show.swift
//  Onit
//
//  Created by Kévin Naudin on 08/06/2026.
//

/*
 * Functions: Show Hint Window
 * Functions: Vertical Drag
 */

import AppKit
import Defaults
import SwiftUI

extension HintManager {
    // MARK: - Functions: Show Hint Window

    /// Builds the Hint SwiftUI view, installs it as the hint window's content view,
    /// positions the window against the right edge of the active screen and orders it front.
    func showHintWindow() {
        let screen = screenBeforeImmersive ?? NSScreen.mouse ?? NSScreen.main ?? NSScreen.screens.first
        screenBeforeImmersive = nil
        currentScreen = screen

        let hintView = Hint(
            onDragChanged: { [weak self] in
                self?.handleHintDragChanged()
            },
            onDragEnded: { [weak self] in
                self?.endHintDrag()
            }
        )
        .environment(\.appState, AppState.shared)

        let hostingView = NSHostingView(rootView: hintView)
        hostingView.layoutSubtreeIfNeeded()

        hintWindow.contentView = hostingView
        configureFrameChangeObserver(for: hostingView)

        updateHintSize()
        positionHintWindow(on: screen)

        hintWindow.orderFront(nil)

        startHoverTracking()

        repositionMoreMenuIfNeeded()
        repositionTranscriptionOverlayIfNeeded()
        reshowPendingDictationPaywallIfNeeded()
    }

    /// Re-attach the Smart Cleanup paywall after the hint window is rebuilt or jumps to another
    /// screen, so the user can't lose the upgrade prompt by moving.
    /// Also called once a pop-up that outranked the card clears.
    func reshowPendingDictationPaywallIfNeeded() {
        if pendingCleanupPaywallMode != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.presentPendingDictationPaywall()
            }
        } else if pendingCleanupSuccessMode != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.resolvePendingPaywallIfEntitled()
            }
        }
    }

    /// Re-evaluates which display the hint belongs on and moves it there if the
    /// user's active screen changed. The hint window is persistent (it stays
    /// visible across dictations), so `showHintWindow()`'s one-time screen pick
    /// never re-runs once the window is up - without this the hint gets "stuck"
    /// on whichever screen it first appeared on. Called when dictation starts so
    /// the hint jumps to the display the user is actually working on.
    func repositionHintToActiveScreenIfNeeded() {
        guard hintWindowIsVisible, !isDraggingHint else { return }
        guard let target = NSScreen.mouse else { return }

        /// NSScreen object identity isn't stable across display-config changes,
        /// so compare frames rather than the screen references themselves.
        guard currentScreen?.frame != target.frame else { return }

        currentScreen = target
        positionHintWindow(on: target)

        repositionMoreMenuIfNeeded()
        repositionTranscriptionOverlayIfNeeded()
    }

    private func positionHintWindow(on screen: NSScreen?) {
        guard let screen = screen ?? hintWindow.screen ?? NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let fittingSize = hintWindow.contentView?.fittingSize ?? hintWindow.frame.size

        let originX = visibleFrame.maxX - fittingSize.width

        /// Restore the last drag position if available, otherwise vertically center.
        /// The saved Y is a global AppKit coordinate captured on whichever screen
        /// the hint was last dragged on. If it doesn't fall within *this* screen's
        /// visible range (e.g. the hint just jumped to another display), honoring it
        /// would clamp the window to a top/bottom edge - a "weird" position. In that
        /// case fall back to vertically centering on the target screen.
        let centeredY = visibleFrame.minY + (visibleFrame.height / 2) - (fittingSize.height / 2)
        let savedY = Defaults[.hintYPositionForPinnedMode]
        let savedYIsOnThisScreen =
            savedY.map { $0 >= visibleFrame.minY && $0 <= visibleFrame.maxY - fittingSize.height } ?? false
        let originY = clampHintY(
            savedYIsOnThisScreen ? savedY! : centeredY,
            fittingSize: fittingSize,
            visibleFrame: visibleFrame
        )

        hintWindow.setFrame(
            NSRect(x: originX, y: originY, width: fittingSize.width, height: fittingSize.height),
            display: true
        )

        lastYComputed = originY
    }

    private func clampHintY(_ y: CGFloat, fittingSize: CGSize, visibleFrame: CGRect) -> CGFloat {
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - fittingSize.height
        return max(minY, min(y, maxY))
    }

    // MARK: - Functions: Vertical Drag

    /// Follows the cursor vertically while dragging the hint. Uses the absolute mouse position
    /// (anchored at drag start) so the window tracks the cursor 1:1, regardless of SwiftUI
    /// re-renders or intermediate size changes.
    func handleHintDragChanged() {
        /// First event of this drag: capture anchors and suspend auto re-positioning.
        guard hintDragStartWindowY != nil else {
            isDraggingHint = true
            hintDragStartMouseY = NSEvent.mouseLocation.y
            hintDragStartWindowY = hintWindow.frame.origin.y
            return
        }

        guard let startMouseY = hintDragStartMouseY,
              let startWindowY = hintDragStartWindowY,
              let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main
        else { return }

        /// AppKit y and mouse y both grow upward, so the window follows the cursor 1:1.
        let deltaY = NSEvent.mouseLocation.y - startMouseY
        var frame = hintWindow.frame
        let newY = clampHintY(startWindowY + deltaY, fittingSize: frame.size, visibleFrame: screen.visibleFrame)

        frame.origin.y = newY
        hintWindow.setFrame(frame, display: true)

        lastYComputed = newY
        Defaults[.hintYPositionForPinnedMode] = newY

        repositionMoreMenuIfNeeded()
        repositionTranscriptionOverlayIfNeeded()
    }

    func endHintDrag() {
        isDraggingHint = false
        hintDragStartMouseY = nil
        hintDragStartWindowY = nil
    }
}
