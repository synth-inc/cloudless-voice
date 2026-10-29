// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CapsTermSelector.swift
//  Onit
//
//  Layer C of the custom dictionary: mine candidate biasing terms from on-screen
//  OCR text using the deterministic "caps" (orthographic) heuristic - capitalised
//  / camelCase / short-acronym / out-of-vocabulary tokens. No model, sub-millisecond.
//
//  Source of truth: macos/scripts/asr_eval/context_terms.py::extract_context_terms
//  (+ keyterms.py single-char garbage filter). Eval (Qwen3-ASR-1.7B-4bit, 36
//  screenshot cases, 2026-06-08): `static + ocr:caps` beat the curated user
//  dictionary alone (recall 17→19/36, WER 0.161); `caps` and `ppl` helped while
//  `tfidf` hurt - so we ship `caps` only. "Orthographic" = decided by surface
//  form only (spelling/casing), never meaning, frequency-importance, or context.
//

import Foundation

/// Stateless, thread-safe extractor of candidate dictionary terms from a text blob.
final class CapsTermSelector: Sendable {
    static let shared = CapsTermSelector()

    private static let maxTermsDefault = 100

    /// Common function/filler words excluded even when capitalised at sentence start.
    private static let stopwords: Set<String> = Set("""
    the a an and or of to in on for with is are was were be been this that it its you he \
    she they we my your our their as at by from but so if then than yeah yes okay just \
    like get got there here what when where which who not have has had will would can \
    could should about into out over under more most i'm it's that's don't can't i've \
    we're you're they're
    """.split(separator: " ").map(String.init))

    /// `[A-Za-z_][A-Za-z0-9_'\-]{2,}` - ≥3 chars; allows a leading underscore and
    /// underscores in the body so code identifiers ("_initializeOnDeviceTranscriber",
    /// "snake_case") are captured whole rather than split or stripped.
    private static let tokenRegex = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_'\\-]{2,}")

    /// Lowercased 100k common-English words. This is the PERMISSIVE list: it
    /// still contains proper nouns and corpus junk ("abbie", "yann"), so it is
    /// only safe as a "could this plausibly be English?" guard - see
    /// `isKnownEnglishWord`, which gates trie-boost aliases and must over-block.
    private let common: Set<String>
    /// `common` minus the words the ASR demonstrably mis-transcribes - the set
    /// used for the mining OOV test. The Leipzig list is a news crawl, so it
    /// calls names like "Yann" and "Huang" common English and mining skipped
    /// them; conversely it clears true homophones ("Wright", "Moore") the model
    /// gets wrong. Subtracting the measured-confusable list fixes both.
    /// See `asr_confusable_terms.txt` for provenance.
    private let miningCommon: Set<String>
    /// High-frequency subset (rank ≤ everydayRankCutoff) for the format matcher's
    /// ambiguity test. The full 100k list is too permissive there - it contains
    /// "qwen", "ocr", "selector" - so it can't tell an everyday phrase from a
    /// technical span; the top of the frequency ranking can.
    private let everyday: Set<String>
    private static let everydayRankCutoff = 25_000
    private var hasCommon: Bool { !common.isEmpty }

    private init() {
        (self.common, self.everyday) = Self.loadCommonWords()
        self.miningCommon = common.subtracting(Self.loadConfusableTerms())
    }

