// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ReferralManager.swift
//  Onit
//
//  Created by Loyd Kim on 3/23/26.
//

import Combine
import Foundation

enum ReferralLinkPlatform: String, CaseIterable {
    case github
    case instagram
    case tiktok
    case x
    case youtube

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .x: return "X"
        case .youtube: return "YouTube"
        }
    }

    @MainActor
    var formPlaceholderText: String {
        switch self {
        case .github: return String.localized("Paste a GitHub link", table: "App")
        case .instagram: return String.localized("Paste an Instagram link", table: "App")
        case .tiktok: return String.localized("Paste a TikTok link", table: "App")
        case .x: return String.localized("Paste an X link", table: "App")
        case .youtube: return String.localized("Paste a YouTube link", table: "App")
        }
    }

    init?(from urlString: String) {
        guard let platformName = getWebPlatformName(from: urlString) else { return nil }

        switch platformName {
        case "github": self = .github
        case "instagram": self = .instagram
        case "tiktok": self = .tiktok
        case "x", "twitter": self = .x
        case "youtube", "youtu": self = .youtube
        default: return nil
        }
    }
}

@MainActor
final class ReferralManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ReferralManager()

    // MARK: - Published Properties: Referral

    @Published private(set) var referralId: Int? = nil
    @Published private(set) var uniqueReferralCode: String? = nil
    @Published private(set) var isGeneratingUniqueReferralCode: Bool = false
    @Published private(set) var failedToGenerateUniqueReferralCode: Bool = false
    @Published private(set) var referralIsLinkedToAccount: Bool? = nil

    // MARK: - Published Properties: Completed Invitations

    @Published private(set) var isFetchingCompletedInvitationsCount: Bool = false
    @Published private(set) var completedInvitationsErrorMessage: String? = nil
    @Published private(set) var completedInvitations: CompletedInvitationsCount? = nil

    // MARK: - Published Properties: Leaderboard Rank

    @Published private(set) var isFetchingLeaderboardRanking: Bool = false
    @Published private(set) var leaderboardRankErrorMessage: String? = nil
    @Published private(set) var leaderboardRank: LeaderboardRank? = nil

    @Published var isUpdatingDisplayName: Bool = false
    @Published var displayNameErrorMessage: String? = nil

    // MARK: - Published Properties: Referrer

    @Published private(set) var isFetchingReferrer: Bool = false
    @Published private(set) var referrer: ReferrerInfo? = nil
    @Published private(set) var hasCheckedReferrer: Bool = false
    @Published private(set) var isApplyingReferrer: Bool = false
    @Published var applyReferrerErrorMessage: String? = nil

    // MARK: - Published Properties: Leaderboard List

    @Published private(set) var isFetchingFirstPage: Bool = false
    @Published private(set) var isFetchingNextPage: Bool = false
    @Published var leaderboardPage: Int = 1
    @Published private(set) var hasMorePages: Bool = true
    @Published private(set) var leaderboardErrorMessage: String? = nil
    @Published private(set) var leaderboardEntries: [LeaderboardEntry] = []

    // MARK: - Public Variables

    var referralURL: String {
        let baseUrl = "https://www.cloudless.so"
        if let uniqueReferralCode {
            return "\(baseUrl)?invite=\(uniqueReferralCode)"
        } else {
            return baseUrl
        }
    }

    // MARK: - Private Properties

    private let pageSize = 20
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initializer

    private init() {
        /// Observe auth state changes to automatically find/create and tie referral codes.
        AuthManager.shared.$account
            .removeDuplicates(by: { $0?.id == $1?.id })
            .dropFirst()
            .sink { [weak self] _ in
                self?.findOrCreateReferral()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods: Reset

    func reset() {
        referralId = nil
        uniqueReferralCode = nil
        isGeneratingUniqueReferralCode = false
        failedToGenerateUniqueReferralCode = false
        referralIsLinkedToAccount = nil
        isFetchingCompletedInvitationsCount = false
        completedInvitationsErrorMessage = nil
        completedInvitations = nil
        isFetchingLeaderboardRanking = false
        leaderboardRankErrorMessage = nil
        leaderboardRank = nil
        isUpdatingDisplayName = false
        displayNameErrorMessage = nil
        isFetchingFirstPage = false
        isFetchingNextPage = false
        leaderboardPage = 1
        hasMorePages = true
        leaderboardErrorMessage = nil
        leaderboardEntries = []
        isFetchingReferrer = false
        referrer = nil
        hasCheckedReferrer = false
        isApplyingReferrer = false
        applyReferrerErrorMessage = nil
    }

    // MARK: - Public Methods: Referral

    /// Finds or creates a referral code for the current user.
    /// If the user is logged in and the referral is not yet tied to their account, it will be automatically tied.
    func findOrCreateReferral() {
        guard !isGeneratingUniqueReferralCode else { return }

        isGeneratingUniqueReferralCode = true
        failedToGenerateUniqueReferralCode = false

        let client = FetchingClient()

        Task {
            do {
                /// Find or create referral.
                /// If the user is already logged in, this allows them to auto-retrieve their referral code data as soon as they log into their account using `accountId`.
                let referral = try await client.findOrCreateReferral(
                    accountId: AuthManager.shared.account?.id,
                    uniqueCode: uniqueReferralCode,
                    productName: .dictation
                )

                /// Used by the referral leaderboard to identify the user's referral entry.
                referralId = referral.id

                /// If the user is logged in...
                if let accountId = AuthManager.shared.account?.id {
                    /// Automatically tie the user's anonymous referral code to their account to de-anonymize it.
                    /// This allows users to retrieve their referral code data as soon as they log into their account on another device.
                    if referral.accountId == nil {
                        tieAnonymousReferralToAccount(with: referral.uniqueCode)
                    }
                    /// Otherwise, for an already de-anonymized referral code...
                    else if accountId == referral.accountId {
                        /// Mark the referral code as being linked to the user's account. This hides the account creation CTAs.
                        referralIsLinkedToAccount = true
                        uniqueReferralCode = referral.uniqueCode
                        SnippetsService.shared.syncInviteLinkSnippet(inviteURL: referralURL)
                    }
                }
                /// Otherwise, if the user is logged out...
                else {
                    uniqueReferralCode = referral.uniqueCode
                    /// Show the account creation CTAs.
                    referralIsLinkedToAccount = false
                    SnippetsService.shared.syncInviteLinkSnippet(inviteURL: referralURL)
                }
            } catch {
                print("[ReferralManager]: Failed to find or create referral: \(error.localizedDescription)")
                failedToGenerateUniqueReferralCode = true
            }

            isGeneratingUniqueReferralCode = false
        }
    }

    private func tieAnonymousReferralToAccount(with uniqueCode: String) {
        referralIsLinkedToAccount = nil

        let client = FetchingClient()

        Task {
            do {
                let _ = try await client.tieReferralToAccount(uniqueCode: uniqueCode)
                referralIsLinkedToAccount = true
                uniqueReferralCode = uniqueCode
                SnippetsService.shared.syncInviteLinkSnippet(inviteURL: referralURL)
            } catch {
                print("[ReferralManager]: Failed to tie anonymous referral code to account: \(error.localizedDescription)")
                referralIsLinkedToAccount = false
            }
        }
    }

    // MARK: - Public Methods: Referrer

    func fetchMyReferrer() {
        isFetchingReferrer = true

        let client = FetchingClient()

        Task {
            do {
                referrer = try await client.getMyReferrer()
            } catch {
                referrer = nil
            }

            isFetchingReferrer = false
            hasCheckedReferrer = true
        }
    }

    func applyReferrer(code input: String, onSuccess: @escaping () -> Void) {
        let code = Self.extractReferralCode(from: input)
        guard !code.isEmpty else { return }

        isApplyingReferrer = true
        applyReferrerErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let _ = try await client.applyReferrer(uniqueCode: code)
                referrer = try await client.getMyReferrer()
                AnalyticsManager.Referral.codeApplied(success: true)
                onSuccess()
            } catch {
                print("[ReferralManager]: Failed to apply referrer: \(error.localizedDescription)")
                AnalyticsManager.Referral.codeApplied(success: false, error: error.localizedDescription)
                applyReferrerErrorMessage = String.localized("Invalid referral code. Please check and try again.", table: "Settings")
            }

            isApplyingReferrer = false
        }
    }

    static func extractReferralCode(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "invite" })?.value {
            return code
        }
        return trimmed
    }

    // MARK: - Public Methods: Completed Invitations

    func fetchCompletedInvitationsCount() {
        guard let uniqueReferralCode else { return }

        isFetchingCompletedInvitationsCount = true
        completedInvitationsErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                completedInvitations = try await client.getCompletedInvitationsCount(
                    uniqueCode: uniqueReferralCode
                )
            } catch {
                print("[ReferralManager]: Failed to fetch completed invitations count: \(error.localizedDescription)")
                completedInvitations = nil
                completedInvitationsErrorMessage = String.localized("Couldn't find your completed invitations.", table: "Settings")
            }

            isFetchingCompletedInvitationsCount = false
        }
    }

    // MARK: - Public Methods: Leaderboard Rank

    func fetchLeaderboardRank() {
        guard let uniqueReferralCode else { return }

        isFetchingLeaderboardRanking = true
        leaderboardRankErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                leaderboardRank = try await client.getLeaderboardRank(
                    uniqueCode: uniqueReferralCode,
                    productName: .dictation
                )
            } catch {
                print("[ReferralManager]: Failed to fetch leaderboard rank: \(error.localizedDescription)")
                leaderboardRankErrorMessage = String.localized("Couldn't find your leaderboard rank.", table: "Settings")
            }

            isFetchingLeaderboardRanking = false
        }
    }

    func updateReferralDisplayName(
        to displayName: String,
        onSuccess: @escaping () -> Void
    ) {
        guard let uniqueReferralCode else { return }

        isUpdatingDisplayName = true
        displayNameErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let updatedReferral = try await client.updateReferralDisplayName(
                    uniqueCode: uniqueReferralCode,
                    displayName: displayName
                )

                leaderboardRank = LeaderboardRank(
                    rank: leaderboardRank?.rank,
                    displayName: updatedReferral.displayName,
                    completedInvitations: leaderboardRank?.completedInvitations ?? 0,
                    mentions: leaderboardRank?.mentions ?? 0
                )

                onSuccess()
            } catch {
                print("[ReferralManager]: Failed to update display name: \(error.localizedDescription)")
                if let fetchingError = error as? FetchingError,
                   case .failedRequest(let serverMessage) = fetchingError,
                   !serverMessage.isEmpty,
                   serverMessage != FetchingError.clientErrorFallback {
                    displayNameErrorMessage = serverMessage
                } else {
                    displayNameErrorMessage = String.localized(
                        "Could not update display name. Please try again.",
                        table: "Settings"
                    )
                }
            }

            isUpdatingDisplayName = false
        }
    }

    // MARK: - Public Methods: Leaderboard List

    func resetAndFetchLeaderboard() {
        leaderboardEntries = []
        hasMorePages = true
        leaderboardErrorMessage = nil
        leaderboardPage = 1
        fetchPaginatedLeaderboard()
    }

    /// Fetches the leaderboard entries for the current `leaderboardPage`.
    func fetchPaginatedLeaderboard() {
        let shouldFetchFirstPage = leaderboardPage == 1

        if shouldFetchFirstPage {
            isFetchingNextPage = false
            isFetchingFirstPage = true
        } else {
            isFetchingFirstPage = false
            isFetchingNextPage = true
        }

        leaderboardErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let paginatedLeaderboardEntries = try await client.getLeaderboard(
                    productName: .dictation,
                    page: leaderboardPage
                )

                if shouldFetchFirstPage {
                    leaderboardEntries = paginatedLeaderboardEntries
                } else {
                    leaderboardEntries.append(contentsOf: paginatedLeaderboardEntries)
                }

                hasMorePages = paginatedLeaderboardEntries.count >= pageSize
            } catch {
                print("[ReferralManager]: Failed to fetch leaderboard: \(error.localizedDescription)")
                leaderboardErrorMessage = String.localized("Couldn't fetch leaderboard.", table: "App")
            }

            isFetchingFirstPage = false
            isFetchingNextPage = false
        }
    }

    /// Increments `leaderboardPage` and fetches the next page atomically.
    func loadNextPage() {
        guard hasMorePages,
              !isFetchingNextPage,
              !isFetchingFirstPage
        else {
            return
        }
        
        leaderboardPage += 1
        fetchPaginatedLeaderboard()
    }

    /// Loads every leaderboard entry from rank 1 ~ to the user's entry in the leaderboard.
    /// No-op if the user has no `referralId` yet or no leaderboard rank.
    func loadLeaderboardUpToUserLeaderboardEntry() {
        guard let referralId = referralId else { return }
        guard let rank = leaderboardRank?.rank else { return }
        guard !isFetchingNextPage,
              !isFetchingFirstPage
        else {
            return
        }

        isFetchingNextPage = true
        leaderboardErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let bulkLoadedLeaderboardEntries = try await client.getLeaderboard(
                    productName: .dictation,
                    pageSize: pageSize,
                    upToReferralId: referralId
                )

                leaderboardEntries = bulkLoadedLeaderboardEntries

                /// Sync the number of loaded leaderboard entry pages so that subsequent "Load more" presses fetches the next leaderboard entry page after the bulk-fetch.
                let loadedPages = max(
                    1,
                    Int(ceil(Double(bulkLoadedLeaderboardEntries.count) / Double(pageSize)))
                )
                leaderboardPage = loadedPages

                /// Optimistic: If the response filled the expected page-aligned slice, assume there might be more entries past it.
                /// The next "Load more" press self-corrects this if not.
                ///     The server returns < pageSize and `fetchPaginatedLeaderboard` flips `hasMorePages` to false
                let expectedSize = Int(ceil(Double(rank) / Double(pageSize))) * pageSize
                hasMorePages = bulkLoadedLeaderboardEntries.count >= expectedSize
            } catch {
                print("[ReferralManager]: Failed to load leaderboard up to user: \(error.localizedDescription)")
                leaderboardErrorMessage = String.localized("Couldn't fetch leaderboard.", table: "App")
            }

            isFetchingNextPage = false
        }
    }

    // MARK: - Public Methods: Leaderboard Entry Link Removal

    func removeLeaderboardEntryLink(url: String) {
        for index in leaderboardEntries.indices {
            let leaderboardEntry = leaderboardEntries[index]
            
            /// Filtering referral links by not including the removed `url`.
            let updatedReferralLinks = leaderboardEntry.links.filter { $0.url != url }

            if updatedReferralLinks.count != leaderboardEntry.links.count {
                leaderboardEntries[index] = LeaderboardEntry(
                    id: leaderboardEntry.id,
                    displayName: leaderboardEntry.displayName,
                    completedInvitations: leaderboardEntry.completedInvitations,
                    mentions: leaderboardEntry.mentions,
                    links: updatedReferralLinks
                )
                return
            }
        }
    }

    // MARK: - Public Methods: Journey Tracking

    /// `NOTE:` The referral journey is both created AND marked as having led to a download on the Framer landing page and not within this app.

    /// Marks the referral journey as having led to an app installation.
    /// Called on every app launch. The server is idempotent - if already marked or no journey exists, this is a no-op.
    func markInstalled() {
        let client = FetchingClient()

        Task {
            _ = try? await client.markReferralInstalled()
        }
    }

    /// Marks the referral journey as having led to an account sign-up.
    /// Called after every successful login. The server is idempotent - if already marked or no journey exists, this is a no-op.
    func markSignedUp() {
        let client = FetchingClient()

        Task {
            _ = try? await client.markReferralSignedUp()
        }
    }
}
