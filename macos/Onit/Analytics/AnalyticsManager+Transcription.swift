// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AnalyticsManager+Transcription.swift
//  Onit
//
//  Created by Kévin Naudin on 15/01/2026.
//

import Foundation
import PostHog

extension AnalyticsManager {

    struct Transcription {

        // MARK: - Feature Lifecycle Events

        /// Tracks when transcription feature is enabled
        static func enabled() {
            AnalyticsManager.sendCommonEvent(event: "transcription_enabled")
        }

        /// Tracks when transcription feature is disabled
        static func disabled() {
            AnalyticsManager.sendCommonEvent(event: "transcription_disabled")
        }

        // MARK: - Insertion Events

        /// Tracks when dictated text was inserted into the macOS Spotlight search field via the
        /// Accessibility API (the Spotlight-only workaround for synthesized-paste landing on the
        /// wrong process). Firing this event for any bundle other than com.apple.Spotlight would
        /// indicate the strict gate has regressed.
        /// - Parameter textLength: Number of characters inserted.
        static func spotlightAXInsertUsed(textLength: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["text_length"] = textLength
            PostHogSDK.shared.capture("transcription_spotlight_ax_insert_used", properties: properties)
        }

        // MARK: - Model Initialization Events

        /// Tracks when model initialization starts
        static func modelInitializationStarted() {
            AnalyticsManager.sendCommonEvent(event: "transcription_model_initialization_started")
        }

        /// Tracks when model initialization completes successfully
        /// - Parameter duration: Time taken to initialize in seconds
        static func modelInitializationCompleted(duration: TimeInterval) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["duration_ms"] = Int(duration * 1000)

            PostHogSDK.shared.capture("transcription_model_initialization_completed", properties: properties)
        }

        /// Tracks when model initialization fails
        /// - Parameters:
        ///   - error: Error description
        ///   - serverIsReady: Whether the Python server was ready at failure time
        ///   - logTail: Last lines of the Python server log for diagnostics
        static func modelInitializationFailed(error: String, serverIsReady: Bool? = nil, logTail: String? = nil) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["error"] = error
            if let serverIsReady {
                properties["server_is_ready"] = serverIsReady
            }
            if let logTail, !logTail.isEmpty {
                properties["python_log_tail"] = String(logTail.suffix(3000))
            }

