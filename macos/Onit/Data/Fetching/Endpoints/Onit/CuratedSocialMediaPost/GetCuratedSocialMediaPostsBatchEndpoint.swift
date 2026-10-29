// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetCuratedSocialMediaPostsBatchEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import Foundation

extension FetchingClient {
    func getCuratedSocialMediaPostsBatch(
        limit: Int,
        excludeIds: [Int]
    ) async throws -> CuratedSocialMediaPostsBatchResponse {
        let endpoint = GetCuratedSocialMediaPostsBatchEndpoint(
            limit: limit,
            excludeIds: excludeIds
        )
        return try await execute(endpoint)
    }
}

struct GetCuratedSocialMediaPostsBatchEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = CuratedSocialMediaPostsBatchResponse

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-posts" }

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
