// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppHome.swift
//  Onit
//
//  Created by Loyd Kim on 4/29/26.
//

import Defaults
import SwiftUI

struct AppHome: View {
    // MARK: - Defaults
    
    @Default(.appHomeCuratedSocialsSectionDismissedForever) private var curatedSocialsSectionDismissedForever
    
    // MARK: - Properties
    
    @Binding var showDictationStatsSheet: Bool
    
    // MARK: - Observations

    @StateObject private var viewModel = RecentTranscriptsViewModel()

    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var historyManager = TranscriptionHistoryManager.shared
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationStatsBar(showDictationStatsSheet: $showDictationStatsSheet)
            AppHomeSetupCard()
            if !curatedSocialsSectionDismissedForever
                && authManager.userLoggedIn {
                AppHomeCuratedSocials()
            }
            RecentTranscriptsList(viewModel: viewModel)
        }
        .task {
            viewModel.load()
        }
        .onAppear {
            Task {
                try? await TranscriptionHistoryManager.shared.updateCounts()
            }
        }
        .onChange(of: historyManager.mostRecentTranscription?.id) { _, _ in
            viewModel.load()
        }
        .onChange(of: historyManager.lastFileTranscript?.id) { _, _ in
            viewModel.load()
        }
        // External edits (e.g. via the Force Correction UI overlay) update
        // the DB without going through the review modal's `onChanged`
        // callback. Mirror those updates into the recent-transcripts list.
        .onChange(of: historyManager.recentlyUpdatedRow) { _, newValue in
            if let item = newValue {
                viewModel.refreshHistoryItem(item)
            }
        }
        .sheet(item: $viewModel.reviewSeed) { seed in
            TranscriptReviewModal(
                seed: seed,
                onChanged: { updated in viewModel.refreshHistoryItem(updated) },
                onDeleted: { deleted in viewModel.deleteHistoryItem(deleted) }
            )
        }
        .id(localization.currentLanguage)
    }
}
