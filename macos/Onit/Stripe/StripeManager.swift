// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StripeManager.swift
//  Onit
//
//  Created by Loyd Kim on 11/26/25.
//

import Foundation
import SwiftUI

@MainActor
final class StripeManager: ObservableObject {
    // MARK: - Singleton
    
    static let shared = StripeManager()
    
    // MARK: - Published Properties
    
    @Published private(set) var planType: String? = nil
    
    @Published private(set) var fetchingSubscriptionData: Bool = false
    @Published private(set) var subscriptionDataErrorMessage: String? = nil
    
    // MARK: - Public Functions: Reset

    /// Logout: nothing here belongs to the next account, and a stale `planType` must never
    /// grant entitlement to a signed-out session.
    func reset() {
        planType = nil
        fetchingSubscriptionData = false
        subscriptionDataErrorMessage = nil
    }

    // MARK: - Public Functions: Published Setters
    
    func setSubscriptionDataErrorMessage(_ errorMessage: String?) {
        self.subscriptionDataErrorMessage = errorMessage
    }
    
    // MARK: - Public Functions: Fetching Client
    
    func fetchSubscriptionData() async {
        subscriptionDataErrorMessage = nil
        fetchingSubscriptionData = true
        
        if AuthManager.shared.userLoggedIn {
            await refreshSubscriptionState()
            
            planType = AppState.shared.subscriptionStatus
        }
            
        fetchingSubscriptionData = false
    }
    
    /// - Returns: this call's error message, nil once the portal opened. Also published as
    ///   `subscriptionDataErrorMessage` for Settings, which other fetches overwrite.
    @discardableResult
    func openBillingPortal(with openURL: OpenURLAction) async -> String? {
        do {
            let client = FetchingClient()
            let response = try await client.createSubscriptionBillingPortalSession()
            if let url = URL(string: response.sessionUrl) {
                openURL(url)
            }
            return nil
        } catch {
            subscriptionDataErrorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }
    
    func refreshSubscriptionState() async {
        do {
            let client = FetchingClient()
            let accountId = AuthManager.shared.account?.id
            let fetched = try await client.getSubscription()
            /// The answer belongs to the account that asked; drop it after a logout or switch.
            guard accountId != nil, AuthManager.shared.account?.id == accountId else { return }
            AppState.shared.subscription = fetched
            LifetimeActivationManager.shared.entitlementAnswerArrived()
        } catch {
            subscriptionDataErrorMessage = error.localizedDescription
        }
    }
    
    func renewSubscription() async {
        do {
            let client = FetchingClient()
            try await client.updateSubscriptionCancel(cancelAtPeriodEnd: false)
            await fetchSubscriptionData()
        } catch {
            subscriptionDataErrorMessage = error.localizedDescription
        }
    }
}
