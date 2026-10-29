// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsSetup.swift
//  Onit
//
//  Created by Loyd Kim on 9/2/25.
//

import Defaults
import SwiftUI

struct SettingsSetup: View {
    // MARK: - Defaults

    @Default(.currentOnboardingStep) private var currentOnboardingStep
    @Default(.transcriptionEnabled) private var transcriptionEnabled
    @Default(.dictationDemoCompleted) private var dictationDemoCompleted

    // MARK: - States

    @ObservedObject private var accessibilityPermissionManager = AccessibilityPermissionManager.shared
    @ObservedObject private var screenRecordingPermissionManager = ScreenRecordingPermissionManager.shared
    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared

    // MARK: - Private Variables

    let onboardingWindowManager = OnboardingWindowManager.shared

    /// Onboarding is complete only if:
    /// - The main onboarding flow reached .complete
    /// - AND all enabled features have their specific steps completed
    private var completedOnboarding: Bool {
        return OnboardingStep.isOnboardingComplete
    }

    private var grantedAccessibility: Bool {
        accessibilityPermissionManager.accessibilityPermissionStatus == .granted
    }

    private var grantedScreenshotPermission: Bool {
        return self.screenRecordingPermissionManager.isScreenRecordingEnabled
    }

    private var grantedMicrophone: Bool {
        return self.microphoneInputManager.hasPermission
    }

    // MARK: - Private Variables: Buttons

    private var skipOnboardingButton: SectionButton {
        return SectionButton(
            text: String.localized("Skip", table: "Settings"),
            color: Color.S_4,
            disabled: false
        ) {
            self.currentOnboardingStep = .complete
        }
    }

    private var continueOnboardingButton: SectionButton {
        return SectionButton(
            text: self.completedOnboarding ? String.localized("Completed", table: "Settings") : String.localized("Complete", table: "Settings"),
            color: self.completedOnboarding ? Color.S_3 : Color.blue,
            disabled: self.completedOnboarding
        ) {
            self.launchOnboarding()
        }
    }

    private var skipDemoButton: SectionButton {
        return SectionButton(
            text: String.localized("Skip", table: "Settings"),
            color: Color.S_4,
            disabled: false
        ) {
            AnalyticsManager.Transcription.Onboarding.demoSkipped(source: "settings_setup")
            Defaults[.dictationDemoCompleted] = true
        }
    }

    private var completeDemoButton: SectionButton {
        return SectionButton(
            text: self.dictationDemoCompleted ? String.localized("Completed", table: "Settings") : String.localized("Complete", table: "Settings"),
            color: self.dictationDemoCompleted ? Color.S_3 : Color.blue,
            disabled: self.dictationDemoCompleted
        ) {
            self.launchDemo()
        }
    }

    private var grantAccessibilityButton: SectionButton {
        return SectionButton(
            text: self.grantedAccessibility ? String.localized("Granted", table: "Settings") : String.localized("Grant Access", table: "Settings"),
            color: self.grantedAccessibility ? Color.S_3 : Color.blue,
            disabled: self.grantedAccessibility
        ) {
            self.accessibilityPermissionManager.requestPermission()
        }
    }

    private var grantMicrophoneButton: SectionButton {
        return SectionButton(
            text: self.grantedMicrophone ? String.localized("Granted", table: "Settings") : String.localized("Grant Access", table: "Settings"),
            color: self.grantedMicrophone ? Color.S_3 : Color.blue,
            disabled: self.grantedMicrophone
        ) {
            Task {
                await self.microphoneInputManager.requestPermissionOrOpenSettings()
            }
        }
    }

    private var grantScreenshotsButton: SectionButton {
        return SectionButton(
            text: self.grantedScreenshotPermission ? String.localized("Granted", table: "Settings") : String.localized("Grant Access", table: "Settings"),
            color: self.grantedScreenshotPermission ? Color.S_3 : Color.blue,
            disabled: self.grantedScreenshotPermission
        ) {
            Task {
                _ = await self.screenRecordingPermissionManager.requestScreenRecordingPermission()
            }
        }
    }

    // MARK: - Private Functions

    /// Launches onboarding at the appropriate step based on current state
    private func launchOnboarding() {
        guard let firstValidStep = OnboardingStep.steps.first,
              firstValidStep != .complete
        else {
            return
        }

        onboardingWindowManager.showWindow(startingAt: firstValidStep)
    }

