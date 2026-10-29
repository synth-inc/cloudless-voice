// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictationStatsBar.swift
//  Onit
//
//  Created by Loyd Kim on 4/29/26.
//

import SwiftUI

struct DictationStatsBar: View {
    // MARK: - Properties

    @Binding var showDictationStatsSheet: Bool

    // MARK: - Observables

    @ObservedObject private var transcriptionHistoryManager = TranscriptionHistoryManager.shared

    // MARK: - States

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    // MARK: - Private Variables
    
    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private let cornerRadius: CGFloat = 22
    
    // MARK: - Private Variables: Lifetime Stats

    private var lifetimeStats: LifetimeTranscriptionStats? {
        return transcriptionHistoryManager.lifetimeStats
    }

    private var totalWords: Int {
        return lifetimeStats?.totalWords ?? 0
    }

    private var timeSavedValueAndUnit: (value: String, unit: String) {
        if isLocked {
            return (
                String(format: "%.1f", 36.9),
                String.localized("h", table: "App")
            )
        }

        let timeSavedDisplay = lifetimeStats?.timeSavedDisplay() ?? .seconds(0)
        
        switch timeSavedDisplay {
        case .hours(let hours):
            return (
                String(format: "%.1f", hours),
                String.localized("h", table: "App")
            )
        case .minutes(let minutes):
            return (
                String(format: "%.1f", minutes),
                String.localized("m", table: "App")
            )
        case .seconds(let seconds):
            return (
                "\(seconds)",
                String.localized("s", table: "App")
            )
        }
    }

    private var wordsPerMinute: Int {
        return Int((lifetimeStats?.averageWPM ?? 0).rounded())
    }

    private var appsUsedCount: Int {
        return lifetimeStats?.distinctAppsUsedCount ?? 0
    }

    private var isLoadingLifetimeDictationStats: Bool {
        return lifetimeStats == nil
    }

    // MARK: - Private Variables: Lock Statuses

    private var isLocked: Bool {
        return
            !isLoadingLifetimeDictationStats &&
            totalWords < LifetimeTranscriptionStats.wordCountUnlockThreshold
    }

    private var isUnlocked: Bool {
        return
            !isLoadingLifetimeDictationStats &&
            !isLocked
    }