            PostHogSDK.shared.capture("transcription_model_initialization_failed", properties: properties)
        }

        /// Tracks when the Python server becomes ready to handle requests
        /// - Parameter durationMs: Time from process launch to server ready in milliseconds
        static func serverBecameReady(durationMs: Double) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["duration_ms"] = Int(durationMs)

            PostHogSDK.shared.capture("transcription_server_became_ready", properties: properties)
        }

        /// Tracks when the Python server fails to start
        /// - Parameters:
        ///   - reason: Failure reason ("process_died" or "health_check_timeout")
        ///   - durationMs: Time elapsed before failure in milliseconds
        ///   - stderrTail: Last lines of stderr for diagnostics
        static func serverStartupFailed(reason: String, durationMs: Double, stderrTail: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["reason"] = reason
            properties["duration_ms"] = Int(durationMs)
            if !stderrTail.isEmpty {
                properties["stderr_tail"] = String(stderrTail.suffix(3000))
            }

            PostHogSDK.shared.capture("transcription_server_startup_failed", properties: properties)
        }

        /// Tracks when user retries model initialization after failure
        static func modelInitializationRetry() {
            AnalyticsManager.sendCommonEvent(event: "transcription_model_initialization_retry")
        }

        /// Tracks when user manually restarts the engine after a startup failure
        static func engineRestartTapped() {
            AnalyticsManager.sendCommonEvent(event: "transcription_engine_restart_tapped")
        }

        // MARK: - Warmup Latency Events

        /// Tracks when a model warmup begins.
        /// - Parameters:
        ///   - model: "parakeet" or "scoring"
        ///   - isFirstTime: true when the model has never been downloaded to this device before
        static func warmupStarted(model: String, isFirstTime: Bool) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["warmup_type"] = isFirstTime ? "first_time" : "reload"
            PostHogSDK.shared.capture("transcription_warmup_started", properties: properties)
        }

        /// Tracks when a model warmup completes successfully.
        /// - Parameters:
        ///   - model: "parakeet" or "scoring"
        ///   - isFirstTime: true when the model was being downloaded for the first time
        ///   - durationMs: Total warmup time in milliseconds
        static func warmupCompleted(model: String, isFirstTime: Bool, durationMs: Double) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["warmup_type"] = isFirstTime ? "first_time" : "reload"
            properties["duration_ms"] = Int(durationMs)
            PostHogSDK.shared.capture("transcription_warmup_completed", properties: properties)
        }

        /// Tracks when a model warmup fails.
        /// - Parameters:
        ///   - model: "parakeet" or "scoring"
        ///   - isFirstTime: true when the model was being downloaded for the first time
        ///   - durationMs: Time elapsed before failure in milliseconds
        ///   - error: Error description
        static func warmupFailed(model: String, isFirstTime: Bool, durationMs: Double, error: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["warmup_type"] = isFirstTime ? "first_time" : "reload"
            properties["duration_ms"] = Int(durationMs)
            properties["error"] = error
            PostHogSDK.shared.capture("transcription_warmup_failed", properties: properties)
        }

        /// Tracks when a warmup appears stuck before reaching the `.downloading` phase.
        /// Emitted by the onboarding UI when the downloader sits in `.idle`/`.fetching`
        /// past the stall-detection threshold - distinct from `warmupFailed`, which fires
        /// only after a thrown error or the 30-min hard timeout.
        /// - Parameters:
        ///   - model: "parakeet" or "scoring"
        ///   - isFirstTime: true when the model has never been downloaded to this device before
        ///   - durationMs: Time spent in the stalled state before the alert was surfaced
        ///   - state: Downloader state at the time of the alert ("fetching", "idle", etc.)
        static func warmupStalled(model: String, isFirstTime: Bool, durationMs: Double, state: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["warmup_type"] = isFirstTime ? "first_time" : "reload"
            properties["duration_ms"] = Int(durationMs)
            properties["state"] = state
            PostHogSDK.shared.capture("transcription_warmup_stalled", properties: properties)
        }

        // MARK: - Session Events

        /// Tracks when a transcription session starts
        /// - Parameters:
        ///   - shortcutType: Type of shortcut used (capsLock, fn, custom)
        ///   - activationMode: How the session was activated (hold, toggle, handsfree)
        ///   - appName: Name of the target application
        ///   - appBundleId: Bundle identifier of the target application
        static func sessionStarted(shortcutType: String, activationMode: String, appName: String?, appBundleId: String?) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["shortcut_type"] = shortcutType
            properties["activation_mode"] = activationMode

            if let appName = appName {
                properties["app_name"] = appName
            }
            if let appBundleId = appBundleId {
                properties["app_bundle_id"] = appBundleId
            }

            PostHogSDK.shared.capture("transcription_session_started", properties: properties)
        }

        /// Tracks when a transcription session completes successfully
        /// - Parameters:
        ///   - shortcutType: Type of shortcut used (capsLock, fn, custom)
        ///   - activationMode: How the session was activated (hold, toggle, handsfree)
        ///   - duration: Session duration in seconds
        ///   - textLength: Length of transcribed text
        ///   - appName: Name of the target application
        ///   - appBundleId: Bundle identifier of the target application
        ///   - asrDurationMs: Time spent in ASR (Parakeet CoreML), in milliseconds
        ///   - nbestDurationMs: Time spent in N-best LLM selection, in milliseconds (nil if skipped)
        ///   - cleanupDurationMs: Time spent in smart formatting cleanup, in milliseconds (nil if skipped)
        ///   - insertionDurationMs: Time spent inserting text into the target app, in milliseconds
        ///   - cleanupCandidateCount: Number of candidates evaluated by the cleanup server (nil if skipped)
        ///   - detectedLanguage: ISO 639-1 language code of the transcribed audio (nil if text was too short to classify)
        static func sessionCompleted(
            shortcutType: String,
            activationMode: String,
            duration: TimeInterval,
            textLength: Int,
            appName: String?,
            appBundleId: String?,
            asrDurationMs: Double? = nil,
            nbestDurationMs: Double? = nil,
            cleanupDurationMs: Double? = nil,
            insertionDurationMs: Double? = nil,
            cleanupCandidateCount: Int? = nil,
            cleanupCategoriesEvaluated: [String: Int]? = nil,
            cleanupCategoriesApplied: [String: Int]? = nil,
            detectedLanguage: String? = nil,
            vadSuppressed: Bool? = nil,
            vadEnabled: Bool? = nil
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["shortcut_type"] = shortcutType
            properties["activation_mode"] = activationMode
            properties["duration_ms"] = Int(duration * 1000)
            properties["text_length"] = textLength

            if let appName = appName {
                properties["app_name"] = appName
            }
            if let appBundleId = appBundleId {
                properties["app_bundle_id"] = appBundleId
            }
            if let asrDurationMs {
                properties["latency_asr_ms"] = Int(asrDurationMs)
            }
            if let nbestDurationMs {
                properties["latency_nbest_ms"] = Int(nbestDurationMs)
            }
            if let cleanupDurationMs {
                properties["latency_cleanup_ms"] = Int(cleanupDurationMs)
            }
            if let insertionDurationMs {
                properties["latency_insertion_ms"] = Int(insertionDurationMs)
            }
            if let cleanupCandidateCount {
                properties["cleanup_candidate_count"] = cleanupCandidateCount
            }
            if let cleanupCategoriesEvaluated {
                for (category, count) in cleanupCategoriesEvaluated {
                    properties["cleanup_\(category)_evaluated"] = count
                }
            }
            if let cleanupCategoriesApplied {
                for (category, count) in cleanupCategoriesApplied {
                    properties["cleanup_\(category)_applied"] = count
                }
            }
            if let detectedLanguage {
                properties["detected_language"] = detectedLanguage
            }
            if let vadSuppressed {
                properties["vad_suppressed"] = vadSuppressed
            }
            if let vadEnabled {
                properties["vad_enabled"] = vadEnabled
            }

            PostHogSDK.shared.capture("transcription_session_completed", properties: properties)
        }

        /// Tracks when a transcription session is cancelled by the user
        /// - Parameters:
        ///   - shortcutType: Type of shortcut used (capsLock, fn, custom)
        ///   - activationMode: How the session was activated (hold, toggle, handsfree)
        ///   - duration: Session duration before cancellation in seconds
        ///   - appName: Name of the target application
        ///   - appBundleId: Bundle identifier of the target application
        static func sessionCancelled(
            shortcutType: String,
            activationMode: String,
            duration: TimeInterval,
            appName: String?,
            appBundleId: String?
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["shortcut_type"] = shortcutType
            properties["activation_mode"] = activationMode
            properties["duration_ms"] = Int(duration * 1000)

            if let appName = appName {
                properties["app_name"] = appName
            }
            if let appBundleId = appBundleId {
                properties["app_bundle_id"] = appBundleId
            }

            PostHogSDK.shared.capture("transcription_session_cancelled", properties: properties)
        }

        /// Tracks when a transcription session fails due to an error
        /// - Parameters:
        ///   - shortcutType: Type of shortcut used (capsLock, fn, custom)
        ///   - activationMode: How the session was activated (hold, toggle, handsfree)
        ///   - error: Error description
        ///   - appName: Name of the target application
        ///   - appBundleId: Bundle identifier of the target application
        static func sessionFailed(
            shortcutType: String,
            activationMode: String,
            error: String,
            appName: String?,
            appBundleId: String?
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["shortcut_type"] = shortcutType
            properties["activation_mode"] = activationMode
            properties["error"] = error

            if let appName = appName {
                properties["app_name"] = appName
            }
            if let appBundleId = appBundleId {
                properties["app_bundle_id"] = appBundleId
            }

            PostHogSDK.shared.capture("transcription_session_failed", properties: properties)
        }

        // MARK: - Startup Timing

        /// Tracks recording startup latency breakdown for diagnosing first-word clipping issues.
        /// All durations are measured from when `performAudioCapture()` begins executing.
        static func recordingStartupTiming(
            taskSchedulingMs: Double,
            startRecordingMs: Double,
            configureAudioEngineMs: Double,
            audioOutputUnitStartMs: Double,
            clipboardSnapshotMs: Double,
            axContextMs: Double,
            tapToFirstBufferMs: Double? = nil
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["task_scheduling_ms"] = Int(taskSchedulingMs)
            properties["start_recording_ms"] = Int(startRecordingMs)
            properties["configure_audio_engine_ms"] = Int(configureAudioEngineMs)
            properties["audio_output_unit_start_ms"] = Int(audioOutputUnitStartMs)
            properties["clipboard_snapshot_ms"] = Int(clipboardSnapshotMs)
            properties["ax_context_ms"] = Int(axContextMs)
            properties["total_blocking_ms"] = Int(clipboardSnapshotMs + axContextMs)
            if let tapToFirstBufferMs {
                properties["tap_to_first_buffer_ms"] = Int(tapToFirstBufferMs)
            }

            PostHogSDK.shared.capture("transcription_recording_startup_timing", properties: properties)
        }

        // MARK: - Correction Events

        /// Tracks when a user submits from the correction overlay (Save / paste button).
        /// Fires on every submission regardless of whether the text was edited.
        /// - Parameters:
        ///   - wasEdited: Whether the user modified the transcription before saving
        ///   - originalLength: Character count of the original ASR output
        ///   - correctedLength: Character count of the final text (same as originalLength if not edited)
        ///   - appName: Name of the target application
        ///   - appBundleId: Bundle identifier of the target application
        static func correctionSaved(
            wasEdited: Bool,
            originalLength: Int,
            correctedLength: Int,
            appName: String?,
            appBundleId: String?
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["was_edited"] = wasEdited
            properties["original_length"] = originalLength
            properties["corrected_length"] = correctedLength

            if let appName {
                properties["app_name"] = appName
            }
            if let appBundleId {
                properties["app_bundle_id"] = appBundleId
            }

            PostHogSDK.shared.capture("transcription_correction_saved", properties: properties)
        }

        // MARK: - Correction Signal Events

        /// Tracks when a user shows editing intent after a paste (delete key, arrow key, or click within pasted text bounds),
        /// triggering the correction overlay.
        /// - Parameter signalType: One of "key_delete", "key_arrow", or "click_in_bounds"
        static func correctionSignalDetected(signalType: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["signal_type"] = signalType
            PostHogSDK.shared.capture("transcription_correction_signal_detected", properties: properties)
        }

        // MARK: - Cleanup Error Events

        /// Tracks when smart formatting was skipped (model not ready, disabled, or empty text).
        /// - Parameters:
        ///   - reason: One of "perplexity_not_warmed_up", "warmup_not_complete", "perplexity_engine_not_ready",
        ///             "empty_text", "apply_rules_false", or similar values from the log entry.
        static func cleanupSkipped(reason: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["reason"] = reason

            PostHogSDK.shared.capture("transcription_cleanup_skipped", properties: properties)
        }

        /// Tracks a Swift-side error during smart formatting (network, timeout, decode failure).
        /// - Parameter error: Localized error description.
        static func cleanupSwiftError(error: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["error"] = String(error.prefix(500))

            PostHogSDK.shared.capture("transcription_cleanup_swift_error", properties: properties)
        }

        /// Tracks a server-side pipeline error returned in log_entries.
        /// - Parameter error: Error description from the pipeline_error log entry.
        static func cleanupPipelineError(error: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["error"] = String(error.prefix(500))

            PostHogSDK.shared.capture("transcription_cleanup_pipeline_error", properties: properties)
        }

        // MARK: - Cleanup Rule Events

        /// Tracks cleanup rule decisions in a single batched event, without logging any transcript text.
        /// - Parameter decisions: Array of (ruleName, accepted) pairs from the cleanup pipeline.
        static func cleanupRulesEvaluated(decisions: [(ruleName: String, accepted: Bool)]) {
            guard !decisions.isEmpty else { return }

            var properties = AnalyticsManager.getCommonProperties()
            properties["rules"] = decisions.map { ["rule_name": $0.ruleName, "accepted": $0.accepted] }
            properties["rules_count"] = decisions.count
            properties["accepted_count"] = decisions.filter(\.accepted).count

            PostHogSDK.shared.capture("transcription_cleanup_rules_evaluated", properties: properties)
        }

        // MARK: - Model Ping Events

        /// Tracks a keep-alive or recording-start warmup ping against the local ASR / scoring engines.
        /// - Parameters:
        ///   - pingType: per-backend keep-alive id (e.g. "keepalive_parakeet", "keepalive_scoring"),
        ///     or a recording-start type ("recording_start_asr", "recording_start_cleanup", etc.)
        ///   - durationMs: Elapsed inference time in milliseconds
        ///   - status: "ok", "busy" (real transcription in progress), "skipped" (engine not loaded / inactive), or "error"
        static func modelPing(pingType: String, durationMs: Double, status: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["ping_type"] = pingType
            properties["duration_ms"] = Int(durationMs)
            properties["status"] = status

            PostHogSDK.shared.capture("transcription_model_ping", properties: properties)
        }

        /// The resident ASR model was unloaded after `idleMinutes` of dictation
        /// inactivity to reclaim RAM. Reloads transparently on the next dictation.
        static func asrModelUnloadedForIdle(model: String, idleMinutes: Int) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["idle_minutes"] = idleMinutes

            PostHogSDK.shared.capture("transcription_asr_idle_unload", properties: properties)
        }

        /// The ASR model was reloaded after an idle-unload. `status` is "ok" or
        /// "slow" (reload exceeded the watchdog threshold - see the Granite
        /// reload anomaly) or "error".
        static func asrModelReloadedAfterIdle(model: String, durationMs: Double, status: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["model"] = model
            properties["duration_ms"] = Int(durationMs)
            properties["status"] = status

            PostHogSDK.shared.capture("transcription_asr_idle_reload", properties: properties)
        }

        // MARK: - Settings Events

        /// Tracks when the transcription shortcut type is changed
        /// - Parameters:
        ///   - oldValue: Previous shortcut type
        ///   - newValue: New shortcut type
        static func shortcutTypeChanged(oldValue: String, newValue: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["old_value"] = oldValue
            properties["new_value"] = newValue

            PostHogSDK.shared.capture("transcription_shortcut_type_changed", properties: properties)
        }

        /// Tracks when the transcription settings page is opened
        static func settingsOpened() {
            AnalyticsManager.sendCommonEvent(event: "transcription_settings_opened")
        }

        /// Tracks when the silence filter (VAD) setting is toggled
        /// - Parameter enabled: Whether the silence filter is now enabled
        static func silenceFilterToggled(enabled: Bool) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["enabled"] = enabled

            PostHogSDK.shared.capture("transcription_silence_filter_toggled", properties: properties)
        }

        // MARK: - Key Monitoring Events

        /// Tracks when `TranscriptionKeysManager` failes to install the `CGEventTap` for custom transcription-related keyboard shortcuts.
        static func transcriptionKeysTapCreationFailed() {
            AnalyticsManager.sendCommonEvent(event: "transcription_keys_tap_creation_failed")
        }

        /// Tracks when the `CGEventTap` installed by `TranscriptionKeysManager` is auto-disabled by macOS (typically due to system pressure or a slow callback).
        /// We re-enable the tap automatically; this event lets us see how often that happens in the wild so we can diagnose shortcut flakiness.
        ///
        /// - Parameter `reason`: One of "timeout", "user_input", or "unknown".
        static func transcriptionKeysTapAutoDisabled(reason: String) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["reason"] = reason

            PostHogSDK.shared.capture("transcription_keys_tap_auto_disabled", properties: properties)
        }

        // MARK: - Last Transcription Events
        
        enum LastTranscriptionAnalyticsNoOpReason {
            case onitFrontmost
            case mostRecentTranscriptionDoesNotExist
            case transcriptionHistoryFeatureDisabled
            case mostRecentTranscriptionTextEmpty
            
            var text: String {
                switch self {
                case .onitFrontmost:
                    return "onit_frontmost"
                case .mostRecentTranscriptionDoesNotExist:
                    return "most_recent_transcription_does_not_exist"
                case .transcriptionHistoryFeatureDisabled:
                    return "transcription_history_feature_disabled"
                case .mostRecentTranscriptionTextEmpty:
                    return "most_recent_transcription_text_empty"
                }
            }
        }
        
        enum LastTranscriptionActionSource {
            case copyLastTranscription
            case pasteLastTranscription
            case correctAndTeach
            
            var eventName: String {
                switch self {
                case .copyLastTranscription:
                    return "last_transcription_copied"
                case .pasteLastTranscription:
                    return "last_transcription_pasted"
                case .correctAndTeach:
                    return "last_transcription_corrected"
                }
            }
        }
        
        /// Tracks when the user invokes a "last transcription" action, such as "copy last transcription", "paste last transcription", and "correct and teach".
        /// - Parameters:
        ///   - shortcutType: The current `.toggleTranscription` binding (`"capsLock"` / `"fn"` / `"custom"`).
        ///   - source: Which UI surface triggered the action (`"menu_bar"` / `"hint_more_menu"` / `"keyboard_shortcut"`).
        ///   - noOpReason: Describes why the action resulted in a no-op.
        ///   - actionSource: Determines the PostHog event name.
        static func lastTranscription(
            shortcutType: String,
            source: String,
            noOpReason: LastTranscriptionAnalyticsNoOpReason? = nil,
            actionSource: LastTranscriptionActionSource
        ) {
            var properties = AnalyticsManager.getCommonProperties()
            properties["shortcut_type"] = shortcutType
            properties["source"] = source
            
            if let noOpReason {
                properties["no_op_reason"] = noOpReason.text
            }
            
            PostHogSDK.shared.capture(actionSource.eventName, properties: properties)
        }
        
        // MARK: - Onboarding Events

        struct Onboarding {

            /// Tracks when the transcription intro onboarding step is shown
            static func introShown() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_intro_shown")
            }

            /// Tracks when the transcription intro is skipped
            static func introSkipped() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_intro_skipped")
            }

            /// Tracks when the transcription setup (microphone) onboarding step is shown
            static func setupShown() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_setup_shown")
            }

            /// Tracks when microphone permission is granted during onboarding
            static func setupMicrophoneGranted() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_setup_microphone_granted")
            }

            /// Tracks when the transcription setup step is completed (mic permission + audio detected)
            static func setupCompleted() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_setup_completed")
            }

            /// Tracks when the transcription warmup onboarding step is shown
            static func warmupShown() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_warmup_shown")
            }

            /// Tracks when the transcription warmup step completes (model ready)
            static func warmupCompleted() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_warmup_completed")
            }

            /// Tracks when user retries model initialization during onboarding
            static func warmupRetry() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_warmup_retry")
            }

            /// Tracks when the transcription demo onboarding step is shown
            static func demoShown() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_demo_shown")
            }

            /// Tracks when the transcription demo is completed
            /// - Parameters:
            ///   - textLength: Length of the transcribed demo text
            ///   - shortcutType: Type of shortcut selected
            static func demoCompleted(textLength: Int, shortcutType: String) {
                var properties = AnalyticsManager.getCommonProperties()
                properties["text_length"] = textLength
                properties["shortcut_type"] = shortcutType

                PostHogSDK.shared.capture("transcription_onboarding_demo_completed", properties: properties)
            }

            /// Tracks when the transcription demo is skipped (without being completed)
            /// - Parameters:
            ///   - subStepIndex: Zero-based demo sub-step the user was on when they skipped.
            ///     `nil` when the skip happened outside the demo (e.g. Settings → Setup).
            ///   - source: Where the skip came from (e.g. "onboarding_demo", "settings_setup")
            static func demoSkipped(subStepIndex: Int? = nil, source: String) {
                var properties = AnalyticsManager.getCommonProperties()
                if let subStepIndex = subStepIndex {
                    properties["sub_step_index"] = subStepIndex
                }
                properties["source"] = source

                PostHogSDK.shared.capture("transcription_onboarding_demo_skipped", properties: properties)
            }

            /// Tracks when user resets the demo
            static func demoReset() {
                AnalyticsManager.sendCommonEvent(event: "transcription_onboarding_demo_reset")
            }
        }
    }
}
