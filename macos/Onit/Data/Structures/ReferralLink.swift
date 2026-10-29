// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ReferralLink.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

struct ReferralLink: Codable, Identifiable, Equatable {
    let id: Int
    let url: String
    let referralId: Int
}

struct ReferralLinksResponse: Codable {
    let referralLinks: [ReferralLink]
    let maxLinks: Int
}
