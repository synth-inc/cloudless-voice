// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppWindowPages.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import SwiftUI

struct AppWindowPages: View {
    
    // MARK: - Observables
    
    @StateObject private var transcriptionsViewModel = TranscriptionsViewModel()

    @ObservedObject private var appWindowManager = AppWindowManager.shared
    @ObservedObject private var historyManager = TranscriptionHistoryManager.shared

    // MARK: - States

    @State private var showDictationStatsSheet: Bool = false
    @State private var showCorrectionBacktestSheet: Bool = false

    @State private var dictionarySearchQuery: String = ""
    @State private var dictionaryShowAddSheet: Bool = false

    @State private var snippetsSearchQuery: String = ""
    @State private var snippetsShowAddSheet: Bool = false
    
    // MARK: - Private Variables

    private let pageContentWidth: CGFloat = 640
    private let pageContentHorizontalPadding: CGFloat = 20
    private let pageBackgroundColor: Color = Color.surface3
    private let scrollToTopAnchorId = "appwindowpages-scroll-to-top-anchor"

    // MARK: - Private Functions

    @MainActor
    private func resetScrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(scrollToTopAnchorId, anchor: .top)
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(scrollToTopAnchorId)

                pageContentView(scrollProxy)
                    .padding(.horizontal, pageContentHorizontalPadding)
                    .padding(.bottom, 32)
                    .frame(width: pageContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .id(appWindowManager.currentPage)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) {
                /// Pins `pageHeaderView` to the top of the `ScrollView`.
                pageHeaderView
                    .padding(.horizontal, pageContentHorizontalPadding)
                    .frame(width: pageContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(pageBackgroundColor)
                    .id(appWindowManager.currentPage)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(pageBackgroundColor)
            .onChange(of: appWindowManager.currentPage) { _, _ in
                resetScrollToTop(scrollProxy)
            }
            // Mounted whatever the page: the Transcripts list model outlives the page and
            // never reloads when the page comes back, so a dictation or a file job that
            // lands while the user is on Home would otherwise be missing from it.
            .onChange(of: historyManager.mostRecentTranscription?.id) { _, _ in
                if let item = historyManager.mostRecentTranscription {
                    transcriptionsViewModel.handleNewTranscription(item)
                }
            }
            .onChange(of: historyManager.lastFileTranscript?.id) { _, _ in
                if let item = historyManager.lastFileTranscript {
                    transcriptionsViewModel.handleNewTranscription(item)
                }
            }
            // External edits (e.g. via the Force Correction UI overlay
            // after a fresh dictation) update the DB without going
            // through the review modal's `onChanged` callback. Mirror
            // those updates into the visible list so the row's text /
            // review status reflects the change immediately.
            .onChange(of: historyManager.recentlyUpdatedRow) { _, newValue in
                if let item = newValue {
                    transcriptionsViewModel.refreshHistoryItem(item)
                }
            }
            .task(id: transcriptionsViewModel.searchQuery) {
                if !transcriptionsViewModel.searchQuery.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                transcriptionsViewModel.loadFirstPage() {
                    resetScrollToTop(scrollProxy)
                }
            }
            .sheet(isPresented: $showDictationStatsSheet) {
                DictationStatsSheet(shouldShow: $showDictationStatsSheet)
            }
        }
    }

    // MARK: - Child Components: Page Header View

    @ViewBuilder
    private var pageHeaderView: some View {
        switch appWindowManager.currentPage {
        case .home:
            AppTitleViews.Home()
                .padding(.top, 32)
                .padding(.bottom, 8)
        case .transcripts:
            TranscriptionHeader(viewModel: transcriptionsViewModel)
        case .dictionary:
            AppDictionaryHeader(
                searchQuery: $dictionarySearchQuery,
                showAddSheet: $dictionaryShowAddSheet
            )
        case .snippets:
            AppSnippetsHeader(
                searchQuery: $snippetsSearchQuery,
                showAddSheet: $snippetsShowAddSheet
            )
        default:
            AppTitleViews.PageTitleView(
                text: appWindowManager.currentPage.pageName
            )
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Child Components: Page Content View

    @ViewBuilder
    private func pageContentView(_ scrollProxy: ScrollViewProxy) -> some View {
        switch appWindowManager.currentPage {
        case .home:
            AppHome(showDictationStatsSheet: $showDictationStatsSheet)
        case .transcripts:
            VStack(alignment: .leading, spacing: 8) {
                FileTranscriptionCard()
                CorrectionBacktestBanner(showBacktestSheet: $showCorrectionBacktestSheet)
                TranscriptionList(viewModel: transcriptionsViewModel)
            }
                .sheet(isPresented: $showCorrectionBacktestSheet) {
                    CorrectionBacktestSheet()
                }
                .onChange(of: transcriptionsViewModel.currentSortOrder) { _, _ in
                    transcriptionsViewModel.loadFirstPage() {
                        resetScrollToTop(scrollProxy)
                    }
                }
                .onChange(of: transcriptionsViewModel.reviewStatusFilter) { _, _ in
                    transcriptionsViewModel.loadFirstPage() {
                        resetScrollToTop(scrollProxy)
                    }
                }
                .sheet(item: $transcriptionsViewModel.reviewSeed) { seed in
                    TranscriptReviewModal(
                        seed: seed,
                        sortOrder: transcriptionsViewModel.currentSortOrder,
                        onChanged: { updated in transcriptionsViewModel.refreshHistoryItem(updated) },
                        onDeleted: { deleted in transcriptionsViewModel.deleteHistoryItem(deleted) }
                    )
                }
        case .dictionary:
            AppDictionary(
                searchQuery: $dictionarySearchQuery,
                showAddSheet: $dictionaryShowAddSheet
            )
        case .snippets:
            AppSnippets(
                searchQuery: $snippetsSearchQuery,
                showAddSheet: $snippetsShowAddSheet
            )
        case .support:
            AppSupport()
        }
    }
}
