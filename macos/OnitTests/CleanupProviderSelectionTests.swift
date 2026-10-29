// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupProviderSelectionTests.swift
//  OnitTests
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  With providers, the Smart Cleanup toggle can no longer stand for "is cleanup
//  on". It mirrors provider == smart; warmup asks the provider; the demo and
//  Reset put the provider (and the Rewrite stage) back.
//

import Defaults
import XCTest
@testable import Onit

@MainActor
final class CleanupProviderSelectionTests: XCTestCase {

    // MARK: - Toggle written by an older build

    /// An older build only knows the toggle. Switching it on while another provider
    /// is stored must not load the Smart Cleanup models or show Smart Cleanup as on.
    func testToggleOnFromOlderBuildDoesNotOverrideAnotherProvider() {
        let resolved = TranscriptionConfig.resolvedCleanupProviderID(stored: "from-the-future", smartFormattingEnabled: true)
        XCTAssertEqual(resolved, "from-the-future")
        XCTAssertFalse(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: "from-the-future", smartFormattingEnabled: true),
                       "Warmup must not load Smart Cleanup models for another provider's user")
        // "byok" stored by a build where it was a cleanup choice: no cleanup now.
        XCTAssertFalse(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: "byok", smartFormattingEnabled: true))
    }

    func testWarmupFollowsTheProvider() {
        XCTAssertTrue(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: "smart", smartFormattingEnabled: true))
        XCTAssertFalse(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: "none", smartFormattingEnabled: false))
        XCTAssertFalse(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: "byok", smartFormattingEnabled: false))
        // Before the first launch on a build with providers, the toggle is all there is.
        XCTAssertTrue(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: nil, smartFormattingEnabled: true))
        XCTAssertFalse(TranscriptionConfig.isSmartCleanupSelected(storedProviderID: nil, smartFormattingEnabled: false))
    }

    /// The live config already agrees with what warmup reads.
    func testSharedConfigMirrorsTheProvider() {
        let config = TranscriptionConfig.shared
        XCTAssertEqual(config.smartFormattingEnabled, config.cleanupProviderID == CleanupProviderID.smart)
        XCTAssertEqual(TranscriptionConfig.isSmartCleanupSelected, config.cleanupProviderID == CleanupProviderID.smart)
    }

    // MARK: - Reset to defaults

    func testDefaultProviderIsTheFreshInstallOne() {
        let fresh = TranscriptionConfig.resolvedCleanupProviderID(
            stored: nil,
            smartFormattingEnabled: Defaults.Keys.TranscriptionConfigKeys.smartFormattingEnabled.defaultValue
        )
        XCTAssertEqual(TranscriptionConfig.defaultCleanupProviderID, fresh)
    }

    // MARK: - Onboarding demo

    private final class Selection: CleanupProviderSelecting {
        var cleanupProviderID: String
        var rewriteEnabled: Bool
        init(_ id: String, rewrite: Bool = false) {
            cleanupProviderID = id
            rewriteEnabled = rewrite
        }
    }

    /// The demo shows Smart Cleanup alone: the user's Rewrite is paused and put back.
    func testDemoPausesRewrite() throws {
        let selection = Selection(CleanupProviderID.none, rewrite: true)
        let restore = try XCTUnwrap(DictationDemoLauncher.borrowSmartCleanup(from: selection))
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.smart, "The demo runs Smart Cleanup")
        XCTAssertFalse(selection.rewriteEnabled)
        restore()
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.none)
        XCTAssertTrue(selection.rewriteEnabled, "The Rewrite stage comes back")
    }

    func testDemoPausesRewriteAfterSmartCleanup() throws {
        let selection = Selection(CleanupProviderID.smart, rewrite: true)
        let restore = try XCTUnwrap(DictationDemoLauncher.borrowSmartCleanup(from: selection))
        XCTAssertFalse(selection.rewriteEnabled)
        restore()
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.smart)
        XCTAssertTrue(selection.rewriteEnabled)
    }

    func testDemoRestoresNone() throws {
        let selection = Selection(CleanupProviderID.none)
        let restore = try XCTUnwrap(DictationDemoLauncher.borrowSmartCleanup(from: selection))
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.smart)
        restore()
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.none)
    }

    func testDemoLeavesSmartAlone() {
        let selection = Selection(CleanupProviderID.smart)
        XCTAssertNil(DictationDemoLauncher.borrowSmartCleanup(from: selection))
        XCTAssertEqual(selection.cleanupProviderID, CleanupProviderID.smart)
    }
}
