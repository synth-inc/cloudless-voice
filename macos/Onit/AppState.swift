// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppState.swift
//  Onit
//
//  Created by Kévin Naudin on 02/04/2025.
//

import Combine
import Defaults
import DefaultsMacros
import Sparkle
import SwiftUI

@MainActor
@Observable
class AppState: NSObject, SPUUpdaterDelegate {
    // MARK: - Singleton
    
    static let shared = AppState()
    
    private var authManager = AuthManager.shared
    
    // MARK: - Properties

    var showMenuBarExtra: Bool = false
    var updater: SPUStandardUpdaterController!

    /// True when the build carries a Sparkle feed (`SUFeedURL`, filled from the
    /// `SU_FEED_URL` build setting). Public and fork builds leave it empty, so the
    /// updater is never started and never contacts Synth's appcast.
    static let isUpdateFeedConfigured: Bool = {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        return !(feed ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }()
    var isUpdateAvailable: Bool = false
    var availableUpdateVersion: String? = nil


    var localFetchFailed: Bool = false
    
    private var fetchSubscriptionTask: Task<Void, Never>?
    
    var subscription: Subscription?

//    var subscriptionActive: Bool { subscription?.status == "active" || subscription?.status == "trialing" }
    
    var subscriptionCanceled: Bool {
        if let canceled = subscription?.cancelAtPeriodEnd {
            return canceled
        } else {
            return false
        }
    }
    
    var subscriptionStatus: String? {
        if authManager.userLoggedIn && subscription == nil {
            return SubscriptionStatus.free
        } else if let subscription = subscription {
            switch subscription.status {
            case "trialing":
                return SubscriptionStatus.trialing
            case "active":
                return SubscriptionStatus.active
            case "past_due":
                return SubscriptionStatus.pastDue
            default:
                // Stripe statuses: Canceled, Incomplete, Incomplete Expired, Past Due, Unpaid, and Paused
                return SubscriptionStatus.free
            }
        } else {
            return nil
        }
    }
    var subscriptionPlanError: String = ""

    /// For a user without unlimited Smart Cleanup: a subscription exists but doesn't entitle (past
    /// due beyond the grace, incomplete, paused). The server refuses a new checkout for it
    /// ("Subscription already exists"), so only the billing portal can fix it. Canceled /
    /// unpaid ones may check out again.
    var subscriptionNeedsBillingPortal: Bool {
        guard authManager.userLoggedIn, let status = subscription?.status else { return false }
        return status != "canceled" && status != "unpaid"
    }

    private var authCancellable: AnyCancellable? = nil

    // MARK: - App Status Properties

    /// Status dot color in the menu bar (reactive)
    var statusDotColor: AppStatusDotColor = .green

    /// Main status message (first line of the menu)
    var statusMessage: AppStatusMessage = .running

    /// Badge count for Settings Setup page (nil = no badge)
    var setupBadgeCount: Int? = nil

    /// Cancellables for status observers
    @ObservationIgnored
    var statusObserverCancellables = Set<AnyCancellable>()

    // MARK: - Initializer
    
    override init() {
        super.init()
        
        // Used for updating subscription variables in response to account updates.
        authCancellable = AuthManager.shared.$account
            .receive(on: DispatchQueue.main)
            .sink { [weak self] account in
                if let self = self {
                    if account == nil {
                        fetchSubscriptionTask?.cancel()
                        fetchSubscriptionTask = nil
                        subscription = nil
                    } else {
                        fetchSubscriptionTask?.cancel()
                        fetchSubscriptionTask = Task {
                            do {
                                let fetched = try await FetchingClient().getSubscription()
                                guard !Task.isCancelled else { return }
                                subscription = fetched
                                /// Successful answer: let the Smart Cleanup entitlement catch up.
                                LifetimeActivationManager.shared.entitlementAnswerArrived()
                            } catch {
                                subscription = nil
                            }
                        }
                    }
                }
            }
        
        // Initialize Sparkle updater for showing/removing update available footer notification.
        // Not started without a feed URL (public/fork builds), see `isUpdateFeedConfigured`.
        updater = SPUStandardUpdaterController(
            startingUpdater: Self.isUpdateFeedConfigured,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        Task {
            await fetchLocalModels()
        }

        // Setup status observers for reactive status updates
        setupStatusObservers()
    }
    
    // MARK: - Functions

    @MainActor
    func fetchLocalModels() async {
        do {
            let models = try await FetchingClient().getLocalModels()

            // Handle local model selection
            let localModel = Defaults[.localModel]

            Defaults[.availableLocalModels] = models
            
            // Initialize visible local models if empty (first time or after being cleared)
            if Defaults[.visibleLocalModels].isEmpty && !models.isEmpty {
                Defaults[.visibleLocalModels] = Set(models)
            } else {
                // Update visible models to only include currently available models
                let currentVisible = Defaults[.visibleLocalModels]
                Defaults[.visibleLocalModels] = currentVisible.intersection(Set(models))
            }
            
            if models.isEmpty {
                Defaults[.localModel] = nil
            } else if localModel == nil || !models.contains(localModel!) {
                // Choose from visible models if available
                let visibleModels = Defaults[.visibleLocalModels]
                if let firstVisibleModel = visibleModels.first {
                    Defaults[.localModel] = firstVisibleModel
                }
            }
            localFetchFailed = false

            // Reset the closedNoLocalModels flag when local models are successfully fetched.
            Defaults[.closedNoLocalModels] = false
        } catch {
            print("Error fetching local models:", error)
            localFetchFailed = true
            Defaults[.availableLocalModels] = []
            Defaults[.localModel] = nil
        }
    }
    
    func handleDeeplink(_ url: URL) {
        guard url.scheme == "onit" else {
            return
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            print("Invalid URL")
            return
        }
        
        // Handle different deeplink actions based on path or host
        // onit://payment-success  → host="payment-success", path=""
        // onit:///payment-success → host="",                path="/payment-success"
        let action = components.path.isEmpty ? (components.host ?? "") : components.path
        switch action {
        case "/update", "/check-for-updates", "update", "check-for-updates":
            handleUpdateDeeplink()
        case "/payment-success", "payment-success":
            handlePaymentSuccessDeeplink()
        default:
            if components.host == "settings" {
                // onit://settings/<page> - host is "settings", path is "/<page>"
                let pagePath = String(components.path.dropFirst()) // drop leading "/"
                if let page = SettingsPage.allCases.first(where: { $0.deepLinkPath == pagePath }) {
                    NSApp.activate(ignoringOtherApps: true)
                    AppWindowManager.shared.showWindow(settingsPage: page)
                }
            } else {
                // For backwards compatibility, if no path is specified, assume it's a token login
                authManager.handleTokenLogin(url)
            }
        }
    }
    
    func handleUpdateDeeplink() {
        // Activate the app to bring it to the foreground
        NSApp.activate(ignoringOtherApps: true)
        checkForAvailableUpdateWithDownload()
    }

    /// Stripe Checkout's success page redirects here. The webhook that creates the subscription
    /// can lag the redirect by a few seconds, so poll rather than fetch once.
    func handlePaymentSuccessDeeplink() {
        NSApp.activate(ignoringOtherApps: true)
        HintManager.shared.startCheckoutPolling()
    }
}

// MARK: - App Update Listeners

extension AppState {
    func removeDiscordFooterNotifications() {
        Defaults[.footerNotifications].removeAll { notification in
            if case .discord = notification {
                return true
            }
            return false
        }
    }
    
    func checkForAvailableUpdate() {
        guard Self.isUpdateFeedConfigured else { return }
        self.updater.updater.checkForUpdateInformation()
    }

    func checkForAvailableUpdateWithDownload() {
        guard Self.isUpdateFeedConfigured else { return }
        self.updater.updater.checkForUpdates()
    }
    
    private func addUpdateFooterNotification() {
        if !Defaults[.footerNotifications].contains(.update) {
            Defaults[.footerNotifications].append(.update)
        }
    }
    
    nonisolated func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        let versionString = item.versionString
        Task { @MainActor in
            availableUpdateVersion = versionString
            isUpdateAvailable = true
            addUpdateFooterNotification()
        }
    }
    
    func removeUpdateFooterNotifications() {
        Defaults[.footerNotifications].removeAll { notification in
            if case .update = notification {
                return true
            }
            return false
        }
    }
    
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            isUpdateAvailable = false
            removeUpdateFooterNotifications()
        }
    }
}
