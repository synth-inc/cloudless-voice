// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SubmissionModelsDecodingTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  The client no longer models a moderation state, but the server may still send
//  `status` and `moderationReason`. Decoding must ignore them without failing.
//

import Foundation
import Testing
@testable import Onit

@Suite
struct SubmissionModelsDecodingTests {

    private static func labels(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    @Test("A referral link payload with moderation fields decodes and does not expose them")
    func referralLinkIgnoresModerationFields() throws {
        let json = """
        {"referralLinks": [
            {"id": 1, "url": "https://example.com/a", "status": "Rejected", "moderationReason": "no", "referralId": 7},
            {"id": 2, "url": "https://example.com/b", "status": "Pending", "moderationReason": null, "referralId": 7}
        ], "maxLinks": 3}
        """
        let response = try JSONDecoder().decode(ReferralLinksResponse.self, from: Data(json.utf8))

        #expect(response.referralLinks.map(\.id) == [1, 2])
        #expect(response.referralLinks[0].url == "https://example.com/a")
        #expect(response.maxLinks == 3)
        let labels = Self.labels(of: response.referralLinks[0])
        #expect(!labels.contains("status"))
        #expect(!labels.contains("moderationReason"))
    }

    @Test("A mention submission payload with moderation fields decodes and does not expose them")
    func mentionContributionIgnoresModerationFields() throws {
        let json = """
        {"id": 5, "createdAt": "2026-06-01T10:00:00.000+0000", "updatedAt": "2026-06-01T10:00:00.000+0000",
         "status": "Declined", "moderationReason": "off topic", "url": "https://example.com/post",
         "mentionId": 9, "isMission": false, "platform": "X", "title": "Title", "subtitle": null,
         "body": null, "mentionUrl": null}
        """
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        decoder.dateDecodingStrategy = .formatted(formatter)

        let contribution = try decoder.decode(MyMentionContribution.self, from: Data(json.utf8))

        #expect(contribution.id == 5)
        #expect(contribution.url == "https://example.com/post")
        let labels = Self.labels(of: contribution)
        #expect(!labels.contains("status"))
        #expect(!labels.contains("moderationReason"))
    }

    @Test("A leaderboard entry reads its links from the server's approvedLinks key")
    func leaderboardEntryReadsLinks() throws {
        let json = """
        {"id": 3, "displayName": "Ada", "completedInvitations": 2,
         "approvedLinks": [{"url": "https://example.com/x"}]}
        """
        let entry = try JSONDecoder().decode(LeaderboardEntry.self, from: Data(json.utf8))

        #expect(entry.links.map(\.url) == ["https://example.com/x"])
        #expect(entry.mentions == 0)
        #expect(!Self.labels(of: entry).contains("approvedLinks"))
    }
}
