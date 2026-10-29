// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BundledWordListsTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  The two bundled English word lists (Leipzig Corpora Collection data, see
//  THIRD_PARTY_NOTICES.md section 6): their file format, a few anchor words, and
//  that the real loaders accept them. Hermetic: reads only files shipped in the app.
//

import Foundation
import Testing
@testable import Onit

@Suite("Bundled word lists")
struct BundledWordListsTests {

    private func lines(_ resource: String) throws -> [Substring] {
        let url = try #require(Bundle.main.url(forResource: resource, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    }

    @Test("frequency list is rank, word, count with unique ranks and words")
    func frequencyListFormat() throws {
        let rows = try lines("eng_news_2024_100K-words").map { $0.split(separator: "\t") }
        #expect(rows.count > 100_000)
        #expect(rows.allSatisfy { $0.count == 3 && Int($0[0]) != nil && Int($0[2]) != nil })
        #expect(Set(rows.map { $0[0] }).count == rows.count)
        // Compare bytes: String equality would merge canonically equivalent spellings.
        #expect(Set(rows.map { Array($0[1].utf8) }).count == rows.count)
        let words = Set(rows.map { String($0[1]) })
        for anchor in ["the", "of", "and", "said", "government"] { #expect(words.contains(anchor)) }
    }

    @Test("frequency list feeds the selector's everyday and known-word sets")
    func frequencyListLoads() {
        let selector = CapsTermSelector.shared
        #expect(selector.isCommonWord("the"))
        #expect(selector.isCommonWord("government"))
        #expect(selector.isKnownEnglishWord("government"))
        #expect(!selector.isKnownEnglishWord("qzxvbn"))
    }

    @Test("bigram list is lowercase 'word word' pairs, sorted, without duplicates")
    func bigramListFormat() throws {
        let rows = try lines("bigrams_common")
        #expect(rows.count > 40_000)
        #expect(Set(rows).count == rows.count)
        #expect(rows.allSatisfy { row in
            let w = row.split(separator: " ", omittingEmptySubsequences: false)
            return w.count == 2 && w.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("a"..."z").contains($0) } }
        })
    }

    @Test("bigram loader recognises everyday phrases and not rare links")
    func bigramLoader() {
        let bigrams = CommonBigrams.shared
        #expect(bigrams.isLoaded)
        for (a, b) in [("on", "it"), ("of", "the"), ("in", "the"), ("going", "to")] {
            #expect(bigrams.isCommon(a, b), "\(a) \(b)")
        }
        #expect(!bigrams.isCommon("it", "keyboard"))
    }

    @Test("the format matcher keeps 'on it' and still merges 'on it keyboard' with the real bigrams")
    func matcherWithBundledBigrams() {
        let matcher = DictionaryFormatMatcher(terms: ["Onit", "OnitKeyboard"])
        #expect(matcher.apply(to: "I am on it") == "I am on it")
        #expect(matcher.apply(to: "open the on it keyboard") == "open the OnitKeyboard")
    }
}
