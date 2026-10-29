// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryCategoryRanker.swift
//  Onit
//
//  Ranks calibration categories by semantic relevance to a set of positive
//  example sentences using Apple NLEmbedding sentence vectors.
//
//  Used by the dictionary calibration sheet to surface the most likely
//  category for a term ("First name", "City", "Programming language", …)
//  given the sentences it appeared in.
//

import Foundation
import NaturalLanguage

enum CustomDictionaryCategoryRanker {

    /// Master list of categories with an anchor phrase used to embed the
    /// category itself for cosine comparison. Anchor phrases are short
    /// noun-phrases that describe an instance of the category - empirically
    /// this gives better separation than the bare category name.
    static let allCategories: [(name: String, anchor: String)] = [
        ("First name", "a person's first name like Sarah or Michael"),
        ("Last name", "a person's last name or surname"),
        ("Username", "a username or online handle"),
        ("City or country", "a city, country, or geographic region"),
        ("Neighborhood, building, or venue", "a neighborhood, building, or venue"),
        ("Street name", "a street or road name"),
        ("Company or startup", "a company or startup"),
        ("Product, app, or brand", "a product, app, or brand name"),
        ("Sports team", "a sports team"),
        ("Programming language or framework", "a programming language or software framework"),
        ("Software tool, command, or library", "a software tool, command line program, or library"),
        ("File format, protocol, or API", "a file format, network protocol, or API"),
        ("Medical or scientific term", "a medical or scientific term"),
        ("Legal or financial term", "a legal or financial term"),
        ("Industry jargon", "industry jargon or specialised slang"),
        ("Foreign word or loanword", "a foreign word or loanword used in English"),
        ("Acronym or initialism", "an acronym or initialism"),
        ("Food, drink, or dish", "a food, drink, or dish"),
        ("Movie, show, book, or game", "a movie, TV show, book, or game title"),
        ("Animal or plant species", "an animal or plant species"),
    ]

    /// Top-N category names ranked by mean cosine similarity between the
    /// positive sentences and each category's anchor phrase.
    ///
    /// Returns the first `topN` of `allCategories` if NLEmbedding is
    /// unavailable or no positives produce a vector.
    static func relevantCategories(
        positives: [String],
        topN: Int = 6
    ) -> [String] {
        let fallback = Array(allCategories.prefix(topN).map(\.name))
        guard !positives.isEmpty else { return fallback }
        guard let embed = NLEmbedding.sentenceEmbedding(for: .english) else {
            log.warning("CategoryRanker: NLEmbedding sentence model unavailable, using default order")
            return fallback
        }

        // Mean-pool sentence vectors.
        var sum: [Double] = []
        var n = 0
        for s in positives {
            guard let v = embed.vector(for: s) else { continue }
            if sum.isEmpty {
                sum = v
            } else if sum.count == v.count {
                for i in 0..<v.count { sum[i] += v[i] }
            }
            n += 1
        }
        guard n > 0, !sum.isEmpty else { return fallback }
        let positiveVec = sum.map { $0 / Double(n) }

        let scored: [(name: String, score: Double)] = allCategories.compactMap { cat in
            guard let cv = embed.vector(for: cat.anchor) else { return nil }
            return (cat.name, cosine(positiveVec, cv))
        }

        let ranked = scored.sorted { $0.score > $1.score }
        log.debug("CategoryRanker: top categories for \(positives.count) positives - " +
                  ranked.prefix(8).map { "\($0.name)=\(String(format: "%.3f", $0.score))" }
                                  .joined(separator: ", "))
        return ranked.prefix(topN).map(\.name)
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
