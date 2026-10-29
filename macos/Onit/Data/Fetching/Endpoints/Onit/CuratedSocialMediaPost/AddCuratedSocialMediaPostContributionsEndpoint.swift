// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AddCuratedSocialMediaPostContributionsEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import Foundation

extension FetchingClient {
    @discardableResult
    func addCuratedSocialMediaPostContributions(
        postIds: [Int]
    ) async throws -> CuratedSocialMediaPostContributionsResponse {
        let endpoint = AddCuratedSocialMediaPostContributionsEndpoint(postIds: postIds)
        return try await execute(endpoint)
    }
}

struct AddCuratedSocialMediaPostContributionsEndpoint: Endpoint {
    typealias Request = ContributionsRequest
    typealias Response = CuratedSocialMediaPostContributionsResponse

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-posts/contributions" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .post }
    var token: String? { TokenManager.token }

    let postIds: [Int]

    var requestBody: Request? { ContributionsRequest(postIds: postIds) }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}

struct ContributionsRequest: Codable {
    let postIds: [Int]
}
