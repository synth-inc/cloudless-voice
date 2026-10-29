// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictionaryFormatMatcher.swift
//  Onit
//
//  Restores a dictionary term's exact written form when the ASR transcribed it as
//  separate spoken words - for ANY formatting (camelCase, snake_case, kebab-case,
//  paths like "macos/Onit.xcodeproj", dotted names, etc.) with no per-format code.
//
//  It is format-BLIND: it erases every boundary (case, separators, symbols) on
//  both the stored term and candidate transcript spans, compares the boundary-free
//  letters, and pastes the exact stored form. The formatting is looked up (from the
//  term you saved), never inferred - so a new term in any style "just works".
//
//  Two universal (not per-term, not per-format) helpers cover the cases where the
//  letters themselves differ: number words ↔ digits ("three" ⇄ 3) and spoken
//  symbol names (slash/dot/dash…) which a speaker may verbalize in a path.
//

import Foundation

struct DictionaryFormatMatcher {

    /// normalized boundary-free key → exact stored term.
    private let byKey: [String: String]
    /// Multi-word terms grouped by word count, for token-anchored fuzzy matching.
    private let termsByWordCount: [Int: [(words: [String], canonical: String)]]
    /// Decides whether a matched span is an everyday phrase (skip) vs a term (merge).
    private let commonBigrams: CommonBigrams
    private let maxWindow: Int
    /// Skip keys shorter than this so tiny terms don't match spuriously.
    private static let minKeyLen = 3

    /// - Parameter maxWindow: most transcript words a single term may span.
    init(terms: [String], commonBigrams: CommonBigrams = .shared, maxWindow: Int = 8) {
        var map: [String: String] = [:]
        var byCount: [Int: [(words: [String], canonical: String)]] = [:]
        for term in terms {
            let key = Self.normalize(Self.words(inToken: term), dropSymbolWords: false)
            if key.count >= Self.minKeyLen { map[key] = term }      // exact stored form
            // Fuzzy index: split on camelCase/separators/digit boundaries so the term's
            // subwords align with the span's spoken words. ≥2-word terms only (single
            // words stay exact-only, for precision).
            let w = Self.termSubwords(term).map { Self.numberWords[$0] ?? $0 }
            if w.count >= 2 { byCount[w.count, default: []].append((w, term)) }
        }
        self.byKey = map
        self.termsByWordCount = byCount
        self.commonBigrams = commonBigrams
        self.maxWindow = maxWindow
    }

    /// One replacement the matcher made: the spoken span it consumed and the
    /// dictionary term whose stored form it pasted. Drives the debug view and
    /// the perplexity gate.
    struct Replacement: Sendable, Equatable, Hashable {
        let spoken: String
        let term: String
        /// True when every word of the spoken span is common English - the span
        /// reads naturally as a phrase ("start recording") so only sentence
        /// context can decide identifier-vs-phrase. Ambiguous replacements are
        /// the ones the perplexity gate scores; distinctive spans ("caps term
        /// selector") merge deterministically.
        let ambiguous: Bool
        /// Position in the whitespace-tokenized transcript, so the NLL gate
        /// scores THIS occurrence of the span (required by its contract for
        /// common-word spans, which may appear multiple times).
        let startWord: Int
        let wordWidth: Int
    }

    /// Replace spans of `transcript` whose boundary-free letters match a term.
    func apply(to transcript: String) -> String {
        applyDetailed(to: transcript).text
    }

    /// `apply(to:)` plus the list of replacements made - so the debug view can
    /// show exactly where each restoration came from. Pass `excluding` (from a
    /// prior dry pass, gate-vetoed) to skip specific spoken→term merges.
    func applyDetailed(to transcript: String,
                       excluding: Set<Replacement> = []) -> (text: String, replacements: [Replacement]) {
        guard !byKey.isEmpty else { return (transcript, []) }
        // Split on ALL whitespace - must match CustomDictionaryNLLGate's word
        // counting (`isWhitespace`) exactly, or `startWord` drifts on unusual
        // whitespace (NBSP, \r) and the gate scores the wrong occurrence.
        let tokens = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return (transcript, []) }

