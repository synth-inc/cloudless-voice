// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+TranscriptionLLM.swift
//  Onit
//
//  Created by Tim on 5/20/26.
//

import PostHog

extension AnalyticsManager {

    /// Events for the on-device LLM that powers the correction
    /// ("correction-marker") cleanup pass. Distinct from the main ASR /
    /// Parakeet pipeline events under `AnalyticsManager.Transcription` -
    /// those track the ASR engine, these track the optional second-stage
    /// language model that rewrites corrected utterances.
    struct TranscriptionLLM {

        /// User-side classification of the load-failure cause so we can
        /// tell apart "user is out of disk" from "network blip" from
        /// "something else broke" without piping the raw error string.
        enum LoadFailureReason: String {
            case insufficientDiskSpace = "insufficient_disk_space"
            case network = "network"
            case other = "other"
        }

        /// User-side classification of inference-failure cause for the
        /// cleanup pass. `notLoaded` is a precondition mismatch we should
        /// never see in production; `timeout` is the most common real
        /// failure (5 s default budget); `other` is everything else.
        enum CleanupFailureReason: String {
            case notLoaded = "not_loaded"
            case timeout = "timeout"
            case other = "other"
        }

        // MARK: - Model load lifecycle

        static func modelLoadStarted(modelId: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            PostHogSDK.shared.capture("transcription_llm_model_load_started", properties: properties)
        }

        static func modelLoadCompleted(modelId: String, durationMs: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["duration_ms"] = durationMs
            PostHogSDK.shared.capture("transcription_llm_model_load_completed", properties: properties)
        }

        static func modelLoadFailed(
            modelId: String,
            reason: LoadFailureReason,
            errorDescription: String? = nil
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model_id"] = modelId
            properties["reason"] = reason.rawValue
            if let errorDescription {
                properties["error_description"] = AnalyticsManager.scrubPaths(errorDescription)
            }
            PostHogSDK.shared.capture("transcription_llm_model_load_failed", properties: properties)
        }

        // MARK: - Self-correction cleanup pass

        /// Fires once per cleanup invocation that runs the LLM (skipped /
        /// no-marker fast paths are NOT counted). Pair with
        /// `cleanupCompleted` / `cleanupTimeout` / `cleanupFailed` for
        /// attempt-vs-outcome funnel analysis.
        static func cleanupAttempted(textLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["text_length"] = textLength
            PostHogSDK.shared.capture("transcription_llm_cleanup_attempted", properties: properties)
        }

        /// Fires after a cleanup pass returns successfully. `wasModified`
        /// distinguishes the "LLM ran but kept input unchanged" case from
        /// the "LLM rewrote the transcript" case - both are useful signals
        /// for tuning the marker gate.
        static func cleanupCompleted(
            textLength: Int,
            durationMs: Int,
            wasModified: Bool
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["text_length"] = textLength
            properties["duration_ms"] = durationMs
            properties["was_modified"] = wasModified
            PostHogSDK.shared.capture("transcription_llm_cleanup_completed", properties: properties)
        }

        /// Fires when the cleanup pass exceeds its timeout budget. `cleanupFailed`
        /// receives the other paths (model-not-loaded, miscellaneous errors).
        static func cleanupTimeout(textLength: Int, timeoutSeconds: Double, durationMs: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["text_length"] = textLength
            properties["timeout_seconds"] = timeoutSeconds
            properties["duration_ms"] = durationMs
            PostHogSDK.shared.capture("transcription_llm_cleanup_timeout", properties: properties)
        }

        static func cleanupFailed(
            textLength: Int,
            reason: CleanupFailureReason,
            durationMs: Int,
            errorDescription: String? = nil
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["text_length"] = textLength
            properties["reason"] = reason.rawValue
            properties["duration_ms"] = durationMs
            if let errorDescription {
                properties["error_description"] = AnalyticsManager.scrubPaths(errorDescription)
            }
            PostHogSDK.shared.capture("transcription_llm_cleanup_failed", properties: properties)
        }
    }
}
