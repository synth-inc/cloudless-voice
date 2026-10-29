// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CommonBigrams.swift
//  Onit
//
//  Membership set of common English bigrams (counted over the Leipzig Corpora
//  Collection eng_news_2024_1M news corpus, CC BY, kept where count ≥ 30; rebuilt
//  with scripts/data/build_common_bigrams.py). Used to decide whether a matched span is an
//  everyday phrase ("on it") rather than a dictionary term - so the format matcher
//  never mangles natural speech. This is a data-driven frequency measurement, not
//  a hand-maintained word list, and it generalizes to any phrase length: a long
//  span is a "natural phrase" only if every adjacent bigram in it is common
//  ("on it" ✓ → phrase; "on it keyboard" has the rare bigram "it keyboard" → term).
//

import Foundation

struct CommonBigrams: Sendable {
    private let set: Set<String>

    init(_ bigrams: Set<String>) { self.set = bigrams }

    /// Is "a b" (lowercased) among the common English bigrams?
    func isCommon(_ a: String, _ b: String) -> Bool {
        set.contains(a.lowercased() + " " + b.lowercased())
    }

    var isLoaded: Bool { !set.isEmpty }

    static let shared = CommonBigrams.loadFromBundle()

    private static func loadFromBundle() -> CommonBigrams {
        guard let url = Bundle.main.url(forResource: "bigrams_common", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CommonBigrams([])
        }
        var s = Set<String>(minimumCapacity: 64_000)
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { s.insert(t) }
        }
        return CommonBigrams(s)
    }
}
