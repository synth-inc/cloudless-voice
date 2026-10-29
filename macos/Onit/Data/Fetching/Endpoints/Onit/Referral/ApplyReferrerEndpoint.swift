// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ApplyReferrerEndpoint.swift
//  Onit
//

import Foundation

extension FetchingClient {
    /// Attributes a referral code to the current user's journey.
    func applyReferrer(uniqueCode: String) async throws -> ReferralJourney {
        let endpoint = ApplyReferrerEndpoint(uniqueCode: uniqueCode)
        return try await execute(endpoint)
    }
}

struct ApplyReferrerEndpoint: Endpoint {
    typealias Request = ApplyReferrerRequest
    typealias Response = ReferralJourney

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/referral/journey/claim" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .post }
    var token: String? { TokenManager.token }
    let uniqueCode: String
    var requestBody: Request? { ApplyReferrerRequest(uniqueCode: uniqueCode) }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}

struct ApplyReferrerRequest: Codable {
    let uniqueCode: String
}
