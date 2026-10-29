// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MarkInstalledEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Marks the referral journey as installed. The server identifies the journey via the client's IP address.
    func markReferralInstalled() async throws -> ReferralJourney {
        let endpoint = MarkInstalledEndpoint()
        return try await execute(endpoint)
    }
}

struct MarkInstalledEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = ReferralJourney

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/journey/installed" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .patch }

    var token: String? { nil }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
