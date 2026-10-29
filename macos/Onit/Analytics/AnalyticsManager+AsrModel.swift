// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+AsrModel.swift
//  Onit
//
//  Created by Tim on 5/20/26.
//

import PostHog

extension AnalyticsManager {

    /// Events for the multi-backend ASR model picker
    /// (`SettingsASRModelsPickerSheet`) - selection, download lifecycle,
    /// deletion. Distinct from `AnalyticsManager.Transcription`'s
    /// `modelInitializationStarted/Completed/Failed` (which fire on the
    /// active backend's warmup), and from
    /// `AnalyticsManager.TranscriptionLLM` (which tracks the optional
    /// self-correction LLM, not the ASR model).
    struct AsrModel {

        /// User-side classification of download-failure cause. The catch in
        /// `ASRModelDownloadManager.download(_:)` carries a raw description
        /// - we surface that alongside a coarse bucket so PostHog dashboards
        /// can chart "network vs disk vs other" without re-parsing strings.
        enum DownloadFailureReason: String {
            case network = "network"
            case insufficientDiskSpace = "insufficient_disk_space"
            case unsupportedModel = "unsupported_model"
            case other = "other"
        }

        // MARK: - Picker lifecycle

        /// User opened the "Local AI Models" picker sheet (from Settings →
        /// Transcription).
        static func pickerOpened() {
            AnalyticsManager.sendCommonEvent(event: "asr_model_picker_opened")
        }

        /// User tapped "Use" on a downloaded model card - the active backend
        /// is about to switch. Fires before the actual config write so the
        /// event captures the user's intent even if the switch fails.
        static func modelSelected(modelId: String, backend: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            PostHogSDK.shared.capture("asr_model_selected", properties: properties)
        }

        // MARK: - Download lifecycle

        static func modelDownloadStarted(modelId: String, backend: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            PostHogSDK.shared.capture("asr_model_download_started", properties: properties)
        }

        static func modelDownloadCompleted(
            modelId: String,
            backend: String,
            durationMs: Int
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            properties["duration_ms"] = durationMs
            PostHogSDK.shared.capture("asr_model_download_completed", properties: properties)
        }

        static func modelDownloadFailed(
            modelId: String,
            backend: String,
            reason: DownloadFailureReason,
            durationMs: Int,
            errorDescription: String? = nil
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            properties["reason"] = reason.rawValue
            properties["duration_ms"] = durationMs
            if let errorDescription {
                properties["error_description"] = AnalyticsManager.scrubPaths(errorDescription)
            }
            PostHogSDK.shared.capture("asr_model_download_failed", properties: properties)
        }

        /// User cancelled an in-flight download via the picker's Cancel
        /// button. Separate from `Failed` so the funnel distinguishes
        /// "user changed their mind" from "download broke."
        static func modelDownloadCancelled(modelId: String, backend: String, durationMs: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            properties["duration_ms"] = durationMs
            PostHogSDK.shared.capture("asr_model_download_cancelled", properties: properties)
        }

        /// User removed a previously-installed model via the picker's trash
        /// button. Useful for understanding storage-pressure churn.
        static func modelDeleted(modelId: String, backend: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["backend"] = backend
            PostHogSDK.shared.capture("asr_model_deleted", properties: properties)
        }
    }
}
