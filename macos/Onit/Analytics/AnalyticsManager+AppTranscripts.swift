// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AppTranscripts.swift
//  Onit
//
//  Created by Tim on 5/9/26.
//

import PostHog

extension AnalyticsManager {

    struct AppTranscripts {

        /// Tracks when the Transcripts page is opened (rendered).
        static func pageOpened() {
            AnalyticsManager.sendCommonEvent(event: "app_transcripts_page_opened")
        }

        /// Tracks when the user types into the Transcripts search field.
        /// - Parameter queryLength: Character count of the current query.
        static func searched(queryLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["query_length"] = queryLength
            PostHogSDK.shared.capture("app_transcripts_searched", properties: properties)
        }

        /// Tracks when the user changes the review-status filter pill.
        /// - Parameter status: The new filter value (e.g. "unreviewed", "reviewed", "corrected"), or nil for "all".
        static func reviewStatusFiltered(status: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            if let status {
                properties["status"] = status
            }
            PostHogSDK.shared.capture("app_transcripts_review_status_filtered", properties: properties)
        }

        /// Tracks when the user changes the sort order on the Transcripts page.
        /// - Parameter sortOrder: A short identifier for the new order (e.g. "newest", "oldest", "audio_duration", "app_name").
        static func sortOrderChanged(sortOrder: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["sort_order"] = sortOrder
            PostHogSDK.shared.capture("app_transcripts_sort_order_changed", properties: properties)
        }

        /// Tracks when the user toggles the "Show edits" toggle on the Transcripts page.
        /// - Parameter enabled: The new toggle state.
        static func showEditsToggled(enabled: Bool) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["enabled"] = enabled
            PostHogSDK.shared.capture("app_transcripts_show_edits_toggled", properties: properties)
        }

        /// Tracks when the user opens the transcript review modal for a transcript.
        /// - Parameter transcriptId: String form of the row's local id, when available.
        static func reviewOpened(transcriptId: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            if let transcriptId {
                properties["transcript_id"] = transcriptId
            }
            PostHogSDK.shared.capture("app_transcripts_review_opened", properties: properties)
        }

        /// User's chosen action from the review-modal toolbar. Distinguishes
        /// the local-only saves (`markAsCorrect`, `save`) from the
        /// share-with-Onit variants (`saveAndRequestFix`, `requestFix`) so
        /// we can measure the share-rate cleanly.
        enum SaveIntent: String {
            case markAsCorrect = "mark_as_correct"
            case save = "save"
            case saveAndRequestFix = "save_and_request_fix"
            case requestFix = "request_fix"
        }

        /// Entry point that summoned the `RequestFixModal` consent overlay.
        /// Mirrors the in-app `RequestFixModalContext` enum so the events
        /// line up with the modal-state transitions.
        enum ConsentContext: String {
            case fromSaveAndRequestFix = "from_save_and_request_fix"
            case fromRequestFix = "from_request_fix"
            case informational = "informational"
        }

        /// Tracks when the user submits a correction from the review modal.
        /// - Parameters:
        ///   - transcriptId: String form of the row's local id, when available.
        ///   - wasEdited: Whether the user modified the transcription before saving.
        ///   - intent: Which toolbar CTA fired the save - distinguishes
        ///     local-only saves from share-with-Onit variants.
        static func correctionSaved(transcriptId: String?, wasEdited: Bool, intent: SaveIntent) {
            var properties = AnalyticsManager.getCommonProperties()
            if let transcriptId {
                properties["transcript_id"] = transcriptId
            }
            properties["was_edited"] = wasEdited
            properties["intent"] = intent.rawValue
            PostHogSDK.shared.capture("app_transcripts_correction_saved", properties: properties)
        }

        /// Tracks when the user deletes a transcript.
        /// - Parameter transcriptId: String form of the row's local id, when available.
        static func transcriptDeleted(transcriptId: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            if let transcriptId {
                properties["transcript_id"] = transcriptId
            }
            PostHogSDK.shared.capture("app_transcripts_deleted", properties: properties)
        }

        // MARK: - Request fix consent modal

        /// Tracks when the consent overlay is presented to the user.
        static func requestFixConsentShown(context: ConsentContext) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["context"] = context.rawValue
            PostHogSDK.shared.capture("app_transcripts_request_fix_consent_shown", properties: properties)
        }

        /// User accepted ("Agree & send") - the row is now eligible to upload.
        static func requestFixConsentGranted(context: ConsentContext) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["context"] = context.rawValue
            PostHogSDK.shared.capture("app_transcripts_request_fix_consent_granted", properties: properties)
        }

        /// User dismissed the consent overlay without accepting (Cancel /
        /// tap-outside). Informational-mode dismissals also fire here even
        /// though they were never gating an upload - keeps the event shape
        /// consistent across contexts.
        static func requestFixConsentCancelled(context: ConsentContext) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["context"] = context.rawValue
            PostHogSDK.shared.capture("app_transcripts_request_fix_consent_cancelled", properties: properties)
        }
    }
}
