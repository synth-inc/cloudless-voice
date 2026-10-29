// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetMissionsBatchEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Foundation

extension FetchingClient {
    func getMissionsBatch(
        limit: Int,
        excludeIds: [Int]
    ) async throws -> MissionsBatchResponse {
        let endpoint = GetMissionsBatchEndpoint(
            limit: limit,
            excludeIds: excludeIds
        )
        return try await execute(endpoint)
    }
}

struct GetMissionsBatchEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = MissionsBatchResponse

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-mentions" }

    let limit: Int
    let excludeIds: [Int]

    var getParams: [String: String]? {
        var params: [String: String] = ["limit": String(limit)]
        if !excludeIds.isEmpty {
            params["excludeIds"] = excludeIds.map(String.init).joined(separator: ",")
        }
        return params
    }

    var method: HTTPMethod { .get }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
