// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryTermDetector.swift
//  Onit
//
//  Detects candidate custom dictionary terms by diffing raw vs corrected transcriptions.
//
//  A "candidate" is a word in the corrected text that looks like a custom term:
//    • Multiple source words collapsed into one    (e.g. "on it" → "Onit")
//    • A single source word expanded into several  (e.g. "Raudin" → "Le Dain",
//                                                        "QuickEditService" → "QuickEdit Service")
//    • OR single word whose casing changed in a    (e.g. "onit" → "Onit")
//      brand-name pattern, or with mid-word caps   ("SwiftUI", "iPhone")
//
//  False-positive guards:
//    • Must be ≥ 3 characters
//    • Must contain at least one uppercase letter
//    • Must not be a common function word (per-locale denylist)
//    • Must not already exist in the caller's term list
//

import Foundation

/// A raw-transcript / user-corrected-transcript pair used by the term
/// detector. Explicit named struct (rather than a `(raw: String, corrected:
/// String)` tuple) so the type is `Sendable` and can cross actor boundaries
/// under Swift 6 strict concurrency without per-call-site annotation.
struct CorrectionPair: Sendable, Equatable {
    let raw: String
    let corrected: String
}

struct CustomDictionaryTermDetector {

    // MARK: - Configuration

    /// BCP-47 / ISO 639-1 language tag (e.g. "en", "fr", "fr-FR") used to pick the
    /// function-word denylist. Unknown languages fall back to English.
    let language: String

    init(language: String = "en") {
        self.language = language
    }

    // MARK: - Public API

    struct Candidate: Equatable {
        /// The proposed custom dictionary term (as the user typed it).
        let term: String
        /// The raw words it replaced (for context).
        let rawSpan: [String]
    }

    /// Detect candidate terms from a single raw→corrected pair.
    ///
    /// - Parameters:
    ///   - raw: The original transcription text (ASR output or cleaned output shown to user).
    ///   - corrected: The user's manually corrected text.
    ///   - existingTerms: Terms already in the dictionary (candidates that overlap are filtered out).
    /// - Returns: Unique candidates that pass all heuristics.
    func detect(raw: String, corrected: String, existingTerms: [String] = []) -> [Candidate] {
        let rawWords = tokenize(raw)
        let correctedWords = tokenize(corrected)
        guard !rawWords.isEmpty, !correctedWords.isEmpty else { return [] }

        let existingNorm = Set(existingTerms.map { normalize($0) })
        var seen = Set<String>()
        var candidates: [Candidate] = []

        let changes = diff(rawWords, correctedWords)

        for change in changes {
            // Pure deletions produce no candidate.
            guard !change.inserted.isEmpty else { continue }

            // Each inserted word is evaluated independently. For 1-word replacements
            // the signal is carried by the (caseChange / midWordCapital / multiWordCollapse)
            // heuristics; for 1→N expansions the `siblingCount > 1` check lets each
            // inserted word stand on its own merits (e.g. "Raudin" → "Le Dain"
            // proposes "Dain" - "Le" is filtered by the ≥3-char guard).
            for term in change.inserted {
                // Must not already be in dictionary (case-insensitive)
                guard !existingNorm.contains(normalize(term)) else { continue }

                // Dedup within this call
                let key = normalize(term)
                guard !seen.contains(key) else { continue }

                // Apply heuristics
                guard isCandidate(
                    term: term,
                    replacedSpan: change.deleted,
                    siblingCount: change.inserted.count
                ) else { continue }

                seen.insert(key)
                candidates.append(Candidate(term: term, rawSpan: change.deleted))
            }
        }

        return candidates
    }

    /// Batch-detect across many correction pairs, returning deduplicated candidates.
    ///
    /// The per-call dedup is centralised here: `detect(...)` is passed an
    /// empty `existingTerms` for the inner call because the outer loop's
    /// `existingNorm` set already accumulates both the caller's dictionary
    /// and every term produced by earlier pairs in the batch. Previously the
    /// inner call's own dedup set was redundant with the outer one.
    func detectAll(
        pairs: [CorrectionPair],
        existingTerms: [String] = []
    ) -> [Candidate] {
        var existingNorm = Set(existingTerms.map { normalize($0) })
        var results: [Candidate] = []

        for pair in pairs {
            let found = detect(raw: pair.raw, corrected: pair.corrected, existingTerms: [])
            for candidate in found {
                let key = normalize(candidate.term)
                guard !existingNorm.contains(key) else { continue }
                existingNorm.insert(key)
                results.append(candidate)
            }
        }

        return results
    }

    // MARK: - Heuristics

