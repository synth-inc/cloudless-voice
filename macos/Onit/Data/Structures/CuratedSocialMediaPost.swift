// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialMediaPost.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import Foundation
import SwiftUI

enum CuratedSocialMediaPostPlatform: String, Codable, Equatable, CaseIterable {
    case reddit = "Reddit"
    case youtube = "YouTube"
    case x = "X"

    var displayName: String { rawValue }

    @MainActor
    var ctaLabel: String {
        switch self {
        case .reddit:
            return String.localized("Upvote", table: "App")
        case .youtube, .x:
            return String.localized("Like", table: "App")
        }
    }

    /// Image asset for the platform's logo, rendered in the card's header
    /// circle and in the curator dropdown. Returns `.link` for platforms
    /// whose logo asset has not yet been added to `Assets.xcassets`.
    var logoImage: ImageResource {
        switch self {
        case .reddit:
            return .logoRedditFilled
        case .youtube:
            return .logoYoutube
        case .x:
            return .logoX
        }
    }
}

struct CuratedSocialMediaPost: Codable, Identifiable, Equatable, Hashable {
    let id: Int
    let createdAt: Date
    let updatedAt: Date
    let platform: CuratedSocialMediaPostPlatform?
    let title: String
    let subtitle: String
    let body: String
    let url: String
    let contributionCount: Int
}

struct CuratedSocialMediaPostsBatchResponse: Codable {
    let posts: [CuratedSocialMediaPost]
    let hasMore: Bool
}

struct CuratedSocialMediaPostContributionsResponse: Codable {
    let added: Int?
    let removed: Int?
}
