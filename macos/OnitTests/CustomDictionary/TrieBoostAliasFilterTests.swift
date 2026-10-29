// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TrieBoostAliasFilterTests.swift
//  OnitTests
//
//  The alias filter is the precision guard for decode-time trie boosting: a
//  surface that passes becomes an UNCONDITIONAL rewrite in the Qwen3 decoder,
//  so anything a user might legitimately dictate must be rejected here.
//

import XCTest
@testable import Onit

final class TrieBoostAliasFilterTests: XCTestCase {

    /// Known-English stub: a small fixed vocabulary standing in for the 100k list.
    private let english: Set<String> = [
        "calendar", "not", "in", "audit", "on", "it", "the", "saturday", "nodded",
    ]
    private func isEnglish(_ w: String) -> Bool { english.contains(w.lowercased()) }

    func testRareSurfacesPass() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Calender", "Kalinder"]), ("Fernardo", ["Fonardo", "Finardo"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertEqual(out["Kalender"], ["Calender", "Kalinder"])
        XCTAssertEqual(out["Fernardo"], ["Fonardo", "Finardo"])
    }

    func testRealWordsBlocked() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Calendar", "Calender"]), ("Onit", ["audit", "on it", "not in"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertEqual(out["Kalender"], ["Calender"])
        XCTAssertNil(out["Onit"], "every Onit alias is real English - all must be blocked")
    }

    func testMultiWordAliasBlockedOnlyWhenAllWordsEnglish() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Raudin", ["not in", "not Odin"])],
            isKnownEnglishWord: isEnglish)
        // "not in" = all English → blocked; "not Odin" contains non-English → passes.
        XCTAssertEqual(out["Raudin"], ["not Odin"])
    }

    func testAliasCollidingWithAnotherTermBlocked() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["calender"]), ("Calender", [])],
            isKnownEnglishWord: isEnglish)
        XCTAssertNil(out["Kalender"], "alias equal to another dictionary term must be blocked")
    }

    func testDuplicateAliasClaimedOnce() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Calender"]), ("Calendar", ["Calender"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertEqual(out["Kalender"], ["Calender"])
        XCTAssertNil(out["Calendar"], "an alias may only rewrite to one canonical term")
    }

    func testShortAliasesBlocked() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("AI", ["Ay", "I"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertNil(out["AI"])
    }

    func testTabSeparatedRealWordsBlocked() {
        // Splitting must cover ALL whitespace: "not\tin" is two real words.
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Raudin", ["not\tin"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertNil(out["Raudin"])
    }

    func testNonAlphabeticAliasBlocked() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("VOK-07", ["707", "0-7"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertNil(out["VOK-07"])
    }

    func testUntrimmedTermKeyIsTrimmed() {
        // Trie build looks up aliases by the trimmed term surface; keys must
        // match or aliases are silently dropped.
        let out = TranscriptionManager.safeBoostAliases(
            terms: [(" Kalender ", ["Calender"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertEqual(out["Kalender"], ["Calender"])
    }

    func testNewlineAliasTrimmed() {
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Calender\n"])],
            isKnownEnglishWord: isEnglish)
        XCTAssertEqual(out["Kalender"], ["Calender"])
    }

    func testNoListMeansNothingBlockedByEnglishTest() {
        // When the frequency list failed to load, isKnownEnglishWord is always
        // false - aliases still pass the other guards. Documents the tradeoff.
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Calendar"])],
            isKnownEnglishWord: { _ in false })
        XCTAssertEqual(out["Kalender"], ["Calendar"])
    }
}
