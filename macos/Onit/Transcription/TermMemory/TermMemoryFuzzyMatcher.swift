// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryFuzzyMatcher.swift
//  Onit
//
//  Tier-2 of the alias system: a gated post-ASR matcher that restores a
//  term-memory term when the ASR wrote something close to a predicted surface
//  but no exact trie rewrite fired. Port of the v8 eval's tier-2 thresholds:
//  char-edit ≤ max(1, len/8) against the predicted-surface set, or phone-edit
//  ≤ max(1, phones/6) against the term's phone key.
//
//  Production conservatism beyond the eval (which only measured single-term
//  clips): fuzzy matching runs only on spans containing at least one
//  out-of-vocabulary token, and gated-EXACT rewrites of real-word phrases
//  require a non-everyday token in the span - a span of everyday words
//  ("calendar", "not in") is never rewritten, which is the
//  calendar→Calendly guard until the NLL-gated path exists. Every rewrite is
//  logged. DEBUG-flagged feature; off by default.
//

import Foundation

struct TermMemoryFuzzyMatcher {

    /// Everything tier-2 needs about one bias-eligible term.
    struct Candidate: Sendable {
        var display: String            // canonical written form ("Lukwise")
        var phones: [String]           // ARPAbet key of the humanized form
        var surfaceNorms: Set<String>  // normalized predicted surfaces (both tiers)
    }

    struct Rewrite: Equatable {
        var range: Range<String.Index>
        var original: String
        var replacement: String
    }

    let candidates: [Candidate]
    /// Detected dictation language (ISO 639-1 / BCP-47, nil = unknown). Every
    /// predicted surface is English-phonetic and the OOV test runs against an
    /// English word list, so a known non-English dictation is left untouched
    /// (in French nearly every token is "OOV" and every span would qualify).
    var language: String?
    /// Full 100k-list membership - defines "OOV token".
    let isKnownEnglishWord: (String) -> Bool
    /// Top-25k membership - defines "everyday" for the exact-gated guard.
    let isEverydayWord: (String) -> Bool
    /// Spoken-string → phones (LTS-backed), for the phone-space test.
    let phonesForSpoken: (String) -> [String]

    private static let maxSpanTokens = 4
    /// Fuzzy floor: below this many normalized characters the len/8 budget is
    /// a single edit, which rewrites near-anything ("SDK" → "SDL").
    private static let minFuzzySpanChars = 5

    /// True when the dictation is English or the backend reported no language.
    private var isEnglishOrUnknown: Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased().hasPrefix("en")
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Bounded Levenshtein (early-out on length gap > 3, matching the eval).
    static func editDistance<T: Equatable>(_ a: [T], _ b: [T], cap: Int = 99) -> Int {
        if abs(a.count - b.count) > 3 { return cap }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() {
                cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Whether an ASR span matches `candidate` under the tier-2 rules.
    /// `spanPhones` is precomputed once per span (empty when the span has no
    /// OOV token - fuzzy tiers don't fire there). Exposed for tests.
    func matches(spanNorm: String, spanPhones: [String],
                 hasOOV: Bool, hasNonEveryday: Bool,
                 candidate: Candidate) -> Bool {
        guard !spanNorm.isEmpty else { return false }
        let candidateNorm = Self.normalize(candidate.display)
        guard spanNorm != candidateNorm else { return false }  // already canonical

        // Exact predicted surface - allowed for real-word phrases only when
        // the span carries a non-everyday token.
        if candidate.surfaceNorms.contains(spanNorm) {
            return hasOOV || hasNonEveryday
        }
        // Fuzzy tiers only fire on OOV-ish spans.
        guard hasOOV else { return false }

        let spanChars = Array(spanNorm)
        guard spanChars.count >= Self.minFuzzySpanChars else { return false }
        let charBudget = max(1, spanChars.count / 8)
        for surface in candidate.surfaceNorms {
            if Self.editDistance(spanChars, Array(surface), cap: 99) <= charBudget { return true }
        }
        if Self.editDistance(spanChars, Array(candidateNorm), cap: 99) <= charBudget { return true }

        if !candidate.phones.isEmpty && !spanPhones.isEmpty {
            let phoneBudget = max(1, candidate.phones.count / 6)
            if Self.editDistance(spanPhones, candidate.phones, cap: 99) <= phoneBudget {
                return true
            }
        }
        return false
    }

    /// Rewrites for `text`, longest matching span wins per position,
    /// non-overlapping, left to right.
    func rewrites(in text: String) -> [Rewrite] {
        guard !candidates.isEmpty, !text.isEmpty, isEnglishOrUnknown else { return [] }
        // Word tokens with their ranges (letters/digits/'/- , like the miner).
        var tokens: [(range: Range<String.Index>, text: String)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isLetter || c.isNumber {
                var j = text.index(after: i)
                while j < text.endIndex,
                      text[j].isLetter || text[j].isNumber || text[j] == "'" || text[j] == "-" {
                    j = text.index(after: j)
                }
                tokens.append((i..<j, String(text[i..<j])))
                i = j
            } else {
                i = text.index(after: i)
            }
        }

        var out: [Rewrite] = []
        var t = 0
        while t < tokens.count {
            var matched = false
            for spanLen in stride(from: min(Self.maxSpanTokens, tokens.count - t), through: 1, by: -1) {
                let span = tokens[t..<(t + spanLen)]
                let spanText = String(text[span.first!.range.lowerBound..<span.last!.range.upperBound])
                let spanNorm = Self.normalize(spanText)
                let spanTokens = span.map { $0.text.lowercased() }
                // A token with no letter ("2024") is absent from the word list
                // by construction - it must not make a span fuzzy-eligible.
                let hasOOV = spanTokens.contains {
                    $0.contains(where: \.isLetter) && !isKnownEnglishWord($0)
                }
                let hasNonEveryday = spanTokens.contains { !isEverydayWord($0) }
                let spanPhones = hasOOV ? phonesForSpoken(spanText) : []
                var best: Candidate?
                for candidate in candidates
                where matches(spanNorm: spanNorm, spanPhones: spanPhones,
                              hasOOV: hasOOV, hasNonEveryday: hasNonEveryday,
                              candidate: candidate) {
                    // Ambiguous multi-candidate spans are never rewritten.
                    if best != nil { best = nil; break }
                    best = candidate
                }
                if let best {
                    let range = span.first!.range.lowerBound..<span.last!.range.upperBound
                    out.append(Rewrite(range: range, original: spanText,
                                       replacement: best.display))
                    t += spanLen
                    matched = true
                    break
                }
            }
            if !matched { t += 1 }
        }
        return out
    }

    /// Apply all rewrites; returns the new text and what changed (for logging).
    func apply(to text: String) -> (text: String, applied: [Rewrite]) {
        let all = rewrites(in: text)
        guard !all.isEmpty else { return (text, []) }
        var result = text
        for r in all.reversed() {
            result.replaceSubrange(r.range, with: r.replacement)
        }
        return (result, all)
    }
}
