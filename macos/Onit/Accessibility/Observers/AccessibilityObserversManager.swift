// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityObserversManager.swift
//  Onit
//
//  Created by Kévin Naudin on 08/05/2025.
//

import ApplicationServices
import Foundation
import SwiftUI

enum ProcessObservationEligibility {
    case eligible
    case ignoreProcess
    case ownProcess
}

@MainActor
class AccessibilityObserversManager {
    
    // MARK: - Singleton
    
    static let shared = AccessibilityObserversManager()

    // Static method to get the current ignored app names (for consistency across managers)
    static var currentIgnoredAppNames: [String] {
    #if DEBUG
        return ["Xcode"]
    #else
        return []
    #endif
    }
    
    
    // MARK: - Properties
    
    // Replace single delegate with multi-delegate pattern
    private var delegates = NSHashTable<AnyObject>.weakObjects()
    
    private lazy var ignoredAppNames: [String] = Self.currentIgnoredAppNames
    
    private var observers: [pid_t: AXObserver] = [:]

    /// Pids for which we've already emitted `serverInitializationError`.
    /// Used to debounce the analytics emission so it fires at most once per
    /// transition into the "not fully initialized" state, rather than on every
    /// app activation (which otherwise produces a high-volume telemetry loop).
    /// A pid is cleared once its AX server is observed initialized, so a later
    /// regression is reported again.
    private var reportedUninitializedPids: Set<pid_t> = []

    private var isStarted = false
    
    // MARK: - Private initializer
    
    private init() { }
    
    // MARK: - Delegate Management
    
    func addDelegate(_ delegate: AccessibilityObserversDelegate) {
        delegates.add(delegate)
    }
    
    func removeDelegate(_ delegate: AccessibilityObserversDelegate) {
        delegates.remove(delegate)
    }
    
    private func notifyDelegates(_ notification: (AccessibilityObserversDelegate) -> Void) {
        for case let delegate as AccessibilityObserversDelegate in delegates.allObjects {
            notification(delegate)
        }
    }
    
    private func checkIfAnyDelegateWantsIgnoredProcesses() -> Bool {
        for delegate in delegates.allObjects {
            if let notificationsManager = delegate as? AccessibilityNotificationsManager {
                if notificationsManager.hasAnyDelegateWantingIgnoredProcesses() {
                    return true
                }
            }
        }
        return false
    }
    
    // MARK: - Functions
    
    func start() {
        guard !isStarted else { return }
        
        isStarted = true
        
        startAppActivationObservers()
    }
    
    func stop() {
        isStarted = false
        
        stopAppActivationObservers()
        
        for pid in observers.keys {
            stopNotificationsObserver(for: pid)
        }
    }
    
