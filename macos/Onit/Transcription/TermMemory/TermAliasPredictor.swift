// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermAliasPredictor.swift
//  Onit
//
//  Real-time (no-audio) prediction of what the ASR will WRITE when a mined
//  term is spoken - the v8 layered predictor from the alias eval (Tier-1 82%,
//  Tier-1+2 91% vs TTS→ASR ground truth). Layers, all μs–ms per term:
//    1. humanization (TermHumanizer) - the spoken rendering
//    2. whole-term G2P + real-word lexicon tilings ("Lukwise" → "luck wise")
//    3. per-token homophone / near-homophone composition (CMUdict + LTS)
//    4. grapheme compound splits + edit-distance-1 typo variants
//  Predicted surfaces are split into the trie's UNCONDITIONAL tier (surfaces
//  the user would never dictate deliberately - safe as decode-time rewrites,
//  same guard as `safeBoostAliases`) and the GATED tier (real-word phrases,
//  matched only by the post-ASR fuzzy matcher).
//

import Foundation

struct TermAliasPredictor {

    struct Prediction: Sendable {
        /// ARPAbet phones of the humanized term (the tier-2 phone-space key).
        var phones: [String]
        /// Safe decode-time rewrite surfaces, best first (capped).
        var unconditional: [String]
        /// Real-word-phrase surfaces for the gated post-ASR matcher (capped).
        var gated: [String]
    }

    static let maxUnconditional = 4
    static let maxGated = 64

    let lexicon: PhoneticLexicon
    /// 100k news-corpus word set (no CMUdict) - the typo-variant layer's
    /// "already a word" bypass, matching the Python `wordset`.
    let newsWords: Set<String>
    /// newsWords ∪ CMUdict headwords - the compound-split vocabulary.
    let splitWords: Set<String>
    /// The `safeBoostAliases` guard: true when the surface is made purely of
    /// known English words (must never be an unconditional rewrite).
    let isKnownEnglishWord: @Sendable (String) -> Bool
    /// Whether the real-word list behind `isKnownEnglishWord` actually loaded
    /// (`CapsTermSelector.hasCommonWordList`). False makes the guard answer
    /// "not a word" for everything, so tiering must fail CLOSED instead:
    /// no unconditional surface is emitted at all.
    var hasWordList = true

    // MARK: - Per-token variants (alias eval v3 token variants)

    /// The token itself + up to `maxVariants`-1 homophones / near-homophones,
    /// common words first. Near-homophones (phone-edit-1) only fill remaining
    /// slots for tokens of ≤8 phones.
    func tokenVariants(_ token: String, maxVariants: Int = 4) -> [String] {
        let tok = token.lowercased()
        var out = [tok]
        let phones = lexicon.phones(forToken: tok)
        guard !phones.isEmpty else { return out }

        for w in lexicon.homophones(of: phones).prefix(3) where w != tok && !out.contains(w) {
            out.append(w)
        }
        if out.count < maxVariants && phones.count <= 8 {
            var near: [String] = []
            for neighbor in Self.phoneNeighbors(phones) {
                if let w = lexicon.homophones(of: neighbor).first,
                   w != tok, !out.contains(w), !near.contains(w) {
                    near.append(w)
                }
            }
            near.sort { (lexicon.frequencyRank($0), $0) < (lexicon.frequencyRank($1), $1) }
            out += near.prefix(maxVariants - out.count)
        }
        return Array(out.prefix(maxVariants))
    }

    /// ARPAbet phone inventory for substitution/insertion neighbors.
    private static let phoneInventory = [
        "AA", "AE", "AH", "AO", "AW", "AY", "B", "CH", "D", "DH", "EH", "ER",
        "EY", "F", "G", "HH", "IH", "IY", "JH", "K", "L", "M", "N", "NG",
        "OW", "OY", "P", "R", "S", "SH", "T", "TH", "UH", "UW", "V", "W",
        "Y", "Z", "ZH",
    ]

    /// Phone strings at edit distance 1 (deletion, substitution, insertion).
    static func phoneNeighbors(_ phones: [String]) -> [[String]] {
        var out: [[String]] = []
        for i in phones.indices {
            var del = phones; del.remove(at: i)
            out.append(del)
            for p in phoneInventory where p != phones[i] {
                var sub = phones; sub[i] = p
                out.append(sub)
            }
        }
        for i in 0...phones.count {
            for p in phoneInventory {
                var ins = phones; ins.insert(p, at: i)
                out.append(ins)
            }
        }
        return out
    }

    // MARK: - Grapheme layers (alias eval v8)

