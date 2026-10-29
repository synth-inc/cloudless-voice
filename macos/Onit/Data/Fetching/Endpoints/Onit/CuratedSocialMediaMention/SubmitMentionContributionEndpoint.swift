// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SubmitMentionContributionEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import Foundation

extension FetchingClient {
    func submitMentionContribution(
        mentionId: Int?,
        url: String
    ) async throws -> MyMentionContribution {
        let endpoint = SubmitMentionContributionEndpoint(
            mentionId: mentionId,
            url: url
        )
        return try await execute(endpoint)
    }
}

struct SubmitMentionContributionEndpoint: Endpoint {
    typealias Request = SubmitMentionContributionRequest
    typealias Response = MyMentionContribution

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/curated-social-media-mentions/contributions" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .post }
    var token: String? { TokenManager.token }

    let mentionId: Int?
    let url: String

    var requestBody: Request? {
        SubmitMentionContributionRequest(mentionId: mentionId, url: url)
    }

    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}

/// `mentionId` is omitted from the JSON when `nil` (the synthesized encoder skips nil optionals), which the server reads as a free-form submission.
struct SubmitMentionContributionRequest: Codable {
    let mentionId: Int?
    let url: String
}
