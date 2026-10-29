// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DeleteMentionContributionEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Foundation

extension FetchingClient {
    @discardableResult
    func deleteMentionContribution(
        contributionId: Int
    ) async throws -> EmptyResponse? {
        let endpoint = DeleteMentionContributionEndpoint(
            contributionId: contributionId
        )
        return try await execute(endpoint)
    }
}

struct DeleteMentionContributionEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = EmptyResponse?

    var baseURL: URL { OnitServer.baseURL }

    let contributionId: Int

    var path: String {
        "/v1/curated-social-media-mentions/contributions/\(contributionId)"
    }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .delete }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
