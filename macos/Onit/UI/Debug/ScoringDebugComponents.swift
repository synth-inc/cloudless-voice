// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringDebugComponents.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-17.
//

#if DEBUG

import SwiftUI

// MARK: - Shared Color Constants

/// Accent green used across scoring debug views.
let scoringAccentGreen = Color(red: 0.10, green: 0.52, blue: 0.22)

// MARK: - Score Heatmap Colors

/// Returns a background color for a token chip based on Score value.
/// Green scale: lighter = lower Score (confident), darker = higher Score (surprising).
func scoreChipColor(for score: Double?) -> Color {
    guard let score else { return Color(NSColor.controlBackgroundColor) }
    switch score {
    case ..<2.0:  return Color(red: 0.86, green: 0.97, blue: 0.86)
    case ..<4.0:  return Color(red: 0.69, green: 0.90, blue: 0.69)
    case ..<7.0:  return Color(red: 0.42, green: 0.74, blue: 0.42)
    default:      return Color(red: 0.13, green: 0.50, blue: 0.18)
    }
}

/// Returns a text color for a token chip based on Score value.
func scoreTextColor(for score: Double?) -> Color {
    guard let score else { return .primary }
    return score >= 7.0 ? .white : Color(red: 0.08, green: 0.18, blue: 0.08)
}

// MARK: - Score Token Chip Flow

/// Wrapping flow of per-token Score chips, filtering out BOS tokens.
struct ScoreTokenChipFlow: View {
    let tokens: [CleanupDebugInfo.TokenScore]
    var showScoreValues: Bool = false
    var spacing: CGFloat = 2.0
    var fontSize: CGFloat = 9

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if token.t != "<|begin_of_text|>" {
                    ScoreTokenChip(token: token, showScoreValue: showScoreValues, fontSize: fontSize)
                }
            }
        }
    }
}

// MARK: - Score Token Chip

/// Single token chip colored by Score heatmap.
struct ScoreTokenChip: View {
    let token: CleanupDebugInfo.TokenScore
    var showScoreValue: Bool = false
    var fontSize: CGFloat = 9

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: token.t.replacingOccurrences(of: " ", with: "·"))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(scoreTextColor(for: token.score))
                .lineLimit(1)
            if showScoreValue, let score = token.score {
                Text(String(format: "%.2f", score))
                    .font(.system(size: max(fontSize - 3, 7), design: .monospaced))
                    .foregroundColor(scoreTextColor(for: token.score).opacity(0.8))
            }
        }
        .padding(.horizontal, showScoreValue ? 4 : 3)
        .padding(.vertical, showScoreValue ? 2 : 1)
        .background(scoreChipColor(for: token.score))
        .cornerRadius(showScoreValue ? 3 : 2)
        .overlay {
            if showScoreValue {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            }
        }
    }
}

#endif
