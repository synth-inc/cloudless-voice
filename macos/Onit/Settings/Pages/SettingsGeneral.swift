// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsGeneral.swift
//  Onit
//
//  Created by Loyd Kim on 9/2/25.
//

import KeyboardShortcuts
import PostHog
import ServiceManagement
import SwiftUI
import Defaults

struct SettingsGeneral: View {
    // MARK: - Defaults
    
    @Default(.hideDockIcon) private var hideDockIcon
    @Default(.alwaysHideHint) private var alwaysHideHint
    @Default(.hintSnoozedUntil) private var hintSnoozedUntil
    @Default(.appAppearance) private var appAppearance

    // MARK: - States

    @State var previousLaunchShortcut: KeyboardShortcuts.Shortcut? = KeyboardShortcuts.Name.launch.shortcut
    
    @State var isLaunchAtStartupEnabled: Bool = SMAppService.mainApp.status == .enabled
    @State var isUpdatingLaunchAtStartup: Bool = false
    @State var launchAtStartupErrorMessage: String? = nil

    @State var autoInstallUpdates: Bool = AppState.shared.updater.updater.automaticallyDownloadsUpdates
    
    @State var isAnalyticsEnabled: Bool = PostHogSDK.shared.isOptOut() == false
    @State var isUpdatingAnalyticsEnabled: Bool = false
    @State var analyticsEnabledErrorMessage: String? = nil
    
    // MARK: - Body
    
    var body: some View {
        generalSection
    }

    // MARK: - Child Components: General Section

    private var generalSection: some View {
        SettingsPageSection(title: .init(text: String.localized("General", table: "Settings"))) {
            hideDockIconToggle
            DividerHorizontal()
            alwaysHideHintToggle
            DividerHorizontal()
            hideHintTemporarily
            DividerHorizontal()
            launchOnStartup
            DividerHorizontal()
            autoInstallUpdatesToggle
            DividerHorizontal()
            // Without PostHog credentials the SDK is never set up, so the toggle would do nothing.
            if FeatureFlagManager.postHogCredentials != nil {
                analytics
                DividerHorizontal()
            }
            appearanceSection
        }
    }
    
