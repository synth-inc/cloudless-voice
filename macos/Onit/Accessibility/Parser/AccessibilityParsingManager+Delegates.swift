// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityParsingManager+Delegates.swift
//  Onit
//
//  Created by Timothy Lenardo on 8/5/25.
//

import Foundation
import ApplicationServices

// MARK: - AccessibilityNotificationsDelegate

extension AccessibilityParsingManager {
    
    // MARK: - Cache Invalidation Methods
    
    func accessibilityManager(_ manager: AccessibilityNotificationsManager, didDestroyWindow window: TrackedWindow) {
        // Invalidate cache when a window is destroyed
        invalidateCache(for: window.element, reason: "Window destroyed")
    }
    
    func accessibilityManager(_ manager: AccessibilityNotificationsManager, didChangeWindowTitle window: TrackedWindow) {
        // Invalidate cache when window title changes
        invalidateCache(for: window.element, reason: "Window title changed")
    }
    
    func accessibilityManager(_ manager: AccessibilityNotificationsManager, didActivateIgnoredWindow window: TrackedWindow?) {
        // Invalidate cache when an ignored window is activated (app deactivated)
        if let window = window {
            invalidateCache(for: window.element, reason: "Ignored window activated")
        }
    }
    
    func accessibilityManager(_ manager: AccessibilityNotificationsManager, didDeactivateApplication appName: String?, processID: pid_t) {
        // Invalidate cache when an application is deactivated
        invalidateCache(for: processID, reason: "Application deactivated")
    }
    
    // MARK: - Unused Delegate Methods
    
    func accessibilityManager(_ manager: AccessibilityNotificationsManager, didActivateWindow window: TrackedWindow) {}
    
    // MARK: - Delegate Configuration
    
    var wantsNotificationsFromIgnoredProcesses: Bool {
        return false // Xcode value changed notifications will be too crazy. 
    }
}