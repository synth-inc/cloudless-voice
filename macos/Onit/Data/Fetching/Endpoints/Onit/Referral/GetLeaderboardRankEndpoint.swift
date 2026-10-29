// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetLeaderboardRankEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Retrieves the leaderboard rank for a specific referral.
    func getLeaderboardRank(
        uniqueCode: String,
        productName: ReferralProductName
    ) async throws -> LeaderboardRank {
        let endpoint = GetLeaderboardRankEndpoint(
            uniqueCode: uniqueCode,
            productName: productName
        )
        return try await execute(endpoint)
    }
}

struct GetLeaderboardRankEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = LeaderboardRank

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/leaderboard-rank" }

    let uniqueCode: String
    let productName: ReferralProductName

    var getParams: [String : String]? {
        [
            "uniqueCode": uniqueCode,
            "productName": productName.rawValue
        ]
    }

    var method: HTTPMethod { .get }

    var token: String? { nil }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