    /**
     * Called once at app launch if accessibility permission is granted.
     * Needed to start monitoring the foreground app manually since
     * app activation notifications aren't delivered at launch.
     */
    func startAccessibilityObserversOnFirstLaunch(with pid: pid_t) {
        let appName = pid.appName ?? "Unknown"
        log.info("Observers automatically started for `\(appName)` (\(pid))")
        
        let authState = authorizationState(for: pid)
        let hasAnyDelegateWantingIgnoredProcesses = checkIfAnyDelegateWantsIgnoredProcesses()

        switch authState {
        case .ignoreProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didActivateIgnoredApplication: pid.appName, processID: pid)
            }
            if hasAnyDelegateWantingIgnoredProcesses {
                // Start full notification set for delegates that want all processes
                startNotificationsObserver(for: pid, notifications: Config.notifications)
            }
        case .eligible:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didActivateApplication: pid.appName, processID: pid)
            }
            startNotificationsObserver(for: pid, notifications: Config.notifications)
        case .ownProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didActivateOnit: pid)
            }
        }
    }
    
    private func startAppActivationObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivationReceived),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDeactivationReceived),
            name: NSWorkspace.didDeactivateApplicationNotification,
            object: nil)
    }
    
    private func stopAppActivationObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    @objc private func appActivationReceived(notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            log.error("Cannot subscribe to notifications - no NSRunningApplication found")
            return
        }
        
        let appName = app.processIdentifier.appName
        let authState = authorizationState(for: app.processIdentifier)
        let hasAnyDelegateWantingIgnoredProcesses = checkIfAnyDelegateWantsIgnoredProcesses()

        switch authState {
        case .ownProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didActivateOnit: app.processIdentifier)
            }
        case .ignoreProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didActivateIgnoredApplication: app.localizedName, processID: app.processIdentifier)
            }
            if hasAnyDelegateWantingIgnoredProcesses {
                startNotificationsObserver(for: app.processIdentifier, notifications: Config.notifications)
            }
        case .eligible:
            log.info("Application `\(app.localizedName ?? "Unknown")` (\(app.processIdentifier)) activated")
            if !isAXServerInitialized(pid: app.processIdentifier) {
                log.error("AXServer not fully initialized")
                // Emit analytics at most once per transition into the uninitialized
                // state. App activation can fire repeatedly for an app whose AX server
                // never initializes; emitting each time floods telemetry.
                if reportedUninitializedPids.insert(app.processIdentifier).inserted {
                    AnalyticsManager.Accessibility.serverInitializationError(app: app)
                }
            } else {
                reportedUninitializedPids.remove(app.processIdentifier)
            }
            
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(
                    didActivateApplication: app.localizedName,
                    processID: app.processIdentifier
                )
            }
            
            startNotificationsObserver(for: app.processIdentifier, notifications: Config.notifications)
        }
    }
    
    @objc private func appDeactivationReceived(notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            log.error("Cannot unsubscribe to notifications - no NSRunningApplication found")
            return
        }
        
        // Check if Onit is activated so we don't deactivate the active app
        if let activeApp = NSWorkspace.shared.frontmostApplication,
           authorizationState(for: activeApp.processIdentifier) == .ownProcess {
            log.debug("Onit is active, ignoring deactivation of `\(app.localizedName ?? "Unknown")` (\(app.processIdentifier))")
            return
        }
        
        let hasAnyDelegateWantingIgnoredProcesses = checkIfAnyDelegateWantsIgnoredProcesses()
        switch authorizationState(for: app.processIdentifier) {
        case .ownProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didDeactivateOnit: app.processIdentifier)
            }
            break
        case .ignoreProcess:
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(didDeactivateIgnoredApplication: app.localizedName, processID: app.processIdentifier)
            }
            if hasAnyDelegateWantingIgnoredProcesses {
                stopNotificationsObserver(for: app.processIdentifier)
            }
        case .eligible:
            log.info("Application `\(app.localizedName ?? "Unknown")` (\(app.processIdentifier)) deactivated")
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(
                    didDeactivateApplication: app.localizedName,
                    processID: app.processIdentifier
                )
            }
            stopNotificationsObserver(for: app.processIdentifier)
        }
    }
    
    private func startNotificationsObserver(for pid: pid_t, notifications: [String]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.startNotificationsObserver(for: pid, notifications: notifications)
            }
            return
        }
        
        stopNotificationsObserver(for: pid)
        
        let appName = pid.appName ?? "Unknown"
        log.info("Registering observers for `\(appName)` (\(pid))")
        
        var observer: AXObserver?
        let observerCallback: AXObserverCallbackWithInfo = {
            observer, element, notification, userInfo, refcon in
            // Dispatch to main thread immediately
            // log.info("Notification received: \(notification)")
            DispatchQueue.main.async {
                let accessibilityInstance = Unmanaged<AccessibilityObserversManager>
                    .fromOpaque(refcon!)
                    .takeUnretainedValue()
                let userInfo: [String: Any] = (userInfo as? [String: Any]) ?? [:]
                
                accessibilityInstance.handleAccessibilityNotifications(
                    notification as String, element: element, info: userInfo)
            }
        }

        let result = AXObserverCreateWithInfoCallback(pid, observerCallback, &observer)

        if result == .success, let observer = observer {
            self.observers[pid] = observer
            
            let refCon = Unmanaged.passUnretained(self).toOpaque()

            for notification in notifications {
                AXObserverAddNotification(
                    observer,
                    pid.getAXUIElement(),
                    notification as CFString,
                    refCon
                )
            }
            
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            
            log.info("Observer registered for `\(appName)` (\(pid))")
        } else {
            log.error("Failed to register observer for `\(appName)` (\(pid))")
            AnalyticsManager.Accessibility.observerError(
                errorCode: result.rawValue,
                pid: pid
            )
        }
    }
    
    private func stopNotificationsObserver(for pid: pid_t) {
        guard let existingObserver = self.observers[pid] else { return }

        let runLoopSource = AXObserverGetRunLoopSource(existingObserver)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        for notification in Config.notifications {
            AXObserverRemoveNotification(
                existingObserver,
                pid.getAXUIElement(),
                notification as CFString
            )
        }

        observers.removeValue(forKey: pid)
        log.info("Stopped observing notifications for `\(pid.appName ?? "Unknown")` (\(pid))")
    }
    
    // MARK: - Notifications handling
    
    private func handleAccessibilityNotifications(
        _ notification: String, element: AXUIElement, info: [String: Any]
    ) {
        // log.info("Notification received: \(notification)")
        if let elementPid = element.pid() {
            notifyDelegates { delegate in
                delegate.accessibilityObserversManager(
                    didReceiveNotification: notification,
                    element: element,
                    elementPid: elementPid,
                    info: info
                )
            }
        }
    }
    
    private func authorizationState(for pid: pid_t) -> ProcessObservationEligibility {
        return Self.determineProcessObservationEligibility(for: pid, ignoredAppNames: ignoredAppNames)
    }

    /// Static method to determine process observation eligibility that can be used by other managers
    static func determineProcessObservationEligibility(for pid: pid_t, ignoredAppNames: [String]) -> ProcessObservationEligibility {
        let appName = pid.appName
        let onitName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        
        if pid == getpid() || appName == onitName {
            return .ownProcess
        } else if ignoredAppNames.contains(appName ?? "") {
            return .ignoreProcess
        }
        
        return .eligible
    }
    
    private func isAXServerInitialized(pid: pid_t) -> Bool {
        func isAppleApplication(for pid: pid_t) -> Bool {
            guard let bundleIdentifier = pid.bundleIdentifier else {
                return false
            }
            
            return bundleIdentifier.starts(with: "com.apple.")
        }
        
        func canReadFocusedUIElement(for pid: pid_t) -> Bool {
            let appElement = pid.getAXUIElement()
            
            var focusedElement: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            
            if result == .success {
                return true
            } else {
                return false
            }
        }
        
        guard !isAppleApplication(for: pid) else {
            return true
        }
        
        return canReadFocusedUIElement(for: pid)
    }
}
