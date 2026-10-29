// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SnippetsMigrationTests.swift
//  OnitTests
//
//  Unit tests for the one-shot snippet-keyword migration.
//
//  Created by Kévin Naudin on 2026-07-23.
//

import XCTest
@testable import Onit

final class SnippetsMigrationTests: XCTestCase {

    private func snippet(_ name: String, appendsKeyword: Bool) -> Snippet {
        Snippet(name: name, replacement: "R", appendsKeyword: appendsKeyword)
    }

    // MARK: - Suffix splitting

    func testWeldedNameIsSplitToBaseWithAppendsKeywordTrue() {
        let migrated = SnippetsService.migratedSnippets(
            [snippet("my email snippet", appendsKeyword: false)],
            alreadyMigrated: false
        )
        XCTAssertEqual(migrated?.count, 1)
        XCTAssertEqual(migrated?.first?.name, "my email")
        XCTAssertEqual(migrated?.first?.appendsKeyword, true)
    }

    func testWeldedSuffixMatchIsCaseInsensitive() {
        let migrated = SnippetsService.migratedSnippets(
            [snippet("My Email SNIPPET", appendsKeyword: false)],
            alreadyMigrated: false
        )
        // Only the trailing " snippet" length is dropped; the base keeps its case.
        XCTAssertEqual(migrated?.first?.name, "My Email")
        XCTAssertEqual(migrated?.first?.appendsKeyword, true)
    }

    // MARK: - Opt-out (non-suffixed) names

    func testNonSuffixedNameKeepsAppendsKeywordFalse() {
        let migrated = SnippetsService.migratedSnippets(
            [snippet("my address", appendsKeyword: true)],
            alreadyMigrated: false
        )
        XCTAssertEqual(migrated?.first?.name, "my address")
        XCTAssertEqual(migrated?.first?.appendsKeyword, false)
    }

    func testNameEqualToSuffixIsNotStrippedToEmpty() {
        // A name that is exactly " snippet" must not be stripped to an empty base;
        // the length guard keeps it intact and opts it out.
        let migrated = SnippetsService.migratedSnippets(
            [snippet(" snippet", appendsKeyword: true)],
            alreadyMigrated: false
        )
        XCTAssertEqual(migrated?.first?.name, " snippet")
        XCTAssertEqual(migrated?.first?.appendsKeyword, false)
    }

    // MARK: - Idempotency

    func testMigrationIsIdempotentOnceGuardIsSet() {
        let input = [snippet("my email snippet", appendsKeyword: false)]
        let once = SnippetsService.migratedSnippets(input, alreadyMigrated: false)
        XCTAssertEqual(once?.first?.name, "my email")
        XCTAssertEqual(once?.first?.appendsKeyword, true)

        // Second pass sees the guard flag set: it is a no-op (returns nil), so the
        // already-stripped base "my email" is never re-processed (which would flip
        // appendsKeyword back off).
        let twice = SnippetsService.migratedSnippets(once ?? [], alreadyMigrated: true)
        XCTAssertNil(twice)
    }
}
