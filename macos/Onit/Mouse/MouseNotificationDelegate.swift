// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MouseNotificationDelegate.swift
//  Onit
//
//  Created by Timothy Lenardo on 7/25/25.
//

import Foundation
import AppKit

enum ScrollPhase {
    case none
    case began
    case changed
    case ended
    case cancelled
    case mayBegin
}

enum MomentumPhase {
    case none
    case began
    case changed
    case ended
}

@MainActor protocol MouseNotificationDelegate: AnyObject {
    // Mouse events
    func mouseNotificationManager(_ manager: MouseNotificationManager, didMove event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveSingleClick event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveDoubleClick event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveTripleClick event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didStartDrag event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didUpdateDrag event: NSEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didEndDrag event: NSEvent)
    
    // Scroll events
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScrollVertically deltaY: Double, deltaX: Double, event: CGEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScrollHorizontally deltaX: Double, deltaY: Double, event: CGEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScroll deltaX: Double, deltaY: Double, event: CGEvent)
    
    // Optional scroll phase methods
    func mouseNotificationManager(_ manager: MouseNotificationManager, didChangeScrollPhase phase: ScrollPhase, event: CGEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didChangeMomentumPhase phase: MomentumPhase, event: CGEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didBeginInertiaScroll event: CGEvent)
    func mouseNotificationManager(_ manager: MouseNotificationManager, didEndInertiaScroll event: CGEvent)
}

extension MouseNotificationDelegate {
    func mouseNotificationManager(_ manager: MouseNotificationManager, didMove event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveSingleClick event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveDoubleClick event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didReceiveTripleClick event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didStartDrag event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didUpdateDrag event: NSEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didEndDrag event: NSEvent) {}
    
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScrollVertically deltaY: Double, deltaX: Double, event: CGEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScrollHorizontally deltaX: Double, deltaY: Double, event: CGEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didScroll deltaX: Double, deltaY: Double, event: CGEvent) {}
    
    func mouseNotificationManager(_ manager: MouseNotificationManager, didChangeScrollPhase phase: ScrollPhase, event: CGEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didChangeMomentumPhase phase: MomentumPhase, event: CGEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didBeginInertiaScroll event: CGEvent) {}
    func mouseNotificationManager(_ manager: MouseNotificationManager, didEndInertiaScroll event: CGEvent) {}
}

