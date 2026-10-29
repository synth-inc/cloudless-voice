// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  UpdateReferralLinkEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import Foundation

extension FetchingClient {
    func updateReferralLink(linkId: Int, uniqueCode: String, url: String) async throws -> ReferralLink {
        let endpoint = UpdateReferralLinkEndpoint(linkId: linkId, uniqueCode: uniqueCode, url: url)
        return try await execute(endpoint)
    }
}

struct UpdateReferralLinkEndpoint: Endpoint {
    typealias Request = UpdateReferralLinkRequest
    typealias Response = ReferralLink

    var baseURL: URL { OnitServer.baseURL }

    let linkId: Int

    var path: String { "/v1/referral/links/\(linkId)" }
    var getParams: [String: String]? { nil }
    var method: HTTPMethod { .patch }
    var token: String? { TokenManager.token }

    let uniqueCode: String
    let url: String

    var requestBody: Request? {
        UpdateReferralLinkRequest(uniqueCode: uniqueCode, url: url)
    }

    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}

struct UpdateReferralLinkRequest: Codable {
    let uniqueCode: String
    let url: String
}
