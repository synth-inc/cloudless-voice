// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionsViewModel.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Foundation
import SwiftUI

/// Owns the search / sort / filter state and pagination logic for the
/// Transcripts page. Shared between `TranscriptionHeader` and
/// `TranscriptionList` via `@StateObject` on `AppWindowPages`, so both
/// halves of the page stay in sync without prop-drilling each piece of state.
@MainActor
final class TranscriptionsViewModel: ObservableObject {
    typealias SortOrder = TranscriptionHistoryManager.SortOrder

    // MARK: - Published state

    @Published var historyItems: [TranscriptionHistory] = []
    @Published var displayedItemsCount: Int = 0
    @Published var isLoadingFirstPage: Bool = false
    @Published var isLoadingNextPage: Bool = false
    /// Starts at `false` so scroll-driven pagination never fires before the
    /// first page has actually returned. Set to `items.count == pageSize`
    /// only when a fetch completes - and reset to `false` synchronously at
    /// the top of `loadFirstPage` so a sort/filter/search change doesn't
    /// let a stale pagination call race ahead of the in-flight first-page
    /// fetch.
    @Published var hasMorePages: Bool = false

    @Published var searchQuery: String = ""
    @Published var currentSortOrder: SortOrder = .newest
    @Published var reviewStatusFilter: TranscriptionHistory.ReviewStatus? = nil

    /// Drives the review modal sheet. Setting this to a non-nil item presents
    /// `TranscriptReviewModal` seeded on that transcript; setting it back to
    /// nil dismisses the sheet.
    @Published var reviewSeed: TranscriptionHistory? = nil

    // MARK: - Configuration

    let pageSize: Int = 10

    // MARK: - Internals

    private var currentPage: Int = 0
    private var currentFetchTask: Task<Void, Never>?
    
    /// Timestamp of the most recent infinite-scroll-driven `loadNextPageForInfiniteScrollPaginationIfNeeded()` trigger.
    /// Acts as a cooldown to prevent SwiftUI scrolling to cause infinite burst-fetching of transcription items.
    private var lastPaginationFireAt: Date? = nil
    private let loadNextPageCooldown: TimeInterval = 0.1

    private var historyManager: TranscriptionHistoryManager { .shared }

    /// Whitespace-only queries are treated as empty so the empty-state CTA
    /// shows the dictation hint instead of a misleading "No matches".
    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    var hasActiveFilter: Bool {
        !trimmedSearchQuery.isEmpty || reviewStatusFilter != nil
    }

    // MARK: - Lifecycle

    deinit {
        currentFetchTask?.cancel()
    }

    // MARK: - Pagination

    /// Snapshot of the query parameters captured synchronously at the
    /// start of a fetch and passed through to the DB layer. Without this
    /// snapshot, the fetch task would read `trimmedSearchQuery` /
    /// `currentSortOrder` / `reviewStatusFilter` mid-flight and could
    /// mix pages from two different queries - e.g. the user changing
    /// the filter between when `loadNextPage` increments `currentPage`
    /// and when the underlying SQL actually runs.
    private struct QueryParams {
        let searchQuery: String?
        let sortOrder: SortOrder
        let reviewStatus: TranscriptionHistory.ReviewStatus?
    }

    private func currentQueryParams() -> QueryParams {
        let trimmed = trimmedSearchQuery
        return QueryParams(
            searchQuery: trimmed.isEmpty ? nil : trimmed,
            sortOrder: currentSortOrder,
            reviewStatus: reviewStatusFilter
        )
    }

