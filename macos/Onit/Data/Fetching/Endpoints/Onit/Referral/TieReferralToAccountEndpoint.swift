// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TieReferralToAccountEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Ties an existing referral to the authenticated user's account.
    func tieReferralToAccount(uniqueCode: String) async throws -> Referral {
        let endpoint = TieReferralToAccountEndpoint(uniqueCode: uniqueCode)
        return try await execute(endpoint)
    }
}

struct TieReferralToAccountEndpoint: Endpoint {
    typealias Request = TieReferralToAccountRequest

    typealias Response = Referral

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/tie-account" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .patch }

    var token: String? { TokenManager.token }

    let uniqueCode: String

    var requestBody: Request? {
        TieReferralToAccountRequest(uniqueCode: uniqueCode)
    }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}

struct TieReferralToAccountRequest: Codable {
    let uniqueCode: String
}
