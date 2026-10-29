// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionList.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Defaults
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// Scrollable list of transcripts grouped into Figma-spec section cards, with
/// inline pagination and dual empty states. Reads list state and routes row
/// callbacks (refresh, delete, review) through `TranscriptionsViewModel`.
struct TranscriptionList: View {
    @ObservedObject var viewModel: TranscriptionsViewModel

    @ObservedObject private var localization = LocalizationManager.shared

    @Default(TranscriptionConfigKeys.showTranscriptEdits) private var showEdits

    /// Flat list entry - section card visuals (rounded corners across
    /// the section, dividers between rows) are rebuilt per-row from the
    /// `Position` so we can keep one ForEach over a single linear array.
    /// Nested ForEach inside a section card would make the lazy stack
    /// reason about identity less efficiently.
    private enum ListEntry: Identifiable {
        enum Position {
            case only, first, middle, last
        }

        case header(id: Date, label: String)
        case row(item: TranscriptionHistory, position: Position, indexInHistoryItems: Int)

        var id: AnyHashable {
            switch self {
            case .header(let date, _):
                return AnyHashable("h-\(date.timeIntervalSince1970)")
            case .row(let item, _, _):
                return AnyHashable(item.id ?? -1)
            }
        }
    }

    private struct HistoryItemsDateGroup {
        let id: Date
        let label: String
        var items: [TranscriptionHistory]
    }

    private var historyItemsDateGroups: [HistoryItemsDateGroup] {
        let calendar = Calendar.current
        var groups: [Date: HistoryItemsDateGroup] = [:]
        var orderedKeys: [Date] = []

        for historyItem in viewModel.historyItems {
            let startOfDay = calendar.startOfDay(for: historyItem.timestamp)

            if groups[startOfDay] == nil {
                let label = DateHelpers.formatDateToRelativeDay(historyItem.timestamp)
                groups[startOfDay] = HistoryItemsDateGroup(id: startOfDay, label: label, items: [])
                orderedKeys.append(startOfDay)
            }
            groups[startOfDay]?.items.append(historyItem)
        }

        return orderedKeys.compactMap { groups[$0] }
    }

    private var nonDateGroupSectionTitle: String {
        switch viewModel.currentSortOrder {
        case .audioDuration:
            return String.localized("Audio Duration: Longest to Shortest", table: "Transcription")
        case .appName:
            return String.localized("App Name: A-Z", table: "Transcription")
        default:
            return ""
        }
    }

    /// Date-keyed sort orders surface a date section header above each
    /// group, so rows can show time only. Other sort orders (audio
    /// duration, app name) flatten everything under a single header - the
    /// row timestamp must then carry the full date for context.
    private var useDateGroups: Bool {
        viewModel.currentSortOrder == .newest || viewModel.currentSortOrder == .oldest
    }

    private var listEntries: [ListEntry] {
        var entries: [ListEntry] = []

        if useDateGroups {
            // `historyItemsDateGroups` preserves the order of
            // `viewModel.historyItems`, so a running counter gives each row
            // its true index in the flat `historyItems` array.
            var cumulativeIndex = 0
            for group in historyItemsDateGroups {
                entries.append(.header(id: group.id, label: group.label))
                entries.append(contentsOf: rowEntries(for: group.items, startIndex: cumulativeIndex))
                cumulativeIndex += group.items.count
            }
        } else {
            let title = nonDateGroupSectionTitle
            if !title.isEmpty {
                entries.append(.header(id: Date.distantPast, label: title))
            }
            entries.append(contentsOf: rowEntries(for: viewModel.historyItems, startIndex: 0))
        }
        return entries
    }

    private func rowEntries(for items: [TranscriptionHistory], startIndex: Int) -> [ListEntry] {
        items.enumerated().map { index, item in
            let position: ListEntry.Position
            switch (items.count, index) {
            case (1, _): position = .only
            case (_, 0): position = .first
            case (let n, let i) where i == n - 1: position = .last
            default: position = .middle
            }
            return .row(item: item, position: position, indexInHistoryItems: startIndex + index)
        }
    }

    var body: some View {
        LoadingContainer(
            isLoading: viewModel.isLoadingFirstPage,
            loaderView: {
                VStack(alignment: .leading, spacing: 4) {
                    Shimmer(height: 120, cornerRadius: 16)
                    Shimmer(height: 120, cornerRadius: 16)
                    Shimmer(height: 120, cornerRadius: 16)
                }
            },
            loadedView: {
                Group {
                    if viewModel.historyItems.isEmpty && !viewModel.isLoadingNextPage {
                        emptyStateView
                    } else {
                        historyListView
                    }
                }
            }
        )
        .id(localization.currentLanguage)
    }

