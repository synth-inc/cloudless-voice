// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetCompletedInvitationsCountEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 3/19/26.
//

import Foundation

extension FetchingClient {
    /// Retrieves the number of completed invitations (sign-ups) for a referral.
    func getCompletedInvitationsCount(uniqueCode: String) async throws -> CompletedInvitationsCount {
        let endpoint = GetCompletedInvitationsCountEndpoint(uniqueCode: uniqueCode)
        return try await execute(endpoint)
    }
}

struct GetCompletedInvitationsCountEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = CompletedInvitationsCount

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/referral/completed-invitations" }

    let uniqueCode: String

    var getParams: [String : String]? {
        ["uniqueCode": uniqueCode]
    }

    var method: HTTPMethod { .get }

    var token: String? { nil }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
