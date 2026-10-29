// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsRewrite.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-22.
//
//  Settings > Rewrite: after cleanup, each dictation can go to a model the user
//  runs or pays for, with their own instructions. The toggle is the only thing on
//  the page until it's on; the model's settings (`BYOKCleanupSettingsView`) are
//  shared with nothing else. Doesn't depend on the closed TranscriptionCleanup
//  library, so it is the same in the fully open build.
//

import SwiftUI

struct SettingsRewrite: View {
    // MARK: - Observations

    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared

    // MARK: - Private Variables

    private var subtitle: String {
        transcriptionConfig.cleanupProviderID == CleanupProviderID.smart
            ? String.localized("Runs after Smart Cleanup on its result. If it fails, you get the Smart Cleanup text.", table: "Settings")
            : String.localized("Runs on your words as transcribed. If it fails, you get them as dictated.", table: "Settings")
    }

    // MARK: - Body

    var body: some View {
        Group {
            SettingsTitleView(
                text: String.localized("Rewrite sends each dictation to a model you run or pay for, with your own instructions: fix the wording, change the tone, translate, or format it for the app you're in. Free in Cloudless.", table: "Settings")
            )

            SettingsPageSection {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Rewrite with your own model", table: "Settings"),
                        subtitle: subtitle
                    ),
                    isOn: $transcriptionConfig.rewriteEnabled
                )
            }

            if transcriptionConfig.rewriteEnabled {
                BYOKCleanupSettingsView()
            }
        }
    }
}
