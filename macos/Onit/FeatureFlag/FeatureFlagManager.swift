// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FeatureFlagManager.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2025.
//

import Defaults
import Foundation
import PostHog
import SwiftUI

/// Class which manages feature flags with PostHog SDK
@MainActor
class FeatureFlagManager: ObservableObject {

    // MARK: - Singleton instance

    static let shared = FeatureFlagManager()

    // MARK: - Feature Flags

    @Published private(set) var autocontextDemoVideoUrl: String? = nil
    @Published private(set) var usePinnedMode: Bool = true
    @Published private(set) var stopMode: StopMode = .removePartial
    @Published private(set) var sileroVadEnabled: Bool = true

    // MARK: - Private initializer

    private init() {
        // Initialize from persisted values so defaults hold before PostHog loads.
        sileroVadEnabled = Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadEnabled]
    }

    // MARK: - Functions

    /// The PostHog credentials, or nil when this build has none. Filled from the
    /// POSTHOG_API_KEY / POSTHOG_HOST build settings, which are empty unless the
    /// official release overlay is applied, so public and fork builds never set up
    /// PostHog and never report to Synth. Single source of truth for "configured".
    static var postHogCredentials: (apiKey: String, host: String)? {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "PostHogApiKey") as? String,
            let host = Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String,
            !apiKey.isEmpty, !host.isEmpty
        else { return nil }
        return (apiKey, host)
    }

    /** Configure the SDK */
    func configure() {
        guard let (apiKey, host) = Self.postHogCredentials else {
            print("PostHog -> Error not initialized due to missing API key or host")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(receiveFeatureFlags),
            name: PostHogSDK.didReceiveFeatureFlags,
            object: nil
        )
        let config = PostHogConfig(apiKey: apiKey, host: host)

        PostHogSDK.shared.setup(config)
    }

    func togglePinnedMode(_ enabled: Bool) {
        Defaults[.usePinnedMode] = enabled
        usePinnedMode = enabled
    }

    func setStopMode(_ mode: StopMode) {
        Defaults[.stopMode] = mode
        stopMode = mode
    }

    func setStopModeByUser(_ mode: StopMode) {
        Defaults[.stopMode] = mode
        Defaults[.stopModeUserConfigured] = true
        stopMode = mode
    }

    func setSileroVad(_ enabled: Bool) {
        Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadEnabled] = enabled
        sileroVadEnabled = enabled
    }

    func setSileroVadByUser(_ enabled: Bool) {
        Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadEnabled] = enabled
        Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadUserConfigured] = true
        sileroVadEnabled = enabled
    }

    // MARK: - Objective-C Functions

    @objc private func receiveFeatureFlags() {
        setFeatureFlagsFromRemote()
    }

    // MARK: - Private functions

    private func setFeatureFlagsFromRemote() {
        // Get demo video URL from feature flag
        if let rawValue = PostHogSDK.shared.getFeatureFlagPayload("autocontext_demo_video_url") {
            if let payload = rawValue as? [String: Any], let urlString = payload["url"] as? String {
                autocontextDemoVideoUrl = urlString
            } else {
                autocontextDemoVideoUrl = nil
            }
        } else {
            autocontextDemoVideoUrl = nil
        }

        // Handle pinned mode feature flag
        if let pinnedModeEnabled = Defaults[.usePinnedMode] {
            usePinnedMode = pinnedModeEnabled
        } else {
            let pinnedModeFlag = PostHogSDK.shared.isFeatureEnabled("pinned_mode")

            togglePinnedMode(pinnedModeFlag)
        }

        // Handle stop mode feature flag
        // Only use remote flag if user hasn't manually configured their preference
        if Defaults[.stopModeUserConfigured] {
            // User has manually set their preference, respect it
            let localStopMode = Defaults[.stopMode]
            stopMode = localStopMode
        } else {
            // User hasn't configured it, use remote feature flag
            if PostHogSDK.shared.isFeatureEnabled("stop_mode_leave_partial") {
                // Remote flag is enabled, use leavePartial
                setStopMode(.leavePartial)
            } else {
                // No remote override, use default
                setStopMode(.removePartial)
            }
        }

        // Handle VAD silence filter feature flag
        // User-configured preference takes priority; otherwise use remote flag.
        // Create "silero_vad_enabled" in PostHog at 100% rollout to keep default-on.
        // Roll to 0% as a kill switch if false positives are discovered.
        if Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadUserConfigured] {
            sileroVadEnabled = Defaults[Defaults.Keys.TranscriptionConfigKeys.sileroVadEnabled]
        } else {
            setSileroVad(PostHogSDK.shared.isFeatureEnabled("silero_vad_enabled"))
        }
    }
}
