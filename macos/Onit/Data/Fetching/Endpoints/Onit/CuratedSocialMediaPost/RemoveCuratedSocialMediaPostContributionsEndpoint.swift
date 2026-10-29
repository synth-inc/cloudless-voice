// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RemoveCuratedSocialMediaPostContributionsEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import Foundation

extension FetchingClient {
    @discardableResult
    func removeCuratedSocialMediaPostContributions(
        postIds: [Int]
    ) async throws -> CuratedSocialMediaPostContributionsResponse {
        let endpoint = RemoveCuratedSocialMediaPostContributionsEndpoint(postIds: postIds)
        return try await execute(endpoint)
    }
}

struct RemoveCuratedSocialMediaPostContributionsEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = CuratedSocialMediaPostContributionsResponse

    let postIds: [Int]

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-posts/contributions" }

    var getParams: [String: String]? {
        ["postIds": postIds.map(String.init).joined(separator: ",")]
    }

    var method: HTTPMethod { .delete }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
