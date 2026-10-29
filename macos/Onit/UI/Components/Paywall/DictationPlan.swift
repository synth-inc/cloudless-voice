// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictationPlan.swift
//  Onit
//

import Foundation

/// Display constants for the paid plan, which unlocks unlimited Smart Cleanup (dictation itself
/// is free). The name and the server's `dictation` plan id predate that. The actual price lives in Stripe; the server
/// maps `checkoutPlan` to the configured Stripe price ID (`STRIPE_DICTATION_SUBSCRIPTION_PRICE_ID`),
/// so a price change never requires an app release: keep these strings in sync with Stripe.
enum DictationPlan {
    /// Identifier sent to `/v1/subscription/stripe/checkout` so the server picks the dictation price.
    static let checkoutPlan = "dictation"

    static let monthlyPriceDisplay = "$5.99"
    @MainActor static var monthlyPriceWithPeriod: String {
        String(format: String.localized("%@/month", table: "Settings"), monthlyPriceDisplay)
    }
}
