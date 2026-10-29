// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialMediaMention.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Foundation

struct CuratedSocialMediaMention: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let createdAt: Date
    let updatedAt: Date
    let platform: CuratedSocialMediaPostPlatform?
    let title: String
    let subtitle: String?
    let body: String?
    let url: String?
    let isMission: Bool
}

struct MissionsBatchResponse: Codable {
    let missions: [CuratedSocialMediaMention]
    let hasMore: Bool
}

/// A user's own submission.
struct MyMentionContribution: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let createdAt: Date
    let updatedAt: Date
    let url: String /// The user's submitted link.
    let mentionId: Int
    let isMission: Bool
    let platform: CuratedSocialMediaPostPlatform?
    let title: String
    let subtitle: String?
    let body: String? /// The mission's sample comment; `nil` for free-form submissions.
    let mentionUrl: String? /// The curated post/video for missions; `nil` for free-form submissions.
}