    /// Opens the dictation demo standalone. Enables Smart Cleanup first if it's off (the demo
    /// showcases it), then presents the demo-only window.
    private func launchDemo() {
        // Through the shared launcher so this entry point gets the same treatment as Home's "Try it
        // now": prerequisites switched on *and restored afterwards*, and the demo presented only once
        // the models are ready (presenting immediately would show steps that can't transcribe).
        DictationDemoLauncher.shared.launch()
    }

    // MARK: - Body

    var body: some View {
        SettingsTitleView(
            text: String.localized("Complete the setup list to ensure Cloudless works seamlessly.", table: "Settings")
        )

        requiredSection
        recommendedSection
    }

    // MARK: - Child Components: Required Section

    private var requiredSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Required", table: "Settings"))) {
            section(
                title: String.localized("Accessibility Permission", table: "Settings"),
                caption: String.localized("This allows Cloudless paste transcript into text fields.", table: "Settings"),
                status: requiredStatus(met: self.grantedAccessibility),
                buttons: [self.grantAccessibilityButton]
            )

            if transcriptionEnabled {
                DividerHorizontal()

                section(
                    title: String.localized("Microphone Permission", table: "Settings"),
                    caption: String.localized("Required for voice dictation to work. You'll need to quit & reopen Cloudless to activate permission.", table: "Settings"),
                    status: requiredStatus(met: self.grantedMicrophone),
                    buttons: [self.grantMicrophoneButton]
                )
            }
        }
    }

    // MARK: - Child Components: Recommended Section

    private var recommendedSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Recommended", table: "Settings"))) {
            section(
                title: String.localized("Complete Onboarding", table: "Settings"),
                caption: String.localized("A quick guide to help you get started.", table: "Settings"),
                status: recommendedStatus(done: self.completedOnboarding),
                buttons: self.completedOnboarding ?
                    [self.continueOnboardingButton] :
                    [self.skipOnboardingButton, self.continueOnboardingButton]
            )

            if transcriptionEnabled {
                DividerHorizontal()

                section(
                    title: String.localized("Complete Demo", table: "Settings"),
                    caption: String.localized("Learn how to use Cloudless.", table: "Settings"),
                    status: recommendedStatus(done: self.dictationDemoCompleted),
                    buttons: self.dictationDemoCompleted ?
                        [self.completeDemoButton] :
                        [self.skipDemoButton, self.completeDemoButton]
                )
            }

            DividerHorizontal()

            section(
                title: String.localized("Screenshots Permission", table: "Settings"),
                caption: String.localized("Get better & more relevant suggestions (you'll need to quit & reopen Cloudless to activate permission)", table: "Settings"),
                status: recommendedStatus(done: self.grantedScreenshotPermission),
                buttons: [self.grantScreenshotsButton]
            )
        }
    }

    // MARK: - Child Components: Section

    struct SectionStatus {
        let icon: ImageResource
        let color: Color
    }

    struct SectionButton: Equatable {
        let id: UUID
        let text: String
        let color: Color
        let disabled: Bool
        let action: () -> Void

        init(
            text: String,
            color: Color,
            disabled: Bool,
            action: @escaping () -> Void
        ) {
            self.id = UUID()
            self.text = text
            self.color = color
            self.disabled = disabled
            self.action = action
        }

        static func == (lhs: SectionButton, rhs: SectionButton) -> Bool {
            return lhs.id == rhs.id
        }
    }

    /// Red when an enabled permission is missing, lime once granted.
    private func requiredStatus(met: Bool) -> SectionStatus {
        return SectionStatus(
            icon: met ? .checkCircle : .warningCircle,
            color: met ? Color.lime400 : Color.red500
        )
    }

    /// Amber while incomplete, lime once done.
    private func recommendedStatus(done: Bool) -> SectionStatus {
        return SectionStatus(
            icon: done ? .checkCircle : .warningCircle,
            color: done ? Color.lime400 : Color.orange500
        )
    }

    private func section(
        title: String,
        caption: String,
        status: SectionStatus? = nil,
        buttons: [SectionButton]
    ) -> some View {
        SettingsPageSubsection(
            horizontal: .init(
                alignment: .top,
                spacing: 8
            ),
            header: .init(
                title: title,
                subtitle: caption
            ),
            imageResource: status != nil ? .init(
                resource: status!.icon,
                color: status!.color
            ) : nil
        ) {
            ForEach(buttons, id: \.id) { button in
                SimpleButton(
                    disabled: button.disabled,
                    text: button.text,
                    action: button.action,
                    background: button.color
                )
            }
        }
    }
}
