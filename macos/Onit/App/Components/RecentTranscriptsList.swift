// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RecentTranscriptsList.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import SwiftUI

/// Home-page preview of the most recent transcripts. Renders a header
/// (clock icon + title + "View all" button), a section card with up to
/// `displayLimit` rows separated by dividers, and a footer link showing
/// the total transcript count. Both "View all" and the footer route to
/// the Transcripts tab. Falls back to `NoTranscriptsPlaceholder` when
/// the user has no transcripts yet.
struct RecentTranscriptsList: View {
    @ObservedObject var viewModel: RecentTranscriptsViewModel

    @ObservedObject private var appWindowManager = AppWindowManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            
            if viewModel.historyItems.isEmpty && !viewModel.isLoading {
                NoTranscriptsPlaceholder()
            } else {
                listCardView
                footerView
            }
        }
        .padding(.vertical, 8)
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components: Header View

    private var headerView: some View {
        AppHomeSectionHeader(
            iconSystemName: "clock",
            title: String.localized("Recent transcripts", table: "App")
        ) {
            viewAllButton
        }
    }

    private var viewAllButton: some View {
        TextButton(
            text: String.localized("View all", table: "App"),
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: 6,
                height: 28,
                cornerRadius: 8
            )
        ) {
            AnalyticsManager.AppHome.recentTranscriptsViewAllClicked()
            appWindowManager.setPage(page: .transcripts)
        }
    }

    // MARK: - Child Components: List Card View

    private var listCardView: some View {
        TranscriptSectionCard {
            ForEach(Array(viewModel.historyItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    DividerHorizontal()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                }
                TranscriptListItem(
                    historyItem: item,
                    // Home recap is read-only - never surface the diff
                    // even when "Show edits" is enabled on the Transcripts
                    // tab. Diff text is only meaningful next to the edit
                    // toolbar that lives on Transcripts.
                    showEdits: false,
                    onRefresh: { viewModel.refreshHistoryItem($0) },
                    onDelete: { viewModel.deleteHistoryItem($0) },
                    onReviewRequest: { viewModel.reviewSeed = $0 }
                )
            }
        }
    }

    // MARK: - Child Components: Footer View

    private var footerView: some View {
        Button {
            AnalyticsManager.AppHome.recentTranscriptsFooterLinkClicked()
            appWindowManager.setPage(page: .transcripts)
        } label: {
            Text(footerLabel)
                .styleText(
                    size: 12,
                    weight: .medium,
                    color: Color.T_2
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .hoverPointerStyle(.link)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footerLabel: String {
        String.localizedStringWithFormat(
            String.localized("View %d transcripts", table: "App"),
            viewModel.totalCount
        )
    }
}
