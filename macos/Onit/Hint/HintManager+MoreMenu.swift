// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager+MoreMenu.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Functions
 * Private Functions
 */

import SwiftUI

extension HintManager {
    // MARK: - Public Functions
    
    /// - Parameter isDictationCard: the paywall / success card. While one is presented, other
    ///   callers (hover tooltips, alerts, the Hint's own menu) must not replace or hide it:
    ///   a blocked dictation's upgrade prompt and its Copy button are never silently lost.
    func showMoreMenu<SwiftUIView: View>(swiftUIView: SwiftUIView, isDictationCard: Bool = false) {
        guard hintWindowIsVisible else { return }

        /// Don't show more menu when transcription overlay is visible (overlay takes priority).
        guard !transcriptionOverlayWindowIsVisible else {
            return
        }

        if dictationCardIsPresented && !isDictationCard {
            return
        }
        if isDictationCard && activePopUpType?.outranksDictationCard == true {
            return
        }
        /// Assign only on change: the property is published and every tooltip passes here.
        if dictationCardIsPresented != isDictationCard { dictationCardIsPresented = isDictationCard }

        createMoreMenuWindowIfNeeded()

        guard let moreMenuWindow = self.moreMenuWindow else { return }

        /// Inject the SwiftUI view first so that we can measure the size.
        let hostingView = OnitHostingView(rootView: swiftUIView)
        moreMenuWindow.contentView = hostingView
        
        /// Initial positioning.
        repositionMoreMenuIfNeeded(
            shouldAnimateIn: true,
            isInitialShow: true
        )
    }

    /// - Parameter force: also hides a presented dictation card (its own dismiss, the Hint
    ///   going away, the transcription overlay taking over). Pending paywall state is kept by
    ///   the caller so the card can be re-presented.
    func hideMoreMenu(force: Bool = false) {
        if dictationCardIsPresented && !force { return }
        if dictationCardIsPresented { dictationCardIsPresented = false }
        moreMenuWindow?.orderOut(nil)
        moreMenuWindow?.contentView = nil
    }
    
    // MARK: - Private Functions
    
    private func createMoreMenuWindowIfNeeded() {
        if moreMenuWindow == nil {
            class CustomPanel: NSPanel {
                override var canBecomeKey: Bool { false }
                override var canBecomeMain: Bool { false }
            }
            
            let window = CustomPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = NSColor.clear
            window.level = .floating
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            
            moreMenuWindow = window
        }
    }
}
