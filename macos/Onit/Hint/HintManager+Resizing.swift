// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+Resizing.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Functions: Hint Resizing
 * Functions: Transcription Overlay Resizing
 */

import AppKit

extension HintManager {
    // MARK: - Public Functions: Hint Resizing
    
    func updateHintSize() {
        if let fittingSize = hintWindow.contentView?.fittingSize {
            currentHintSize = fittingSize
        }
    }
    
    // MARK: - Functions: Transcription Overlay Resizing

    func updateTranscriptionOverlaySize() {
        /// Defer to next run loop to ensure SwiftUI has finished updating the view layout.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            /// If user has manually positioned the overlay or it's caret-anchored, update size while keeping its position (clamped to screen).
            if self.userHasManuallyPositionedOverlay || self.isCaretAnchoredOverlay {
                self.updateTranscriptionOverlaySizePreservingPosition()
            } else {
                self.repositionTranscriptionOverlayIfNeeded()
            }
        }
    }

    private func updateTranscriptionOverlaySizePreservingPosition() {
        // Force-correction mode: re-anchor to mouse so the button stays under the cursor
        // even as the overlay grows/shrinks (e.g. edit mode expanding the text field).
        if forceCorrectionUIMouseAnchor != nil && !userHasManuallyPositionedOverlay {
            repositionTranscriptionOverlayAtMouseAnchor()
            return
        }

        guard let overlayWindow = transcriptionOverlayWindow,
              let overlayHostingController = transcriptionOverlayHostingController
        else {
            return
        }

        /// Force layout update.
        overlayHostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = overlayHostingController.view.fittingSize

        /// Get current frame and update size while keeping position.
        var frame = overlayWindow.frame
        frame.size = fittingSize

        /// Ensure the resized overlay stays on screen.
        if let screen = overlayWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame

            if frame.origin.x + fittingSize.width > screenFrame.maxX {
                frame.origin.x = screenFrame.maxX - fittingSize.width
            }
            if frame.origin.x < screenFrame.minX {
                frame.origin.x = screenFrame.minX
            }
            if frame.origin.y < screenFrame.minY {
                frame.origin.y = screenFrame.minY
            }
            if frame.origin.y + fittingSize.height > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - fittingSize.height
            }
        }

        overlayWindow.setFrame(frame, display: true)
    }
}
