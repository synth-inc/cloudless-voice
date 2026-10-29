// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+Shortcuts.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-08.
//

import Foundation
import PostHog

extension AnalyticsManager {
    static func shortcutPressed(for shortcutName: String, panelOpened: Bool) {
        var properties = Self.getCommonProperties()

        properties["shortcut_name"] = shortcutName
        properties["panel_opened"] = panelOpened

        PostHogSDK.shared.capture("shortcut_pressed", properties: properties)
    }
}
