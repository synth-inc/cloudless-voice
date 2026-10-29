// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetMyMentionContributionsEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Foundation

extension FetchingClient {
    func getMyMentionContributions() async throws -> [MyMentionContribution] {
        let endpoint = GetMyMentionContributionsEndpoint()
        return try await execute(endpoint)
    }
}

struct GetMyMentionContributionsEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = [MyMentionContribution]

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-mentions/contributions/mine" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .get }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
