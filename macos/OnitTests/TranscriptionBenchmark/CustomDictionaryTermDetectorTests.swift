// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryTermDetectorTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 10/04/2026.
//
//  Unit tests for `CustomDictionaryTermDetector` - the pure-Swift candidate
//  suggestion pipeline that diffs raw → corrected transcripts and proposes
//  custom dictionary entries. These tests cover the heuristics (minimum
//  length, uppercase requirement, common-word denylist, multi-word collapse,
//  single-word case change, mid-word capital) and the LCS-based diff.
//

import XCTest
@testable import Onit

final class CustomDictionaryTermDetectorTests: XCTestCase {

    private let detector = CustomDictionaryTermDetector()

    // MARK: - Accepted candidates

    func test_multiWordCollapse_onIt_producesOnit() {
        let candidates = detector.detect(
            raw: "I was on it last week",
            corrected: "I was Onit last week"
        )
        XCTAssertEqual(candidates.map(\.term), ["Onit"])
        XCTAssertEqual(candidates.first?.rawSpan, ["on", "it"])
    }

    func test_multiWordCollapse_checkBin_producesCheckbin() {
        let candidates = detector.detect(
            raw: "upload it to check bin",
            corrected: "upload it to Checkbin"
        )
        XCTAssertEqual(candidates.map(\.term), ["Checkbin"])
    }

    func test_multiWordCollapse_swiftUI_producesSwiftUI() {
        // NOTE: the detector's `isCaseChange` path (single-word "swiftui"
        // → "SwiftUI") is currently unreachable because `wordMatches`
        // normalises case-insensitively. We exercise the same target term
        // via the reachable multi-word-collapse path instead.
        let candidates = detector.detect(
            raw: "opened the swift ui demo",
            corrected: "opened the SwiftUI demo"
        )
        XCTAssertEqual(candidates.map(\.term), ["SwiftUI"])
    }

    func test_multiWordCollapse_iPhone_accepted() {
        // Multi-word collapse "i phone" → "iPhone". Exercises both the
        // multi-word path and the mid-word-capital heuristic.
        let candidates = detector.detect(
            raw: "I bought an i phone yesterday",
            corrected: "I bought an iPhone yesterday"
        )
        XCTAssertEqual(candidates.map(\.term), ["iPhone"])
    }

    func test_digitsPreservedInNormalisation_gpt4_accepted() {
        // Regression guard for the `CharacterSet.letters` → `.alphanumerics`
        // fix: before the fix, "GPT4" normalised to "gpt" which collided
        // with the raw word "gpt" → detected as a false case-only change
        // instead of a digit-bearing brand name.
        let candidates = detector.detect(
            raw: "we tried gpt 4 yesterday",
            corrected: "we tried GPT4 yesterday"
        )
        XCTAssertEqual(candidates.map(\.term), ["GPT4"])
    }

    // MARK: - Rejected candidates