    private var remainingWordCountToUnlock: Int {
        return max(0, LifetimeTranscriptionStats.wordCountUnlockThreshold - totalWords)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            lifetimeDictationStatsView
            shareYourStatsView
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, isLocked ? 28 : 12)
        .frame(maxWidth: .infinity)
        .overlay(lockedPillOverlay)
        .addBorder(
            cornerRadius: cornerRadius,
            stroke: (isUnlocked && isHovered) ? Color.T_3 : Color.T_4,
            dotted: true
        )
        .addButtonEffects(
            background: Color.cloud,
            hoverBackground: Color.cloud.opacity(0.7),
            cornerRadius: cornerRadius,
            disabled: isLoadingLifetimeDictationStats,
            shouldFadeOnClick: false,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            AnalyticsManager.AppHome.statsBarClicked()
            showDictationStatsSheet = true
        }
        .allowsHitTesting(!isLocked)
    }
    
    // MARK: - Child Components: Locked Pill Overlay

    @ViewBuilder
    private var lockedPillOverlay: some View {
        if isLocked {
            HStack(spacing: 4) {
                Text(
                    String.localized(
                        "%d words left to unlock stats",
                        table: "App",
                        remainingWordCountToUnlock
                    )
                )
                .styleText(
                    color: Color.black
                )
                Text("🔥")
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white)
            .addBorder(
                cornerRadius: 999,
                stroke: Color.T_8
            )
        }
    }

    // MARK: - Lifetime Dictation Stats View

    private var lifetimeDictationStatsView: some View {
        HStack(alignment: .center, spacing: 0) {
            statColumn(
                label: String.localized("TOTAL WORDS", table: "App"),
                value: { totalWordsView }
            )
            statDivider
            statColumn(
                label: String.localized("TIME SAVED", table: "App"),
                isTimeSaved: true,
                value: { timeSavedView }
            )
            statDivider
            statColumn(
                label: String.localized("AVG. SPEED", table: "App"),
                value: { averageSpeedView }
            )
            statDivider
            statColumn(
                label: String.localized("APPS USED", table: "App"),
                value: { appsUsedView }
            )
        }
        .frame(maxWidth: .infinity)
        .blur(radius: isLocked ? 3 : 0)
    }

    private func statColumn<Content: View>(
        label: String,
        isTimeSaved: Bool = false,
        @ViewBuilder value: () -> Content
    ) -> some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(alignment: .center, spacing: 4) {
                Text(label)
                    .styleText(
                        size: 11,
                        weight: .regular,
                        color: Color.black.opacity(0.6),
                    )
                
                if isTimeSaved {
                    StatColumnInfoView(
                        hoverText: String.localized("Compared to the average\ntyping speed of 45 WPM", table: "App")
                    )
                }
            }
            
            value()
        }
        .frame(maxWidth: .infinity)
    }
    
    private struct StatColumnInfoView: View {
        let hoverText: String
        
        @State private var showToolipPopover: Bool = false
        
        var body: some View {
            Image(systemName: "info.circle")
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.black.opacity(0.6),
                )
                .onHover { isHovered in
                    showToolipPopover = isHovered
                }
                .popover(
                    isPresented: $showToolipPopover,
                    arrowEdge: .bottom
                ) {
                    Text(hoverText)
                        .padding(12)
                }
        }
    }

    private var statDivider: some View {
        Path { path in
            path.move(to: CGPoint(x: 0.5, y: 0))
            path.addLine(to: CGPoint(x: 0.5, y: 49))
        }
        .stroke(
            Color.black.opacity(0.2),
            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
        )
        .frame(width: 1, height: 49)
    }

    @ViewBuilder
    private var totalWordsView: some View {
        if isLoadingLifetimeDictationStats {
            valueShimmer
        } else {
            let value = isLocked ? 200678 : totalWords
            HStack(spacing: 4) {
                Text("🔥")
                    .font(.system(size: 16))
                Text(
                    Self.numberFormatter.string(
                        from: NSNumber(value: value)
                    ) ?? "\(value)"
                )
                .styleText(
                    fontFamily: .inter,
                    size: 19,
                    weight: .regular,
                    color: Color.black
                )
            }
        }
    }

    @ViewBuilder
    private var timeSavedView: some View {
        if isLoadingLifetimeDictationStats {
            valueShimmer
        } else {
            valueWithUnit(
                value: timeSavedValueAndUnit.value,
                unit: timeSavedValueAndUnit.unit,
                spacing: 2
            )
        }
    }

    @ViewBuilder
    private var averageSpeedView: some View {
        if isLoadingLifetimeDictationStats {
            valueShimmer
        } else {
            valueWithUnit(
                value: "\(isLocked ? 160 : wordsPerMinute)",
                unit: String.localized("WPM", table: "App"),
                spacing: 6
            )
        }
    }

    @ViewBuilder
    private var appsUsedView: some View {
        if isLoadingLifetimeDictationStats {
            valueShimmer
        } else {
            let value = isLocked ? 12 : appsUsedCount
            valueWithUnit(
                value: "\(value)",
                unit: value == 1
                    ? String.localized("app", table: "App")
                    : String.localized("apps", table: "App"),
                spacing: 6
            )
        }
    }
    
    private var valueShimmer: some View {
        Shimmer(
            width: 60,
            height: 19,
            cornerRadius: 4
        )
    }

    private func valueWithUnit(
        value: String,
        unit: String,
        spacing: CGFloat
    ) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: spacing) {
            Text(value)
                .styleText(
                    fontFamily: .inter,
                    size: 19,
                    weight: .regular,
                    color: Color.black
                )
            Text(unit)
                .styleText(
                    fontFamily: .inter,
                    size: 16,
                    weight: .regular,
                    color: Color.black
                )
        }
    }

    // MARK: - Share Button

    @ViewBuilder
    private var shareYourStatsView: some View {
        if !isLocked {
            HStack(alignment: .center, spacing: 5) {
                Text(String.localized("Share your stats", table: "App"))
                    .styleText(
                        weight: .regular,
                        color: Color.black
                    )
                
                Image(systemName: "arrowshape.turn.up.forward.fill")
                    .styleText(
                        size: 14,
                        color: Color.black.opacity(0.3)
                    )
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 36, alignment: .center)
            .background(Color.sky)
            .cornerRadius(9)
        }
    }
}
