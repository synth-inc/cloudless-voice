// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ReferralLinkManager.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import Combine
import Foundation

@MainActor
final class ReferralLinkManager: ObservableObject {
    // MARK: - Singleton

    static let shared = ReferralLinkManager()

    // MARK: - Published Properties: Links

    @Published private(set) var links: [ReferralLink] = []
    @Published private(set) var maxLinks: Int = 6
    @Published private(set) var isFetchingLinks: Bool = false
    @Published private(set) var fetchLinksErrorMessage: String? = nil

    // MARK: - Published Properties: Add Link

    @Published private(set) var isAddingLink: Bool = false
    @Published var addLinkErrorMessage: String? = nil

    // MARK: - Published Properties: Update Link

    @Published private(set) var isUpdatingLink: Bool = false
    @Published var updateLinkErrorMessage: String? = nil

    // MARK: - Published Properties: Delete Link

    @Published private(set) var isDeletingLink: Bool = false
    @Published var deleteLinkErrorMessage: String? = nil
    
    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initializer

    private init() {
        ReferralManager.shared.$uniqueReferralCode
            .removeDuplicates()
            .sink { [weak self] code in
                guard let self else { return }
                guard let code else {
                    self.reset()
                    return
                }
                self.fetchLinks(uniqueCode: code)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Variables
    
    var hasReachedMaxLinks: Bool {
        return links.count >= maxLinks
    }
    
    // MARK: - Public Methods: Reset

    func reset() {
        links = []
        maxLinks = 6
        isFetchingLinks = false
        fetchLinksErrorMessage = nil
        
        isAddingLink = false
        addLinkErrorMessage = nil
        
        isUpdatingLink = false
        updateLinkErrorMessage = nil
        
        isDeletingLink = false
        deleteLinkErrorMessage = nil
    }

    // MARK: - Public Methods: Fetch Links

    func fetchLinks(uniqueCode: String? = nil) {
        guard let code = uniqueCode ?? ReferralManager.shared.uniqueReferralCode
        else {
            return
        }

        isFetchingLinks = true
        fetchLinksErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let response = try await client.getReferralLinks(
                    uniqueCode: code
                )
                
                links = response.referralLinks
                maxLinks = response.maxLinks
            } catch {
                print("[ReferralLinkManager]: Failed to fetch links: \(error.localizedDescription)")
                fetchLinksErrorMessage = String.localized("Couldn't fetch your referral links.", table: "Settings")
            }

            isFetchingLinks = false
        }
    }

    // MARK: - Public Methods: Add Link

    func addLink(url: String) {
        guard let uniqueCode = ReferralManager.shared.uniqueReferralCode
        else {
            return
        }

        isAddingLink = true
        addLinkErrorMessage = nil

        let client = FetchingClient()

        Task {
            do {
                let newLink = try await client.addReferralLink(
                    uniqueCode: uniqueCode,
                    url: url
                )
                
                links.append(newLink)
            } catch {
                print("[ReferralLinkManager]: Failed to add link: \(error.localizedDescription)")
                addLinkErrorMessage = String.localized("Failed to add link. Please try again.", table: "Settings")
            }

            isAddingLink = false
        }
    }

    // MARK: - Public Methods: Update Link

    func updateLink(
        linkId: Int,
        url: String
    ) {
        guard let uniqueCode = ReferralManager.shared.uniqueReferralCode
        else {
            return
        }

        isUpdatingLink = true
        updateLinkErrorMessage = nil

        let oldUrl = links.first(where: { $0.id == linkId })?.url
        let client = FetchingClient()

        Task {
            do {
                let updatedLink = try await client.updateReferralLink(
                    linkId: linkId,
                    uniqueCode: uniqueCode,
                    url: url
                )

                if let existingReferralLinkIndex = links.firstIndex(where: { $0.id == linkId }) {
                    links[existingReferralLinkIndex] = updatedLink
                }

                if let oldUrl, oldUrl != updatedLink.url {
                    ReferralManager.shared.removeLeaderboardEntryLink(url: oldUrl)
                }
            } catch {
                print("[ReferralLinkManager]: Failed to update link: \(error.localizedDescription)")
                updateLinkErrorMessage = String.localized("Failed to update link. Please try again.", table: "Settings")
            }

            isUpdatingLink = false
        }
    }

    // MARK: - Public Methods: Delete Link

    func deleteLink(
        linkId: Int,
        onSuccess: @escaping () -> Void
    ) {
        guard let uniqueCode = ReferralManager.shared.uniqueReferralCode
        else {
            return
        }

        isDeletingLink = true
        deleteLinkErrorMessage = nil

        let deletedUrl = links.first(where: { $0.id == linkId })?.url
        let client = FetchingClient()

        Task {
            do {
                let _ = try await client.deleteReferralLink(
                    linkId: linkId,
                    uniqueCode: uniqueCode
                )

                links.removeAll { $0.id == linkId }

                if let deletedUrl {
                    ReferralManager.shared.removeLeaderboardEntryLink(url: deletedUrl)
                }

                onSuccess()
            } catch {
                print("[ReferralLinkManager]: Failed to delete link: \(error.localizedDescription)")
                deleteLinkErrorMessage = String.localized("Failed to remove link. Please try again.", table: "Settings")
            }

            isDeletingLink = false
        }
    }
}
