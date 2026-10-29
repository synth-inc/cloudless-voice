// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictionaryFormatMatcherTests.swift
//  OnitTests
//
//  The format-blind dictionary matcher: one mechanism restores any term's exact
//  written form (camelCase / snake_case / kebab-case / paths) - and the precision
//  guard leaves homophone phrases like "on it" untouched.
//

import Foundation
import Testing
@testable import Onit

@Suite("DictionaryFormatMatcher")
struct DictionaryFormatMatcherTests {

    /// Inject a tiny common-bigram set so tests are deterministic (production uses
    /// a 60k-entry bundle). Here only "on it" counts as a common English phrase.
    private func m(_ terms: [String], common: Set<String> = ["on it"]) -> DictionaryFormatMatcher {
        DictionaryFormatMatcher(terms: terms, commonBigrams: CommonBigrams(common))
    }

    @Test("camelCase is restored")
    func camelCase() {
        #expect(m(["CapsTermSelector"]).apply(to: "how the caps term selector works")
                == "how the CapsTermSelector works")
    }

    @Test("fuzzy: a morphological ASR variant of one token still matches")
    func fuzzyMorphological() {
        let mm = m(["capsSelected"])
        // STT heard "Selective" for "Selected"; "caps" anchors, one fuzzy token.
        #expect(mm.apply(to: "how does caps selective work") == "how does capsSelected work")
        // exact still works too
        #expect(mm.apply(to: "how does caps selected work") == "how does capsSelected work")
    }

    @Test("fuzzy: needs an exact anchor - a hard-mismatched token blocks the merge")
    func fuzzyNeedsAnchor() {
        // "cans" is not within a stem of "caps" → hard mismatch → no merge.
        #expect(m(["capsSelected"]).apply(to: "use cans selective now") == "use cans selective now")
    }

    @Test("fuzzy: at most ONE variant token - two fuzzy tokens reject")
    func fuzzyOneVariantMax() {
        // both tokens off (no anchor) → reject.
        #expect(m(["OnitKeyboard"]).apply(to: "the onity keyboart here") == "the onity keyboart here")
    }

    @Test("fuzzy: never applies to single-word terms (precision)")
    func fuzzySingleWordSafe() {
        #expect(m(["Onit"]).apply(to: "please audit this") == "please audit this")
    }

    @Test("gate plumbing: common-word spans are ambiguous; distinctive spans are not")
    func ambiguityFlag() {
        // "start recording" = both common English words → only sentence context
        // can decide → flagged for the perplexity gate.
        let (_, reps) = m(["start_recording"]).applyDetailed(to: "please start recording now")
        #expect(reps.count == 1 && reps[0].ambiguous)

        // "caps" is rare → distinctive → deterministic merge, no gate needed.
        let (_, reps2) = m(["CapsTermSelector"]).applyDetailed(to: "open the caps term selector")
        #expect(reps2.count == 1 && !reps2[0].ambiguous)

        // Single everyday word matching a formatted term ("trigger" → "_trigger")
        // is ambiguous too - back-test regression: junk dictionary terms must not
        // rewrite ordinary words ungated.
        let (_, reps3) = m(["_trigger"]).applyDetailed(to: "hit the trigger twice")
        #expect(reps3.count == 1 && reps3[0].ambiguous)
    }

    @Test("gate plumbing: excluded replacements are skipped")
    func excludedReplacementSkipped() {
        let mm = m(["start_recording"])
        let (_, reps) = mm.applyDetailed(to: "please start recording now")
        let (text, after) = mm.applyDetailed(to: "please start recording now",
                                             excluding: Set(reps))
        #expect(text == "please start recording now")
        #expect(after.isEmpty)
    }

    @Test("snake_case is restored")
    func snakeCase() {
        #expect(m(["custom_dictionary"]).apply(to: "the custom dictionary feature")
                == "the custom_dictionary feature")
    }

    @Test("kebab-case with a number - digits or words")
    func kebabAndNumber() {
        let mm = m(["qwen3-dictionary-ocr"])
        #expect(mm.apply(to: "the qwen 3 dictionary ocr branch") == "the qwen3-dictionary-ocr branch")
        #expect(mm.apply(to: "the qwen three dictionary ocr branch") == "the qwen3-dictionary-ocr branch")
    }

    @Test("path - symbols not spoken")
    func pathNoSymbols() {
        #expect(m(["macos/Onit.xcodeproj"]).apply(to: "open macos onit xcodeproj now")
                == "open macos/Onit.xcodeproj now")
    }

    @Test("path - symbols spoken (slash, dot)")
    func pathSpokenSymbols() {
        #expect(m(["macos/Onit.xcodeproj"]).apply(to: "open macos slash onit dot xcodeproj now")
                == "open macos/Onit.xcodeproj now")
    }

    @Test("trailing punctuation is preserved")
    func trailingPunct() {
        #expect(m(["CapsTermSelector"]).apply(to: "how does caps term selector work?")
                == "how does CapsTermSelector work?")
    }

    @Test("longest span wins")
    func longestWins() {
        #expect(m(["Onit", "OnitTests"]).apply(to: "add onit tests now") == "add OnitTests now")
    }

    @Test("PRECISION: homophone 'Onit' never mangles 'on it'")
    func homophoneSafe() {
        let mm = m(["Onit", "CapsTermSelector"])
        // "on it" is a common bigram → natural phrase → left alone.
        #expect(mm.apply(to: "i am still working on it right now") == "i am still working on it right now")
        // a distinctive term in the same dictionary still merges.
        #expect(mm.apply(to: "open the caps term selector") == "open the CapsTermSelector")
    }

    @Test("chain rule: 'on it keyboard' merges (rare link) but 'on it' alone does not")
    func chainRule() {
        // Only "on it" is a common bigram; "it keyboard" is not.
        let mm = m(["Onit", "OnitKeyboard"])
        #expect(mm.apply(to: "open the on it keyboard now") == "open the OnitKeyboard now")
        #expect(mm.apply(to: "i am working on it now") == "i am working on it now")
    }

    @Test("no spurious matches")
    func noSpurious() {
        #expect(m(["CapsTermSelector"]).apply(to: "the quick brown fox") == "the quick brown fox")
    }

    // MARK: - Regression: `precedingTextForMining` (4-word camelCase) not restored
    //
    // Real case: the term `precedingTextForMining` was in the ASR prompt (mined
    // from on-screen code) but the model transcribed it as four spaced words.
    // These tests isolate the MATCHER - if they pass, the matcher restores the
    // term fine, so the failure was upstream (the mined term never reached the
    // matcher on the accessibility path - `onScreenMinedTerms` is only populated
    // by the OCR path, so `applyFormatMatcherIfEnabled` never sees AX-mined terms).

    @Test("4-word camelCase: 'preceding text for mining' → precedingTextForMining")
    func precedingTextForMining() {
        #expect(m(["precedingTextForMining"]).apply(to: "preceding text for mining")
                == "precedingTextForMining")
    }

    @Test("4-word camelCase restored mid-sentence")
    func precedingTextForMiningMidSentence() {
        #expect(m(["precedingTextForMining"])
                .apply(to: "set the preceding text for mining value to four thousand")
                == "set the precedingTextForMining value to four thousand")
    }

    @Test("a common middle word ('for') doesn't block the merge")
    func commonWordInMiddleStillMerges() {
        // "for" is common, but the precision guard is bigram-based, not
        // per-word - "preceding text"/"for mining" aren't common bigrams here,
        // so the distinctive span still merges.
        #expect(m(["precedingTextForMining"]).apply(to: "the preceding text for mining variable")
                == "the precedingTextForMining variable")
    }

    @Test("reproduces the bug: term absent from the matcher's set → unchanged")
    func termAbsentFromMatcherIsUnchanged() {
        // The actual production failure at the matcher boundary: if the AX-mined
        // term is NOT passed in (empty term set), the matcher cannot restore it -
        // the output stays spaced, exactly what the user saw.
        #expect(m([]).apply(to: "preceding text for mining") == "preceding text for mining")
    }

    // MARK: - Wiring guard: on-screen mined terms must feed the matcher

    @Test("assembleFormatMatcherTerms includes on-screen mined terms")
    func minedTermsFeedTheMatcher() {
        // Guards the exact regression: if the term-assembly ever stops folding in
        // on-screen mined terms, a mined camelCase term reaches the prompt but not
        // the matcher - and this fails.
        let terms = TranscriptionManager.assembleFormatMatcherTerms(
            dictionaryEnabled: true,
            savedTerms: ["MySavedTerm"],
            onScreenMined: ["precedingTextForMining"]
        )
        #expect(terms.contains("precedingTextForMining"))
        #expect(terms.contains("MySavedTerm"))
    }

    @Test("mined terms feed the matcher even when the saved dictionary is off")
    func minedTermsWorkWithDictionaryDisabled() {
        // On the AX fallback the user may have no saved dictionary - the mined
        // term must still reach the matcher and merge.
        let terms = TranscriptionManager.assembleFormatMatcherTerms(
            dictionaryEnabled: false,
            savedTerms: ["ShouldBeIgnored"],
            onScreenMined: ["precedingTextForMining"]
        )
        #expect(terms == ["precedingTextForMining"])
        // …and end-to-end through the matcher, the spoken form is restored.
        #expect(m(terms).apply(to: "preceding text for mining") == "precedingTextForMining")
    }

    // MARK: - Repro: kebab-case identifier of common words (perplexity gate over-veto)

    @Test("kebab-case: 'scoring model language selection' → scoring-model-language-selection")
    func kebabCaseRestore() {
        #expect(m(["scoring-model-language-selection"]).apply(to: "scoring model language selection")
                == "scoring-model-language-selection")
    }

    @Test("both short + full kebab present: longest (full) should win")
    func shortAndFullKebab_longestWins() {
        // Exactly the production term set: BOTH "scoring-model" and the full term
        // were mined. Longest-match should pick the full 4-word term.
        let mm = m(["scoring-model", "scoring-model-language-selection"])
        #expect(mm.apply(to: "scoring model language selection")
                == "scoring-model-language-selection")
    }

    @Test("is the full span flagged ambiguous? (all common words → perplexity gate)")
    func fullKebabAmbiguityFlag() {
        // If ambiguous, production routes it to the perplexity gate - which may
        // veto gluing four fluent English words into a hyphenated compound.
        let (_, reps) = m(["scoring-model-language-selection"])
            .applyDetailed(to: "scoring model language selection")
        #expect(reps.count == 1)
        // If this passes, the span IS ambiguous → production routes it to the
        // perplexity gate (which apply() skips), the real suspect for the veto.
        #expect(reps[0].ambiguous == true)
    }
}
