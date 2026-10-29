// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+Referral.swift
//  Onit
//

import PostHog

extension AnalyticsManager {

    struct Referral {

        /// Tracks when a user copies their referral link
        static func linkCopied() {
            AnalyticsManager.sendCommonEvent(event: "referral_link_copied")
        }

        /// Tracks when a user copies their referral code
        static func codeCopied() {
            AnalyticsManager.sendCommonEvent(event: "referral_code_copied")
        }

        /// Tracks when a user applies a referrer code
        /// - Parameters:
        ///   - success: Whether the referrer code was applied successfully
        ///   - error: Error message if the application failed
        static func codeApplied(success: Bool, error: String? = nil) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["success"] = success
            if let error {
                properties["error"] = error
            }

            PostHogSDK.shared.capture("referral_code_applied", properties: properties)
        }

        /// Tracks when a user views the referral leaderboard
        static func leaderboardViewed() {
            AnalyticsManager.sendCommonEvent(event: "referral_leaderboard_viewed")
        }
    }
}
