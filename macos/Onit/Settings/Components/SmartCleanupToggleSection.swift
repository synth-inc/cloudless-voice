// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupToggleSection.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Smart Cleanup on or off, at the top of the Smart Cleanup page. Underneath, the
//  toggle picks the cleanup provider ("smart" or "none", `CleanupProviderID`);
//  the user's own model is the Rewrite stage, on its own page (`SettingsRewrite`).
//  A fully open build has no Smart Cleanup and shows
//  `SmartCleanupUnavailableSection` instead. Doesn't depend on the closed
//  TranscriptionCleanup library.
//

import SwiftUI

struct SmartCleanupToggleSection<Footer: View>: View {
    // MARK: - Observations

    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared

    // MARK: - Properties

    /// Shown under the toggle while Smart Cleanup is on.
    @ViewBuilder let footer: () -> Footer

    init(@ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.footer = footer
    }

    // MARK: - Body

    var body: some View {
        if SmartCleanupAvailability.isCompiledIn {
            SettingsPageSection {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Smart Cleanup", table: "Settings"),
                        subtitle: String.localized("Cleaned on your Mac by Cloudless.", table: "Settings")
                    ),
                    isOn: $transcriptionConfig.smartFormattingEnabled
                )

                if transcriptionConfig.smartFormattingEnabled {
                    DividerHorizontal()
                    footer()
                }
            }
        }
    }
}