    private var historyListView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(listEntries.enumerated()), id: \.element.id) { index, entry in
                entryView(entry, isFirst: index == 0)
            }

            loadMoreView
                .padding(.top, 8)
            reachedBottomView
                .padding(.top, 8)
        }
        // Only padding-bottom: keeps a small breathing gap before the
        // load-more / reached-bottom affordances. The top is intentionally
        // flush so the header above sits at its natural distance (parent
        // VStack spacing) from the first row.
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func entryView(_ entry: ListEntry, isFirst: Bool) -> some View {
        switch entry {
        case .header(_, let label):
            sectionHeaderView(label: label, isFirst: isFirst)
                .id(entry.id)
        case .row(let item, let position, let indexInHistoryItems):
            rowEntryView(item: item, position: position)
                .id(entry.id)
                .onAppear {
                    viewModel.loadNextPageForInfiniteScrollIfNeeded(at: indexInHistoryItems)
                }
        }
    }

    /// `isFirst` is true for the very first list entry overall, not just
    /// the first row in a section. Subsequent date-group headers need
    /// breathing room above them so successive groups read as visually
    /// separate; the first header sits flush so the count row above
    /// (rendered by `TranscriptionHeader`) keeps its natural 12pt gap.
    @ViewBuilder
    private func sectionHeaderView(label: String, isFirst: Bool) -> some View {
        if !label.isEmpty {
            Text(label)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.T_2
                )
                // No leading padding: align with the left edge of the
                // section card below (the card's border sits flush at
                // the LazyVStack edge).
                .padding(.top, isFirst ? 0 : 16)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func rowEntryView(item: TranscriptionHistory, position: ListEntry.Position) -> some View {
        let isFirst = position == .first || position == .only
        let isLast = position == .last || position == .only
        let isNotFirst = position == .middle || position == .last

        VStack(spacing: 0) {
            if isNotFirst {
                DividerHorizontal()
                    // 4pt here + 8pt outer side padding = 12pt from the card
                    // edge, matching the original `TranscriptSectionCard`.
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }
            TranscriptListItem(
                historyItem: item,
                showEdits: showEdits,
                showFullDate: !useDateGroups,
                onRefresh: { viewModel.refreshHistoryItem($0) },
                onDelete: { viewModel.deleteHistoryItem($0) },
                onReviewRequest: { viewModel.reviewSeed = $0 }
            )
        }
        // Per Figma the section card has 8pt of internal padding on every
        // side; rows sit inside with full content width but with this
        // padding visible against the card edges. The card background and
        // border are still drawn on the outer frame so the visual card
        // continues to span all rows in the section seamlessly.
        .padding(.horizontal, 8)
        .padding(.top, isFirst ? 8 : 0)
        .padding(.bottom, isLast ? 8 : 0)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? 22 : 0,
                bottomLeadingRadius: isLast ? 22 : 0,
                bottomTrailingRadius: isLast ? 22 : 0,
                topTrailingRadius: isFirst ? 22 : 0
            )
            .fill(Color.special1)
        }
        .overlay {
            sectionCardBorder(isFirst: isFirst, isLast: isLast)
        }
    }

    /// Reproduces the `TranscriptSectionCard` 1pt `T_8` border across the
    /// flat list:
    /// - sides are stroked on every row, clipped to the card's rounded
    ///   shape so they don't bleed across the corner zones;
    /// - the top edge (with its rounded corners) is drawn only on the
    ///   first/only row;
    /// - the bottom edge (with its rounded corners) is drawn only on the
    ///   last/only row.
    /// Rows in the middle of a section therefore have sides only - no
    /// horizontal stroke that would double up with the inline divider.
    @ViewBuilder
    private func sectionCardBorder(isFirst: Bool, isLast: Bool) -> some View {
        let cardShape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 22 : 0,
            bottomLeadingRadius: isLast ? 22 : 0,
            bottomTrailingRadius: isLast ? 22 : 0,
            topTrailingRadius: isFirst ? 22 : 0
        )

        ZStack {
            // Side strokes, always present, clipped to the card so the
            // line doesn't run through the rounded corner zones.
            HStack(spacing: 0) {
                Rectangle().fill(Color.T_8).frame(width: 1)
                Spacer()
                Rectangle().fill(Color.T_8).frame(width: 1)
            }
            .clipShape(cardShape)

            // Top edge + rounded top corners.
            if isFirst {
                cardShape
                    .strokeBorder(Color.T_8, lineWidth: 1)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black.frame(height: 22)
                            Color.clear
                        }
                    }
            }

            // Bottom edge + rounded bottom corners.
            if isLast {
                cardShape
                    .strokeBorder(Color.T_8, lineWidth: 1)
                    .mask {
                        VStack(spacing: 0) {
                            Color.clear
                            Color.black.frame(height: 22)
                        }
                    }
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyStateView: some View {
        if viewModel.hasActiveFilter {
            noMatchesPlaceholder
        } else {
            NoTranscriptsPlaceholder()
        }
    }

    private var noMatchesPlaceholder: some View {
        TranscriptSectionCard {
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Color.S_0)
                    .frame(width: 32, height: 32, alignment: .center)
                    .background(Color.info500.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)

                Text(String.localized("No matches", table: "Transcription"))
                    .styleText(weight: .medium)

                Text(String.localized("Try clearing any filters", table: "Transcription"))
                    .styleText(
                        size: 12,
                        weight: .regular,
                        color: Color.T_2
                    )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Pagination affordances

    @ViewBuilder
    private var loadMoreView: some View {
        if viewModel.hasMorePages && !viewModel.historyItems.isEmpty {
            if viewModel.isLoadingNextPage {
                Loader()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Button {
                    viewModel.loadNextPage()
                } label: {
                    Text(String.localized("Load more", table: "Transcription"))
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: Color.info500
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .hoverPointerStyle(.link)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private var reachedBottomView: some View {
        if !viewModel.hasMorePages && !viewModel.historyItems.isEmpty {
            Text(String.localized("No more transcriptions", table: "Transcription"))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.T_1
                )
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
