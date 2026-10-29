// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetMyReferrerEndpoint.swift
//  Onit
//

import Foundation

extension FetchingClient {
    /// Returns info about the person who referred the current user, if any.
    func getMyReferrer() async throws -> ReferrerInfo? {
        let endpoint = GetMyReferrerEndpoint()
        return try await execute(endpoint)
    }
}

struct GetMyReferrerEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = ReferrerInfo?

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/referral/referrer" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .get }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
