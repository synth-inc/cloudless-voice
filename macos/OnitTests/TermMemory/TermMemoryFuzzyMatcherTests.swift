// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryFuzzyMatcherTests.swift
//  OnitTests
//
//  Tier-2 gated restore: the v8 thresholds (char-edit ≤ len/8, phone-edit ≤
//  phones/6) plus the production guards - fuzzy only on OOV spans, exact
//  gated rewrites need a non-everyday token, ambiguous matches never fire.
//  Also covers the trie-alias merge (saved dictionary wins).
//

import XCTest
@testable import Onit

final class TermMemoryFuzzyMatcherTests: XCTestCase {

    /// Small everyday-English stub. Everything in it is "known"; the first
    /// tier (everyday) is the same set for these tests.
    private let english: Set<String> = [
        "the", "team", "luck", "wise", "about", "let's", "be", "it", "meeting",
        "with", "calendar", "on", "was", "great", "not", "in",
    ]

    private func matcher(_ candidates: [TermMemoryFuzzyMatcher.Candidate],
                         language: String? = nil) -> TermMemoryFuzzyMatcher {
        TermMemoryFuzzyMatcher(
            candidates: candidates,
            language: language,
            isKnownEnglishWord: { self.english.contains($0.lowercased()) },
            isEverydayWord: { self.english.contains($0.lowercased()) },
            phonesForSpoken: { PhoneticLexicon.lettersToSound($0) })
    }

    private var lukwise: TermMemoryFuzzyMatcher.Candidate {
        .init(display: "Lukwise",
              phones: PhoneticLexicon.lettersToSound("lukwise"),
              surfaceNorms: ["luckwise", "luckwise".replacingOccurrences(of: " ", with: "")])
    }

    func testOOVCharEditRestores() {
        // "lackwise" is OOV, 1 char edit from the predicted surface "luckwise".
        let m = matcher([lukwise])
        let (text, applied) = m.apply(to: "the lackwise team meeting")
        XCTAssertEqual(text, "the Lukwise team meeting")
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].original, "lackwise")
    }

    func testEverydayPhraseIsNeverRewritten() {
        // "luck wise" normalizes to a predicted surface, but both tokens are
        // everyday words - the calendar→Calendly guard must hold.
        let m = matcher([lukwise])
        let (text, applied) = m.apply(to: "let's be luck wise about it")
        XCTAssertEqual(text, "let's be luck wise about it")
        XCTAssertTrue(applied.isEmpty)
    }

    func testCanonicalSpanUntouched() {
        let m = matcher([lukwise])
        let (text, applied) = m.apply(to: "the Lukwise team")
        XCTAssertEqual(text, "the Lukwise team")
        XCTAssertTrue(applied.isEmpty)
    }

    func testAmbiguousMatchDoesNotFire() {
        let other = TermMemoryFuzzyMatcher.Candidate(
            display: "Werkwize",
            phones: PhoneticLexicon.lettersToSound("werkwize"),
            surfaceNorms: ["luckwise"])
        let m = matcher([lukwise, other])
        let (text, applied) = m.apply(to: "the luckwise team")
        XCTAssertEqual(text, "the luckwise team")
        XCTAssertTrue(applied.isEmpty)
    }

    func testDistantSpanDoesNotMatch() {
        let m = matcher([lukwise])
        let (text, applied) = m.apply(to: "the woodworking team")
        XCTAssertEqual(text, "the woodworking team")
        XCTAssertTrue(applied.isEmpty)
    }

    // MARK: - Rewrite guards

    func testShortSpanIsNeverFuzzyMatched() {
        // "sdk" is OOV and one edit from the stored "SDL", which the len/8
        // budget alone would accept - the length floor is what stops it.
        let sdl = TermMemoryFuzzyMatcher.Candidate(
            display: "SDL", phones: [], surfaceNorms: ["sdl"])
        let (text, applied) = matcher([sdl]).apply(to: "the sdk team")
        XCTAssertEqual(text, "the sdk team")
        XCTAssertTrue(applied.isEmpty)
    }

    func testNonEnglishDictationIsLeftAlone() {
        // Same span that restores in English: the surfaces and the OOV test
        // are English-only, so a French dictation must not be rewritten.
        let (french, frenchApplied) = matcher([lukwise], language: "fr")
            .apply(to: "the lackwise team meeting")
        XCTAssertEqual(french, "the lackwise team meeting")
        XCTAssertTrue(frenchApplied.isEmpty)

        let (english, englishApplied) = matcher([lukwise], language: "en-US")
            .apply(to: "the lackwise team meeting")
        XCTAssertEqual(english, "the Lukwise team meeting")
        XCTAssertEqual(englishApplied.count, 1)
    }

    func testLetterlessTokenIsNotOutOfVocabulary() {
        // "202402" is absent from any word list by construction; treating it
        // as OOV would open the fuzzy tiers on plain numbers.
        let build = TermMemoryFuzzyMatcher.Candidate(
            display: "202401", phones: [], surfaceNorms: ["202401"])
        let (text, applied) = matcher([build]).apply(to: "the 202402 meeting")
        XCTAssertEqual(text, "the 202402 meeting")
        XCTAssertTrue(applied.isEmpty)
    }

    func testEditDistance() {
        XCTAssertEqual(TermMemoryFuzzyMatcher.editDistance(Array("luckwise"), Array("lackwise")), 1)
        XCTAssertEqual(TermMemoryFuzzyMatcher.editDistance(Array("abc"), Array("abc")), 0)
        // Length gap > 3 short-circuits to the cap.
        XCTAssertEqual(TermMemoryFuzzyMatcher.editDistance(Array("ab"), Array("abcdefg"), cap: 99), 99)
    }

    // MARK: - Trie-alias merge

    func testMemoryAliasesMergeUnderSavedDictionary() {
        let saved = ["Kalender": ["Calender"]]
        let memory = ["Lukwise": ["luckwise", "lackwise"], "Other": ["Calender", "otherr"]]
        let merged = TranscriptionManager.mergingMemoryAliases(into: saved, memory: memory)
        XCTAssertEqual(merged["Kalender"], ["Calender"])                // untouched
        XCTAssertEqual(merged["Lukwise"], ["luckwise", "lackwise"])
        XCTAssertEqual(merged["Other"], ["otherr"])                     // "Calender" already claimed
    }

    func testMemoryTermAlreadySavedIsSkipped() {
        let saved = ["Kalender": ["Calender"]]
        let memory = ["kalender": ["kalinder"]]
        let merged = TranscriptionManager.mergingMemoryAliases(into: saved, memory: memory)
        XCTAssertEqual(merged, saved)  // saved dictionary owns the term
    }
}
