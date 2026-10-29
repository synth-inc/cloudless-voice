// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Subscription.swift
//  Onit
//
//  Created by Jason Swanson on 4/29/25.
//

import Foundation

struct SubscriptionStatus {
    static let incomplete = "Incomplete"
    static let incompleteExpired = "Incomplete Expired"
    static let trialing = "⭐️ Pro 2-Week Trial"
    static let active = "⭐️ Pro"
    static let pastDue = "Past Due"
    static let canceled = "Pro Plan Expiring Soon"
    static let unpaid = "Unpaid"
    static let paused = "Paused"
    static let free = "Free Plan"

    /// Returns the localized display name for a given subscription status.
    @MainActor
    static func localizedName(_ status: String) -> String {
        return String.localized(status, table: "Settings")
    }

    /// Whether a subscription in `status` is paid up: active, trialing, or `pastDue` for a
    /// bounded grace window while Stripe retries the card (roughly a week). The window starts
    /// with the unpaid period: on a failed renewal Stripe has already moved
    /// `current_period_start` to the start of that period. A subscription parked in `pastDue`
    /// beyond the window is treated as lapsed. Same rule as the TranscriptionCleanup library's
    /// Smart Cleanup entitlement, so Settings and the paywall agree with it.
    static func entitles(status: String?, periodStart: Date?, now: Date = Date()) -> Bool {
        switch status {
        case active, trialing:
            return true
        case pastDue:
            guard let periodStart else { return true }
            return now < periodStart.addingTimeInterval(pastDueGrace)
        default:
            return false
        }
    }

    static let pastDueGrace: TimeInterval = 7 * 24 * 60 * 60
}

struct Subscription: Codable {
    let id: String
    let status: String
    let statusMessage: String?
    let trialEnd: Double? // Second since the epoch
    let currentPeriodStart: Double // Second since the epoch
    let currentPeriodEnd: Double // Second since the epoch
    let cancelAtPeriodEnd: Bool
}

struct ChatUsage: Codable {
    let usage: Double
    let quota: Double
    let paid: Bool
    let currentPeriodStart: Double // Second since the epoch
    let currentPeriodEnd: Double // Second since the epoch
}
