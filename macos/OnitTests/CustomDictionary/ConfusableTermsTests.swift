// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ConfusableTermsTests.swift
//  OnitTests
//
//  Layer C mining decides "is this word worth putting in the ASR glossary?" by
//  asking whether it is out-of-vocabulary. The vocabulary is a news crawl, which
//  is wrong in both directions: it lists rare names ("Yann", "Abbie") as common
//  English so they were never mined, and it clears true homophones ("Wright",
//  "Moore") that the model reliably mis-transcribes.
//
//  `asr_confusable_terms.txt` is the measured correction - every word the ASR
//  failed to reproduce in an offline TTS→ASR sweep. These tests pin the contract:
//  the list is bundled, it widens the MINING net, and it leaves the trie-boost
//  alias guard (`isKnownEnglishWord`) untouched, since that guard must stay
//  permissive or real English words become unconditional decode-time rewrites.
//

import XCTest
@testable import Onit

final class ConfusableTermsTests: XCTestCase {

    private var selector: CapsTermSelector { CapsTermSelector.shared }

    /// Lowercase so the caps heuristic can't select the token - this isolates
    /// the out-of-vocabulary path, which is what the confusable list changes.
    private func minedTerms(_ text: String) -> [String] {
        selector.selectCapsTerms(text).map { $0.lowercased() }
    }

    func testBundledResourceLoaded() {
        XCTAssertTrue(selector.hasCommonWordList, "frequency list must load or every guard degrades")
        // If the .txt failed to bundle, nothing below can pass - assert it directly
        // so the failure names the real cause instead of looking like a logic bug.
        XCTAssertNotNil(Bundle.main.url(forResource: "asr_confusable_terms", withExtension: "txt"),
                        "asr_confusable_terms.txt is missing from the app bundle")
    }

    // MARK: - The list widens the mining net

    func testConfusableWordsAreMinedDespiteBeingInTheNewsList() {
        // All of these are in the Leipzig 100k list, so before the confusable
        // list they read as "common English, not caps" and were dropped.
        for word in ["wright", "moore", "leeds", "singh", "yann", "abbie"] {
            XCTAssertTrue(minedTerms("we discussed \(word) today").contains(word),
                          "\"\(word)\" is a measured ASR confusion and must be minable")
        }
    }

    func testNonConfusableCommonWordsStillDropped() {
        // The other half of the contract: words the ASR gets right stay common,
        // so they never occupy a glossary slot. Several of these were wrongly
        // flagged by the single-voice sweep and rescued by the multi-voice one.
        for word in ["ohio", "george", "nato", "brought", "gaza", "musk"] {
            XCTAssertFalse(minedTerms("we discussed \(word) today").contains(word),
                           "\"\(word)\" is recognised correctly and must not pollute the glossary")
        }
    }

    // MARK: - The alias guard must NOT narrow

    func testAliasGuardStillSeesConfusableWordsAsEnglish() {
        // `isKnownEnglishWord` gates trie-boost aliases, where a false negative
        // turns a real English word into an unconditional rewrite of the user's
        // speech. It reads the FULL list, so the confusable subtraction must not
        // reach it - "wright" is still English even though the ASR mishears it.
        for word in ["wright", "moore", "leeds", "singh"] {
            XCTAssertTrue(selector.isKnownEnglishWord(word),
                          "alias guard must stay permissive for \"\(word)\"")
        }
    }

    func testAliasFilterStillBlocksConfusableSurfaces() {
        // End-to-end version of the guard above, through the real filter.
        let out = TranscriptionManager.safeBoostAliases(
            terms: [("Kalender", ["Wright", "Calender"])],
            isKnownEnglishWord: { CapsTermSelector.shared.isKnownEnglishWord($0) })
        XCTAssertEqual(out["Kalender"], ["Calender"],
                       "\"Wright\" is real English and must never become a decode-time rewrite")
    }

    // MARK: - Unaffected neighbours

    func testEverydayTestUnchanged() {
        // The format matcher's ambiguity test reads the top-25k `everyday` set,
        // which the confusable list does not touch.
        XCTAssertTrue(selector.isCommonWord("brought"))
        XCTAssertTrue(selector.isCommonWord("outcome"))
    }

    func testSpellingVariantNamesAreMinedButCanonicalIsNot() {
        // The case that motivated the whole sweep: dictating "Abbie" produced
        // "Abby" because the news list called Abbie common English, so mining
        // skipped it. The ASR defaults to the canonical spelling, so the variants
        // need biasing and the canonical one does not - measured, not guessed.
        for variant in ["abbie", "abbey", "alison", "allan"] {
            XCTAssertTrue(minedTerms("email \(variant) about it").contains(variant),
                          "\"\(variant)\" is a spelling variant the ASR collapses; it must be minable")
        }
        for canonical in ["abby", "aaron", "gina"] {
            XCTAssertFalse(minedTerms("email \(canonical) about it").contains(canonical),
                           "\"\(canonical)\" is transcribed correctly and must stay common")
        }
    }

    func testGenuinelyOOVTermsStillMined() {
        // Terms absent from the news list entirely were always minable and must
        // stay that way - this is the path Raudin/Lukwise/Fernardo take.
        for word in ["raudin", "lukwise", "fernardo"] {
            XCTAssertTrue(minedTerms("shipping \(word) tomorrow").contains(word))
        }
    }
}
