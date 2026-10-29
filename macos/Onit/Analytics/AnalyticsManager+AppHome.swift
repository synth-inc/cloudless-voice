// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AppHome.swift
//  Onit
//
//  Created by Tim on 5/9/26.
//

import PostHog

extension AnalyticsManager {

    struct AppHome {

        /// Tracks when the user clicks the dictation stats bar to open the stats sheet.
        static func statsBarClicked() {
            AnalyticsManager.sendCommonEvent(event: "app_home_stats_bar_clicked")
        }

        /// Tracks when the user clicks "View all" on the recent transcripts list.
        static func recentTranscriptsViewAllClicked() {
            AnalyticsManager.sendCommonEvent(event: "app_home_recent_transcripts_view_all_clicked")
        }

        /// Tracks when the user clicks the recent-transcripts footer link (e.g. "View N transcripts").
        static func recentTranscriptsFooterLinkClicked() {
            AnalyticsManager.sendCommonEvent(event: "app_home_recent_transcripts_footer_clicked")
        }

        /// Tracks when the user changes their typing speed (WPM) used to compute time-saved.
        /// - Parameter wpm: The new WPM value.
        static func wpmMultiplierChanged(wpm: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["wpm"] = wpm
            PostHogSDK.shared.capture("app_home_wpm_multiplier_changed", properties: properties)
        }
    }
}
