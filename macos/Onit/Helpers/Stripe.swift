// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Stripe.swift
//  Onit
//
//  Created by Loyd Kim on 5/7/25.
//

import Foundation
import SwiftUI

struct Stripe {
    /// Opens Stripe Checkout in the browser.
    /// - Parameter plan: optional plan identifier the server maps to a Stripe price
    ///   (e.g. `DictationPlan.checkoutPlan`). Nil keeps the server's default (legacy Pro) price.
    static func openSubscriptionForm(_ openURL: OpenURLAction, plan: String? = nil) async -> String? {
        do {
            let client = FetchingClient()
            let response = try await client.createSubscriptionCheckoutSession(plan: plan)
            if let url = URL(string: response.sessionUrl) {
                await openURL(url)
            }
            
            return nil
        } catch {
            print("Error: \(error.localizedDescription)")
            return NSLocalizedString("Failed to open subscription form.", tableName: "Settings", comment: "")
        }
    }
}