    func loadFirstPage(onFetchDone: (() -> Void)? = nil) {
        // Cancel anything in flight - including a `loadNextPage` that would
        // otherwise resolve and append stale rows from the previous query
        // onto the freshly cleared list.
        currentFetchTask?.cancel()
        lastPaginationFireAt = nil
        isLoadingFirstPage = true
        // Reset `isLoadingNextPage` synchronously in case we just cancelled
        // an in-flight `loadNextPage` Task. That Task short-circuits at its
        // `Task.isCancelled` check before the `MainActor.run` block that
        // would normally flip this back to `false` - so without resetting
        // here the flag stays stuck `true` and every future pagination call
        // early-returns on its guard.
        isLoadingNextPage = false
        // Block pagination triggers for the duration of the fetch. Without
        // this, an infinite-scroll trigger (or any other path into
        // `loadNextPage`) can fire with the next-page offset before the
        // first page has returned - appending stale rows to the cleared
        // list. Re-set after the fetch resolves.
        hasMorePages = false
        currentPage = 0
        historyItems = []
        // Zero the count so the header doesn't briefly show a stale total
        // (e.g. "127 transcripts") above the empty list while the new fetch
        // is in flight.
        displayedItemsCount = 0

        let params = currentQueryParams()

        currentFetchTask = Task { [weak self] in
            guard let self else { return }

            async let fetchedItems = fetchPage(offset: 0, params: params)
            async let fetchedCount = historyManager.fetchFilteredCount(
                searchQuery: params.searchQuery,
                reviewStatus: params.reviewStatus
            )

            let items = await fetchedItems
            let count = await fetchedCount

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.historyItems = items
                self.displayedItemsCount = count
                self.hasMorePages = items.count == self.pageSize
                self.isLoadingFirstPage = false
            }
            
            guard !Task.isCancelled else { return }
            
            onFetchDone?()
        }
    }

    func loadNextPageForInfiniteScrollIfNeeded(at historyItemIndex: Int) {
        /// We initially load 10 history items on the first page load and then another 10 items with every pagination.
        /// So a `prefetchThreshold` of `3` allows us to start fetching when the user scrolls to the last 3 items of each page.
        /// This allows the next list of transcription history items to be readily available for the user to view.
        let prefetchThreshold = 3
        let thresholdIndex = max(0, historyItems.count - prefetchThreshold)

        if historyItemIndex >= thresholdIndex {
            loadNextPageForInfiniteScrollPaginationIfNeeded()
        }
    }
    
    private func loadNextPageForInfiniteScrollPaginationIfNeeded() {
        guard !isLoadingNextPage,
              hasMorePages
        else {
            return
        }
        
        /// Early return to prevent infinite burst-fetching of transcription items.
        if let dateLastPaginated = lastPaginationFireAt,
           Date().timeIntervalSince(dateLastPaginated) < loadNextPageCooldown
        {
            return
        }
        
        lastPaginationFireAt = Date()
        loadNextPage()
    }

    func loadNextPage() {
        guard !isLoadingNextPage && !isLoadingFirstPage && hasMorePages else { return }
        isLoadingNextPage = true
        currentPage += 1
        let nextOffset = currentPage * pageSize
        let params = currentQueryParams()

        // Reuse `currentFetchTask` so a subsequent `loadFirstPage` (search,
        // sort, filter change) cancels this fetch too.
        currentFetchTask = Task { [weak self] in
            guard let self else { return }
            let fetched = await fetchPage(offset: nextOffset, params: params)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.historyItems.append(contentsOf: fetched)
                self.hasMorePages = fetched.count == self.pageSize
                self.isLoadingNextPage = false
            }
        }
    }

    private func fetchPage(offset: Int, params: QueryParams) async -> [TranscriptionHistory] {
        return await historyManager.fetchPaginated(
            limit: pageSize,
            offset: offset,
            searchQuery: params.searchQuery,
            sortOrder: params.sortOrder,
            reviewStatus: params.reviewStatus
        )
    }

    // MARK: - External updates

    /// Called when `TranscriptionHistoryManager.mostRecentTranscription`
    /// republishes - i.e. a new dictation just landed (or an existing
    /// one was modified and surfaced as most-recent). Inserts in place
    /// when the current view is the natural home for it (newest-first
    /// with no filter / search), otherwise falls back to a full first-page
    /// reload so any active filter is respected and `displayedItemsCount`
    /// stays accurate.
    func handleNewTranscription(_ item: TranscriptionHistory) {
        if hasActiveFilter || currentSortOrder != .newest {
            loadFirstPage()
            return
        }
        if let idx = historyItems.firstIndex(where: { $0.id == item.id }) {
            historyItems[idx] = item
        } else {
            historyItems.insert(item, at: 0)
            displayedItemsCount += 1
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
        displayedItemsCount = max(0, displayedItemsCount - 1)

        // Optimistic decrement above keeps the count badge in sync visually,
        // but pagination offsets shift after a delete - re-fetch the canonical
        // count from the DB so subsequent "Load More" calls don't skip rows
        // (and the badge stays correct if a server-side filter was involved).
        Task { [weak self] in
            guard let self else { return }
            let count = await historyManager.fetchFilteredCount(
                searchQuery: trimmedSearchQuery.isEmpty ? nil : trimmedSearchQuery,
                reviewStatus: reviewStatusFilter
            )
            await MainActor.run { self.displayedItemsCount = count }
        }
    }
}
