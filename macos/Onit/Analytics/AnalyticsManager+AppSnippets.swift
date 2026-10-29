// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AppSnippets.swift
//  Onit
//
//  Created by Kévin Naudin on 17/06/2026.
//

import PostHog

extension AnalyticsManager {

    struct AppSnippets {

        /// Tracks when the Snippets page is opened (rendered).
        static func pageOpened() {
            AnalyticsManager.sendCommonEvent(event: "app_snippets_page_opened")
        }

        /// Tracks when the user types into the Snippets search field.
        /// - Parameter queryLength: Character count of the current query.
        static func searched(queryLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["query_length"] = queryLength
            PostHogSDK.shared.capture("app_snippets_searched", properties: properties)
        }

        /// Tracks when the user changes the sort order on the Snippets page.
        /// - Parameter sortOrder: A short identifier (e.g. "newest", "oldest", "alphabetical").
        static func sortOrderChanged(sortOrder: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["sort_order"] = sortOrder
            PostHogSDK.shared.capture("app_snippets_sort_order_changed", properties: properties)
        }

        /// Tracks when a new snippet has been added.
        /// - Parameters:
        ///   - snippetId: The new snippet's UUID string.
        ///   - nameLength: Character count of the name. The text itself is intentionally
        ///     not sent - snippets are user-supplied content and stay on-device.
        ///   - replacementLength: Character count of the replacement.
        static func snippetAdded(snippetId: String, nameLength: Int, replacementLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["snippet_id"] = snippetId
            properties["name_length"] = nameLength
            properties["replacement_length"] = replacementLength
            PostHogSDK.shared.capture("app_snippets_snippet_added", properties: properties)
        }

        /// Tracks when the user saves changes from the edit-snippet sheet.
        /// - Parameter snippetId: The snippet's UUID string.
        static func snippetEdited(snippetId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["snippet_id"] = snippetId
            PostHogSDK.shared.capture("app_snippets_snippet_edited", properties: properties)
        }

        /// Tracks when the user deletes a snippet.
        /// - Parameter snippetId: The snippet's UUID string.
        static func snippetDeleted(snippetId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["snippet_id"] = snippetId
            PostHogSDK.shared.capture("app_snippets_snippet_deleted", properties: properties)
        }
    }
}
