// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityNotificationsManager.swift
//  Onit
//
//  Created by Kévin Naudin on 22/01/2025.
//

import ApplicationServices
import Defaults
import Foundation
import PostHog
import SwiftUI

@MainActor
class AccessibilityNotificationsManager: ObservableObject {

    // MARK: - Singleton instance

    static let shared = AccessibilityNotificationsManager()
    
    // MARK: - Properties
    
    let windowsManager = AccessibilityWindowsManager()

    private var currentSource: String?

    private var parseDebounceWorkItem: DispatchWorkItem?

    // MARK: - Private initializer

    private init() { }
    
    // MARK: - Delegates
    
    private var delegates = NSHashTable<AnyObject>.weakObjects()
    
    func addDelegate(_ delegate: AccessibilityNotificationsDelegate) {
        delegates.add(delegate)
    }
    
    func removeDelegate(_ delegate: AccessibilityNotificationsDelegate) {
        delegates.remove(delegate)
    }
    
    private func notifyDelegates(_ notification: (AccessibilityNotificationsDelegate) -> Void) {
        for case let delegate as AccessibilityNotificationsDelegate in delegates.allObjects {
            notification(delegate)
        }
    }

    // MARK: - Functions
    
    func hasAnyDelegateWantingIgnoredProcesses() -> Bool {
        for case let delegate as AccessibilityNotificationsDelegate in delegates.allObjects {
            if delegate.wantsNotificationsFromIgnoredProcesses {
                return true
            }
        }
        return false
    }
    
    func reset() {
        windowsManager.reset()

        currentSource = nil
        parseDebounceWorkItem?.cancel()
        
        ContextFetchingService.shared.reset()
    }

    // MARK: Handling app activated/deactived

    private func handleAppActivation(appName: String?, processID: pid_t) {
        print("Application activated: \(appName ?? "Unknown") \(processID)")

        currentSource = appName
        ContextFetchingService.shared.setLastActive(windowPid: processID)
        
        if let mainWindow = processID.firstMainWindow {
            handleWindowBounds(for: mainWindow, elementPid: processID)
            
            // When we activate a new application, we dont get a focusedUIElementChanged notification, because it hasn't "changed"
            // Instead, we need to scan the hierarchy for the focused elements and then handle it, if found!
            // Note - focusedElements is plural here, because some applications will have many.
            // On my (Tim's) computer Notes gives 21 focusedElements. 20 of the are "AXCell" and one is the "AXTextArea" that we care about.
        }
    }
    
    private func handleIgnoredAppActivate(appName: String?, processID: pid_t) {
        if let mainWindow = processID.firstMainWindow {
            guard let trackedWindow = self.windowsManager.trackWindowForElement(mainWindow, pid: processID) else { return }
            notifyDelegates { delegate in
                delegate.accessibilityManager(self, didActivateIgnoredWindow: trackedWindow)
            }
        }
    }
    
    
    private func handleAppDeactivation(appName: String?, processID: pid_t) {
        print("Application deactivated: \(appName ?? "Unknown") \(processID)")

        // Notify delegates about application deactivation
        notifyDelegates { delegate in
            delegate.accessibilityManager(self, didDeactivateApplication: appName, processID: processID)
        }
    }

    func handleAccessibilityNotifications(
        _ notification: String, info: [String: Any], element: AXUIElement, elementPid: pid_t
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        
        // log.debug("Received notification: \(notification) \(element.role() ?? "")")
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            self.handleWindowBounds(for: element, elementPid: elementPid)
        case kAXWindowCreatedNotification:
            self.handleCreatedWindowElement(for: element, elementPid: elementPid)
        case kAXUIElementDestroyedNotification:
            self.handleDetroyedElement(for: element)
        case kAXTitleChangedNotification:
            self.handleTitleChanged(for: element, elementPid: elementPid)
        default:
            break
        }
    }
    
    private func handleTitleChanged(for element: AXUIElement, elementPid: pid_t) {
        guard let trackedWindow = self.windowsManager.trackWindowForElement(element, pid: elementPid) else { return }
        
        notifyDelegates { $0.accessibilityManager(self, didChangeWindowTitle: trackedWindow) }
    }
    
    private func handleWindowBounds(for element: AXUIElement, elementPid: pid_t) {
        guard let trackedWindow = self.windowsManager.trackWindowForElement(element, pid: elementPid) else { return }
        
        notifyDelegates { $0.accessibilityManager(self, didActivateWindow: trackedWindow) }
    }
    
    private func handleCreatedWindowElement(for element: AXUIElement, elementPid: pid_t) {
        guard let trackedWindow = self.windowsManager.trackWindowForElement(element, pid: elementPid) else { return }
        if element.isTargetWindow() {
            self.notifyDelegates { $0.accessibilityManager(self, didActivateWindow: trackedWindow) }
        }
    }
    
    private func handleDetroyedElement(for element: AXUIElement) {
        let foundWindows = self.windowsManager.trackedWindows(for: element)
        
        for foundWindow in foundWindows {
            if foundWindow.element.role() == nil {
                guard let trackedWindow = self.windowsManager.remove(foundWindow) else { return }
                
                notifyDelegates { $0.accessibilityManager(self, didDestroyWindow: trackedWindow) }
            }
        }
    }
}

// MARK: - AccessibilityObserversDelegate

extension AccessibilityNotificationsManager: AccessibilityObserversDelegate {

    func accessibilityObserversManager(didActivateApplication appName: String?, processID: pid_t) {
        handleAppActivation(appName: appName, processID: processID)
    }
    
    func accessibilityObserversManager(didReceiveNotification notification: String, element: AXUIElement, elementPid: pid_t, info: [String: Any]) {
        handleAccessibilityNotifications(notification, info: info, element: element, elementPid: elementPid)
    }
    
    func accessibilityObserversManager(didDeactivateApplication appName: String?, processID: pid_t) {
        handleAppDeactivation(appName: appName, processID: processID)
    }
    
    func accessibilityObserversManager(didActivateIgnoredApplication appName: String?, processID: pid_t) {
        handleIgnoredAppActivate(appName: appName, processID: processID)
    }

    func accessibilityObserversManager(didDeactivateIgnoredApplication appName: String?, processID: pid_t) { }

    func accessibilityObserversManager(didActivateOnit processID: pid_t) { }
    
    func accessibilityObserversManager(didDeactivateOnit processID: pid_t) { }
}
