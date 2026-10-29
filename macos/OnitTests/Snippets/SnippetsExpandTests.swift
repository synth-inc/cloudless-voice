// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SnippetsExpandTests.swift
//  OnitTests
//
//  Unit tests for the pure dictation-expansion matcher.
//
//  Created by Kévin Naudin on 17/06/2026.
//

import XCTest
@testable import Onit

final class SnippetsExpandTests: XCTestCase {

    private func snippet(
        _ name: String,
        _ replacement: String,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        appendsKeyword: Bool = false
    ) -> Snippet {
        Snippet(
            name: name,
            replacement: replacement,
            createdAt: createdAt,
            appendsKeyword: appendsKeyword
        )
    }

    // MARK: - Basics

    func testSingleMatch() {
        let result = SnippetsService.expand(
            in: "please send my email and confirm",
            snippets: [snippet("my email", "elise@x.com")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "please send elise@x.com and confirm")
    }

    func testCaseInsensitiveMatch() {
        let result = SnippetsService.expand(
            in: "My Email please",
            snippets: [snippet("my email", "elise@x.com")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "elise@x.com please")
    }

    func testNoChangeWhenNoMatch() {
        let transcript = "nothing to expand here"
        let result = SnippetsService.expand(
            in: transcript,
            snippets: [snippet("my email", "elise@x.com")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, transcript)
    }

    // MARK: - Word boundaries

    func testDoesNotMatchInsideLargerWord() {
        // "cat" must not fire inside "category".
        let transcript = "the category of cat food"
        let result = SnippetsService.expand(
            in: transcript,
            snippets: [snippet("cat", "DOG")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "the category of DOG food")
    }

    func testMatchAtStartAndEnd() {
        let result = SnippetsService.expand(
            in: "sig",
            snippets: [snippet("sig", "Best, Kevin")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "Best, Kevin")
    }

    func testMatchAdjacentToPunctuation() {
        let result = SnippetsService.expand(
            in: "here: my email.",
            snippets: [snippet("my email", "elise@x.com")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "here: elise@x.com.")
    }

    func testUnderscoreIsWordCharacter() {
        // "cat" must not fire inside the identifier "cat_dog".
        let result = SnippetsService.expand(
            in: "set the cat_dog flag",
            snippets: [snippet("cat", "DOG")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "set the cat_dog flag")
    }

    // MARK: - Multiple occurrences

    func testMultipleOccurrences() {
        let result = SnippetsService.expand(
            in: "sig then sig again",
            snippets: [snippet("sig", "X")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "X then X again")
    }

    // MARK: - Overlap / precedence

    func testLongestNameWinsOnOverlap() {
        let short = snippet("follow up", "SHORT")
        let long = snippet("follow up email", "LONG")
        let result = SnippetsService.expand(
            in: "send a follow up email now",
            snippets: [short, long],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "send a LONG now")
    }

    func testPrecedenceUsesEffectiveTriggerLengthNotBaseNameLength() {
        // A short base whose effective trigger is long (base + long keyword) must
        // outrank a longer BARE base it overlaps. Sorting by name.count would pick
        // the bare "hi there" (8 chars) over the base "hi" (2 chars) and produce
        // "say PARTIAL everyone now"; sorting by effective-trigger length picks
        // "hi there everyone" (17 chars) and produces "say GREETING now".
        let composed = snippet("hi", "GREETING", appendsKeyword: true)
        let bare = snippet("hi there", "PARTIAL", appendsKeyword: false)
        let result = SnippetsService.expand(
            in: "say hi there everyone now",
            snippets: [bare, composed],
            keyword: "there everyone"
        )
        XCTAssertEqual(result, "say GREETING now")
    }

    // MARK: - Anti-cascade

    func testReplacementIsNotReExpanded() {
        // Expanding A produces text that contains B's trigger; B must NOT fire on it.
        let a = snippet("greet", "hello jane")
        let b = snippet("jane", "Jane Doe")
        let result = SnippetsService.expand(
            in: "greet please",
            snippets: [a, b],
            keyword: "snippet"
        )
        // "greet" → "hello jane"; the injected "jane" is not re-scanned.
        XCTAssertEqual(result, "hello jane please")
    }

    func testSelfReferentialNameDoesNotLoop() {
        // Name appears in its own replacement - single pass, no infinite loop.
        let result = SnippetsService.expand(
            in: "say ab now",
            snippets: [snippet("ab", "ab cd")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "say ab cd now")
    }

    // MARK: - Multi-line replacement

    func testMultiLineReplacement() {
        let result = SnippetsService.expand(
            in: "insert mysig here",
            snippets: [snippet("mysig", "Line 1\nLine 2")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "insert Line 1\nLine 2 here")
    }

    // MARK: - Diacritics

    func testDiacriticsAreNotFolded() {
        // "cafe" must not match "café".
        let result = SnippetsService.expand(
            in: "meet at the cafe",
            snippets: [snippet("café", "STARBUCKS")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "meet at the cafe")
    }

    // MARK: - Degenerate input

    func testEmptyTranscript() {
        XCTAssertEqual(
            SnippetsService.expand(in: "", snippets: [snippet("a", "b")], keyword: "snippet"),
            ""
        )
    }

    func testEmptySnippets() {
        XCTAssertEqual(
            SnippetsService.expand(in: "hello", snippets: [], keyword: "snippet"),
            "hello"
        )
    }

    func testWhitespaceOnlyNameIsIgnored() {
        let result = SnippetsService.expand(
            in: "hello world",
            snippets: [snippet("   ", "X")],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "hello world")
    }

    // MARK: - Keyword composition

    func testKeywordCompositionMatchesBasePlusKeyword() {
        // appendsKeyword=true composes "my email" + "snippet" → "my email snippet".
        let result = SnippetsService.expand(
            in: "please send my email snippet now",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "please send elise@x.com now")
    }

    func testKeywordComposedTriggerDoesNotMatchBaseAlone() {
        // With appendsKeyword=true, the bare base must NOT fire without the keyword.
        let result = SnippetsService.expand(
            in: "please send my email now",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "please send my email now")
    }

    // MARK: - Custom keyword

    func testCustomKeyword() {
        let result = SnippetsService.expand(
            in: "say my email boop please",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: "boop"
        )
        XCTAssertEqual(result, "say elise@x.com please")
    }

    // MARK: - Multi-word keyword

    func testMultiWordKeyword() {
        let result = SnippetsService.expand(
            in: "say my email insert now please",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: "insert now"
        )
        XCTAssertEqual(result, "say elise@x.com please")
    }

    // MARK: - Empty-keyword fallback

    func testEmptyKeywordMatchesBaseEvenWhenAppendsKeyword() {
        // Empty keyword must fall back to the base name, never a trailing-space trigger.
        let result = SnippetsService.expand(
            in: "please send my email now",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: ""
        )
        XCTAssertEqual(result, "please send elise@x.com now")
    }

    func testWhitespaceOnlyKeywordMatchesBase() {
        // A whitespace-only keyword trims to empty and falls back to the base.
        let result = SnippetsService.expand(
            in: "please send my email now",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: true)],
            keyword: "   "
        )
        XCTAssertEqual(result, "please send elise@x.com now")
    }

    // MARK: - Opt-out (appendsKeyword=false)

    func testAppendsKeywordFalseMatchesBareNameIgnoringKeyword() {
        // A snippet that opts out matches its base name regardless of the keyword.
        let result = SnippetsService.expand(
            in: "please send my email now",
            snippets: [snippet("my email", "elise@x.com", appendsKeyword: false)],
            keyword: "snippet"
        )
        XCTAssertEqual(result, "please send elise@x.com now")
    }
}
