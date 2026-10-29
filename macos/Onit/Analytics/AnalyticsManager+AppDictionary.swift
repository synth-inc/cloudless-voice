// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AppDictionary.swift
//  Onit
//
//  Created by Tim on 5/9/26.
//

import PostHog

extension AnalyticsManager {

    struct AppDictionary {

        /// Tracks when the Dictionary page is opened (rendered).
        static func pageOpened() {
            AnalyticsManager.sendCommonEvent(event: "app_dictionary_page_opened")
        }

        /// Tracks when the user types into the Dictionary search field.
        /// - Parameter queryLength: Character count of the current query.
        static func searched(queryLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["query_length"] = queryLength
            PostHogSDK.shared.capture("app_dictionary_searched", properties: properties)
        }

        /// Tracks when the user changes the sort order on the Dictionary page.
        /// - Parameter sortOrder: A short identifier for the new order (e.g. "newest", "oldest", "alphabetical").
        static func sortOrderChanged(sortOrder: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["sort_order"] = sortOrder
            PostHogSDK.shared.capture("app_dictionary_sort_order_changed", properties: properties)
        }

        /// Tracks when the user opens the "Add a term" sheet.
        static func addTermStarted() {
            AnalyticsManager.sendCommonEvent(event: "app_dictionary_add_term_started")
        }

        /// Tracks when a new dictionary term has been added.
        /// - Parameters:
        ///   - termId: The new term's UUID string.
        ///   - textLength: Character count of the term. The text itself is intentionally
        ///     not sent - dictionary terms are user-supplied names, jargon, and proper
        ///     nouns and should not leave the device.
        static func termAdded(termId: String, textLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            properties["text_length"] = textLength
            PostHogSDK.shared.capture("app_dictionary_term_added", properties: properties)
        }

        /// Tracks when the user opens the edit-term sheet.
        /// - Parameter termId: The term's UUID string.
        static func editTermStarted(termId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            PostHogSDK.shared.capture("app_dictionary_edit_term_started", properties: properties)
        }

        /// Tracks when the user saves changes from the edit-term sheet.
        /// - Parameter termId: The term's UUID string.
        static func termEdited(termId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            PostHogSDK.shared.capture("app_dictionary_term_edited", properties: properties)
        }

        /// Tracks when the user deletes a term.
        /// - Parameter termId: The term's UUID string.
        static func termDeleted(termId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            PostHogSDK.shared.capture("app_dictionary_term_deleted", properties: properties)
        }

        /// Tracks when calibration begins for a term (the calibration sheet is shown).
        /// - Parameter termId: The term's UUID string.
        static func calibrationStarted(termId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            PostHogSDK.shared.capture("app_dictionary_calibration_started", properties: properties)
        }

        /// Tracks when calibration completes successfully for a term.
        /// - Parameters:
        ///   - termId: The term's UUID string.
        ///   - category: The chosen category, when applicable.
        static func calibrationCompleted(termId: String, category: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            if let category {
                properties["category"] = category
            }
            PostHogSDK.shared.capture("app_dictionary_calibration_completed", properties: properties)
        }

        /// Tracks when the user re-runs calibration ("re-scan history") for an existing term.
        /// - Parameter termId: The term's UUID string.
        static func rescanStarted(termId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["term_id"] = termId
            PostHogSDK.shared.capture("app_dictionary_rescan_started", properties: properties)
        }

        /// Tracks when the user opens the Dictionary advanced settings sheet.
        static func advancedSettingsOpened() {
            AnalyticsManager.sendCommonEvent(event: "app_dictionary_advanced_settings_opened")
        }
    }
}