    /// Loads `eng_news_2024_100K-words.txt` (Leipzig format: rank⇥word⇥freq) from
    /// the app bundle. The word is column index 1; rank (column 0) feeds the
    /// everyday subset.
    private static func loadCommonWords() -> (all: Set<String>, everyday: Set<String>) {
        guard let url = Bundle.main.url(forResource: "eng_news_2024_100K-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], [])
        }
        var all = Set<String>(minimumCapacity: 100_000)
        var everyday = Set<String>(minimumCapacity: everydayRankCutoff)
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 2 else { continue }
            let word = cols[1]
            guard word.allSatisfy({ $0.isLetter }) else { continue }
            let key = word.lowercased()
            all.insert(key)
            if let rank = Int(cols[0]), rank <= everydayRankCutoff {
                everyday.insert(key)
            }
        }
        return (all, everyday)
    }

    /// Loads `asr_confusable_terms.txt` - one lowercased word per line, the words
    /// Qwen3-ASR fails to reproduce when they are spoken in isolation.
    ///
    /// Built offline (2026-08) by synthesizing every word in the Leipzig list and
    /// transcribing it back: 3 Kokoro-82M voices with majority vote, plus
    /// ElevenLabs ground truth for the ~1.5k everyday-English words where a false
    /// entry would pollute the glossary. A single TTS voice was measurably not
    /// enough - macOS Samantha alone disagreed with ElevenLabs on ~20% of words,
    /// mispronouncing ordinary words ("brought" → "Broad") into false entries.
    ///
    /// Missing/failed load returns empty, which leaves `miningCommon == common`:
    /// today's behavior, never a crash and never a wider mining net than before.
    private static func loadConfusableTerms() -> Set<String> {
        guard let url = Bundle.main.url(forResource: "asr_confusable_terms", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var out = Set<String>(minimumCapacity: 25_000)
        for line in text.split(separator: "\n") {
            let w = line.trimmingCharacters(in: .whitespaces).lowercased()
            if !w.isEmpty { out.insert(w) }
        }
        return out
    }

    /// Whether `word` is EVERYDAY English (top-25k by news-corpus frequency).
    /// Used by the format matcher's ambiguity test: a spoken span made ONLY of
    /// everyday words ("start recording", "drag gesture") needs the perplexity
    /// gate; any rarer word ("selector", "qwen", "transcriber") makes the merge
    /// safe to apply deterministically. False for everything when the list
    /// failed to load - ambiguity detection then degrades to off.
    func isCommonWord(_ word: String) -> Bool {
        everyday.contains(word.lowercased())
    }

    /// Whether `word` appears anywhere in the full 100k news-corpus list -
    /// stricter than `isCommonWord`'s top-25k. Safety guard for trie-boost
    /// aliases: a known-English surface must never become an unconditional
    /// decode-time rewrite (it routes to the gated path instead). False for
    /// everything when the list failed to load.
    func isKnownEnglishWord(_ word: String) -> Bool {
        common.contains(word.lowercased())
    }

    /// Bulk access to the loaded word sets for consumers that build derived
    /// structures from them (term-memory admission trigrams, alias predictor
    /// vocabularies) rather than testing single words.
    var knownEnglishWordSet: Set<String> { common }
    var everydayWordSet: Set<String> { everyday }

    /// Whether the frequency list actually loaded. Alias generation MUST fail
    /// closed on this (no unconditional rewrites without the real-word guard -
    /// review finding: a missing bundle resource would otherwise let common
    /// English words become decode-time rewrites).
    var hasCommonWordList: Bool { !common.isEmpty }

    /// Per-token decision, for the on-screen-terms debug view.
    struct Decision: Sendable {
        let token: String
        let kept: Bool
        let reason: String
    }

    /// Return up to `maxTerms` candidate terms from `text`, OOV-first then by frequency.
    func selectCapsTerms(_ text: String, maxTerms: Int? = nil) -> [String] {
        selectCapsTermsTraced(text, maxTerms: maxTerms).terms
    }

    /// Same selection, plus a per-unique-token trace explaining why each candidate
    /// was kept or dropped, and whether the common-word list was loaded (so an empty
    /// list - which disables the OOV test - is visible in the debug view).
    func selectCapsTermsTraced(_ text: String, maxTerms: Int? = nil)
        -> (terms: [String], decisions: [Decision], hasCommonList: Bool) {
        let cap = maxTerms ?? Self.maxTermsDefault
        guard !text.isEmpty else { return ([], [], hasCommon) }
        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else { return ([], [], hasCommon) }

        var freq: [String: Int] = [:]
        for t in tokens { freq[t.lowercased(), default: 0] += 1 }

        var decisions: [Decision] = []
        var out: [String] = []
        var seen = Set<String>()
        for tok in tokens {
            let key = tok.lowercased()
            if seen.contains(key) { continue }                  // record first occurrence only
            seen.insert(key)

            if Self.stopwords.contains(key) {
                decisions.append(.init(token: tok, kept: false, reason: "dropped: stopword")); continue
            }
            if tok.count < 3 {
                decisions.append(.init(token: tok, kept: false, reason: "dropped: < 3 chars")); continue
            }
            if Set(key).count == 1 {
                decisions.append(.init(token: tok, kept: false, reason: "dropped: garbage (one repeated char)")); continue
            }
            let isOOV = hasCommon && !miningCommon.contains(key)
            let isCaps = Self.isCapsLike(tok)
            if isOOV || isCaps {
                out.append(tok)
                let tag = [isCaps ? "caps" : nil, isOOV ? "OOV" : nil].compactMap { $0 }.joined(separator: "+")
                decisions.append(.init(token: tok, kept: true, reason: "selected: \(tag)"))
            } else {
                decisions.append(.init(token: tok, kept: false, reason: "dropped: common word, not caps"))
            }
        }

        // Rank: out-of-vocabulary (likely real custom terms) first, then frequency,
        // stable on original order for ties.
        let ranked = out.enumerated().sorted { l, r in
            // Same vocabulary as the OOV test above, so ordering matches selection.
            let lc = miningCommon.contains(l.element.lowercased())
            let rc = miningCommon.contains(r.element.lowercased())
            if lc != rc { return !lc }                           // OOV (false) before common
            let lf = freq[l.element.lowercased(), default: 0]
            let rf = freq[r.element.lowercased(), default: 0]
            if lf != rf { return lf > rf }                       // higher frequency first
            return l.offset < r.offset                           // stable
        }
        let terms = ranked.prefix(cap).map(\.element)

        // Re-label selected-but-past-the-cap tokens so the trace explains the cut.
        let finalKeys = Set(terms.map { $0.lowercased() })
        let traced = decisions.map { d -> Decision in
            guard d.kept, !finalKeys.contains(d.token.lowercased()) else { return d }
            return Decision(token: d.token, kept: false, reason: "dropped: past top-\(cap) cap")
        }
        return (terms, traced, hasCommon)
    }

    /// Orthographically a STRUCTURED identifier: short ALLCAPS acronym ("NLL"),
    /// internal-capital camelCase ("doSomething", "initializeOnDeviceTranscriber"),
    /// or an underscore ("snake_case", "_private"). A plain leading capital is
    /// deliberately NOT enough - it's usually just sentence-initial position
    /// ("Only", "Links", "Read"). Single-word proper nouns ("Onit") are caught by
    /// the OOV test instead (they're rare); a leading-capital COMMON word is not.
    /// Long ALLCAPS runs (shouting / UI headers) are still rejected.
    private static func isCapsLike(_ tok: String) -> Bool {
        guard !tok.isEmpty else { return false }
        let isAllUpper = tok == tok.uppercased() && tok.contains(where: { $0.isLetter })
        if isAllUpper && tok.count <= 6 { return true }              // short acronym (NLL, CTC)
        if tok.dropFirst().contains(where: { $0.isUppercase }) { return true }  // internal capital
        if tok.contains("_") { return true }                        // snake_case / _private
        return false
    }

    private static func tokenize(_ text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return tokenRegex.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }
}
