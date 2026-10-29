// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+SmartCleanupPaywall.swift
//  Onit
//
//  Analytics for the Smart Cleanup paywall (Oct 2026), when dictation became free
//  and unlimited.
//
//  Never send transcript text: only counts, plans and reasons.
//

import Foundation
import PostHog

extension AnalyticsManager {

    struct SmartCleanupPaywall {

        /// A Smart Cleanup run was refused and the raw transcript was pasted. Sent for every
        /// refusal, whether or not the (rate-limited) prompt follows.
        @MainActor
        static func cleanupRefused(reason: SmartCleanupDenialReason) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["reason"] = reason.analyticsValue
            /// Signed in with no server answer the library trusts (likely offline).
            properties["subscription_unconfirmed"] = SmartCleanupEntitlement.shared.isSubscriptionUnconfirmed
            addUsage(to: &properties)
            PostHogSDK.shared.capture("smart_cleanup_refused", properties: properties)
        }

        /// Tracks when the Smart Cleanup paywall is shown.
        /// - Parameter mode: where the paywall was triggered ("after_dictation" after a refused
        ///   cleanup, "after_login" when it comes back after the sign-in handoff)
        @MainActor
        static func paywallShown(mode: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["mode"] = mode
            if let usage = SmartCleanupEntitlement.shared.usage {
                properties["reason"] = usage.denialReason.analyticsValue
            }
            addUsage(to: &properties)
            PostHogSDK.shared.capture("smart_cleanup_paywall_shown", properties: properties)
        }

        /// Tracks when the user clicks the upgrade CTA on the Smart Cleanup paywall.
        static func paywallCTAClicked(ctaType: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["cta_type"] = ctaType
            PostHogSDK.shared.capture("smart_cleanup_paywall_cta_clicked", properties: properties)
        }

        /// Tracks when the user expands "Why does this cost money?" on the paywall.
        static func whyOpened() {
            AnalyticsManager.sendCommonEvent(event: "smart_cleanup_paywall_why_opened")
        }

        /// Tracks when the user dismisses the Smart Cleanup paywall without taking action.
        static func paywallDismissed() {
            AnalyticsManager.sendCommonEvent(event: "smart_cleanup_paywall_dismissed")
        }

        /// Tracks when a user successfully subscribes from the Smart Cleanup paywall.
        static func paywallConversion() {
            AnalyticsManager.sendCommonEvent(event: "smart_cleanup_paywall_conversion")
        }

        @MainActor
        private static func addUsage(to properties: inout [String: Any]) {
            guard let usage = SmartCleanupEntitlement.shared.usage else { return }
            properties["words_used"] = usage.wordsUsed
            properties["words_this_month"] = usage.wordsThisMonth
            properties["free_tier_available"] = usage.freeTierAvailable
        }
    }
}

extension SmartCleanupDenialReason {
    var analyticsValue: String {
        switch self {
        case .freeAllowanceUsed: "free_allowance_used"
        case .freeTierRequiresSignedBuild: "free_tier_requires_signed_build"
        }
    }
}
