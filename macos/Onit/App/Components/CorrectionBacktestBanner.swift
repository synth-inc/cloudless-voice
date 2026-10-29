// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionBacktestBanner.swift
//  Onit
//
//  Banner above the Transcripts list inviting the user to replay their
//  corrected transcripts through other ASR models to find the most accurate
//  one for their voice. Visuals match the dictionary model-nudge banner
//  (special2 bg, T_8 stroke, T_9 button).
//

import SwiftUI

struct CorrectionBacktestBanner: View {

    /// Opens the backtest flow sheet (owned by `AppWindowPages`).
    @Binding var showBacktestSheet: Bool

    /// Observed so the banner appears as soon as the first correction is
    /// saved and the count in the subtitle stays live.
    @ObservedObject private var historyManager = TranscriptionHistoryManager.shared

    @State private var isHoveredTestNow = false
    @State private var isPressedTestNow = false

    /// Replayable ones only: offering a test the sheet then refuses (file transcripts
    /// are not replayed) would be a dead end.
    private var correctionsCount: Int { historyManager.replayableCorrectedCount }
    private var threshold: Int { CorrectionBacktestRunner.minCases }

    var body: some View {
        if correctionsCount >= threshold {
            // Enough corrections - invite the test.
            bannerContainer {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String.localized("Use your corrections to test different models", table: "App"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color.S_0)
                    Text(String.localized(
                        "Replay your %@ corrected transcripts through other models to find the most accurate one for your voice.",
                        table: "App",
                        String(correctionsCount)
                    ))
                    .styleText(size: 13, weight: .regular, color: Color.T_2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                testNowButton
            }
        } else if historyManager.historyCount > 0 {
            // Below the threshold - this banner is the reason to correct more.
            // Shows concrete progress toward unlocking model testing.
            bannerContainer {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String.localized("Find the most accurate model for your voice", table: "App"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color.S_0)
                    Text(String.localized(
                        "Correct %@ more transcripts to unlock model testing (%@/%@). Click a transcript below and fix its mistakes - Cloudless can then replay them through other models to see which hears you best.",
                        table: "App",
                        String(threshold - correctionsCount),
                        String(correctionsCount),
                        String(threshold)
                    ))
                    .styleText(size: 13, weight: .regular, color: Color.T_2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func bannerContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(16)
        .background(Color.special2)
        .addBorder(cornerRadius: 14, stroke: Color.T_8)
    }

    private var testNowButton: some View {
        Text(String.localized("Test now", table: "App"))
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(Color.S_0)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .addButtonEffects(
                background: Color.T_9,
                hoverBackground: Color.T_8,
                cornerRadius: 9,
                isHovered: $isHoveredTestNow,
                isPressed: $isPressedTestNow
            ) {
                showBacktestSheet = true
            }
            .help(String.localized("Compare model accuracy on your own corrected transcripts", table: "App"))
    }
}
