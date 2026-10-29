// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermHumanizerAdmissionTests.swift
//  OnitTests
//
//  Humanizer: spoken renderings must match the reference script
//  (the v8 alias eval's humanizer) - the alias predictor and the TTS ground truth both
//  operate in that spoken space. Admission: the surface gates that keep junk
//  out of the bias list (the large-K stress test's mandatory filter).
//

import XCTest
@testable import Onit

final class TermHumanizerAdmissionTests: XCTestCase {

    // MARK: - Humanizer

    func testCamelCaseSplits() {
        XCTAssertEqual(TermHumanizer.humanize("Lukwise"), "Lukwise")
        XCTAssertEqual(TermHumanizer.humanize("CapsTermSelector"), "Caps Term Selector")
        XCTAssertEqual(TermHumanizer.humanize("iPhone"), "i Phone")
        XCTAssertEqual(TermHumanizer.humanize("HTMLParser"), "HTML Parser")
    }

    func testSeparatorsSplit() {
        XCTAssertEqual(TermHumanizer.humanize("snake_case"), "snake case")
        XCTAssertEqual(TermHumanizer.humanize("kebab-case"), "kebab case")
        XCTAssertEqual(TermHumanizer.humanize("a.b/c"), "a b c")
    }

    func testNumbers() {
        XCTAssertEqual(TermHumanizer.humanize("Qwen3ASR"), "Qwen three ASR")
        XCTAssertEqual(TermHumanizer.humanize("v42"), "v forty two")
        XCTAssertEqual(TermHumanizer.humanize("S3"), "S three")
        XCTAssertEqual(TermHumanizer.humanize("255"), "two hundred fifty five")
        XCTAssertEqual(TermHumanizer.humanize("2026"), "two zero two six")
    }

    func testNumberWords() {
        XCTAssertEqual(TermHumanizer.numberWords(0), "zero")
        XCTAssertEqual(TermHumanizer.numberWords(15), "fifteen")
        XCTAssertEqual(TermHumanizer.numberWords(90), "ninety")
        XCTAssertEqual(TermHumanizer.numberWords(101), "one hundred one")
    }

    // MARK: - Admission gate 1: dictatable

    func testDictatableAcceptsRealTerms() {
        for term in ["Kalender", "Lukwise", "Qwen3ASR", "snake_case", "NLL"] {
            XCTAssertTrue(TermAdmission.isDictatable(term), term)
        }
        // Note: "v42" is REJECTED by the reference rules (2 of 3 chars are
        // digits > the 40% cap) - matching the v8 alias eval, not a bug.
        XCTAssertFalse(TermAdmission.isDictatable("v42"))
    }

    func testDictatableRejectsUndictatableSurfaces() {
        XCTAssertFalse(TermAdmission.isDictatable("deadbeef01"))          // hex run
        XCTAssertFalse(TermAdmission.isDictatable("550e8400-e29b-41d4"))  // UUID chunk
        XCTAssertFalse(TermAdmission.isDictatable("A1234567"))            // digit run
        XCTAssertFalse(TermAdmission.isDictatable("a1b2c3"))              // dense alternation
        XCTAssertFalse(TermAdmission.isDictatable("x123456789"))          // mostly digits
        XCTAssertFalse(TermAdmission.isDictatable(
            "averyverylongtokenthatnobodywouldsay"))                      // > 24 chars
    }

    // MARK: - Admission gate 2: pronounceable

    /// The production configuration: trigrams trained on the bundled 100k
    /// news list (the tiny-corpus alternative is too sparse - real trigram
    /// statistics are what the −3.1 floor was tuned against).
    private func makeAdmission() throws -> TermAdmission {
        let news = CapsTermSelector.shared.knownEnglishWordSet
        try XCTSkipIf(news.isEmpty, "100k word list not bundled in this test host")
        return TermAdmission(
            trigrams: TermAdmission.TrigramModel(words: news),
            knownWords: news)
    }

    func testPronounceableAcceptsKnownAndEnglishLike() throws {
        let admission = try makeAdmission()
        XCTAssertTrue(admission.isPronounceable("work"))       // known word
        XCTAssertTrue(admission.isPronounceable("luckwise"))   // unknown, English-like
        XCTAssertTrue(admission.isPronounceable("Kalender"))   // unknown, English-like
        XCTAssertTrue(admission.isPronounceable("term_store")) // splits to known words
    }

    func testPronounceableRejectsGarble() throws {
        let admission = try makeAdmission()
        XCTAssertFalse(admission.isPronounceable("xqzjwv"))
        XCTAssertFalse(admission.isPronounceable("lqjxwk"))
    }

    func testShortTokensAreNotScored() throws {
        // "v4" humanizes to "v four" - "four" is a known word; nothing to score.
        let admission = try makeAdmission()
        XCTAssertTrue(admission.isPronounceable("v4"))
    }
}