    /// Two-part splits of an unknown ≥6-char token into known words
    /// ("luckwise" → "luck wise"), plural-tolerant on the first part. Top 5.
    func compoundSplits(_ token: String) -> [String] {
        let tok = token.lowercased()
        guard tok.count >= 6, !splitWords.contains(tok) else { return [] }
        let chars = Array(tok)
        var out: [String] = []
        for i in 3...(chars.count - 3) {
            let a = String(chars[..<i])
            let b = String(chars[i...])
            if splitWords.contains(a) && splitWords.contains(b) { out.append("\(a) \(b)") }
            if splitWords.contains(a + "s") && splitWords.contains(b) { out.append("\(a)s \(b)") }
            if out.count >= 5 { break }
        }
        return Array(out.prefix(5))
    }

    /// Known words at character-edit-distance 1 from an unknown token
    /// ("kalender" → "calendar"). Empty for tokens that are already words. Top 6.
    func typoVariants(_ token: String) -> [String] {
        let tok = token.lowercased()
        guard tok.count >= 4, tok.allSatisfy(\.isLetter), !newsWords.contains(tok) else { return [] }
        let chars = Array(tok)
        let alphabet = "abcdefghijklmnopqrstuvwxyz"
        var candidates = Set<String>()
        for i in chars.indices {
            var del = chars; del.remove(at: i)
            candidates.insert(String(del))
            for c in alphabet where c != chars[i] {
                var sub = chars; sub[i] = c
                candidates.insert(String(sub))
            }
        }
        for i in 0...chars.count {
            for c in alphabet {
                var ins = chars; ins.insert(c, at: i)
                candidates.insert(String(ins))
            }
        }
        return candidates
            .filter { $0 != tok && splitWords.contains($0) }
            .sorted { (lexicon.frequencyRank($0), $0) < (lexicon.frequencyRank($1), $1) }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Full prediction

    /// All predicted ASR surfaces for `term`, tiered. Candidate order encodes
    /// confidence: tilings and single-swap homophone combos first.
    func predict(_ term: String) -> Prediction {
        let humanized = TermHumanizer.humanize(term)
        let spokenTokens = humanized.lowercased()
            .split(separator: " ").map(String.init)

        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let canonicalKeys: Set<String> = [norm(term), norm(humanized)]

        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ candidate: String) {
            let key = norm(candidate)
            guard !key.isEmpty, !canonicalKeys.contains(key), seen.insert(key).inserted else { return }
            ordered.append(candidate)
        }

        // Layer 2 - whole-term real-word tilings.
        let phones = lexicon.phones(forSpoken: humanized)
        for tiling in lexicon.tilings(of: phones) {
            add(tiling.joined(separator: " "))
        }

        // Layer 4 - compound splits + typo variants on the humanized form.
        // Runs BEFORE the combo flood: these few candidates are the highest
        // precision per surface, and candidate order decides who survives the
        // tier caps.
        for tok in spokenTokens {
            for split in compoundSplits(tok) {
                add(humanized.lowercased().replacingOccurrences(of: tok, with: split))
                for part in split.split(separator: " ").map(String.init) {
                    for typo in typoVariants(part) {
                        let patched = split.replacingOccurrences(of: part, with: typo)
                        add(humanized.lowercased().replacingOccurrences(of: tok, with: patched))
                    }
                }
            }
            for typo in typoVariants(tok) {
                add(humanized.lowercased().replacingOccurrences(of: tok, with: typo))
            }
        }

        // Layer 3 - per-token homophone composition. Full cartesian product
        // capped like the prototype: >256 combos → top-2 variants per token,
        // ≤200 combos total.
        if !spokenTokens.isEmpty && spokenTokens.count <= 6 {
            var perToken = spokenTokens.map { tokenVariants($0) }
            if perToken.reduce(1, { $0 * $1.count }) > 256 {
                perToken = perToken.map { Array($0.prefix(2)) }
            }
            var combos: [[String]] = [[]]
            outer: for variants in perToken {
                var next: [[String]] = []
                for prefix in combos {
                    for v in variants {
                        next.append(prefix + [v])
                        if next.count >= 200 { combos = next; continue outer }
                    }
                }
                combos = next
            }
            for combo in combos { add(combo.joined(separator: " ")) }
        }

        // Tiering: a surface made purely of known English words can never be
        // an unconditional decode-time rewrite (safeBoostAliases' guard).
        var unconditional: [String] = []
        var gated: [String] = []
        for candidate in ordered {
            let words = candidate.lowercased().split(separator: " ").map(String.init)
            let allEnglish = !words.isEmpty && words.allSatisfy { isKnownEnglishWord($0) }
            if allEnglish || !hasWordList {
                if gated.count < Self.maxGated { gated.append(candidate) }
            } else if unconditional.count < Self.maxUnconditional {
                unconditional.append(candidate)
            } else if gated.count < Self.maxGated {
                gated.append(candidate)
            }
        }
        return Prediction(phones: phones, unconditional: unconditional, gated: gated)
    }
}
