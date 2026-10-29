// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RequestFixInfoFooter.swift
//  Onit
//
//  Created by Loyd Kim on 5/19/26.
//

import SwiftUI

struct RequestFixInfoFooter: View {
    // MARK: - Types

    enum Mode {
        /// Active Save & request fix or Request fix CTA is reachable.
        case canRequestFix
        /// Current correction's `everUploadedAt` is non-nil.
        case alreadyRequestedFix
    }

    // MARK: - Properties

    let mode: Mode
    let learnMoreAction: () -> Void

    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @State private var hoveredLearnMore: Bool = false
    
    // MARK: - Private Variables
    
    private var messageText: String {
        switch mode {
        case .canRequestFix:
            return String.localized(
                "Requesting a fix will share this correction with the Cloudless team.",
                table: "Transcription"
            )
        case .alreadyRequestedFix:
            return String.localized(
                "Fix requested.", 
                table: "Transcription"
            )
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "info.circle")
                .styleText(
                    size: 12,
                    color: Color.T_2
                )

            Text(messageText)
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.T_2
                )

            learnMoreButton
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components

    private var learnMoreButton: some View {
        Button(action: learnMoreAction) {
            Text(String.localized("Learn More", table: "Transcription"))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.info500,
                    underline: hoveredLearnMore
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover {
            hoveredLearnMore = $0
        }
        .addAnimation(dependency: hoveredLearnMore)
    }
}
