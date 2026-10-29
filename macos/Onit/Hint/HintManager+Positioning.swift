// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Positioning.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Functions: Reset Positions
 * Public Functions: Hint Reposition
 * Public Functions: More Menu Resposition
 * Public Functions: Transcription Overlay Reposition
 * Public Functions: Transcription Overlay Caret-Relative Reposition
 * Private Functions: Caret-Relative Helpers
 */

import AppKit
import Defaults

extension HintManager {
    // MARK: - Public Functions: Reset Positions

    func resetPositions() {
        Defaults[.hintYPositionByApp].removeAll()
        Defaults[.hintYPositionForPinnedMode] = nil
        Defaults[.hintYPositionForUntetheredModeScreens].removeAll()
        lastYComputed = nil
    }

    // MARK: - Public Functions: Hint Reposition

    /// Reposition window to stay anchored to the right edge of the screen when content size changes.
    func repositionHintToRightEdge() {
        guard let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main
        else {
            return
        }

        let anchorX: CGFloat = screen.visibleFrame.maxX

        var hintWindowFrame = hintWindow.frame
        
        /// Setting x-position anchor to right edge.
        hintWindowFrame.origin.x = anchorX - hintWindowFrame.width

        /// Ensure we don't go off the left edge of the screen.  Allows hint positioning to be multi-monitor aware, preventing bleeding across monitors.
        let screenMinX = screen.visibleFrame.minX
        if hintWindowFrame.origin.x < screenMinX {
            hintWindowFrame.origin.x = screenMinX
        }

        hintWindow.setFrame(hintWindowFrame, display: true)
        
        repositionMoreMenuIfNeeded()
        repositionTranscriptionOverlayIfNeeded()
    }
    
    // MARK: - Public Functions: More Menu Reposition

    func repositionMoreMenuIfNeeded(
        shouldAnimateIn: Bool = false,
        isInitialShow: Bool = false
    ) {
        guard isInitialShow || moreMenuWindowIsVisible else { return }
        guard let moreMenuWindow = self.moreMenuWindow else { return }

        /// Force layout update before measuring to ensure accurate Hint window dimensions.
        hintWindow.contentView?.layoutSubtreeIfNeeded()

        let hintWindowFrame: CGRect
        
        /// Get Hint window dimensions directly from the injected SwiftUI view.
        if let fittingSize = hintWindow.contentView?.fittingSize {
            let expectedMinX = hintWindow.frame.maxX - fittingSize.width
            hintWindowFrame = CGRect(
                x: expectedMinX,
                y: hintWindow.frame.origin.y,
                width: fittingSize.width,
                height: fittingSize.height
            )
        }
        /// Otherwise, fall back to getting the dimensions from the Hint window's built-in frame.
        else {
            hintWindowFrame = hintWindow.frame
        }
        
        let moreMenuWindowWidth: CGFloat
        let moreMenuWindowHeight: CGFloat
        
        /// Force layout update before measuring to ensure accurate More Menu dimensions.
        moreMenuWindow.contentView?.layoutSubtreeIfNeeded()

        /// Get more menu window dimensions from injected SwiftUI view.
        if let fittingSize = moreMenuWindow.contentView?.fittingSize {
            moreMenuWindowWidth = fittingSize.width
            moreMenuWindowHeight = fittingSize.height
        }
        /// Otherwise, fall back to getting current more menu window's dimensions.
        else {
            moreMenuWindowWidth = moreMenuWindow.frame.width
            moreMenuWindowHeight = moreMenuWindow.frame.height
        }

        /// Position menu 8px to the left of the hint window.
        var finalX = hintWindowFrame.minX - moreMenuWindowWidth - Hint.contentSpacing

        /// Ensure menu doesn't go off-screen to the left.
        if let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main {
            let minX = screen.visibleFrame.minX
            if finalX < minX {
                finalX = minX
            }
        }

        /// Keep vertical center aligned with Hint, clamping to screen bounds by anchoring to Hint edges.
        var finalY = hintWindowFrame.midY - moreMenuWindowHeight / 2

        if let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main {
            let screenMinY = screen.visibleFrame.minY
            let screenMaxY = screen.visibleFrame.maxY

            /// Align the More Menu's bottom edge with the Hint's bottom edge if there is no room below the screen.
            if finalY < screenMinY {
                finalY = hintWindowFrame.minY
            }
            
            /// Align the More Menu's top edge with the Hint's top edge if there is no room above the screen.
            if finalY + moreMenuWindowHeight > screenMaxY {
                finalY = hintWindowFrame.maxY - moreMenuWindowHeight
            }
        }

        if shouldAnimateIn {
            showMoreMenuAnimatedIn(
                moreMenuWindow: moreMenuWindow,
                finalX: finalX,
                finalY: finalY,
                moreMenuWindowWidth: moreMenuWindowWidth,
                moreMenuWindowHeight: moreMenuWindowHeight,
                isInitialShow: isInitialShow
            )
        } else {
            showMoreMenuImmediately(
                moreMenuWindow: moreMenuWindow,
                finalX: finalX,
                finalY: finalY,
                moreMenuWindowWidth: moreMenuWindowWidth,
                moreMenuWindowHeight: moreMenuWindowHeight,
                isInitialShow: isInitialShow
            )
        }
    }
    
