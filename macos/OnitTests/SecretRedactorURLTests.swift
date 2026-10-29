// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SecretRedactorURLTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  Credentials in URL query items and Authorization headers must be masked before a
//  string reaches a log; strings without a secret must pass through untouched.
//

import Foundation
import Testing
@testable import Onit

// Built at run time so this file holds no literal that looks like a real credential.
private let fakeSecret = String(repeating: "ab12", count: 4)
private let fakeBearer = String(repeating: "cd34", count: 5)

struct SecretRedactorURLTests {

    @Test(arguments: [
        ("https://x.test/v1/models?key=\(fakeSecret)&alt=sse",
         "https://x.test/v1/models?key=[REDACTED]&alt=sse"),
        ("https://x.test/v1?alt=sse&key=\(fakeSecret)",
         "https://x.test/v1?alt=sse&key=[REDACTED]"),
        ("https://x.test/cb?token=\(fakeSecret) end",
         "https://x.test/cb?token=[REDACTED] end"),
        ("https://x.test/cb?a=1&access_token=\(fakeSecret)&b=2",
         "https://x.test/cb?a=1&access_token=[REDACTED]&b=2"),
        ("https://x.test/cb?id_token=\(fakeSecret)",
         "https://x.test/cb?id_token=[REDACTED]"),
        ("Authorization: Bearer \(fakeBearer)",
         "Authorization: Bearer [REDACTED]"),
    ])
    func masksCredentials(input: String, expected: String) {
        #expect(SecretRedactor.redact(input) == expected)
    }

    @Test(arguments: [
        "https://x.test/v1/models?page=2&q=hello",
        "https://x.test/v1/models",
        "https://x.test/v1?key=short",
        "https://x.test/v1?monkey=\(fakeSecret)",
        "key=\(fakeSecret) is not a URL query item",
        "Dictation finished in 412 ms",
    ])
    func leavesNonSecretsUntouched(input: String) {
        #expect(SecretRedactor.redact(input) == input)
    }

    @Test func masksGoogleStyleKeyInAFullURL() {
        let key = "AIza" + String(repeating: "a1B2", count: 9)
        let out = SecretRedactor.redact("GET https://g.test/v1beta/m:generate?key=\(key)&alt=sse")
        #expect(!out.contains(key))
        #expect(out.hasSuffix("&alt=sse"))
    }
}
