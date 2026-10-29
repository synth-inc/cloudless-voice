// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  UpdateDisplayNameEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Updates the display name for a referral owned by the authenticated user.
    func updateReferralDisplayName(uniqueCode: String, displayName: String) async throws -> Referral {
        let endpoint = UpdateDisplayNameEndpoint(
            uniqueCode: uniqueCode,
            displayName: displayName
        )
        return try await execute(endpoint)
    }
}

struct UpdateDisplayNameEndpoint: Endpoint {
    typealias Request = UpdateDisplayNameRequest

    typealias Response = Referral

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/display-name" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .patch }

    var token: String? { TokenManager.token }

    let uniqueCode: String
    let displayName: String

    var requestBody: Request? {
        UpdateDisplayNameRequest(uniqueCode: uniqueCode, displayName: displayName)
    }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}

struct UpdateDisplayNameRequest: Codable {
    let uniqueCode: String
    let displayName: String
}
