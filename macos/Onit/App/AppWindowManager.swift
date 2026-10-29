// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppWindowManager.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import AppKit
import Defaults

@MainActor
final class AppWindowManager: NSObject, NSWindowDelegate, ObservableObject {
    // MARK: - Singleton

    static let shared = AppWindowManager()

    // MARK: - Published Variables

    @Published private(set) var currentPage: AppPages = .home
    @Published var showSettingsSheet: Bool = false

    // MARK: - Private Variables

    private var window: AppWindow? = nil

    // MARK: - Public Functions

    func setPage(page: AppPages) {
        if currentPage != page {
            currentPage = page
            AnalyticsManager.AppNavigation.pageViewed(page: pageAnalyticsName(page))
        }
    }

    func showWindow(settingsPage: SettingsPage? = nil) {
        if let settingsPage {
            Defaults[.settingsPage] = settingsPage
            showSettingsSheet = true
        }

        // Only count this as an "open" when the window is actually transitioning
        // from absent/hidden to visible - refocus calls on an already-open window
        // shouldn't inflate the count. We also emit a page-view for whatever
        // page the window lands on, since `setPage` only fires on change and
        // wouldn't fire when the window opens onto its initial page.
        let isAlreadyVisible = window?.isVisible == true
        if !isAlreadyVisible {
            AnalyticsManager.AppNavigation.appWindowOpened()
            AnalyticsManager.AppNavigation.pageViewed(page: pageAnalyticsName(currentPage))
        }

        if let existingWindow = window {
            showExistingWindow(existingWindow)
        } else {
            createWindow()
        }
    }

    /// Stable analytics-friendly identifier for an `AppPages` case.
    /// `AppPages` doesn't conform to `RawRepresentable`, so we map manually
    /// to keep the property values consistent across builds.
    private func pageAnalyticsName(_ page: AppPages) -> String {
        switch page {
        case .home: return "home"
        case .transcripts: return "transcripts"
        case .dictionary: return "dictionary"
        case .snippets: return "snippets"
        case .support: return "support"
        }
    }
    
    func closeWindow() {
        if let window {
            window.close()
        }
    }
    
    // MARK: - Private Functions
    
    private func showExistingWindow(_ window: AppWindow) {
        if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    private func createWindow() {
        window = AppWindow()
        
        guard let window else { return }
        
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - NSWindowDelegate Protocol Conformance
    
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? AppWindow,
           window === self.window
        else {
            return
        }

        window.cleanupObservers()
        window.delegate = nil
        self.window = nil
        showSettingsSheet = false
    }
}