    private func isCandidate(term: String, replacedSpan: [String], siblingCount: Int) -> Bool {
        // Minimum length
        guard term.count >= 3 else { return false }

        // Must contain at least one uppercase letter
        guard term.contains(where: { $0.isUppercase }) else { return false }

        // Must not be a common function word (even if capitalised at sentence start)
        guard !commonWords.contains(term.lowercased()) else { return false }

        // Multi-word collapse: several raw words replaced by exactly one corrected word.
        let isMultiWordCollapse = replacedSpan.count > 1 && siblingCount == 1

        // 1→N expansion: a single raw word split into several corrected words
        // (e.g. "Raudin" → "Le Dain", "QuickEditService" → "QuickEdit Service").
        // Each inserted word is evaluated on its own merits - "Le" / "Service"
        // are filtered here by the shared ≥3-char / common-word guards.
        let isExpansion = replacedSpan.count == 1 && siblingCount > 1

        // `isCaseChange` is now reachable: `wordMatches` uses case-sensitive
        // comparison, so "onit" and "Onit" produce a delete+insert pair in the
        // LCS diff rather than being treated as a match. A user correcting
        // "onit" → "Onit" will now surface "Onit" as a candidate.
        // Function words that happen to be capitalised at sentence start
        // (e.g. "The" → "the") are still filtered by the common-word denylist.
        let isCaseChange: Bool = {
            guard replacedSpan.count == 1, siblingCount == 1 else { return false }
            return normalize(replacedSpan[0]) == normalize(term) // same letters, different case
        }()
        let isMidWordCapital = term.dropFirst().contains(where: { $0.isUppercase })

        // Accept if:
        //  • Multiple raw words collapsed into one   ("on it" → "Onit")
        //  • A single raw word expanded into several ("Raudin" → "Le Dain")
        //  • Single word whose case changed          ("onit" → "Onit")
        //  • CamelCase / mixed caps                  ("SwiftUI", "iPhone")
        return isMultiWordCollapse || isExpansion || isCaseChange || isMidWordCapital
    }

    // MARK: - LCS Word Diff

    struct Change {
        let deleted: [String]   // words removed from raw
        let inserted: [String]  // words added in corrected
    }

    /// Produce a list of Changes (edit operations) between two word sequences.
    private func diff(_ a: [String], _ b: [String]) -> [Change] {
        let lcsSeq = lcs(a, b)
        var changes: [Change] = []

        var ai = 0, bi = 0, li = 0

        while li < lcsSeq.count {
            let lcsWord = lcsSeq[li]

            // Collect deletions (in a but not yet at lcs checkpoint)
            var deleted: [String] = []
            while ai < a.count && !wordMatches(a[ai], lcsWord) {
                deleted.append(a[ai])
                ai += 1
            }

            // Collect insertions (in b but not yet at lcs checkpoint)
            var inserted: [String] = []
            while bi < b.count && !wordMatches(b[bi], lcsWord) {
                inserted.append(b[bi])
                bi += 1
            }

            if !deleted.isEmpty || !inserted.isEmpty {
                changes.append(Change(deleted: deleted, inserted: inserted))
            }

            // Advance past the matched LCS word
            if ai < a.count { ai += 1 }
            if bi < b.count { bi += 1 }
            li += 1
        }

        // Trailing changes after last LCS element
        let trailingDeleted = Array(a[ai...])
        let trailingInserted = Array(b[bi...])
        if !trailingDeleted.isEmpty || !trailingInserted.isEmpty {
            changes.append(Change(deleted: trailingDeleted, inserted: trailingInserted))
        }

        return changes
    }

