// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FindOrCreateReferralEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Finds an existing referral by account ID or unique code, or creates a new one.
    func findOrCreateReferral(
        accountId: Int? = nil,
        uniqueCode: String? = nil,
        productName: ReferralProductName
    ) async throws -> Referral {
        let endpoint = FindOrCreateReferralEndpoint(
            accountId: accountId,
            uniqueCode: uniqueCode,
            productName: productName
        )
        return try await execute(endpoint)
    }
}

struct FindOrCreateReferralEndpoint: Endpoint {
    typealias Request = FindOrCreateReferralRequest

    typealias Response = Referral

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .post }

    var token: String? { nil }

    let accountId: Int?
    let uniqueCode: String?
    let productName: ReferralProductName

    var requestBody: Request? {
        FindOrCreateReferralRequest(
            accountId: accountId,
            uniqueCode: uniqueCode,
            productName: productName
        )
    }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}

struct FindOrCreateReferralRequest: Codable {
    let accountId: Int?
    let uniqueCode: String?
    let productName: ReferralProductName
}
