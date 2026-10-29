// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DeleteReferralLinkEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import Foundation

extension FetchingClient {
    func deleteReferralLink(linkId: Int, uniqueCode: String) async throws -> EmptyResponse? {
        let endpoint = DeleteReferralLinkEndpoint(linkId: linkId, uniqueCode: uniqueCode)
        return try await execute(endpoint)
    }
}

struct DeleteReferralLinkEndpoint: Endpoint {
    typealias Request = EmptyRequest
    typealias Response = EmptyResponse?

    var baseURL: URL { OnitServer.baseURL }

    let linkId: Int
    let uniqueCode: String

    var path: String { "/v1/referral/links/\(linkId)" }

    var getParams: [String: String]? {
        ["uniqueCode": uniqueCode]
    }

    var method: HTTPMethod { .delete }
    var token: String? { TokenManager.token }
    var requestBody: Request? { nil }
    var additionalHeaders: [String: String]? { nil }
    var timeout: TimeInterval? { nil }
}
