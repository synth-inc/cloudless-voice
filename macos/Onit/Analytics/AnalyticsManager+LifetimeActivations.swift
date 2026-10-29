// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+LifetimeActivations.swift
//  Onit
//
//  Created by Loyd Kim on 4/21/26.
//

import PostHog

extension AnalyticsManager {
    struct LifetimeActivations {
        static func activationFetchFailed(error: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["error"] = error
            PostHogSDK.shared.capture("lifetime_activation_fetch_failed", properties: properties)
        }
    }
}
