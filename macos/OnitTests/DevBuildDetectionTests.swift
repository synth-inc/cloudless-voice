// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DevBuildDetectionTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-27.
//
//  Which bundle identifiers count as a dev build that the release build defers to.
//

import XCTest
@testable import Onit

final class DevBuildDetectionTests: XCTestCase {

    func testOfficialDevBuildIsDevBuild() {
        XCTAssertTrue(DevBuildDetectionService.isDevBuild(bundleIdentifier: "inc.synth.Onit.dev"))
    }

    func testFullyOpenBuildIsDevBuild() {
        XCTAssertTrue(DevBuildDetectionService.isDevBuild(bundleIdentifier: "inc.synth.Onit.dev.open"))
    }

    func testReleaseBuildIsNotDevBuild() {
        XCTAssertFalse(DevBuildDetectionService.isDevBuild(bundleIdentifier: "inc.synth.Onit"))
    }

    func testUnknownOrMissingIdentifierIsNotDevBuild() {
        XCTAssertFalse(DevBuildDetectionService.isDevBuild(bundleIdentifier: "com.apple.finder"))
        XCTAssertFalse(DevBuildDetectionService.isDevBuild(bundleIdentifier: "inc.synth.Onit.dev.open.extra"))
        XCTAssertFalse(DevBuildDetectionService.isDevBuild(bundleIdentifier: ""))
        XCTAssertFalse(DevBuildDetectionService.isDevBuild(bundleIdentifier: nil))
    }

    /// The fully open build's bundle ID, read from its xcconfig, must be one the
    /// release build recognises, or both would run side by side without deferring.
    func testFullyOpenXcconfigBundleIDIsDevBuild() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fully-open/FullyOpen.xcconfig")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("FullyOpen.xcconfig not readable at \(url.path)")
        }
        let id = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER") }
            .flatMap { $0.split(separator: "=", maxSplits: 1).last }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(id, "inc.synth.Onit.dev.open")
        XCTAssertTrue(DevBuildDetectionService.isDevBuild(bundleIdentifier: id))
    }
}
