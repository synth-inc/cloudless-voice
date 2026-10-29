// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermAdmission.swift
//  Onit
//
//  Admission chain for the persistent term-memory store: decides which mined
//  surfaces are worth biasing at all. The large-K stress test showed this
//  filter is mandatory - it removed the junk-term FP class entirely while the
//  raw store produced "built-in and corrupting now"-class hallucinations.
//  Based on the `dictatable()` +
//  `pron3()`/`pronounceable()` checks of the alias prediction eval, same constants.
//
//  Three gates:
//   1. dictatable - surface a human could plausibly SAY (rejects hex/UUIDs,
//      digit runs, dense letter-digit alternation, >24 chars).
//   2. pronounceable - every spoken token is a known word or scores above the
//      character-trigram log-probability floor (kills OCR garble: "lqjxw").
//   3. evidence (applied by the store, not here) - sightings on ≥2 distinct
//      days OR any dictated-kept/correction event.
//

import Foundation

struct TermAdmission: Sendable {

    /// Character-trigram log-probability model over a known-word corpus.
    /// score = mean log P(c3 | c1c2) with add-0.5 smoothing, matching pron3.
    final class TrigramModel: Sendable {
        private let trigrams: [String: Int]
        private let bigrams: [String: Int]

        init(words: some Sequence<String>) {
            var tg: [String: Int] = [:]
            var bg: [String: Int] = [:]
            tg.reserveCapacity(60_000)
            bg.reserveCapacity(3_000)
            for w in words {
                let padded = Array("^^\(w.lowercased())$")
                guard padded.count >= 3 else { continue }
                for i in 0...(padded.count - 3) {
                    tg[String(padded[i..<(i + 3)]), default: 0] += 1
                    bg[String(padded[i..<(i + 2)]), default: 0] += 1
                }
            }
            self.trigrams = tg
            self.bigrams = bg
        }

        /// Length-normalized trigram log-likelihood of the token's letters.
        /// 0.0 for tokens under 3 letters (nothing to score).
        func score(_ token: String) -> Double {
            let letters = token.lowercased().filter { $0.isLetter && $0.isASCII }
            guard letters.count >= 3 else { return 0.0 }
            let padded = Array("^^\(letters)$")
            var lp = 0.0
            for i in 0...(padded.count - 3) {
                let t = Double(trigrams[String(padded[i..<(i + 3)])] ?? 0)
                let b = Double(bigrams[String(padded[i..<(i + 2)])] ?? 0)
                lp += Darwin.log((t + 0.5) / (b + 25))  // Darwin: the app's `log` is the logger
            }
            return lp / Double(letters.count + 1)
        }
    }

    /// Trigram score below which an unknown token is considered OCR garble.
    static let pronounceabilityFloor = -3.1

    let trigrams: TrigramModel
    /// Known-word union (100k news list + CMUdict) for the "token is a real
    /// word" bypass of the trigram floor.
    let knownWords: Set<String>

    // MARK: - Gate 1: dictatable

    private static let hexRun = try! NSRegularExpression(pattern: "^[0-9a-fA-F\\-]{8,}$")
    private static let digitRun = try! NSRegularExpression(pattern: "^[A-Za-z]?[0-9]{6,}[A-Za-z0-9]*$")
    private static let alternation = try! NSRegularExpression(pattern: "[a-zA-Z][0-9]|[0-9][a-zA-Z]")

    /// Whether a human could plausibly dictate this surface.
    static func isDictatable(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !t.isEmpty, t.count <= 24 else { return false }
        let range = NSRange(t.startIndex..., in: t)
        if hexRun.firstMatch(in: t, range: range) != nil { return false }
        if digitRun.firstMatch(in: t, range: range) != nil { return false }
        if alternation.numberOfMatches(in: t, range: range) >= 3 { return false }
        let digits = t.filter(\.isNumber).count
        if Double(digits) > Double(t.count) * 0.4 { return false }
        return true
    }

    // MARK: - Gate 2: pronounceable

    /// Whether every spoken token (≥3 letters, from the humanized rendering)
    /// is a known word or plausibly English by trigram score. Vacuously true
    /// when humanization leaves no scoreable token.
    func isPronounceable(_ term: String, humanized: String? = nil) -> Bool {
        let spoken = humanized ?? TermHumanizer.humanize(term)
        let tokens = spoken.split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy {
            knownWords.contains($0.lowercased()) || trigrams.score($0) > Self.pronounceabilityFloor
        }
    }

    /// Both surface gates. (Evidence gate lives in the store query.)
    func admits(_ term: String) -> Bool {
        Self.isDictatable(term) && isPronounceable(term)
    }
}
