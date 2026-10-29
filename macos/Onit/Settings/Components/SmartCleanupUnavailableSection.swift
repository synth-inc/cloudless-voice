// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupUnavailableSection.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Shown on the Smart Cleanup page of a fully open build (`scripts/build-fully-open.sh`),
//  which has no Smart Cleanup: says where to get it. Renders nothing in the official
//  build. Doesn't depend on the closed TranscriptionCleanup library.
//

import SwiftUI

struct SmartCleanupUnavailableSection: View {
    var body: some View {
        if !SmartCleanupAvailability.isCompiledIn {
            SettingsPageSection {
                SettingsPageSubsection(
                    header: .init(
                        title: String.localized("Smart Cleanup", table: "Settings"),
                        subtitle: String.localized("Included in the official app", table: "Settings")
                    )
                ) {
                    Spacer()

                    SimpleButton(text: String.localized("Get the official app", table: "Settings")) {
                        NSWorkspace.shared.open(SmartCleanupAvailability.officialAppURL)
                    }
                }
            }
        }
    }
}
