// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetReferralLinksEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import Foundation

extension FetchingClient {
    func getReferralLinks(uniqueCode: String) async throws -> ReferralLinksResponse {
        let endpoint = GetReferralLinksEndpoint(uniqueCode: uniqueCode)
        return try await execute(endpoint)
    }
}

struct GetReferralLinksEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = ReferralLinksResponse

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/referral/links" }

    let uniqueCode: String

    var getParams: [String: String]? {
        ["uniqueCode": uniqueCode]
    }

    var method: HTTPMethod { .get }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
