// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialsManager.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class CuratedSocialsManager: ObservableObject {
    // MARK: - Singleton

    static let shared = CuratedSocialsManager()

    // MARK: - Types

    enum ViewMode: Equatable {
        case hidden
        case carousel
        case dailyStackDone
        case stackDone
        case stackDismissed
    }
    
    // MARK: - Published Variables
    
    @Published private(set) var loadedPosts: [CuratedSocialMediaPost] = []
    @Published private(set) var hasMore: Bool = false
    @Published private(set) var isLoadingPosts: Bool = false
    @Published private(set) var errorMessage: String? = nil

    @Published var viewMode: ViewMode = .hidden

    @Published var centeredPostId: Int? = nil
    @Published private(set) var thankYouFeedbackPostId: Int? = nil
    @Published private(set) var openAllPostIds: [Int] = []
    
    // MARK: - Private States

    private var pendingThankYouFeedbackPostIds: Set<Int> = []
    private var isHandlingRefocus: Bool = false
    private var cancellables = Set<AnyCancellable>()

    /// Incremented when we call `loadInitialPosts()`, `loadMorePosts()`, and `reset()`.
    /// It ensures that we rely on the data that is returned from the most recent request, rather than the most-recently-returned request-response.
    /// This prevents edge cases where the client loads with stale data due to slow network connections.
    private var requestGenerationCounter: Int = 0
    
    // MARK: - Private Variables

    private let paginationLoadLimit: Int = 5

    // MARK: - Initializer

    private init() {
        AuthManager.shared.$account
            .removeDuplicates(by: { $0?.id == $1?.id })
            .dropFirst()
            .sink { [weak self] account in
                guard let self else { return }
                if account == nil {
                    self.reset()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reset

    func reset() {
        // Published Variables
        loadedPosts = []
        hasMore = false
        isLoadingPosts = false
        errorMessage = nil
        viewMode = .hidden
        centeredPostId = nil
        thankYouFeedbackPostId = nil
        openAllPostIds = []

        // Private States
        pendingThankYouFeedbackPostIds = []
        isHandlingRefocus = false
        /// We increment by `1` here, rather than resetting to `0` because it ensures that any in-flight task is properly invalidated when we enter a "reset" scenario.
        ///     For example, when the user logs in or logs out.
        requestGenerationCounter += 1
    }

    // MARK: - Network Requests: Fetching

    func loadInitialPosts(isReloadingStack: Bool = false) {
        guard AuthManager.shared.userLoggedIn
        else {
            viewMode = .hidden
            return
        }

        guard !isLoadingPosts else { return }

        isLoadingPosts = true
        errorMessage = nil

        if isReloadingStack {
            openAllPostIds = []
        }

        requestGenerationCounter += 1
        let requestCounter = requestGenerationCounter

        let client = FetchingClient()

        Task {
            do {
                let response = try await client.getCuratedSocialMediaPostsBatch(
                    limit: paginationLoadLimit,
                    excludeIds: []
                )

                guard requestCounter == requestGenerationCounter else { return }

                loadedPosts = response.posts
                hasMore = response.hasMore
                centeredPostId = response.posts.first?.id
                recomputeViewMode()
            } catch {
                if isReloadingStack {
                    print("[CuratedSocialsManager]: Failed to reload new stack: \(error.localizedDescription)")
                } else {
                    print("[CuratedSocialsManager]: Failed to fetch initial batch: \(error.localizedDescription)")
                }

                guard requestCounter == requestGenerationCounter else { return }

                errorMessage = error.localizedDescription

                if !isReloadingStack {
                    viewMode = .hidden
                }
            }

            guard requestCounter == requestGenerationCounter else { return }

            isLoadingPosts = false
        }
    }

    func loadMorePosts() {
        guard AuthManager.shared.userLoggedIn,
              !isLoadingPosts,
              hasMore
        else {
            return
        }

        isLoadingPosts = true
        errorMessage = nil

        requestGenerationCounter += 1
        let requestCounter = requestGenerationCounter

        let excludeIds = loadedPosts.map(\.id)
        let client = FetchingClient()

        Task {
            do {
                let response = try await client.getCuratedSocialMediaPostsBatch(
                    limit: paginationLoadLimit,
                    excludeIds: excludeIds
                )

                guard requestCounter == requestGenerationCounter else { return }

                let firstNewPostId = response.posts.first?.id
                loadedPosts.append(contentsOf: response.posts)
                hasMore = response.hasMore

                if centeredPostId == nil,
                   let firstNewPostId
                {
                    centeredPostId = firstNewPostId
                }
            } catch {
                print("[CuratedSocialsManager]: Failed to append more: \(error.localizedDescription)")

                guard requestCounter == requestGenerationCounter else { return }

                errorMessage = error.localizedDescription
            }

            guard requestCounter == requestGenerationCounter else { return }

            isLoadingPosts = false
        }
    }

    // MARK: - Network Requests: Contribute To One Curated Social Media Post

    func contribute(to post: CuratedSocialMediaPost) {
        guard AuthManager.shared.userLoggedIn else { return }

        /// Ensuring we don't maintain stale previously-all-opened post IDs.
        openAllPostIds = []

        let postId = post.id

        /// "Contributing" to a post means to open its `url` in the user's browser. This causes the browser to become the focused app, rather than Onit.
        /// Therefore, we store the now-contributed post's `id` in local state to defer the "Thank you" UI feedback until the user refocuses Onit.
        pendingThankYouFeedbackPostIds.insert(postId)

        /// Fire-and-forget: contribution recording is analytics, not transactional. If the POST fails the user may see this post again on a future load - acceptable.
        Task {
            try? await FetchingClient().addCuratedSocialMediaPostContributions(postIds: [postId])
        }

        /// Open post `url` in the browser.
        if let safeUrl = BrowserManager.getSafeWebURL(from: post.url) {
            NSWorkspace.shared.open(safeUrl)
        }
    }

    // MARK: - Network Requests: Contribute To All Currently-Fetched Posts

    func contributeAllFetchedPosts() {
        guard AuthManager.shared.userLoggedIn,
              !loadedPosts.isEmpty
        else {
            return
        }

        let openAllPosts = loadedPosts
        let openAllPostIds = openAllPosts.map(\.id)

        /// Mutate UI state synchronously: a second rapid tap then trips the `!loadedPosts.isEmpty` guard above and bails, preventing duplicate browser windows and duplicate POSTs.
        /// `openAllPostIds` is also the data source for the "undo open all" action.
        self.openAllPostIds = openAllPostIds
        for postId in openAllPostIds {
            pendingThankYouFeedbackPostIds.remove(postId)
        }
        loadedPosts = []
        centeredPostId = nil
        recomputeViewMode()

        /// Fire-and-forget: contribution recording is analytics, not transactional. If the POST fails the user may see these posts again on a future load - acceptable.
        Task {
            try? await FetchingClient().addCuratedSocialMediaPostContributions(postIds: openAllPostIds)
        }

        /// Open all post URLs in a new browser window.
        let openAllPostUrls = openAllPosts.map(\.url)
        Task {
            await BrowserManager.shared.openNewBrowserWindow(urls: openAllPostUrls)
        }
    }
    
    // MARK: - Network Requests: Undo Recent Contribution To All Currently-Fetched Posts

    func undoContributeAllFetchedPosts() {
        guard AuthManager.shared.userLoggedIn,
              !openAllPostIds.isEmpty
        else {
            return
        }

        let undoIds = openAllPostIds

        openAllPostIds = []

        let client = FetchingClient()

        Task {
            do {
                _ = try await client.removeCuratedSocialMediaPostContributions(
                    postIds: undoIds
                )
                
                loadInitialPosts()
            } catch {
                print("[CuratedSocialsManager]: Failed to undo \"open all\" curated social media post contributions: \(error.localizedDescription)")
                
                self.errorMessage = error.localizedDescription
                
                /// Restore the undone IDs so the user can access the "undo" again if they want.
                openAllPostIds = undoIds
            }
        }
    }
    
    // MARK: - UI: Show Thank You Feedback On App Refocus If Needed

    func showThankYouFeedbackOnAppRefocusIfNeeded() async {
        guard !isHandlingRefocus else { return }
        guard !pendingThankYouFeedbackPostIds.isEmpty else { return }

        isHandlingRefocus = true
        defer { isHandlingRefocus = false }

        let pendingThankYouPostIds = loadedPosts
            .map(\.id)
            .filter { pendingThankYouFeedbackPostIds.contains($0) }

        for pendingThankYouPostId in pendingThankYouPostIds {
            thankYouFeedbackPostId = pendingThankYouPostId
            try? await Task.sleep(for: .seconds(1))

            withAnimation(.easeOut(duration: 0.3)) {
                removePost(id: pendingThankYouPostId)
            }
            
            try? await Task.sleep(for: .milliseconds(300))
        }

        thankYouFeedbackPostId = nil
        pendingThankYouFeedbackPostIds.subtract(pendingThankYouPostIds)
        recomputeViewMode()
    }

    private func removePost(id: Int) {
        guard let index = loadedPosts.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let removedPostWasCenteredInCarousel = centeredPostId == id
        loadedPosts.remove(at: index)

        if removedPostWasCenteredInCarousel {
            /// If the curated socials carousel is now empty, `nil` out the `centeredPostId`.
            if loadedPosts.isEmpty {
                centeredPostId = nil
            }
            /// Otherwise, snap the curated socials carousel to the next post in the list.
            else {
                let newIndex = min(index, loadedPosts.count - 1)
                centeredPostId = loadedPosts[newIndex].id
            }
        }
    }

    // MARK: - UI: Carousel Navigation

    /// Index in `loadedPosts` of the currently-centered post. Derived from
    /// `centeredPostId`. Returns `0` when nothing is centered (e.g. user is
    /// on the trailing "More" button) so chevron-disabled checks degrade to
    /// "stay where you are" rather than crashing.
    private var currentPostIndex: Int {
        /// When centered on the trailing thanks card, report one index past the
        /// last post so chevron-prev returns to the last post.
        if centeredPostId == Self.thanksCardCenterId {
            return loadedPosts.count
        }
        return loadedPosts.firstIndex(where: { $0.id == centeredPostId }) ?? 0
    }

    /// Sentinel `centeredPostId` value for the trailing "Thanks for your
    /// support!" card, which isn't a post. `Int.min` can't collide with a real
    /// post id (DB serials are positive).
    static let thanksCardCenterId: Int = .min

    /// Whether the carousel shows the trailing "Thanks for your support!" card -
    /// only once every post has loaded and there's at least one post to trail.
    var hasThanksCard: Bool {
        return !hasMore && !loadedPosts.isEmpty
    }

    var canGoNext: Bool {
        if currentPostIndex < loadedPosts.count - 1 {
            return true
        }
        /// From the last post, allow advancing to the trailing thanks card.
        return centeredPostId != Self.thanksCardCenterId
            && currentPostIndex == loadedPosts.count - 1
            && hasThanksCard
    }

    var canGoPrevious: Bool {
        return currentPostIndex > 0
    }

    func goToNextPostItem() {
        guard canGoNext else { return }
        if currentPostIndex == loadedPosts.count - 1 {
            centeredPostId = Self.thanksCardCenterId
        } else {
            centeredPostId = loadedPosts[currentPostIndex + 1].id
        }
    }

    func goToPreviousPostItem() {
        guard canGoPrevious else { return }
        let previousIndex = currentPostIndex - 1
        centeredPostId = loadedPosts[previousIndex].id
    }

    // MARK: - UI: Dismissals

    func dismissDailyStackDone() {
        Defaults[.appHomeCuratedSocialsDailyStackDoneDismissedAt] = Date()
        openAllPostIds = []
        viewMode = .stackDismissed
    }

    func dismissStackDone() {
        Defaults[.appHomeCuratedSocialsStackDoneDismissedAt] = Date()
        openAllPostIds = []
        viewMode = .stackDismissed
    }

    // MARK: - Private Functions: Recompute View Mode

    private func recomputeViewMode() {
        if let curatedSocialsSectionDismissedAt = Defaults[.appHomeCuratedSocialsSectionDismissedAt] {
            let newDayNotStarted = !newDayStarted(since: curatedSocialsSectionDismissedAt)
            let noPostsToShow = loadedPosts.isEmpty && !hasMore
            
            if newDayNotStarted || noPostsToShow {
                viewMode = .hidden
                return
            }
            
            /// Clear the section-level dismissal state (1) at the start of a new day AND (2) there are new posts to contribute to.
            Defaults[.appHomeCuratedSocialsSectionDismissedAt] = nil
        }

        /// **When social posts loaded:**
        ///     * Clear stale "completed"-view dismissals.
        ///     * Re-show the carousel.
        if !loadedPosts.isEmpty {
            Defaults[.appHomeCuratedSocialsDailyStackDoneDismissedAt] = nil
            Defaults[.appHomeCuratedSocialsStackDoneDismissedAt] = nil
            viewMode = .carousel
            return
        }

        /// **When no social posts loaded:**
        /// Daily Stack Completed
        if hasMore {
            /// Ensure we maintain the `stackDismissed` state when "Daily stack completed" view was manually dismissed + new day hasn't rolled over.
            if let dailyStackDoneDismissedAt = Defaults[.appHomeCuratedSocialsDailyStackDoneDismissedAt],
               !newDayStarted(since: dailyStackDoneDismissedAt)
            {
                viewMode = .stackDismissed
            }
            /// Otherwise, show the "Daily stack completed" view.
            else {
                Defaults[.appHomeCuratedSocialsDailyStackDoneDismissedAt] = nil
                viewMode = .dailyStackDone
            }
        }
        /// Entire Stack Completed
        else {
            /// Ensure we maintain the `stackDismissed` state when "Stack completed" view was manually dismissed.
            /// We don't check for if we rolled into a new day here because we should only ever leave this state if we added new social entries into the database - new entries the user should contribute to.
            if Defaults[.appHomeCuratedSocialsStackDoneDismissedAt] != nil {
                viewMode = .stackDismissed
            }
            /// Otherwise, show the "Stack completed" view.
            else {
                viewMode = .stackDone
            }
        }
    }

    private func newDayStarted(since date: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: Date()) > calendar.startOfDay(for: date)
    }
}