    private func showMoreMenuAnimatedIn(
        moreMenuWindow: NSWindow,
        finalX: CGFloat,
        finalY: CGFloat,
        moreMenuWindowWidth: CGFloat,
        moreMenuWindowHeight: CGFloat,
        isInitialShow: Bool
    ) {
        /// Start animation at 8px to the right of the final position for the animate-in.
        let startX = finalX + Hint.contentSpacing
        
        /// Start frame.
        moreMenuWindow.setFrame(
            NSRect(
                x: startX,
                y: finalY,
                width: moreMenuWindowWidth,
                height: moreMenuWindowHeight
            ),
            display: true
        )
        moreMenuWindow.alphaValue = 0
        
        if isInitialShow {
            moreMenuWindow.orderFront(nil)
        }

        /// Animate more menu to slide in.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            /// Final frame.
            moreMenuWindow.animator().setFrame(
                NSRect(
                    x: finalX,
                    y: finalY,
                    width: moreMenuWindowWidth,
                    height: moreMenuWindowHeight
                ),
                display: true
            )
            moreMenuWindow.animator().alphaValue = 1
        }
    }
    
    private func showMoreMenuImmediately(
        moreMenuWindow: NSWindow,
        finalX: CGFloat,
        finalY: CGFloat,
        moreMenuWindowWidth: CGFloat,
        moreMenuWindowHeight: CGFloat,
        isInitialShow: Bool
    ) {
        moreMenuWindow.setFrame(
            NSRect(
                x: finalX,
                y: finalY,
                width: moreMenuWindowWidth,
                height: moreMenuWindowHeight
            ),
            display: true
        )
        
        if isInitialShow {
            moreMenuWindow.orderFront(nil)
        }
    }
    
    // MARK: - Public Functions: Transcription Overlay Reposition
    
    /// Reposition the transcription overlay when the hint moves
    func repositionTranscriptionOverlayIfNeeded(
        isInitialShow: Bool = false
    ) {
        /// Skip auto-repositioning if user has manually positioned the overlay.
        guard !userHasManuallyPositionedOverlay else { return }

        /// Skip hint-relative repositioning if overlay is caret-anchored.
        /// The overlay should stay near the caret, not follow the hint.
        guard !isCaretAnchoredOverlay else { return }

        guard isInitialShow || transcriptionOverlayWindowIsVisible,
              let overlayWindow = transcriptionOverlayWindow,
              let overlayHostingController = transcriptionOverlayHostingController
        else {
            return
        }

        /// Force layout update and get fitting size.
        overlayHostingController.view.layoutSubtreeIfNeeded()
        
        /// Force layout update before measuring to ensure accurate Hint window dimensions.
        hintWindow.contentView?.layoutSubtreeIfNeeded()
        
        let hintWindowFrame: CGRect
        
        /// Get Hint window dimensions directly from the injected SwiftUI view.
        if let fittingSize = hintWindow.contentView?.fittingSize {
            let expectedMinX = hintWindow.frame.maxX - fittingSize.width
            hintWindowFrame = CGRect(
                x: expectedMinX,
                y: hintWindow.frame.origin.y,
                width: fittingSize.width,
                height: fittingSize.height
            )
        }
        /// Otherwise, fall back to getting the dimensions from the Hint window's built-in frame.
        else {
            hintWindowFrame = hintWindow.frame
        }

        let fittingSize = overlayHostingController.view.fittingSize
        let overlayWindowWidth: CGFloat = fittingSize.width
        let overlayWindowHeight: CGFloat = fittingSize.height

        /// Position overlay 8px to the left of the hint window.
        var finalX = hintWindowFrame.minX - overlayWindowWidth - Hint.contentSpacing

        /// Ensure overlay doesn't go off-screen to the left.
        if let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main {
            let minX = screen.visibleFrame.minX
            if finalX < minX {
                /// Reposition to the right of the hint.
                finalX = hintWindowFrame.maxX + Hint.contentSpacing
                let maxX = screen.visibleFrame.maxX
                if finalX + overlayWindowWidth > maxX {
                    finalX = maxX - overlayWindowWidth
                }
            }
        }

        /// Keep vertical center aligned with Hint, clamping to screen bounds by anchoring to Hint edges.
        var finalY = hintWindowFrame.midY - overlayWindowHeight / 2

        if let screen = currentScreen ?? hintWindow.screen ?? NSScreen.main {
            let screenMinY = screen.visibleFrame.minY
            let screenMaxY = screen.visibleFrame.maxY

            /// Align the Transcription Overlay's bottom edge with the Hint's bottom edge if there is no room below the screen.
            if finalY < screenMinY {
                finalY = hintWindowFrame.minY
            }
            
            /// Align the Transcription Overlay's top edge with the Hint's top edge if there is no room above the screen.
            if finalY + overlayWindowHeight > screenMaxY {
                finalY = hintWindowFrame.maxY - overlayWindowHeight
            }
        }

        isProgrammaticallyPositioningOverlay = true

        showTranscriptionOverlayImmediately(
            overlayWindow: overlayWindow,
            finalX: finalX,
            finalY: finalY,
            overlayWindowWidth: overlayWindowWidth,
            overlayWindowHeight: overlayWindowHeight,
            isInitialShow: isInitialShow
        )

        isProgrammaticallyPositioningOverlay = false
    }

    private func showTranscriptionOverlayImmediately(
        overlayWindow: ToggleableKeyPanel,
        finalX: CGFloat,
        finalY: CGFloat,
        overlayWindowWidth: CGFloat,
        overlayWindowHeight: CGFloat,
        isInitialShow: Bool
    ) {
        overlayWindow.setFrame(
            NSRect(
                x: finalX,
                y: finalY,
                width: overlayWindowWidth,
                height: overlayWindowHeight
            ),
            display: true
        )
        
        if isInitialShow {
            overlayWindow.orderFront(nil)
        }
    }

    // MARK: - Public Functions: Transcription Overlay Pasted-Text-Relative Reposition

    /// Position the transcription overlay above the detected pasted text region.
    func repositionTranscriptionOverlayNearPastedText(
        pastedTextDetectionResult: TranscriptionManager.PastedTextDetectionResult,
        isInitialShow: Bool
    ) {
        guard !userHasManuallyPositionedOverlay else { return }

        guard let overlayWindow = transcriptionOverlayWindow,
              let overlayHostingController = transcriptionOverlayHostingController
        else {
            return
        }

        overlayHostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = overlayHostingController.view.fittingSize

        let pastedTextBounds = pastedTextDetectionResult.boundingBox

        /// Position above the pasted text.
        let fallbackPosition = calculateSimplePastedTextRelativePosition(
            pastedTextBounds: pastedTextBounds,
            overlaySize: fittingSize
        )

        Task { @MainActor in
            let finalPosition = fallbackPosition

            /// Verify overlay is still valid after async work.
            guard isInitialShow || transcriptionOverlayWindowIsVisible,
                  !userHasManuallyPositionedOverlay,
                  isCaretAnchoredOverlay
            else {
                return
            }

            isProgrammaticallyPositioningOverlay = true

            showTranscriptionOverlayImmediately(
                overlayWindow: overlayWindow,
                finalX: finalPosition.origin.x,
                finalY: finalPosition.origin.y,
                overlayWindowWidth: fittingSize.width,
                overlayWindowHeight: fittingSize.height,
                isInitialShow: isInitialShow
            )

            isProgrammaticallyPositioningOverlay = false
        }
    }

    // MARK: - Functions: Mouse-Anchored Positioning (Force Correction UI)

    /// Position the overlay so the primary footer button sits exactly under the stored mouse anchor.
    ///
    /// Layout constants (from TranscriptionCorrectionView):
    ///   - Outer VStack vertical padding: 8pt  → button bottom is 8pt above window bottom
    ///   - Footer button height: 28pt           → button center is 8 + 14 = 22pt above window bottom
    ///   - Footer HStack horizontal padding: 10pt → primary button left edge is 10pt right of window left
    func repositionTranscriptionOverlayAtMouseAnchor(isInitialShow: Bool = false) {
        guard let mouse = forceCorrectionUIMouseAnchor,
              !userHasManuallyPositionedOverlay,
              let overlayWindow = transcriptionOverlayWindow,
              let overlayHostingController = transcriptionOverlayHostingController
        else { return }

        overlayHostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = overlayHostingController.view.fittingSize

        // Align the primary button's left edge with the mouse X, and its center with the mouse Y.
        let buttonLeftPadding: CGFloat = 10   // HStack left padding
        let buttonCenterFromBottom: CGFloat = 22  // 8pt outer + 14pt half-button

        var finalX = mouse.x - buttonLeftPadding
        var finalY = mouse.y - buttonCenterFromBottom

        // Clamp to the screen containing the mouse.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let screen = screen {
            let visible = screen.visibleFrame
            finalX = max(visible.minX, min(finalX, visible.maxX - fittingSize.width))
            finalY = max(visible.minY, min(finalY, visible.maxY - fittingSize.height))
        }

        isProgrammaticallyPositioningOverlay = true
        showTranscriptionOverlayImmediately(
            overlayWindow: overlayWindow,
            finalX: finalX,
            finalY: finalY,
            overlayWindowWidth: fittingSize.width,
            overlayWindowHeight: fittingSize.height,
            isInitialShow: isInitialShow
        )
        isProgrammaticallyPositioningOverlay = false
    }

    // MARK: - Private Functions: Pasted-Text-Relative Helpers

    /// Position the overlay either above the mouse cursor or above the pasted text bounds,
    /// depending on the `transcriptionOverlayPositioningMode` setting.
    private func calculateSimplePastedTextRelativePosition(
        pastedTextBounds: CGRect,
        overlaySize: CGSize
    ) -> CGRect {
        switch Defaults[.transcriptionOverlayPositioningMode] {
        case .mouse:
            return calculateMouseRelativePosition(overlaySize: overlaySize)
        case .screenRecording, .ax, .hint:
            // .hint should never reach this function (upstream produces a nil
            // detection result for .hint so we route through the Hint-anchored
            // path instead). Bucket it with the bounds-relative branch as defensive
            // fallback in case the call slips through.
            return calculatePastedTextRelativePosition(pastedTextBounds: pastedTextBounds, overlaySize: overlaySize)
        }
    }

    /// Place the overlay centered on the mouse cursor, just above it.
    private func calculateMouseRelativePosition(overlaySize: CGSize) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main

        guard let screen = screen else {
            return CGRect(origin: .zero, size: overlaySize)
        }

        let visibleFrame = screen.visibleFrame
        let padding: CGFloat = 12

        var x = mouse.x - overlaySize.width / 2
        var y = mouse.y + padding

        if y + overlaySize.height > visibleFrame.maxY {
            y = mouse.y - overlaySize.height - padding
        }

        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - overlaySize.width))
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - overlaySize.height))

        return CGRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
    }

    /// Place the overlay just above the pasted text bounding box, horizontally closest to the mouse.
    private func calculatePastedTextRelativePosition(pastedTextBounds: CGRect, overlaySize: CGSize) -> CGRect {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: pastedTextBounds.midX, y: pastedTextBounds.midY))
        }) ?? NSScreen.main

        guard let screen = screen else {
            return CGRect(origin: .zero, size: overlaySize)
        }

        let visibleFrame = screen.visibleFrame
        let padding: CGFloat = 8

        // Horizontal: center on mouse, clamped so the overlay stays within the text bounds,
        // then clamped to screen. This puts the overlay closest to the mouse cursor.
        let mouseX = NSEvent.mouseLocation.x
        let idealX = mouseX - overlaySize.width / 2
        let clampedToText = max(pastedTextBounds.minX, min(idealX, pastedTextBounds.maxX - overlaySize.width))
        var x = clampedToText
        var y = pastedTextBounds.maxY + padding

        if y + overlaySize.height > visibleFrame.maxY {
            y = pastedTextBounds.minY - overlaySize.height - padding
        }

        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - overlaySize.width))
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - overlaySize.height))

        return CGRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
    }
}
