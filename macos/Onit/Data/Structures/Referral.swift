// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Referral.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

enum ReferralProductName: String, Codable {
    case quickEdit = "QuickEdit"
    case dictation = "Dictation"
    case sidekick = "Sidekick"
    case autocomplete = "Autocomplete"
}

struct Referral: Codable {
    let id: Int
    let uniqueCode: String
    let productName: ReferralProductName
    let displayName: String
    let accountId: Int?
}

struct ReferralJourney: Codable {
    let id: Int
    let referenceId: String
    let downloadedAt: String?
    let installedAt: String?
    let signedUpAt: String?
    let referralId: Int
}

struct CompletedInvitationsCount: Codable {
    let count: Int
}

struct LeaderboardEntryLink: Codable {
    let url: String
}

struct LeaderboardEntry: Codable {
    let id: Int
    let displayName: String
    let completedInvitations: Int
    /// Mentions for this entry's account. Counts alongside
    /// `completedInvitations` toward the entry's leaderboard ranking.
    /// Defaults to 0 while the server doesn't send the field yet, so the
    /// leaderboard keeps decoding against the currently deployed API.
    let mentions: Int
    /// Decoded from the `approvedLinks` key, the name the server still uses on the wire.
    let links: [LeaderboardEntryLink]

    private enum CodingKeys: String, CodingKey {
        case id, displayName, completedInvitations, mentions
        case links = "approvedLinks"
    }

    init(id: Int, displayName: String, completedInvitations: Int, mentions: Int, links: [LeaderboardEntryLink]) {
        self.id = id
        self.displayName = displayName
        self.completedInvitations = completedInvitations
        self.mentions = mentions
        self.links = links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        completedInvitations = try container.decode(Int.self, forKey: .completedInvitations)
        mentions = try container.decodeIfPresent(Int.self, forKey: .mentions) ?? 0
        links = try container.decode([LeaderboardEntryLink].self, forKey: .links)
    }
}

struct LeaderboardRank: Codable {
    let rank: Int?
    let displayName: String
    let completedInvitations: Int
    let mentions: Int

    init(rank: Int?, displayName: String, completedInvitations: Int, mentions: Int) {
        self.rank = rank
        self.displayName = displayName
        self.completedInvitations = completedInvitations
        self.mentions = mentions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rank = try container.decodeIfPresent(Int.self, forKey: .rank)
        displayName = try container.decode(String.self, forKey: .displayName)
        completedInvitations = try container.decode(Int.self, forKey: .completedInvitations)
        mentions = try container.decodeIfPresent(Int.self, forKey: .mentions) ?? 0
    }
}

struct ReferrerInfo: Codable {
    let id: Int
    let uniqueCode: String
    let productName: ReferralProductName
    let displayName: String
    let accountId: Int?
}
