// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsTranscriptionNotifications.swift
//  Onit
//
//  Created by Loyd Kim on 3/27/26.
//

import Defaults
import SwiftUI

struct SettingsTranscriptionNotifications: View {
    // MARK: - Defaults

    @Default(.showHintTranscriptionFailedAlert) private var showHintTranscriptionFailedAlert
    @Default(.showHintTranscriptionSilentAlert) private var showHintTranscriptionSilentAlert
    @Default(.showHintTranscriptionCancelledAlert) private var showHintTranscriptionCancelledAlert
    @Default(.showHintTranscriptionInputDeviceFailedAlert) private var showHintTranscriptionInputDeviceFailedAlert
    @Default(.showHintTranscriptionInputDeviceUnpluggedAlert) private var showHintTranscriptionInputDeviceUnpluggedAlert
    @Default(.showHintTranscriptionDetectedNewInputDeviceAlert) private var showHintTranscriptionDetectedNewInputDeviceAlert

    // MARK: - Observations

    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared

    // MARK: - Body

    var body: some View {
        dictationSection
        microphoneSection
    }

    // MARK: - Child Components: Dictation Section

    private var dictationSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Dictation", table: "Settings"))) {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Dictation Failed", table: "Settings"),
                        subtitle: String.localized("Alert when Dictation fails.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionFailedAlert
                )
                .onChange(of: showHintTranscriptionFailedAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "dictation_failed", enabled: new)
                }

                DividerHorizontal()
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Dictation Silent", table: "Settings"),
                        subtitle: String.localized("Alert when Dictation captures no audio.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionSilentAlert
                )
                .onChange(of: showHintTranscriptionSilentAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "dictation_silent", enabled: new)
                }

                DividerHorizontal()
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Dictation Dismissed", table: "Settings"),
                        subtitle: String.localized("Alert when Dictation is cancelled.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionCancelledAlert
                )
                .onChange(of: showHintTranscriptionCancelledAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "dictation_cancelled", enabled: new)
                }
            }
    }

    // MARK: - Child Components: Microphone Section

    @ViewBuilder
    private var microphoneSection: some View {
        if microphoneInputManager.hasPermission {
            SettingsPageSection(title: .init(text: String.localized("Microphone", table: "Settings"))) {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Microphone Failed", table: "Settings"),
                        subtitle: String.localized("Alert when there is an issue setting up the microphone.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionInputDeviceFailedAlert
                )
                .onChange(of: showHintTranscriptionInputDeviceFailedAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "mic_failed", enabled: new)
                }

                DividerHorizontal()
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Microphone Disconnected", table: "Settings"),
                        subtitle: String.localized("Alert when the microphone is disconnected during Dictation.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionInputDeviceUnpluggedAlert
                )
                .onChange(of: showHintTranscriptionInputDeviceUnpluggedAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "mic_disconnected", enabled: new)
                }

                DividerHorizontal()
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("New Microphone Detected", table: "Settings"),
                        subtitle: String.localized("Alert when a new microphone is detected.", table: "Settings")
                    ),
                    isOn: $showHintTranscriptionDetectedNewInputDeviceAlert
                )
                .onChange(of: showHintTranscriptionDetectedNewInputDeviceAlert, initial: false) { _, new in
                    AnalyticsManager.Settings.Notifications.toggleChanged(notificationType: "mic_new_detected", enabled: new)
                }
            }
        }
    }

}
