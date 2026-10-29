// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+CuratedSocials.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import PostHog

extension AnalyticsManager {

    struct CuratedSocials {

        /// In-carousel "More" reload button (right peek slot, when the user is
        /// on the last loaded card and the server has more posts available).
        static func morePressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_more_pressed")
        }

        /// "Load more" pill on the daily-stack-completed view.
        static func loadMorePressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_load_more_pressed")
        }

        /// X close button on the daily-stack-completed view.
        static func dailyStackDoneDismissed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_daily_stack_done_dismissed")
        }

        /// X close button on the stack-completed (all-done) view.
        static func stackDoneDismissed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_stack_done_dismissed")
        }

        /// "see more ways to spread the word →" inline link on the
        /// collapsed (post-dismissal) state.
        static func collapsedLinkPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_collapsed_link_pressed")
        }

        /// Header ellipsis button - completely dismisses the entire section forever.
        static func sectionDismissedForever() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_section_dismissed_forever")
        }
        
        /// Header ellipsis button - completely dismisses the entire section.
        static func sectionDismissed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_section_dismissed")
        }

        /// Collapsed-header ellipsis button - "Unhide section" brings the
        /// dismissed-for-today section back into full view.
        static func sectionRestored() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_section_restored")
        }

        /// User clicked a peek card to bring it into the centered (active) slot.
        /// Fires only on explicit click-to-snap - programmatic centering (initial
        /// load, reload, autoadvance, delete-then-advance) and scroll-drag-snap
        /// are intentionally excluded so the event reflects user intent.
        /// - Parameter postId: The newly centered post id.
        static func carouselCardCentered(postId: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["post_id"] = postId
            PostHogSDK.shared.capture("curated_socials_card_centered", properties: properties)
        }

        /// CTA on a centered card - opens the post URL in the browser.
        /// - Parameters:
        ///   - postId: The post id.
        ///   - platform: The post's platform (e.g. "Reddit", "YouTube", "X"), or nil when unknown.
        static func postOpened(postId: Int, platform: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["post_id"] = postId
            if let platform {
                properties["platform"] = platform
            }
            PostHogSDK.shared.capture("curated_socials_post_opened", properties: properties)
        }

        /// "Open all" pill on the carousel - opens every loaded post in a new browser window.
        /// - Parameter postCount: How many posts were opened.
        static func openAllPressed(postCount: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["post_count"] = postCount
            PostHogSDK.shared.capture("curated_socials_open_all_pressed", properties: properties)
        }

        /// "Undo open all" button on either the daily-stack-done or stack-done view.
        static func undoOpenAllPressed() {
            AnalyticsManager.sendCommonEvent(event: "curated_socials_undo_open_all_pressed")
        }

        /// Info icon on a YouTube card - surfaces the "highlighted comment" explainer popover.
        /// - Parameter postId: The post id.
        static func youtubeInfoClicked(postId: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["post_id"] = postId
            PostHogSDK.shared.capture("curated_socials_youtube_info_clicked", properties: properties)
        }
    }
}
