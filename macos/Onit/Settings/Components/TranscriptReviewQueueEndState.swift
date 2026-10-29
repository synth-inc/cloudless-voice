// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptReviewQueueEndState.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import Defaults
import SwiftUI

/// End-of-queue screen displayed inside the review modal once the user has
/// stepped through every item in the current session.
///
/// Two visual variants:
/// - `.allReviewed` - every transcript in the database is now reviewed; show
///   only "Done".
/// - `.queueComplete` - the current queue is finished but unreviewed items
///   remain elsewhere; show "Done" and "Keep reviewing".
///
/// Mid-session close dismisses the modal silently rather than surfacing a
/// stats/recap interstitial - only true end-of-queue triggers this view.
struct TranscriptReviewQueueEndState: View {
    enum Mode {
        case allReviewed
        case queueComplete
    }

    let mode: Mode
    let totalReviewed: Int
    let totalCorrected: Int
    let totalCount: Int
    let currentAccountId: String?
    let onDone: () -> Void
    let onKeepReviewing: () -> Void

    @ObservedObject private var localization = LocalizationManager.shared

    @Default(.transcriptionContributionsByAccount) private var contributionsByAccount

    private var contributionsCount: Int {
        currentAccountId.flatMap { contributionsByAccount[$0] } ?? 0
    }

    private var completionPercent: Int {
        guard totalCount > 0 else { return 0 }
        if totalReviewed >= totalCount { return 100 }
        return Int(floor(Double(totalReviewed) / Double(totalCount) * 100))
    }

    private var leftCount: Int {
        max(0, totalCount - totalReviewed)
    }

    private var title: String {
        switch mode {
        case .allReviewed:
            return String.localized("You've reviewed all transcripts!", table: "Transcription")
        case .queueComplete:
            return String.localized("Review queue complete!", table: "Transcription")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .styleText(
                        size: 18
                    )

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        statCard(
                            label: String.localized("Total Reviewed", table: "Transcription"),
                            value: "\(totalReviewed)",
                            sublabel: String.localized(
                                "(%lld corrections)",
                                table: "Transcription",
                                totalCorrected
                            )
                        )

                        statCard(
                            label: String.localized("Completion", table: "Transcription"),
                            value: "\(completionPercent)%",
                            sublabel: String.localized(
                                "(%lld left)",
                                table: "Transcription",
                                leftCount
                            )
                        )
                    }

                    if contributionsCount > 0 {
                        contributingBadge
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(16)

            actions
        }
        .id(localization.currentLanguage)
    }

    private var contributingBadge: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(Color.lime400)
                .frame(width: 7, height: 7)
            Text(
                String.localized(
                    "%lld corrections contributed",
                    table: "Transcription",
                    contributionsCount
                )
            )
            .styleText(
                color: Color.lime400
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 50, alignment: .center)
        .background(Color.lime400.opacity(0.08))
        .addBorder(
            cornerRadius: 14,
            stroke: Color.lime400.opacity(0.25)
        )
    }

    private func statCard(label: String, value: String, sublabel: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Text(label)
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
            Text(value)
                .styleText(
                    size: 19,
                    weight: .regular
                )
            Text(sublabel)
                .styleText(
                    size: 13,
                    weight: .regular
                )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(8)
        .background(Color.T_9)
        .cornerRadius(14)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            
            TextButton(
                text: String.localized("Done", table: "Transcription"),
                colorConfig: .init(
                    background: Color.T_9,
                    hoverBackground: Color.T_8
                ),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                )
            ) {
                onDone()
            }

            if mode == .queueComplete {
                TextButton(
                    type: .primary,
                    text: String.localized("Keep reviewing", table: "Transcription"),
                    sizeConfig: .init(
                        horizontalPadding: 12,
                        height: 36
                    )
                ) {
                    onKeepReviewing()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56, alignment: .center)
        .addBorder(
            sides: .top,
            stroke: Color.T_7
        )
    }
}