    private var hideDockIconToggle: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Hide dock icon", table: "Settings"),
                subtitle: String.localized("Show only the menu bar icon.", table: "Settings")
            ),
            isOn: self.$hideDockIcon
        )
        .onChange(of: hideDockIcon, initial: false) { _, _ in
            AppDelegate.configureDockIconVisibility()
        }
    }
    
    private var alwaysHideHintToggle: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Always hide hint", table: "Settings"),
                subtitle: String.localized("Permanently hide the hint button that shows on the right side of your screen. Important alerts will still be shown.", table: "Settings"),
            ),
            isOn: $alwaysHideHint
        )
    }
    
    /// Writes `Defaults[.hintSnoozedUntil]` through `HintManager`, same as the Hint's more menu.
    ///     Disabled (rather than hidden) while `alwaysHideHint` is on, where a snooze is a no-op.
    private var hideHintTemporarily: some View {
        Group {
            if let hintSnoozedUntil = hintSnoozedUntil,
               hintSnoozedUntil > .now
            {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Hide hint temporarily", table: "Settings"),
                        subtitle: String.localized(
                            "Hint hidden until %@",
                            table: "Settings",
                            hintSnoozedUntil.formatted(date: .omitted, time: .shortened)
                        )
                    )
                ) {
                    Button(String.localized("Show hint", table: "Settings")) {
                        HintManager.shared.cancelHintSnooze()
                    }
                }
            } else {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Hide hint temporarily", table: "Settings"),
                        subtitle: String.localized("Silence the hint for a while. It comes back on its own.", table: "Settings")
                    ),
                    dropdown: .init(
                        placeholder: String.localized("Select a duration", table: "Settings"),
                        options: HintSnoozeDuration.allCases.map { duration in
                                .init(
                                    id: UUID(),
                                    name: duration.title(table: "Settings"),
                                    action: {
                                        HintManager.shared.snoozeHint(duration)
                                    }
                                )
                        }
                    )
                )
                /// Only starting a snooze is pointless while the Hint is always hidden. Cancelling
                ///     one must stay available, or a snooze started before the toggle was flipped
                ///     could no longer be cleared from here.
                .disabled(alwaysHideHint)
            }
        }
    }

    private var launchOnStartup: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = launchAtStartupErrorMessage {
                errorMessageView(errorMessage)
            }

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Launch automatically at login", table: "Settings"),
                    subtitle: String.localized("Open Cloudless automatically when you log into your computer.", table: "Settings"),
                ),
                isOn: $isLaunchAtStartupEnabled
            )
            .disabled(isUpdatingLaunchAtStartup)
            .onChange(of: isLaunchAtStartupEnabled, initial: false) { old, new in
                guard !isUpdatingLaunchAtStartup else { return }

                toggleLaunchAtStartup(
                    shouldLaunchAtStartup: new,
                    originalValue: old
                )
            }
        }
    }
    
    private var autoInstallUpdatesToggle: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Automatically install updates", table: "Settings"),
                subtitle: String.localized("Install updates in the background and apply them on next launch.", table: "Settings")
            ),
            isOn: $autoInstallUpdates
        )
        .onChange(of: autoInstallUpdates, initial: false) { _, new in
            AppState.shared.updater.updater.automaticallyDownloadsUpdates = new
            AnalyticsManager.Settings.autoInstallUpdatesToggled(enabled: new)
        }
    }

    private var analytics: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = analyticsEnabledErrorMessage {
                errorMessageView(errorMessage)
            }

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Enable usage analytics", table: "Settings"),
                    subtitle: String.localized("Help us improve the app. We send usage events (features used, errors, timings, device model and the name of the app you use). When you are signed in, they are linked to your account, including its ID and email.", table: "Settings"),
                ),
                isOn: $isAnalyticsEnabled
            )
            .disabled(isUpdatingAnalyticsEnabled)
            .onChange(of: isAnalyticsEnabled, initial: false) { old, new in
                guard !isUpdatingAnalyticsEnabled else { return }

                toggleAnalyticsOptOut(
                    shouldOptIn: new,
                    originalValue: old
                )
            }
        }
    }

    private var appearanceSection: some View {
        SettingsPageSubsection(
            header: .init(title: String.localized("Appearance", table: "Settings")),
            dropdown: .init(
                placeholder: String.localized("Select an appearance", table: "Settings"),
                options: AppAppearance.allCases.map { appearanceOption in
                        .init(
                            id: UUID(),
                            name: appearanceOption.displayName,
                            isSelected: appearanceOption == appAppearance,
                            action: {
                                AppAppearance.set(appearanceOption)
                            }
                        )
                }
            )
        )
    }

    // MARK: - Child Components: Shared
    
    private func errorMessageView(_ errorMessage: String) -> some View {
        Text(errorMessage)
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.red500
            )
    }

    // MARK: - Private Functions
    
    private func toggleLaunchAtStartup(
        shouldLaunchAtStartup: Bool,
        originalValue: Bool
    ) {
        isUpdatingLaunchAtStartup = true
        defer { isUpdatingLaunchAtStartup = false }
        
        launchAtStartupErrorMessage = nil
        
        do {
            if shouldLaunchAtStartup {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            
            isLaunchAtStartupEnabled = shouldLaunchAtStartup
        } catch {
            print("Error : \(error)")
         
            isLaunchAtStartupEnabled = originalValue
            launchAtStartupErrorMessage = error.localizedDescription
        }
    }
    
    private func toggleAnalyticsOptOut(
        shouldOptIn: Bool,
        originalValue: Bool
    ) {
        isUpdatingAnalyticsEnabled = true
        defer { isUpdatingAnalyticsEnabled = false }
        
        analyticsEnabledErrorMessage = nil
        
        if shouldOptIn {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
        
        let isNowOptedIn = PostHogSDK.shared.isOptOut() == false
        let failedToUpdate = isNowOptedIn != shouldOptIn
        
        if failedToUpdate {
            isAnalyticsEnabled = originalValue
            analyticsEnabledErrorMessage = String.localized("Update failed. Please try again.", table: "Settings")
        } else {
            isAnalyticsEnabled = shouldOptIn
        }
    }
}
