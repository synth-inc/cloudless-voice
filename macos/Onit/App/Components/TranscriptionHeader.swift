// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionHeader.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Defaults
import SwiftUI

struct TranscriptionHeader: View {
    // MARK: - Properties
    
    @ObservedObject var viewModel: TranscriptionsViewModel
    
    // MARK: - Observations
    
    @ObservedObject private var localization = LocalizationManager.shared
    
    // MARK: - Defaults

    private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys
    @Default(TranscriptionConfigKeys.showTranscriptEdits) private var showEdits
    
    // MARK: - States
    
    @State private var showSortPopover: Bool = false
    
    // MARK: - Private Variables
    
    private let sortOptions: [(
        text: String,
        sortOrder: TranscriptionHistoryManager.SortOrder
    )] = [
        (
            text: String.localized("Newest first", table: "Transcription"),
            sortOrder: .newest
        ),
        (
            text: String.localized("Oldest first", table: "Transcription"),
            sortOrder: .oldest
        ),
        (
            text: String.localized("Audio duration", table: "Transcription"),
            sortOrder: .audioDuration
        ),
        (
            text: String.localized("App", table: "Transcription"),
            sortOrder: .appName
        )
    ]
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleAndSearchRow
            filterRow
            countAndSortRow
        }
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components: Title and Search Row

    private var titleAndSearchRow: some View {
        HStack(alignment: .top, spacing: 8) {
            AppTitleViews.PageTitleView(
                text: String.localized("Transcripts", table: "App")
            )

            Spacer()
            
            ExpandingSearchBar(
                searchQuery: $viewModel.searchQuery,
                placeholder: String.localized("Search transcripts", table: "Transcription"),
                tooltip: String.localized("Search transcripts", table: "Transcription")
            )
        }
        .padding(.top, 32)
        .padding(.bottom, 4)
    }

    // MARK: - Child Components: Filter Row

    private var filterRow: some View {
        HStack(alignment: .center, spacing: 8) {
            TranscriptStatusFilter(selection: $viewModel.reviewStatusFilter)
            TranscriptShowEditsToggle(isOn: $showEdits)
            Spacer()
        }
        .frame(height: 40)
        .onChange(of: showEdits) { _, newValue in
            AnalyticsManager.AppTranscripts.showEditsToggled(enabled: newValue)
        }
    }

    // MARK: - Child Components: Count and Sort Row

    private var countAndSortRow: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(String.localized("%d transcripts", table: "Transcription", viewModel.displayedItemsCount))
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.T_2
                )

            Spacer()

            sortButton
        }
    }
    
    private var sortButton: some View {
        AppIconButton(
            systemName: "arrow.up.arrow.down",
            tooltip: String.localized("Sort by", table: "Transcription")
        ) {
            showSortPopover.toggle()
        }
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            PopoverButtonsView(
                items: sortOptions.map { sortOption in
                    PopoverButtonsView.ButtonItem(
                        text: sortOption.text,
                        statusConfig: PopoverButtonsView.buttonStatusConfig(
                            selected: viewModel.currentSortOrder == sortOption.sortOrder
                        )
                    ) {
                        viewModel.currentSortOrder = sortOption.sortOrder
                        showSortPopover = false
                    }
                }
            )
        }
    }
}
