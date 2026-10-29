// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MarkSignedUpEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Marks the referral journey as signed up. The server identifies the journey via the client's IP address.
    func markReferralSignedUp() async throws -> ReferralJourney {
        let endpoint = MarkSignedUpEndpoint()
        return try await execute(endpoint)
    }
}

struct MarkSignedUpEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = ReferralJourney

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/journey/signed-up" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .patch }

    var token: String? { TokenManager.token }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
