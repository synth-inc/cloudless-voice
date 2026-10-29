// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RecentTranscriptsViewModel.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Foundation
import SwiftUI

/// Owns the "Recent transcripts" preview state for the Home page: top N most
/// recent transcripts plus the total count surfaced in the footer / "View all"
/// affordances. No search/sort/filter - Home is read-only.
@MainActor
final class RecentTranscriptsViewModel: ObservableObject {
    // MARK: - Published state

    @Published var historyItems: [TranscriptionHistory] = []
    @Published var totalCount: Int = 0
    @Published var isLoading: Bool = false

    /// Drives the review modal sheet, mirroring `TranscriptionsViewModel`.
    @Published var reviewSeed: TranscriptionHistory? = nil

    // MARK: - Configuration

    let displayLimit: Int = 5

    // MARK: - Internals

    private var currentFetchTask: Task<Void, Never>?
    private var historyManager: TranscriptionHistoryManager { .shared }

    deinit {
        currentFetchTask?.cancel()
    }

    // MARK: - Loading

    func load() {
        currentFetchTask?.cancel()
        isLoading = true

        currentFetchTask = Task { [weak self] in
            guard let self else { return }

            async let fetchedItems = historyManager.fetchPaginated(
                limit: displayLimit,
                offset: 0,
                searchQuery: nil,
                sortOrder: .newest,
                reviewStatus: nil
            )
            async let fetchedCount = historyManager.fetchFilteredCount(
                searchQuery: nil,
                reviewStatus: nil
            )

            let items = await fetchedItems
            let count = await fetchedCount

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.historyItems = items
                self.totalCount = count
                self.isLoading = false
            }
        }
    }

    // MARK: - Row callbacks

    func refreshHistoryItem(_ historyItem: TranscriptionHistory) {
        if let index = historyItems.firstIndex(where: { $0.id == historyItem.id }) {
            historyItems[index] = historyItem
        }
    }

    func deleteHistoryItem(_ historyItem: TranscriptionHistory) {
        guard let id = historyItem.id else { return }
        historyItems.removeAll { $0.id == id }
        totalCount = max(0, totalCount - 1)

        // Removing one row may surface the 6th most recent transcript into
        // the top-5 list - re-fetch so the preview stays full.
        load()
    }
}
