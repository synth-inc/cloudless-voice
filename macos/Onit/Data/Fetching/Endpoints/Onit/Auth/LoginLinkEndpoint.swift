// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LoginLinkEndpoint.swift
//  Onit
//
//  Created by Jason Swanson on 4/21/25.
//

import Foundation

extension FetchingClient {
    func requestLoginLink(email: String) async throws -> Void {
        let endpoint = LoginLinkEndpoint(email: email)
        let _ = try await execute(endpoint)
    }
}

struct LoginLinkEndpoint: Endpoint {
    typealias Request = LoginLinkRequest
    
    typealias Response = EmptyResponse?
    
    var baseURL: URL { OnitServer.baseURL }
    
    var path: String { "/v1/auth/login/link" }
    
    var getParams: [String : String]? { nil }
    
    var method: HTTPMethod { .post }
    
    var token: String? { nil }
    
    let email: String

    var requestBody: Request? {
        LoginLinkRequest(email: email, app: LoginLinkRequest.appIdentifier)
    }
    
    var additionalHeaders: [String : String]? { nil }
    
    var timeout: TimeInterval? { nil }
    
}

struct LoginLinkRequest: Codable {
    /// Identifies which app requested the magic link so the backend can choose
    /// the correct deeplink scheme (onit://) and email branding. The shared Onit
    /// server serves multiple apps (onit / quickedit / sidekick); without this it
    /// defaults to Onit/Dictate, but we send it explicitly so a change to that
    /// default can't silently break login. Matches QuickEdit's contract (which
    /// sends "quickedit"). NB: the app name is "onit", NOT "cloudless".
    static let appIdentifier = "onit"

    let email: String
    let app: String
}
