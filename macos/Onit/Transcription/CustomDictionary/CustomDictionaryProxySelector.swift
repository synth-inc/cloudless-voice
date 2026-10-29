// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryProxySelector.swift
//  Onit
//
//  Auto-selects proxy word candidates for a custom dictionary term using Llama top-K
//  predictions at the position of the confusion span in reference sentences.
//
//  Ranking: blended score = aggregated Llama probability + Levenshtein similarity
//  bonus between the candidate and the term text. This surfaces phonetically plausible
//  candidates (e.g. "Unit", "Audit" for "Onit") alongside high-probability contextual
//  ones (e.g. "Python", "Safari"), giving the user a more useful selection.
//

import Foundation

actor CustomDictionaryProxySelector {

    static let shared = CustomDictionaryProxySelector()
    private init() {}

    // MARK: - Exclusion List

    private static let excluded: Set<String> = [
        "The","A","An","I","He","She","They","We","You","It","His","Her",
        "Their","Our","Your","Its","Me","Him","Us","Them","This","That",
        "These","Those","My","Not","No","Yes","But","And","Or","So","If",
        "In","On","At","To","For","With","By","From","Of","Do","Did","Does",
        "Is","Are","Was","Were","Be","Been","Have","Has","Had","Will","Would",
        "Could","Should","May","Might","Must","Can","Get","Got","Go","Make",
        "Just","Now","Then","Here","There","When","Where","What","How",
        "All","Some","Any","More","Most","Many","Much","Mr","Dr","Ms","Mrs",
        "Work","Health","Care","Time","New","Good","Best","Check","Send",
        "Open","Add","Set","Use","Try","See","Look","Run","Ask",
    ]

    private func isCandidate(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespaces)
        return t.count >= 3
            && t.first?.isUppercase == true
            && !Self.excluded.contains(t)
            && !t.hasPrefix("##")
            && t.allSatisfy(\.isLetter)
    }

    // MARK: - Public API

    /// Select proxy word candidates for `term` given positive reference sentences.
    ///
    /// Aggregates Llama top-100 predictions across sentences, then ranks by a blended
    /// score of aggregated probability + Levenshtein similarity to the term text.
    /// The similarity bonus surfaces phonetically plausible candidates (e.g. "Unit"
    /// for "Onit") that Llama may rank lower than high-frequency context words.
    ///
    /// - Parameters:
    ///   - referenceSentences: Sentences where the term is used correctly.
    ///   - confusionSpan: The span STT produces instead of the term (e.g. "on it").
    ///   - termText: The dictionary term itself, used for similarity ranking.
    ///   - count: Maximum number of candidates to return.
    /// - Returns: Up to `count` proxy candidates sorted by blended score.
    func selectProxy(
        referenceSentences: [String],
        confusionSpan: String,
        termText: String,
        count: Int = 10
    ) async throws -> [String] {
        guard await MLXScoringEngine.shared.isLoaded else { return [] }

        var aggregated: [String: Float] = [:]

        for sentence in referenceSentences {
            guard let range = sentence.range(of: confusionSpan, options: .caseInsensitive) else {
                continue
            }
            let prefix = String(sentence[..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty else { continue }

            let preds = try await MLXScoringEngine.shared.topKNext(prefix: prefix, k: 100)
            for (token, prob) in preds where isCandidate(token) {
                aggregated[token, default: 0] += prob
            }
        }

        guard !aggregated.isEmpty else { return [] }

        // Normalize Llama probs to [0,1] relative to the highest scorer.
        let maxProb = aggregated.values.max() ?? 1
        let termKey = termText.lowercased().filter(\.isLetter)

        // Blend: 70% Llama context signal + 30% phonetic similarity to the term.
        // The similarity bonus ensures candidates like "Unit" (sim≈0.5 to "onit")
        // surface alongside pure context picks like "Python" (sim≈0).
        let scored: [(token: String, score: Float)] = aggregated.map { token, prob in
            let normProb = prob / maxProb
            let candidateKey = token.lowercased().filter(\.isLetter)
            let sim = levenshteinSimilarity(candidateKey, termKey)
            let blended = 0.7 * normProb + 0.3 * sim
            return (token, blended)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(count)
            .map(\.token)
    }

    // MARK: - Category-aware re-ranking (Llama zero-shot)

    /// Pick the candidate that best fits a category using Llama NLL scoring.
    ///
    /// For each candidate we score `"{candidate} is a {category}."` and pick the
    /// one with the lowest mean NLL - i.e. the candidate Llama judges most
    /// semantically consistent with the chosen category. Falls back to the first
    /// candidate if Llama is unavailable.
    ///
    /// - Parameters:
    ///   - candidates: Proxy candidates produced by `selectProxy`.
    ///   - category: A category label (one of `CustomDictionaryCategoryRanker.allCategories`,
    ///               or a user-supplied free-form string).
    func pickProxyForCategory(
        candidates: [String],
        category: String
    ) async throws -> String? {
        guard !candidates.isEmpty else { return nil }
        guard await MLXScoringEngine.shared.isLoaded else { return candidates.first }

        let trimmedCategory = category.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedCategory.isEmpty else { return candidates.first }

        var bestScore: Float = .infinity
        var best: String? = nil
        for candidate in candidates {
            let prompt = "\(candidate) is a \(trimmedCategory)."
            do {
                let (_, nlls) = try await MLXScoringEngine.shared.tokenScores(prompt)
                guard !nlls.isEmpty else { continue }
                let mean = nlls.reduce(0, +) / Float(nlls.count)
                if mean < bestScore {
                    bestScore = mean
                    best = candidate
                }
            } catch {
                continue
            }
        }
        return best ?? candidates.first
    }

    // MARK: - Levenshtein

    private func levenshteinSimilarity(_ a: String, _ b: String) -> Float {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return 1.0 - Float(prev[n]) / Float(max(m, n))
    }
}
