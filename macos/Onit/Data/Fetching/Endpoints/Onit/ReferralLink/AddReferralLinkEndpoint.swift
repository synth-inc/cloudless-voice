// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AddReferralLinkEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import Foundation

extension FetchingClient {
    func addReferralLink(uniqueCode: String, url: String) async throws -> ReferralLink {
        let endpoint = AddReferralLinkEndpoint(uniqueCode: uniqueCode, url: url)
        return try await execute(endpoint)
    }
}

struct AddReferralLinkEndpoint: Endpoint {
    typealias Request = AddReferralLinkRequest
    typealias Response = ReferralLink

    var baseURL: URL { OnitServer.baseURL }
    var path: String { "/v1/referral/links" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .post }
    var token: String? { TokenManager.token }

    let uniqueCode: String
    let url: String

    var requestBody: Request? {
        AddReferralLinkRequest(uniqueCode: uniqueCode, url: url)
    }

    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}

struct AddReferralLinkRequest: Codable {
    let uniqueCode: String
    let url: String
}
