// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CreateSubscriptionCheckoutSessionEndpoint.swift
//  Onit
//
//  Created by Jason Swanson on 5/6/25.
//

import Foundation

extension FetchingClient {
    func createSubscriptionCheckoutSession(plan: String? = nil) async throws -> CreateSubscriptionCheckoutSessionResponse {
        let endpoint = CreateSubscriptionCheckoutSessionEndpoint(plan: plan)
        return try await execute(endpoint)
    }
}

struct CreateSubscriptionCheckoutSessionEndpoint: Endpoint {
    typealias Request = CreateSubscriptionCheckoutSessionRequest

    typealias Response = CreateSubscriptionCheckoutSessionResponse

    /// Server-side plan identifier (see `DictationPlan.checkoutPlan`). Nil = server default price.
    let plan: String?

    var baseURL: URL { OnitServer.baseURL }

    var path: String { "/v1/subscription/stripe/checkout" }

    var getParams: [String : String]? { nil }

    var method: HTTPMethod { .post }

    var token: String? { TokenManager.token }

    var requestBody: Request? { plan.map { CreateSubscriptionCheckoutSessionRequest(plan: $0) } }

    var additionalHeaders: [String : String]? { nil }

    var timeout: TimeInterval? { nil }

}

struct CreateSubscriptionCheckoutSessionRequest: Codable {
    let plan: String
}

struct CreateSubscriptionCheckoutSessionResponse: Codable {
    let sessionUrl: String
}
