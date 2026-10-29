// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionBacktestResultsView.swift
//  Onit
//
//  Results step of the correction backtest - the in-app port of the offline
//  benchmark comparison viewer: per-model mean-WER stat strip, then one card
//  per correction with the user's correction as the target and a
//  classification-tinted block per model with word-level diff highlighting.
//

import SwiftUI

// MARK: - Classification

/// WER buckets matching the offline benchmark viewer: good ≤15%,
/// acceptable ≤35%, poor above.
enum BacktestClassification {
    case good
    case acceptable
    case poor

    init(wer: Double) {
        if wer <= 0.15 {
            self = .good
        } else if wer <= 0.35 {
            self = .acceptable
        } else {
            self = .poor
        }
    }

    var color: Color {
        switch self {
        case .good: return Color.green
        case .acceptable: return Color.orange500
        case .poor: return Color.red500
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .good: return String.localized("Good", table: "App")
        case .acceptable: return String.localized("Acceptable", table: "App")
        case .poor: return String.localized("Poor", table: "App")
        }
    }
}

// MARK: - Results View

struct CorrectionBacktestResultsView: View {

    @ObservedObject var runner: CorrectionBacktestRunner
    let models: [ASRModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            legend
            statStrip

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(runner.results.enumerated()), id: \.element.id) { index, result in
                        caseCard(index: index + 1, result: result)
                    }
                }
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String.localized(
                "Scored against your correct transcripts · WER = word error rate · good ≤15% · acceptable ≤35% · poor >35%. Note, this only shows raw model output for cleaner results (i.e. no Smart Cleanup, Dictionary, or formatting applied)",
                table: "App"
            ))
            .styleText(size: 13, weight: .regular, color: Color.T_2)
        }
    }

    // MARK: - Stat Strip

    private var statStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(models) { model in
                    statCard(
                        name: model.displayName,
                        sub: scoredSubtitle(modelId: model.id),
                        wer: runner.meanWER(modelId: model.id)
                    )
                }
            }
        }
    }

    /// Coverage denominator: how many cases this model actually scored vs the
    /// total. A model that failed most cases reads "scored 3/50", so a
    /// flattering mean over its few successes can't be mistaken for a win.
    private func scoredSubtitle(modelId: String) -> String {
        let scored = runner.scoredCount(modelId: modelId)
        let total = runner.scoredCaseCount
        if scored < total {
            return String.localized("scored %@/%@", table: "App", String(scored), String(total))
        }
        return String.localized("replayed", table: "App")
    }

    private func statCard(name: String, sub: String, wer: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .styleText(size: 11.5, weight: .semibold)
                .lineLimit(1)
            Text(wer.map { Self.percentLabel($0) } ?? "-")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(wer.map { Self.statColor($0) } ?? Color.T_2)
            Text(sub)
                .styleText(size: 9.5, weight: .regular, color: Color.T_2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(minWidth: 110, alignment: .leading)
        .background(Color.T_9)
        .addBorder(cornerRadius: 12, stroke: Color.T_8)
    }

    /// Header-stat thresholds from the benchmark viewer (looser than the
    /// per-case buckets: a *mean* of 25% already implies many poor cases).
    private static func statColor(_ wer: Double) -> Color {
        if wer <= 0.25 { return Color.green }
        if wer <= 0.40 { return Color.orange500 }
        return Color.red500
    }

    private static func percentLabel(_ wer: Double) -> String {
        "\(Int((wer * 100).rounded()))%"
    }

    // MARK: - Case Cards

    private func caseCard(index: Int, result: CorrectionBacktestRunner.CaseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(index)")
                    .styleText(size: 11, weight: .medium, color: Color.T_4)
                Text(String.localized("Your correction", table: "App").uppercased())
                    .styleText(size: 10, weight: .semibold, color: Color.T_2)
                    .kerning(0.5)
            }

            Text(result.reference)
                .styleText(size: 12.5, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(models) { model in
                let run = result.runs[model.id]
                modelBlock(
                    name: model.displayName,
                    transcript: run?.transcript,
                    wer: run?.wer,
                    reference: result.reference
                )
            }
        }
        .padding(12)
        .background(Color.special1)
        .addBorder(cornerRadius: 14, stroke: Color.T_8)
    }

    @ViewBuilder
    private func modelBlock(
        name: String,
        transcript: String?,
        wer: Double?,
        reference: String
    ) -> some View {
        let classification = wer.map(BacktestClassification.init(wer:))

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(name)
                    .styleText(size: 12, weight: .semibold)
                    .lineLimit(1)
                Spacer()
                if let classification, let wer {
                    classificationPill(classification)
                    werChip(wer)
                }
            }

            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diffText(reference: reference, actual: transcript, classification: classification)
            } else {
                Text(transcript == nil
                    ? String.localized("(transcription failed)", table: "App")
                    : String.localized("(no output)", table: "App"))
                    .styleText(size: 12, italic: true, weight: .regular, color: Color.T_4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((classification?.color ?? Color.T_4).opacity(0.06))
        .addBorder(cornerRadius: 10, stroke: Color.T_8)
    }

    private func classificationPill(_ classification: BacktestClassification) -> some View {
        Text(classification.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color.S_0)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(classification.color.opacity(0.25))
            .cornerRadius(9)
    }

    private func werChip(_ wer: Double) -> some View {
        Text("WER \(Self.percentLabel(wer))")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.T_2)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color.T_9)
            .cornerRadius(9)
    }

    /// Word-level diff: tokens of the model output that aren't part of the
    /// longest common subsequence with the correction get the error tint.
    /// Good outputs render plain - highlighting one or two near-miss tokens
    /// on an otherwise clean transcript reads as noise.
    @ViewBuilder
    private func diffText(
        reference: String,
        actual: String,
        classification: BacktestClassification?
    ) -> some View {
        if classification == .good {
            Text(actual)
                .styleText(size: 12, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(highlightedDiff(reference: reference, actual: actual))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func highlightedDiff(reference: String, actual: String) -> AttributedString {
        let tokens = BacktestMetrics.wordDiff(expected: reference, actual: actual)
        var output = AttributedString()
        for (index, entry) in tokens.enumerated() {
            var token = AttributedString(entry.token)
            if entry.isError {
                token.foregroundColor = Color.red500
                token.backgroundColor = Color.red500.opacity(0.12)
            } else {
                token.foregroundColor = Color.S_0
            }
            output += token
            if index < tokens.count - 1 {
                output += AttributedString(" ")
            }
        }
        return output
    }
}
