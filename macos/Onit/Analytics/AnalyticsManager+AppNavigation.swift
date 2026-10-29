// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AppNavigation.swift
//  Onit
//
//  Created by Tim on 5/9/26.
//

import PostHog

extension AnalyticsManager {

    struct AppNavigation {

        /// Tracks when the App window is opened (shown/created).
        static func appWindowOpened() {
            AnalyticsManager.sendCommonEvent(event: "app_window_opened")
        }

        /// Tracks when the user navigates to a page inside the App window.
        /// - Parameter page: A short identifier for the page (e.g. "home", "transcripts", "dictionary", "support").
        static func pageViewed(page: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["page"] = page
            PostHogSDK.shared.capture("app_page_viewed", properties: properties)
        }
    }
}
