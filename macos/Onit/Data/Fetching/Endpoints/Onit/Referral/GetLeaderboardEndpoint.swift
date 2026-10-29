// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetLeaderboardEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Retrieves the referral leaderboard for a given product, with optional pagination.
    ///
    /// When `upToReferralId` is provided, the server returns every entry from rank 1 up to the rank of the provided referral ID.
    func getLeaderboard(
        productName: ReferralProductName,
        page: Int? = nil,
        pageSize: Int? = nil,
        upToReferralId: Int? = nil
    ) async throws -> [LeaderboardEntry] {
        let endpoint = GetLeaderboardEndpoint(
            productName: productName,
            page: page,
            pageSize: pageSize,
            upToReferralId: upToReferralId
        )
        return try await execute(endpoint)
    }
}

struct GetLeaderboardEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = [LeaderboardEntry]

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/leaderboard" }

    let productName: ReferralProductName
    let page: Int?
    let pageSize: Int?
    let upToReferralId: Int?

    var getParams: [String : String]? {
        var params: [String : String] = [
            "productName": productName.rawValue
        ]
        if let page { params["page"] = String(page) }
        if let pageSize { params["pageSize"] = String(pageSize) }
        if let upToReferralId { params["upToReferralId"] = String(upToReferralId) }
        return params
    }

    var method: HTTPMethod { .get }

    var token: String? { nil }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
