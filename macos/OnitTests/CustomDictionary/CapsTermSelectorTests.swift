// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CapsTermSelectorTests.swift
//  OnitTests
//
//  Layer C on-screen term mining - the deterministic "caps" heuristic.
//  Structural decisions (camelCase / ALLCAPS / underscore / stopword / garbage /
//  common-word rejection) are independent of the bundled eng_news word list.
//  Single-word proper nouns ("Onit") now rely on the OOV test, so capsSelected
//  needs the bundled list to load in the test host.
//

import Foundation
import Testing
@testable import Onit

@Suite("CapsTermSelector")
struct CapsTermSelectorTests {

    /// The reported bug: "CapsTermSelector" (camelCase) is a clear caps term and
    /// must be selected. Title-case product names too.
    @Test("camelCase / Title-case names are selected")
    func capsSelected() {
        let terms = CapsTermSelector.shared.selectCapsTerms(
            "in this chat we just tested the term CapsTermSelector and Onit and TurboBias")
        #expect(terms.contains("CapsTermSelector"))
        #expect(terms.contains("Onit"))
        #expect(terms.contains("TurboBias"))
    }

    /// The reported regression: words capitalized only because they start a
    /// sentence/line ("Only", "Links", "Why") must NOT be mined as terms - a plain
    /// leading capital on a COMMON word is not a proper-noun signal. A structured
    /// term in the same text still gets through.
    @Test("sentence-initial common words are not mistaken for terms")
    func commonWordsRejected() {
        let terms = CapsTermSelector.shared.selectCapsTerms(
            "Only the links matter here. Links and reads are common. Why bother?")
        #expect(!terms.contains("Only"))
        #expect(!terms.contains("Links"))
        #expect(!terms.contains("Why"))

        let mixed = CapsTermSelector.shared.selectCapsTerms("Only the CapsTermSelector matters")
        #expect(!mixed.contains("Only"))
        #expect(mixed.contains("CapsTermSelector"))
    }

    /// Short ALLCAPS acronyms are caps-selected (independent of the word list).
    @Test("short ALLCAPS acronyms are selected")
    func acronyms() {
        let terms = CapsTermSelector.shared.selectCapsTerms("the NLL gate and the CTC head")
        #expect(terms.contains("NLL"))
        #expect(terms.contains("CTC"))
    }

    /// Code identifiers - leading underscore, lowercase-leading camelCase, and
    /// snake_case - are captured whole and selected (independent of the word list).
    @Test("code identifiers (_leadingUnderscore / camelCase / snake_case) are selected")
    func codeIdentifiers() {
        let terms = CapsTermSelector.shared.selectCapsTerms(
            "call _initializeOnDeviceTranscriber then doSomething with snake_case_value "
            + "and AppSettings_OnDevicePolisherType")
        #expect(terms.contains("_initializeOnDeviceTranscriber"))
        #expect(terms.contains("doSomething"))
        #expect(terms.contains("snake_case_value"))
        #expect(terms.contains("AppSettings_OnDevicePolisherType"))   // PascalCase + underscore mix
    }

    /// Stopwords and single-char-repeat OCR garbage are dropped, and the trace
    /// explains why - this is what the debug view surfaces.
    @Test("stopwords and garbage are dropped with explained reasons")
    func exclusionsAndTrace() {
        let r = CapsTermSelector.shared.selectCapsTermsTraced("the llll CapsTermSelector")
        #expect(r.terms.contains("CapsTermSelector"))
        #expect(!r.terms.contains("llll"))
        #expect(!r.terms.contains("the"))

        func reason(_ token: String) -> String? {
            r.decisions.first { $0.token == token }?.reason
        }
        #expect(reason("the") == "dropped: stopword")
        #expect(reason("llll") == "dropped: garbage (one repeated char)")
        #expect(reason("CapsTermSelector")?.hasPrefix("selected") == true)
    }

    @Test("empty / whitespace input yields no terms")
    func emptyInput() {
        #expect(CapsTermSelector.shared.selectCapsTerms("").isEmpty)
        #expect(CapsTermSelector.shared.selectCapsTerms("   \n\t  ").isEmpty)
    }

    @Test("the term cap is respected")
    func respectsCap() {
        // 30 distinct Title-case tokens, cap of 5.
        let tokens = (0..<30).map { "Termabcd\($0)" }.joined(separator: " ")
        let terms = CapsTermSelector.shared.selectCapsTerms(tokens, maxTerms: 5)
        #expect(terms.count == 5)
    }

    // MARK: - Repro: kebab-case term (scoring-model-language-selection)

    @Test("kebab-case term is mined WHOLE, not fragmented")
    func kebabCaseWholeTerm() {
        let terms = CapsTermSelector.shared.selectCapsTerms(
            "we are on the feat/scoring-model-language-selection branch right now")
        #expect(terms.contains("scoring-model-language-selection"))
        #expect(!terms.contains("scoring-model"))   // must not surface a fragment
    }

    @Test("line-wrapped kebab term fragments (explains 'scoring-model' fragment)")
    func kebabLineWrapFragments() {
        // When the on-screen term wraps across a line, the tokenizer sees pieces.
        let terms = CapsTermSelector.shared.selectCapsTerms(
            "branch feat/scoring-model-\nlanguage-selection is checked out")
        // The full term is NOT recoverable once the source text is split.
        #expect(!terms.contains("scoring-model-language-selection"))
    }
}
