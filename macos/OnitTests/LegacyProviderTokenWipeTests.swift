// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LegacyProviderTokenWipeTests.swift
//  OnitTests
//
//  Runs the one-time legacy token wipe against a throwaway UserDefaults suite, never
//  the app's real preferences.
//

import Defaults
import XCTest
@testable import Onit

final class LegacyProviderTokenWipeTests: XCTestCase {

    /// The custom-provider shape the old sidebar app stored, token included.
    private struct OldCustomProvider: Codable, Defaults.Serializable {
        var name: String
        var baseURL: String
        var token: String
        var models: [AIModel]
        var isEnabled: Bool
        var isTokenValidated: Bool
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LegacyProviderTokenWipeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRemovesEveryRetiredKeyAndLeavesOthersAlone() {
        for key in LegacyProviderTokenWipe.retiredKeys {
            defaults.set(key.hasSuffix("Token") ? "sk-test-\(key)" : true, forKey: key)
        }
        defaults.set(true, forKey: "useLocalModel")
        defaults.set("keep", forKey: "unrelatedSetting")

        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)

        for key in LegacyProviderTokenWipe.retiredKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be wiped")
        }
        XCTAssertEqual(defaults.object(forKey: "useLocalModel") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "keep")
        XCTAssertTrue(defaults.bool(forKey: LegacyProviderTokenWipe.doneKey))
    }

    func testStripsTokensFromCustomProvidersAndKeepsTheRest() throws {
        let oldKey = Defaults.Key<[OldCustomProvider]>(
            LegacyProviderTokenWipe.customProvidersKey, default: [], suite: defaults)
        Defaults[oldKey] = [
            OldCustomProvider(name: "Local LLM", baseURL: "http://localhost:1234/v1",
                              token: "sk-custom-secret-1", models: [], isEnabled: true,
                              isTokenValidated: true),
            OldCustomProvider(name: "Other", baseURL: "https://llm.example.com/v1",
                              token: "sk-custom-secret-2", models: [], isEnabled: false,
                              isTokenValidated: false),
        ]

        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)

        let raw = try XCTUnwrap(defaults.array(forKey: LegacyProviderTokenWipe.customProvidersKey) as? [String])
        XCTAssertEqual(raw.count, 2)
        for entry in raw {
            XCTAssertFalse(entry.contains("sk-custom-secret"), "token survived: \(entry)")
            XCTAssertFalse(entry.contains("isTokenValidated"))
        }

        // The providers still decode as the current CustomProvider, minus the token.
        let currentKey = Defaults.Key<[CustomProvider]>(
            LegacyProviderTokenWipe.customProvidersKey, default: [], suite: defaults)
        let providers = Defaults[currentKey]
        XCTAssertEqual(providers.map(\.name), ["Local LLM", "Other"])
        XCTAssertEqual(providers.map(\.baseURL), ["http://localhost:1234/v1", "https://llm.example.com/v1"])
        XCTAssertEqual(providers.map(\.isEnabled), [true, false])
    }

    func testRemovesCustomProvidersStoredInAnUnexpectedShape() {
        defaults.set(["not json", "{\"token\":\"sk-custom-secret\"}"], forKey: LegacyProviderTokenWipe.customProvidersKey)

        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: LegacyProviderTokenWipe.customProvidersKey))
    }

    func testRunsOnlyOnce() {
        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: LegacyProviderTokenWipe.doneKey))

        // Anything written after the first run is not touched again.
        defaults.set("sk-written-later", forKey: "openAIToken")
        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "openAIToken"), "sk-written-later")
    }

    func testDoesNothingHarmfulOnACleanInstall() {
        LegacyProviderTokenWipe.runIfNeeded(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: LegacyProviderTokenWipe.customProvidersKey))
        XCTAssertTrue(defaults.bool(forKey: LegacyProviderTokenWipe.doneKey))
    }
}