        var out: [String] = []
        var replacements: [Replacement] = []
        var i = 0
        while i < tokens.count {
            var canonical: String?
            var matchedLen = 0
            var candidate: Replacement?
            let maxL = min(maxWindow, tokens.count - i)
            for L in stride(from: maxL, through: 1, by: -1) {     // longest span wins
                if let c = match(Array(tokens[i..<(i + L)])) {
                    let spoken = tokens[i..<(i + L)].joined(separator: " ")
                    let words = tokens[i..<(i + L)].flatMap { Self.words(inToken: $0) }
                    let rep = Replacement(spoken: spoken, term: c,
                                          ambiguous: isAmbiguousSpan(words),
                                          startWord: i, wordWidth: L)
                    if excluding.contains(rep) { continue }       // gate-vetoed
                    canonical = c; matchedLen = L; candidate = rep
                    break
                }
            }
            if let c = canonical, matchedLen > 0, let rep = candidate {
                replacements.append(rep)
                // keep trailing punctuation of the span's last token (e.g. "selector." → ".")
                out.append(c + Self.trailingSymbols(tokens[i + matchedLen - 1]))
                i += matchedLen
            } else {
                out.append(tokens[i]); i += 1
            }
        }
        // Preserve the transcript byte-for-byte when nothing matched - the token
        // join below collapses newlines and runs of spaces, which would rewrite
        // every transcript this matcher merely inspected.
        guard !replacements.isEmpty else { return (transcript, []) }
        return (out.joined(separator: " "), replacements)
    }

    /// A span is ambiguous when EVERY word is common English - multi-word
    /// ("start recording", "drag gesture") or single-word ("trigger" matching a
    /// "_trigger" term): it could equally be ordinary prose, so the merge
    /// decision belongs to the perplexity gate. Any rare/structural word
    /// ("qwen", "onit") makes the span distinctive enough to merge
    /// deterministically.
    private func isAmbiguousSpan(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        return words.allSatisfy { CapsTermSelector.shared.isCommonWord($0) }
    }

    /// Match a window two ways: symbol-words kept (so "dot-product" survives) and
    /// symbol-words dropped (so a spoken "macos slash onit dot xcodeproj" aligns).
    private func match(_ window: [String]) -> String? {
        let words = window.flatMap { Self.words(inToken: $0) }
        var canonical: String?
        let keep = Self.normalize(words, dropSymbolWords: false)
        if keep.count >= Self.minKeyLen { canonical = byKey[keep] }
        if canonical == nil {
            let drop = Self.normalize(words, dropSymbolWords: true)
            if drop != keep, drop.count >= Self.minKeyLen { canonical = byKey[drop] }
        }
        // Fallback: exact failed, so try a token-anchored fuzzy match - the ASR may
        // have emitted a morphological/acoustic cousin of one word ("Selective" for
        // "Selected"). Requires every other token to match exactly (an anchor).
        if canonical == nil { canonical = fuzzyMatch(words) }
        guard let c = canonical else { return nil }
        // Precision: don't merge if the spoken span is an everyday phrase - i.e.
        // every adjacent bigram is common. "on it" stays "on it"; "on it keyboard"
        // (rare bigram "it keyboard") still merges. Phrase-level, no hand list.
        return isNaturalPhrase(words) ? nil : c
    }

    /// True when `words` reads as a natural phrase: 2+ words whose every adjacent
    /// pair is a common English bigram (chain-rule - scales to any length).
    private func isNaturalPhrase(_ words: [String]) -> Bool {
        guard words.count >= 2 else { return false }   // single word ⇒ not a phrase
        for i in 0..<(words.count - 1) where !commonBigrams.isCommon(words[i], words[i + 1]) {
            return false                                // a rare link ⇒ not natural
        }
        return true
    }

    // MARK: - Token-anchored fuzzy match

    /// Match a span to a same-length term when exactly ONE token differs by a
    /// morphological/acoustic variant and every other token is an exact anchor.
    private func fuzzyMatch(_ rawWords: [String]) -> String? {
        let words = rawWords.map { Self.numberWords[$0] ?? $0 }
        guard words.count >= 2, let candidates = termsByWordCount[words.count] else { return nil }
        for cand in candidates where Self.tokensAlign(words, cand.words) {
            return cand.canonical
        }
        return nil
    }

    /// All tokens align (same count); at most ONE is a fuzzy variant and at least
    /// one is an exact anchor. A single hard mismatch rejects the whole span.
    private static func tokensAlign(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        var fuzzy = 0, exact = 0
        for (x, y) in zip(a, b) {
            if x == y { exact += 1 }
            else if fuzzyToken(x, y) { fuzzy += 1; if fuzzy > 1 { return false } }
            else { return false }
        }
        return fuzzy == 1 && exact >= 1
    }

    /// Two words are a fuzzy variant when they share a long stem (≥4-char common
    /// prefix) and diverge by a small suffix edit (≤3). Conservative: both words
    /// must be ≥4 chars, so short words only ever match exactly.
    private static func fuzzyToken(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4, b.count >= 4 else { return false }
        return commonPrefixLen(a, b) >= 4 && editDistance(a, b) <= 3
    }

    private static func commonPrefixLen(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0.0 == $0.1 }.count
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty else { return t.count }
        guard !t.isEmpty else { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    // MARK: - Normalization

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]
    private static let symbolWords: Set<String> = [
        "slash", "backslash", "dot", "point", "period", "dash", "hyphen",
        "underscore", "colon", "comma",
    ]
    /// Lowercased alphanumeric runs of a string ("macos/Onit.xcodeproj" → [macos, onit, xcodeproj]).
    private static func words(inToken token: String) -> [String] {
        token.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Split a stored term into its constituent lowercased subwords, honoring
    /// camelCase/PascalCase, separators, and letter↔digit boundaries - so the term's
    /// pieces align with the span's spoken words for fuzzy matching:
    /// "capsSelected"→[caps,selected]; "qwen3-dictionary-ocr"→[qwen,3,dictionary,ocr];
    /// "_initializeOnDeviceTranscriber"→[initialize,on,device,transcriber].
    private static func termSubwords(_ term: String) -> [String] {
        var words: [String] = []
        var cur = ""
        let chars = Array(term)
        func flush() { if !cur.isEmpty { words.append(cur.lowercased()); cur = "" } }
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else { flush(); continue }
            if let last = cur.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary =
                    (c.isUppercase && (last.isLowercase || last.isNumber)) ||       // word→Word
                    (c.isUppercase && last.isUppercase && (next?.isLowercase ?? false)) || // XMLParser→XML,Parser
                    ((c.isNumber) != (last.isNumber))                               // letter↔digit
                if boundary { flush() }
            }
            cur.append(c)
        }
        flush()
        return words
    }

    /// Join words into a boundary-free key: number-words → digits, optionally drop
    /// spoken symbol names, keep only letters/digits.
    private static func normalize(_ words: [String], dropSymbolWords: Bool) -> String {
        var parts: [String] = []
        for w in words {
            if dropSymbolWords && symbolWords.contains(w) { continue }
            parts.append(numberWords[w] ?? w)
        }
        return parts.joined()
    }

    private static func trailingSymbols(_ token: String) -> String {
        String(token.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }
}