    /// Longest Common Subsequence of word arrays (case-insensitive).
    private func lcs(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if wordMatches(a[i - 1], b[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Reconstruct
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if wordMatches(a[i - 1], b[j - 1]) {
                result.append(a[i - 1])
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    // MARK: - Helpers

    /// Split on whitespace, strip trailing punctuation for comparison purposes.
    private func tokenize(_ s: String) -> [String] {
        s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    /// Normalize for dictionary/comparison purposes: lowercase, keep letters
    /// AND digits so alphanumeric brand terms (iOS17, GPT4, Llama3) are not
    /// collapsed to their letter-only form.
    private func normalize(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    /// Case-sensitive word match (strip punctuation before comparing, but preserve case).
    ///
    /// Using case-sensitive comparison allows `isCaseChange` to fire: "onit" and "Onit"
    /// no longer count as the same LCS element, so the correction "onit → Onit" surfaces
    /// as a delete+insert pair that `isCandidate` can evaluate. Function words that differ
    /// only due to sentence-start capitalisation (e.g. "The" → "the") are still filtered
    /// by the shared uppercase-required and common-word guards downstream.
    private func wordMatches(_ a: String, _ b: String) -> Bool {
        // Strip punctuation but keep original case for comparison.
        let strippedA = a.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
        let strippedB = b.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
        return strippedA == strippedB
    }

    // MARK: - Common Words Filter

    /// Function-word denylist used to reject obvious non-terms (e.g. an
    /// auto-capitalised "The" at the start of a sentence should never be
    /// proposed as a custom dictionary entry). Selected from
    /// `commonWordsByLanguage` based on the detector's `language`; unknown
    /// languages fall back to English to avoid false-positive additions to
    /// users' dictionaries.
    var commonWords: Set<String> {
        Self.commonWordsByLanguage[primaryLanguage] ?? Self.commonWordsByLanguage["en"]!
    }

    private var primaryLanguage: String {
        String(language.split(separator: "-").first ?? Substring("en")).lowercased()
    }

    private static let englishCommonWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "with", "by", "from", "as", "is", "it", "its", "be", "was",
        "are", "were", "been", "being", "have", "has", "had", "do", "does",
        "did", "will", "would", "could", "should", "may", "might", "shall",
        "can", "not", "no", "nor", "so", "yet", "both", "either", "neither",
        "each", "few", "more", "most", "other", "some", "such", "than", "too",
        "very", "just", "that", "this", "these", "those", "they", "them",
        "their", "there", "then", "when", "where", "which", "who", "whom",
        "how", "what", "why", "all", "any", "every", "he", "she", "we", "you",
        "me", "him", "her", "us", "my", "your", "his", "our", "its",
        "also", "about", "up", "out", "if", "into", "through", "during",
        "before", "after", "above", "below", "between", "here", "now", "only",
        "own", "same", "again", "further", "once", "under", "over", "while",
        "because", "although", "even", "well", "back", "still", "since",
        "going", "get", "make", "like", "know", "think", "see", "come",
        "want", "look", "use", "go", "say", "said", "one", "two", "three",
    ]

    private static let frenchCommonWords: Set<String> = [
        // Articles + élision
        "le", "la", "les", "un", "une", "des", "du", "de", "au", "aux", "à",
        // Pronoms personnels / réfléchis
        "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "me", "te", "se", "lui", "leur", "leurs", "moi", "toi", "soi", "eux",
        // Prépositions
        "dans", "par", "pour", "en", "vers", "avec", "sans", "sous", "sur",
        "entre", "contre", "chez", "après", "avant", "depuis", "pendant",
        // Conjonctions
        "et", "ou", "mais", "donc", "car", "ni", "que", "quand", "comme",
        "puisque", "parce", "lorsque", "tandis",
        // Être / avoir / faire (formes usuelles)
        "est", "sont", "suis", "es", "êtes", "sommes", "soit",
        "était", "étaient", "étais", "étiez", "étions", "été", "être", "étant",
        "ai", "as", "avons", "avez", "ont", "avait", "avaient", "avais",
        "aviez", "avions", "ayant", "eu", "avoir",
        "fait", "faire", "fais", "font", "faisait", "faisaient", "feraient",
        // Démonstratifs / possessifs
        "ce", "cet", "cette", "ces",
        "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses",
        "notre", "votre", "nos", "vos",
        "cela", "celle", "celles", "celui", "ceux", "ceci", "ça",
        // Interrogatifs
        "qui", "quoi", "quel", "quelle", "quels", "quelles",
        "où", "pourquoi", "comment", "combien",
        // Négations / adverbes fréquents
        "non", "oui", "pas", "plus", "jamais", "rien", "personne",
        "très", "trop", "peu", "beaucoup",
        "tout", "tous", "toute", "toutes", "même", "mêmes",
        "aussi", "encore", "déjà", "toujours", "souvent", "parfois",
        "bien", "mal", "ici", "là", "voici", "voilà",
        // Verbes usuels (formes les plus fréquentes)
        "aller", "vais", "vas", "va", "allez", "allons", "vont", "allait", "allé",
        "dire", "dit", "dis", "disait", "disent", "disons",
        "voir", "vois", "voit", "voyait", "vu", "voyons",
        "savoir", "sait", "savent", "savais", "savez", "su",
        "pouvoir", "peut", "peuvent", "pouvait", "peux", "pu",
        "vouloir", "veut", "veux", "veulent", "voulait", "voulu",
    ]

    private static let commonWordsByLanguage: [String: Set<String>] = [
        "en": englishCommonWords,
        "fr": frenchCommonWords,
    ]
}