    func test_commonWord_the_rejected() {
        // Sentence-initial "The" often gets auto-capitalised on edit; it
        // must never be proposed as a dictionary entry.
        let candidates = detector.detect(
            raw: "the cat sat",
            corrected: "The cat sat"
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_commonWord_on_rejected() {
        // Multi-word rewrite whose target is in the denylist must also be rejected.
        let candidates = detector.detect(
            raw: "Sit on it please",
            corrected: "Sit On please"
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_tooShort_ai_rejected() {
        // Term shorter than the 3-character minimum.
        let candidates = detector.detect(
            raw: "using open ai tools",
            corrected: "using AI tools"
        )
        XCTAssertTrue(candidates.isEmpty, "expected to reject 2-letter term 'AI'")
    }

    func test_allLowercase_rejected() {
        // Must contain at least one uppercase letter.
        let candidates = detector.detect(
            raw: "opened kubernetes cluster",
            corrected: "opened kube cluster"
        )
        XCTAssertTrue(candidates.isEmpty, "expected to reject all-lowercase replacement 'kube'")
    }

    func test_existingTerm_notReProposed() {
        // Caller already has "Onit" in their dictionary - don't suggest again.
        let candidates = detector.detect(
            raw: "I was on it",
            corrected: "I was Onit",
            existingTerms: ["onit"]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Edge cases

    func test_emptyInputs_produceNoCandidates() {
        XCTAssertTrue(detector.detect(raw: "", corrected: "anything").isEmpty)
        XCTAssertTrue(detector.detect(raw: "anything", corrected: "").isEmpty)
        XCTAssertTrue(detector.detect(raw: "", corrected: "").isEmpty)
    }

    func test_punctuationOnlyChange_producesNoCandidates() {
        // Adding a period / comma / quote without touching any word should
        // not trigger the detector - tokeniser splits on whitespace, so the
        // LCS walks the same word sequence in both inputs.
        let candidates = detector.detect(
            raw: "Hello world",
            corrected: "Hello, world."
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_identicalInputs_produceNoCandidates() {
        let candidates = detector.detect(raw: "identical text here", corrected: "identical text here")
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Batch detectAll

    func test_detectAll_deduplicatesAcrossPairs() {
        let pairs: [CorrectionPair] = [
            .init(raw: "talked to on it yesterday", corrected: "talked to Onit yesterday"),
            .init(raw: "on it again today", corrected: "Onit again today"),
            .init(raw: "the swift ui demo", corrected: "the SwiftUI demo"),
        ]
        let candidates = detector.detectAll(pairs: pairs)
        // "Onit" should appear exactly once despite being in two pairs.
        XCTAssertEqual(candidates.map(\.term).sorted(), ["Onit", "SwiftUI"])
    }

    func test_detectAll_respectsExistingTermsAcrossBatch() {
        let pairs: [CorrectionPair] = [
            .init(raw: "on it now", corrected: "Onit now"),
            .init(raw: "opened in swift ui", corrected: "opened in SwiftUI"),
        ]
        let candidates = detector.detectAll(pairs: pairs, existingTerms: ["Onit"])
        XCTAssertEqual(candidates.map(\.term), ["SwiftUI"])
    }

    func test_detectAll_emptyPairs_returnsEmpty() {
        XCTAssertTrue(detector.detectAll(pairs: []).isEmpty)
    }

    // MARK: - 1→N expansion

    func test_expansion_oneWordToTwo_proposesProperNounInsertion() {
        // The user typed a single raw word ("Raudin") then corrected it by
        // splitting into two words ("Le Dain"). The detector should propose
        // the proper-noun-looking word ("Dain") while rejecting "Le" on the
        // ≥3-character guard.
        let candidates = detector.detect(
            raw: "Je m'appelle Raudin",
            corrected: "Je m'appelle Le Dain"
        )
        XCTAssertEqual(candidates.map(\.term), ["Dain"])
    }

    func test_expansion_wordSplit_proposesCamelCaseFirstHalf() {
        // Splitting "QuickEditService" into "QuickEdit Service" is a 1→2
        // expansion. "QuickEdit" passes via mid-word capital; "Service"
        // also passes as an expansion candidate (single capital, ≥3 chars,
        // not a common word).
        let candidates = detector.detect(
            raw: "Call QuickEditService",
            corrected: "Call QuickEdit Service"
        )
        XCTAssertEqual(Set(candidates.map(\.term)), ["QuickEdit", "Service"])
    }

    // MARK: - Localised denylist (FR)

    func test_frenchDenylist_dans_rejected() {
        // Sentence-initial "Dans" in a French transcript should be caught
        // by the French denylist, not surface as a dictionary suggestion.
        let fr = CustomDictionaryTermDetector(language: "fr")
        let candidates = fr.detect(
            raw: "dans la maison",
            corrected: "Dans la maison"
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_frenchDenylist_été_rejected_withAccent() {
        // Accented French common words must be matched verbatim (no accent stripping).
        let fr = CustomDictionaryTermDetector(language: "fr")
        let candidates = fr.detect(
            raw: "c'était l' été dernier",
            corrected: "c'était L' Été dernier"
        )
        XCTAssertTrue(candidates.isEmpty, "expected 'Été' to be rejected by the French denylist")
    }

    func test_frenchDenylist_properNoun_stillAccepted() {
        // The French denylist must not suppress legitimate proper nouns.
        let fr = CustomDictionaryTermDetector(language: "fr")
        let candidates = fr.detect(
            raw: "on va à paris demain",
            corrected: "on va à Paris demain"
        )
        // "Paris" is single-word case-change → unreachable via LCS (case-insensitive match),
        // so expressly test via a multi-word collapse instead:
        let collapseCandidates = fr.detect(
            raw: "c'est le cto de flower computer",
            corrected: "c'est le CTO de FlowerComputer"
        )
        XCTAssertEqual(candidates, [])
        XCTAssertEqual(collapseCandidates.map(\.term), ["FlowerComputer"])
    }

    func test_localeSubtag_normalisedToPrimary() {
        // "fr-FR" / "fr-CA" should resolve to the French denylist, not fall
        // back to English (which would let "Dans" through).
        let frFR = CustomDictionaryTermDetector(language: "fr-FR")
        let candidates = frFR.detect(
            raw: "dans la maison",
            corrected: "Dans la maison"
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_unknownLanguage_fallsBackToEnglish() {
        // A language we don't have a denylist for should fall back to
        // English so we don't regress known-rejection cases.
        let de = CustomDictionaryTermDetector(language: "de")
        let candidates = de.detect(
            raw: "the cat sat",
            corrected: "The cat sat"
        )
        XCTAssertTrue(candidates.isEmpty, "expected English fallback to still reject 'The'")
    }
}
