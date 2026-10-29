// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+CuratedMentions.swift
//  Onit
//
//  Created by Loyd Kim on 6/4/26.
//

import PostHog

extension AnalyticsManager {
    struct CuratedMentions {
        /// Left chevron - navigate to the previous mission card.
        static func previousPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_previous_pressed")
        }

        /// Right chevron - navigate to the next mission card.
        static func nextPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_next_pressed")
        }

        /// "Comment now!" - opens the curated post/video to comment on.
        static func commentNowPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_comment_now_pressed")
        }

        /// "Submit your link" - opens the submit-link sheet for a mission.
        static func submitLinkPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_submit_link_pressed")
        }

        /// Cancel button on the submit-link sheet.
        static func submitSheetCancelled() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_submit_sheet_cancelled")
        }

        /// A link was successfully submitted from the submit-link sheet.
        static func submitSheetSubmitted() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_submit_sheet_submitted")
        }

        /// Section-header comments button - opens the "Your comments" sheet.
        static func yourCommentsOpened() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_your_comments_opened")
        }

        /// Section-header leaderboard icon button.
        static func leaderboardPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_mentions_leaderboard_pressed")
        }
    }
}
