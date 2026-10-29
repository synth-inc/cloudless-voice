// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDelegate.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2025.
//

import Combine
import Defaults
import ServiceManagement
import SwiftUI
import GoogleSignIn

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var menuBarController: MenuBarController?
    private var keystrokeManager: KeystrokeNotificationManager?
    private var appCoordinator: AppCoordinator?
    private var appModeCoordinator: AppModeCoordinator?
    private var frontmostPidBeforeLaunch: pid_t?

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Uncomment this if the macOS menu bar (File, Edit, View) appears in the wrong language.
        // This can happen after testing with Xcode's scheme App Language setting (Product → Scheme → Edit Scheme → Run → Options → App Language).
//        Self.clearTestSchemeLanguage()

        frontmostPidBeforeLaunch = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests boot the full Onit.app as their host process. If we let the
        // delegate's real init run, the test bundle's Onit.app registers
        // global hotkeys + CGEventTaps in parallel with the user's real
        // running Onit.app - pressing the dictation hotkey fires both
        // instances and the transcription is inserted twice.
        //
        // Skip all delegate-side setup when running under XCTest. Test code
        // that needs subsystems (warmup, dictionary, ASR engine) initializes
        // them explicitly via their singletons.
        if TestEnvironment.isRunningTests() {
            log.info("AppDelegate: XCTest detected - skipping delegate setup to avoid double-dictation")
            return
        }

        // One-shot migration for the two post-onboarding "Cloudless is ready!" surfaces - the Hint
        // pop-up nudge (`appHomeReadyToastShown`) and the App Home setup card
        // (`appHomeSetupCardDismissed`). Both shipped with the onboarding overhaul (after v4.4) and
        // are gated on their own flags that default false, so every existing user would see them once
        // on update - confusing for someone already set up. Suppress both for anyone already past
        // onboarding. New users (onboarding not yet complete at first launch) are untouched, so they
        // still get the full first-run experience.
        if !Defaults[.readyToastMigrationDone] {
            Defaults[.readyToastMigrationDone] = true
            if Defaults[.mainOnboardingCompleted] {
                Defaults[.appHomeReadyToastShown] = true
                Defaults[.appHomeSetupCardDismissed] = true
            }
        }

        AppAppearance.applyCurrent()
        FirebaseSetup.configureIfAvailable()
        GIDSignIn.sharedInstance.restorePreviousSignIn()

        // Initialize the app coordinator with the frontmost pid before launch
        appCoordinator = AppCoordinator(frontmostPidAtLaunch: frontmostPidBeforeLaunch)
        
        // Initialize menu bar.
        self.menuBarController = MenuBarController.shared

        // We need to initialize the keystroke outside of the SwiftUI Application.
        keystrokeManager = KeystrokeNotificationManager.shared

        // Configure dock icon visibility based on user preference
        AppDelegate.configureDockIconVisibility()

        // This is helpful for debugging the new user experience, but should never be committed!
        //        if let appDomain = Bundle.main.bundleIdentifier {
        //            UserDefaults.standard.removePersistentDomain(forName: appDomain)
        //            UserDefaults.standard.synchronize()
        //        }

        // Arm the ambient term-memory capture observer (free when the dev
        // flags are off - every focus-change event re-checks them, so the
        // settings toggle needs no restart).
        AmbientTermCaptureService.shared.start()

        // Retention must keep running after the feature is switched off: no
        // dictation means no ingestion pass, so this is the only place a store
        // the user asked to expire still gets swept. No-op when the feature is
        // on, the window is "Never", or no store exists.
        TermMemoryService.shared.pruneRetentionAtLaunch()

        // Initialize ReferralManager for referral tracking.
        _ = ReferralManager.shared
        ReferralManager.shared.markInstalled()
        
        // Initialize ReferralLinkManager for referral links tracking.
        _ = ReferralLinkManager.shared

        // Initialize AppModeCoordinator to manage Transcription
        appModeCoordinator = AppModeCoordinator.shared
        appModeCoordinator?.delegate = self

        // Dev build coexistence monitoring (Release builds only)
        #if !DEBUG
        DevBuildDetectionService.shared.startMonitoring()
        KeyboardShortcutsManager.observeDevBuildDetection()
        EscapeKeyManager.shared.observeDevBuildDetection()
        #endif

        // Pre-decode dictation sound effects off the main thread so the first
        // chime isn't a cold ~160ms decode. No-op when sound effects are disabled.
        if Defaults[.transcriptionSoundEffectsEnabled] {
            SoundEffectsService.shared.prewarm()
        }

        checkLaunchOnStartup()
        // Smart Cleanup's paywall (inside the TranscriptionCleanup library): point it at
        // the backend and the sign-in token before the first dictation.
        SmartCleanupEntitlement.shared.configure()
        restoreSession()

        // Launch onboarding for first-time users
        launchOnboardingIfNeeded()

        #if DEBUG
        #if canImport(TranscriptionCleanup)
        // Re-open the Scoring Debug window if it was open at last quit.
        if Defaults[.scoringDebugWindowOpen] {
            ScoringDebugWindowController.shared.show()
        }
        #endif

        CorrectionModeDailyReset.shared.start()
        #endif
    }

    @MainActor
    private func launchOnboardingIfNeeded() {
        appModeCoordinator?.launchOnboardingIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppState.shared.handleDeeplink(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Menu bar app - don't quit when windows close
    }

    func applicationWillTerminate(_ notification: Notification) {
        keystrokeManager?.stopMonitoring()
        appModeCoordinator?.cleanup()
        appCoordinator?.cleanup()
        AnalyticsManager.appQuit()

        // Remove HID remapping to restore normal CapsLock behavior
        KeystrokeNotificationManager.shared.removeHIDRemapping()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock-icon click → open the home window. `showWindow()` is idempotent
        // (focuses the existing window if one is already open; creates one
        // otherwise) so this is safe to call regardless of `flag`.
        AppWindowManager.shared.showWindow()

        return true
    }
     
    static func configureDockIconVisibility() {
        let hideDockIcon = Defaults[.hideDockIcon]
        
        Task { @MainActor in
            if hideDockIcon {
                // Hide the dock icon - app becomes an accessory (background app)
                NSApp.setActivationPolicy(.accessory)
            } else {
                // Show the dock icon - app becomes a regular app
                NSApp.setActivationPolicy(.regular)
            }
        }
    }
    
    @MainActor
    private func checkLaunchOnStartup() {
        if !Defaults[.launchOnStartupRequested] {
            do {
                try SMAppService.mainApp.register()
                Defaults[.launchOnStartupRequested] = true
            } catch {
                print("Error: \(error)")
            }
        }
    }
    
    /// - Parameter retryDelay: wait before retrying after a network / server failure, doubled
    ///   on each attempt (capped at 30 min) until the account loads or the token is cleared.
    @MainActor
    private func restoreSession(retryDelay: TimeInterval = 60) {
        if TokenManager.token != nil && AuthManager.shared.account == nil {
            AuthManager.shared.isRestoringSession = true

            Task { @MainActor in
                defer { AuthManager.shared.isRestoringSession = false }
                /// An attempt still in flight when the user logs out or signs in by hand
                /// answers for a token that is gone: drop it.
                let token = TokenManager.token
                let isStale = { AuthManager.shared.account != nil || token == nil || TokenManager.token != token }
                do {
                    let client = FetchingClient()
                    let account = try await client.getAccount()
                    guard !isStale() else { return }
                    AuthManager.shared.setAccount(account: account)
                    AnalyticsManager.Identity.identify(account: account)
                } catch {
                    guard !isStale() else { return }
                    AuthManager.shared.setAccount(account: nil)
                    // `setAccount(nil)` is a no-op for Firebase (the non-nil
                    // branch is the one that calls signIn). Without an
                    // explicit signOut here, a previously cached Firebase
                    // session would survive a failed restoreSession(),
                    // leaving us with `Auth.auth().currentUser` pointing at
                    // an account we can no longer authenticate locally -
                    // any subsequent correction upload would then land
                    // under that stranded uid.
                    FirebaseAuthService.shared.signOut()
                    print("Error in `restoreSession()` method in `AppDelegate.swift`: \(error)")
                    /// Offline at launch or server down (not a rejected token): retry. Otherwise
                    /// the account stays nil all session and no seat / subscription is fetched,
                    /// leaving entitled users on the free Smart Cleanup allowance.
                    switch error {
                    /// `/account` only answers 401 for a bad token; a 403 comes from something in
                    /// between (proxy, firewall) and is retried rather than signing the user out.
                    case FetchingError.networkError, FetchingError.serverError, FetchingError.forbidden:
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .seconds(retryDelay))
                            self?.restoreSession(retryDelay: min(retryDelay * 2, 30 * 60))
                        }
                    /// A rejected token is a signed-out session: drop it, and the cached
                    /// Smart Cleanup entitlement with it.
                    case FetchingError.unauthorized:
                        AuthManager.shared.logout()
                    default:
                        break
                    }
                }
            }
        } else {
            AuthManager.shared.isRestoringSession = false
        }
    }
    
    private static func clearTestSchemeLanguage() {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
}

// MARK: - AppModeCoordinatorDelegate

extension AppDelegate: AppModeCoordinatorDelegate {
    func appModeCoordinator(_ coordinator: AppModeCoordinator, didChangeTranscriptionState enabled: Bool) {
        menuBarController?.updateStatusDot()
    }

    func appModeCoordinatorDidUpdateTranscriptionModelStatus(_ coordinator: AppModeCoordinator) {
        menuBarController?.updateStatusDot()
    }
}
