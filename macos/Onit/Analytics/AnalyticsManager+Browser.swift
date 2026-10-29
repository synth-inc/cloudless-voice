// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+Browser.swift
//  Onit
//
//  Created by Loyd Kim on 5/11/26.
//

extension AnalyticsManager {
    struct Browser {
        static func requestOpenBrowserUrlWithoutAccessibilityPermission() {
            AnalyticsManager.sendCommonEvent(event: "browser_request_open_url_without_accessibility_permission")
        }
    }
}
