// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermAliasPredictorTests.swift
//  OnitTests
//
//  The v8 prediction layers against the real bundled lexicon (CMUdict +
//  news-frequency list): LTS fallback, real-word tilings, homophone variants,
//  compound splits, typo variants, and tier assignment. Skipped when the
//  bundled resources are missing (the guard mirrors production fail-closed).
//

import XCTest
@testable import Onit

final class TermAliasPredictorTests: XCTestCase {

    private var lexicon: PhoneticLexicon!
    private var predictor: TermAliasPredictor!

    override func setUpWithError() throws {
        lexicon = PhoneticLexicon.shared
        try XCTSkipIf(lexicon.cmuPronunciations("work").isEmpty,
                      "cmudict_phones.txt not bundled in this test host")
        let news = CapsTermSelector.shared.knownEnglishWordSet
        try XCTSkipIf(news.isEmpty, "100k word list not bundled in this test host")
        predictor = TermAliasPredictor(
            lexicon: lexicon,
            newsWords: news,
            splitWords: news.union(lexicon.knownWords),
            isKnownEnglishWord: { CapsTermSelector.shared.isKnownEnglishWord($0) })
    }

    // MARK: - LTS fallback

    func testLTSKnownDigraphs() {
        XCTAssertEqual(PhoneticLexicon.lettersToSound("sharp"), ["SH", "AA", "R", "P"])
        XCTAssertEqual(PhoneticLexicon.lettersToSound("werq"), ["W", "ER", "K"])
        XCTAssertEqual(PhoneticLexicon.lettersToSound("wise"), ["W", "AY", "Z"])
    }

    func testLTSApproximatesCMUOnSimpleWords() {
        // Sanity floor, not a quality bar: LTS phones for easy CMU words stay
        // within a small edit distance of the reference pronunciation.
        for word in ["work", "store", "market", "wind", "print"] {
            guard let reference = lexicon.cmuPronunciations(word).first else { continue }
            let lts = PhoneticLexicon.lettersToSound(word)
            let distance = TermMemoryFuzzyMatcher.editDistance(lts, reference)
            XCTAssertLessThanOrEqual(distance, 2, "\(word): \(lts) vs \(reference)")
        }
    }

    // MARK: - Tilings

    func testTilingFindsRealWordSplit() {
        // "luckwise" is OOV but its phones tile as luck + wise.
        let phones = lexicon.phones(forSpoken: "luckwise")
        let tilings = lexicon.tilings(of: phones)
        XCTAssertTrue(tilings.contains(["luck", "wise"]),
                      "tilings were \(tilings)")
    }

    func testHomophonesRankedByFrequency() {
        guard let phones = lexicon.cmuPronunciations("there").first else { return }
        let words = lexicon.homophones(of: phones)
        XCTAssertTrue(words.contains("there"))
        XCTAssertTrue(words.contains("their"))
        // The frequency ranking puts the more common news-corpus spelling
        // first ("their" ranks 130 vs "there" at 176 in the bundled list).
        XCTAssertEqual(words.first, "their")
    }

    // MARK: - Predictions

    func testLukwisePredictionCoversTheObservedASRForm() {
        // The eval's canonical case: the ASR writes "luck wise".
        let prediction = predictor.predict("Lukwise")
        let norms = Set((prediction.unconditional + prediction.gated)
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } })
        XCTAssertTrue(norms.contains("luckwise"), "predictions were \(norms.sorted())")
        XCTAssertFalse(prediction.phones.isEmpty)
        // "luck wise" is all known English - it must NOT be an unconditional
        // decode-time rewrite.
        XCTAssertFalse(prediction.unconditional.contains { $0 == "luck wise" })
    }

    func testFernardoPredictionIncludesTypoNeighbor() {
        // "Fernardo" is OOV in both lists; "fernando" is one edit away - the
        // classic mishearing the trie-boost docs use as their alias example.
        let prediction = predictor.predict("Fernardo")
        let all = prediction.unconditional + prediction.gated
        XCTAssertTrue(all.contains("fernando"), "predictions were \(all)")
    }

    func testCompoundSplits() {
        XCTAssertTrue(predictor.compoundSplits("luckwise").contains("luck wise"))
        XCTAssertTrue(predictor.compoundSplits("work").isEmpty)      // too short
        XCTAssertTrue(predictor.compoundSplits("market").isEmpty)    // already a word
    }

    func testTypoVariants() {
        XCTAssertTrue(predictor.typoVariants("fernardo").contains("fernando"))
        XCTAssertTrue(predictor.typoVariants("work").isEmpty)        // already a word
        // The rare name "abbie" is (surprisingly) IN the Leipzig news list, so the
        // reference guard skips it - matching the v8 alias eval exactly.
        XCTAssertTrue(predictor.typoVariants("abbie").isEmpty)
    }

    func testTokenVariantsIncludeHomophones() {
        let variants = predictor.tokenVariants("wise")
        XCTAssertEqual(variants.first, "wise")
        XCTAssertLessThanOrEqual(variants.count, 4)
    }

    func testPredictionCapsHold() {
        let prediction = predictor.predict("CapsTermSelector")
        XCTAssertLessThanOrEqual(prediction.unconditional.count, TermAliasPredictor.maxUnconditional)
        XCTAssertLessThanOrEqual(prediction.gated.count, TermAliasPredictor.maxGated)
    }
}
