// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AXWindowMiningTests.swift
//  OnitTests
//
//  The AX window walk feeds two consumers with hard size requirements: the
//  Layer C term selector (prompt budget) and the history windowContextSnapshot
//  (SQLite row). A terminal running a long agent session can expose hundreds of
//  thousands of words through one AXTextArea value, so the caps are the
//  contract - not an optimization.
//

import XCTest
@testable import Onit

final class AXWindowMiningTests: XCTestCase {

    // MARK: - Per-element truncation

    func testShortValuePassesThrough() {
        let text = "Kalender kickoff notes"
        XCTAssertEqual(AccessibilityParserConfig.truncatedValue(text), text)
    }

    func testOversizedValueKeepsTail() {
        // Terminal scrollback: the bottom of the buffer is what's on screen.
        let head = String(repeating: "alpha beta ", count: 5_000)
        let tail = "Lukwise deploy finished"
        let out = AccessibilityParserConfig.truncatedValue(head + tail)
        XCTAssertLessThanOrEqual(out.count, AccessibilityParserConfig.maxElementValueLength + 1)
        XCTAssertTrue(out.hasSuffix(tail), "tail content must survive truncation")
        XCTAssertTrue(out.hasPrefix("…"), "truncation must be visible in the snapshot")
    }

    func testTruncationDropsLeadingWordFragment() {
        // The cut lands mid-word; the fragment must not survive to be mined as
        // a garbage glossary term (e.g. "…aaaLukwise").
        let text = String(repeating: "a", count: 50_000) + "Lukwise deploy finished"
        let out = AccessibilityParserConfig.truncatedValue(text)
        XCTAssertEqual(out, "…deploy finished")
    }

    func testTruncationKeepsSingleGiantToken() {
        // No whitespace anywhere - keep the raw tail rather than returning nothing.
        let text = String(repeating: "x", count: 50_000)
        let out = AccessibilityParserConfig.truncatedValue(text)
        XCTAssertEqual(out.count, AccessibilityParserConfig.maxElementValueLength + 1)
        XCTAssertTrue(out.hasPrefix("…"))
    }

    func testValueAtLimitNotTruncated() {
        let text = String(repeating: "b", count: AccessibilityParserConfig.maxElementValueLength)
        XCTAssertEqual(AccessibilityParserConfig.truncatedValue(text), text)
    }

    func testTotalBudgetExceedsPerElementBudget() {
        // The total cap is checked before appending, so the final string can
        // overshoot by at most one (already truncated) element value.
        XCTAssertGreaterThan(
            AccessibilityParserConfig.maxCapturedTextLength,
            AccessibilityParserConfig.maxElementValueLength)
    }

    // MARK: - Mining text assembly

    func testMiningTextJoinsTextBearingKeys() {
        let parsed = [
            AccessibilityParsedElements.applicationName: "Terminal",
            AccessibilityParsedElements.applicationTitle: "kalender-analysis",
            AccessibilityParsedElements.screen: "Kalender VOK-07 rollout",
            AccessibilityParsedElements.elapsedTime: "0.42",
        ]
        let text = TranscriptionManager.axMiningText(from: parsed)
        XCTAssertTrue(text.contains("kalender-analysis"), "window title carries project names")
        XCTAssertTrue(text.contains("Kalender VOK-07 rollout"))
        XCTAssertFalse(text.contains("0.42"), "elapsedTime is metadata, not vocabulary")
    }

    func testMiningTextDropsUnknownPlaceholders() {
        // AccessibilityParser writes "Unknown" when the app name/title can't be
        // resolved - that must not leak into the mining input.
        let parsed = [
            AccessibilityParsedElements.applicationName: "Unknown",
            AccessibilityParsedElements.screen: "  Raudin sync at 3pm  ",
        ]
        XCTAssertEqual(TranscriptionManager.axMiningText(from: parsed), "Raudin sync at 3pm")
    }

    func testMiningTextEmptyWhenNothingParsed() {
        XCTAssertEqual(TranscriptionManager.axMiningText(from: [:]), "")
        XCTAssertEqual(
            TranscriptionManager.axMiningText(from: [AccessibilityParsedElements.screen: "   "]), "")
    }

    func testMiningTextDeterministicOrder() {
        let parsed = [
            AccessibilityParsedElements.screen: "beta",
            AccessibilityParsedElements.highlightedText: "alpha",
        ]
        // Keys sort alphabetically: highlightedText < screen.
        XCTAssertEqual(TranscriptionManager.axMiningText(from: parsed), "alpha\nbeta")
    }
}
