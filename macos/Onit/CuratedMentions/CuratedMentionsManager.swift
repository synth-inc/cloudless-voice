// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedMentionsManager.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Combine
import Foundation

@MainActor
final class CuratedMentionsManager: ObservableObject {
    // MARK: - Singleton

    static let shared = CuratedMentionsManager()
    
    // MARK: - Initializer

    private init() {
        AuthManager.shared.$account
            .removeDuplicates(by: { $0?.id == $1?.id })
            .dropFirst()
            .sink { [weak self] account in
                guard let self else { return }
                if account == nil {
                    self.reset()
                } else {
                    /// Account (re)connected or switched: drop any previous account's
                    /// submissions and invalidate an in-flight request - so its response
                    /// can't land in this account's view - before loading the new one's.
                    /// Clearing `isLoadingMyContributions` ensures the reload below isn't
                    /// blocked by the in-progress guard when switching mid-request.
                    self.myContributions = []
                    self.isLoadingMyContributions = false
                    self.myContributionsRequestGenerationCounter += 1
                    self.loadMyContributions()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Published Variables: Missions Feed

    @Published private(set) var missions: [CuratedSocialMediaMention] = []
    @Published private(set) var hasMoreMissions: Bool = false
    @Published private(set) var isLoadingMissions: Bool = false
    @Published private(set) var isLoadingMoreMissions: Bool = false
    @Published private(set) var missionsErrorMessage: String? = nil

    // MARK: - Published Variables: My Submissions

    @Published private(set) var myContributions: [MyMentionContribution] = []
    @Published private(set) var isLoadingMyContributions: Bool = false
    @Published private(set) var myContributionsErrorMessage: String? = nil

    // MARK: - States

    private var cancellables = Set<AnyCancellable>()

    /// Guards against stale responses overwriting fresher data on slow networks.
    private var missionsRequestGenerationCounter: Int = 0
    private var myContributionsRequestGenerationCounter: Int = 0

    // MARK: - Private Variables

    private let paginationLoadLimit: Int = 5

    // MARK: - Reset

    func reset() {
        missions = []
        hasMoreMissions = false
        isLoadingMissions = false
        isLoadingMoreMissions = false
        missionsErrorMessage = nil

        myContributions = []
        isLoadingMyContributions = false
        myContributionsErrorMessage = nil


        /// Invalidate any in-flight requests so their responses can't repopulate
        /// state after a log out / log in (e.g. with the previous account's data).
        missionsRequestGenerationCounter += 1
        myContributionsRequestGenerationCounter += 1
    }

    // MARK: - Network Requests: Missions Feed

    func loadMissions() {
        guard AuthManager.shared.userLoggedIn
        else {
            missions = []
            return
        }

        guard !isLoadingMissions,
              !isLoadingMoreMissions
        else {
            return
        }

        isLoadingMissions = true
        missionsErrorMessage = nil

        missionsRequestGenerationCounter += 1
        let requestCounter = missionsRequestGenerationCounter

        let client = FetchingClient()

        Task {
            do {
                let response = try await client.getMissionsBatch(
                    limit: paginationLoadLimit,
                    excludeIds: []
                )

                guard requestCounter == missionsRequestGenerationCounter else { return }

                missions = response.missions
                hasMoreMissions = response.hasMore
            } catch {
                print("[CuratedMentionsManager]: Failed to fetch missions: \(error.localizedDescription)")

                guard requestCounter == missionsRequestGenerationCounter else { return }

                missionsErrorMessage = error.localizedDescription
            }

            guard requestCounter == missionsRequestGenerationCounter else { return }

            isLoadingMissions = false
        }
    }

    func loadMoreMissions() {
        guard AuthManager.shared.userLoggedIn,
              !isLoadingMissions,
              !isLoadingMoreMissions,
              hasMoreMissions
        else {
            return
        }

        isLoadingMoreMissions = true
        missionsErrorMessage = nil

        missionsRequestGenerationCounter += 1
        let requestCounter = missionsRequestGenerationCounter

        let excludeIds = missions.map(\.id)
        let client = FetchingClient()

        Task {
            do {
                let response = try await client.getMissionsBatch(
                    limit: paginationLoadLimit,
                    excludeIds: excludeIds
                )

                guard requestCounter == missionsRequestGenerationCounter else { return }

                missions.append(contentsOf: response.missions)
                hasMoreMissions = response.hasMore
            } catch {
                print("[CuratedMentionsManager]: Failed to append more missions: \(error.localizedDescription)")

                guard requestCounter == missionsRequestGenerationCounter else { return }

                missionsErrorMessage = error.localizedDescription
            }

            guard requestCounter == missionsRequestGenerationCounter else { return }

            isLoadingMoreMissions = false
        }
    }

    // MARK: - Network Requests: Submit A Mention

    /// Submits a link for `mentionId` (a mission) or, when `mentionId` is `nil`,
    /// as a free-form "mentioned Onit elsewhere" submission. Throws so the
    /// submit sheet can surface server errors (e.g. duplicate link, already
    /// claimed) inline. On success, records the submission and drops the
    /// now-claimed mission from the active feed.
    @discardableResult
    func submitContribution(
        mentionId: Int?,
        url: String
    ) async throws -> MyMentionContribution {
        let client = FetchingClient()
        let contribution = try await client.submitMentionContribution(
            mentionId: mentionId,
            url: url
        )

        myContributions.insert(contribution, at: 0)
        
        if let mentionId {
            missions.removeAll { $0.id == mentionId }
        }

        return contribution
    }

    // MARK: - Network Requests: My Submissions

    func loadMyContributions() {
        guard AuthManager.shared.userLoggedIn
        else {
            myContributions = []
            return
        }
        
        guard !isLoadingMyContributions else { return }

        isLoadingMyContributions = true
        myContributionsErrorMessage = nil

        myContributionsRequestGenerationCounter += 1
        let requestCounter = myContributionsRequestGenerationCounter

        let client = FetchingClient()

        Task {
            do {
                let contributions = try await client.getMyMentionContributions()

                guard requestCounter == myContributionsRequestGenerationCounter else { return }

                myContributions = contributions
            } catch {
                print("[CuratedMentionsManager]: Failed to fetch my submissions: \(error.localizedDescription)")

                guard requestCounter == myContributionsRequestGenerationCounter else { return }

                myContributionsErrorMessage = error.localizedDescription
            }

            guard requestCounter == myContributionsRequestGenerationCounter else { return }

            isLoadingMyContributions = false
        }
    }

    func deleteMyContribution(_ contribution: MyMentionContribution) {
        guard AuthManager.shared.userLoggedIn else { return }

        /// Optimistically remove; restore on failure.
        let removedIndex = myContributions.firstIndex(where: { $0.id == contribution.id })
        myContributions.removeAll { $0.id == contribution.id }

        let client = FetchingClient()

        Task {
            do {
                try await client.deleteMentionContribution(
                    contributionId: contribution.id
                )
            } catch {
                print("[CuratedMentionsManager]: Failed to delete submission: \(error.localizedDescription)")
                myContributionsErrorMessage = error.localizedDescription

                /// Restore contribution at its prior position so the list order is preserved.
                if let removedIndex,
                   !myContributions.contains(where: { $0.id == contribution.id })
                {
                    let insertIndex = min(removedIndex, myContributions.count)
                    myContributions.insert(contribution, at: insertIndex)
                }
            }
        }
    }
}
