// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GetLifetimeActivationEndpoint.swift
//  Onit
//
//  Created by Loyd Kim on 4/8/26.
//

import Foundation

extension FetchingClient {
    func getLifetimeActivation(productName: ReferralProductName) async throws -> LifetimeActivation? {
        let endpoint = GetLifetimeActivationEndpoint(productName: productName)
        return try await execute(endpoint)
    }
}

struct GetLifetimeActivationEndpoint: Endpoint {
    typealias Request = EmptyRequest

    typealias Response = LifetimeActivation?

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/lifetime-activation" }

    let productName: ReferralProductName

    var getParams: [String : String]? {
        ["productName": productName.rawValue]
    }

    var method: HTTPMethod { .get }

    var token: String? { TokenManager.token }

    var requestBody: Request? { nil }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }
}
