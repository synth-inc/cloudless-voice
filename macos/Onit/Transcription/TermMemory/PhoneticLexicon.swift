// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  PhoneticLexicon.swift
//  Onit
//
//  ARPAbet pronunciation service for the term-memory alias predictor:
//  CMUdict lookups (bundled `cmudict_phones.txt`, stress-stripped), a
//  phones→words homophone index ranked by news-corpus frequency, and a
//  rule-based letter-to-sound fallback for out-of-vocabulary tokens - the
//  role `g2p_en` played in the Python prototype. The LTS rules are a compact
//  context-sensitive set (digraphs, magic-e, soft c/g); approximate phones are
//  fine downstream because every consumer matches with tolerance (tier-2
//  gates on phone-edit ≤ len/6).
//

import Foundation

final class PhoneticLexicon: Sendable {
    static let shared = PhoneticLexicon()

    /// word (lowercased) → pronunciations (each a stress-stripped ARPAbet list).
    private let pronunciations: [String: [[String]]]
    /// space-joined phones → words with that pronunciation, most frequent first.
    private let phoneIndex: [String: [String]]
    /// word → news-corpus frequency rank (lower = more common).
    private let rank: [String: Int]

    /// All CMUdict headwords - the "splitset" the Python prototype unioned
    /// with the 100k news list for compound splits and pronounceability.
    let knownWords: Set<String>

    private init() {
        var prons: [String: [[String]]] = [:]
        prons.reserveCapacity(130_000)
        if let url = Bundle.main.url(forResource: "cmudict_phones", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count == 2 else { continue }
                prons[String(cols[0]), default: []].append(cols[1].split(separator: " ").map(String.init))
            }
        }
        self.pronunciations = prons
        self.knownWords = Set(prons.keys)

        var rank: [String: Int] = [:]
        rank.reserveCapacity(100_000)
        if let url = Bundle.main.url(forResource: "eng_news_2024_100K-words", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: "\t")
                guard cols.count >= 2, let r = Int(cols[0]) else { continue }
                let word = cols[1].lowercased()
                if rank[word] == nil { rank[word] = r }
            }
        }
        self.rank = rank

        var index: [String: [String]] = [:]
        index.reserveCapacity(120_000)
        for (word, list) in prons {
            for phones in list {
                index[phones.joined(separator: " "), default: []].append(word)
            }
        }
        for key in index.keys {
            index[key]?.sort { (rank[$0] ?? 1_000_000, $0) < (rank[$1] ?? 1_000_000, $1) }
        }
        self.phoneIndex = index
    }

    /// News-corpus frequency rank; unranked words sort last.
    func frequencyRank(_ word: String) -> Int { rank[word.lowercased()] ?? 1_000_000 }

    /// All CMUdict pronunciations for `word`, or empty when OOV.
    func cmuPronunciations(_ word: String) -> [[String]] {
        pronunciations[word.lowercased()] ?? []
    }

    /// Words pronounced exactly `phones`, most frequent first.
    func homophones(of phones: [String]) -> [String] {
        phoneIndex[phones.joined(separator: " ")] ?? []
    }

    /// Phones for one alphabetic token: CMUdict when known, LTS rules otherwise.
    func phones(forToken token: String) -> [String] {
        let key = token.lowercased()
        if let prons = pronunciations[key], let first = prons.first { return first }
        return Self.lettersToSound(key)
    }

    /// Phones for a whole (possibly multi-token) spoken string: per-token
    /// phones concatenated. Non-alphabetic characters split tokens.
    func phones(forSpoken text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .flatMap { phones(forToken: String($0)) }
    }

    // MARK: - Real-word tilings

    /// Sequences of ≤ `maxWords` real words whose pronunciations concatenate to
    /// exactly `phones` - the "Lukwise" → "luck wise" layer. Port of
    /// the alias eval's G2P tiling: DFS over the phone index (words of ≥2 phones,
    /// ≤12-phone windows, top-3 homophones per window), ranked by fewest words
    /// then combined frequency, deduplicated, top `topN`.
    func tilings(of phones: [String], maxWords: Int = 3, topN: Int = 5) -> [[String]] {
        let n = phones.count
        guard n >= 2 else { return [] }
        var found: [[String]] = []
        var acc: [String] = []

        func rec(_ i: Int) {
            if found.count > 400 { return }
            if i == n {
                if !acc.isEmpty { found.append(acc) }
                return
            }
            if acc.count >= maxWords { return }
            let maxJ = min(i + 12, n)
            guard i + 2 <= maxJ else { return }
            for j in stride(from: i + 2, through: maxJ, by: 1) {
                for w in homophones(of: Array(phones[i..<j])).prefix(3) {
                    acc.append(w)
                    rec(j)
                    acc.removeLast()
                }
            }
        }
        rec(0)

        func score(_ t: [String]) -> (Int, Int) {
            (t.count, t.reduce(0) { $0 + frequencyRank($1) })
        }
        var seen = Set<String>()
        var out: [[String]] = []
        for t in found.sorted(by: { score($0) < score($1) }) {
            let key = t.joined(separator: " ")
            if seen.insert(key).inserted {
                out.append(t)
                if out.count >= topN { break }
            }
        }
        return out
    }

    // MARK: - Letter-to-sound fallback

    /// Ordered context-sensitive spelling→phones rules, longest-grapheme match
    /// first at each position. `when` inspects (previous char, next char after
    /// the grapheme). Vowel quality is approximate by design.
    private struct LTSRule: Sendable {
        let grapheme: String
        let phones: [String]
        let when: (@Sendable (Character?, Character?) -> Bool)?
        init(_ grapheme: String, _ phones: [String],
             when: (@Sendable (Character?, Character?) -> Bool)? = nil) {
            self.grapheme = grapheme
            self.phones = phones
            self.when = when
        }
    }

    private static let vowels = Set("aeiouy")
    private static func isVowel(_ c: Character?) -> Bool { c.map { vowels.contains($0) } ?? false }
    private static func softens(_ c: Character?) -> Bool { c == "e" || c == "i" || c == "y" }

    /// Multi-character graphemes, tried before single letters.
    private static let ltsMultiRules: [LTSRule] = [
        LTSRule("tion", ["SH", "AH", "N"]),
        LTSRule("sion", ["ZH", "AH", "N"]),
        LTSRule("ough", ["OW"]),
        LTSRule("augh", ["AO"]),
        LTSRule("eigh", ["EY"]),
        LTSRule("igh", ["AY"]),
        LTSRule("dge", ["JH"]),
        LTSRule("tch", ["CH"]),
        LTSRule("sch", ["S", "K"]),
        LTSRule("que", ["K"]),
        LTSRule("qu", ["K", "W"]),
        LTSRule("ch", ["CH"]),
        LTSRule("sh", ["SH"]),
        LTSRule("th", ["TH"]),
        LTSRule("ph", ["F"]),
        LTSRule("wh", ["W"]),
        LTSRule("ck", ["K"]),
        LTSRule("ng", ["NG"]),
        LTSRule("wor", ["W", "ER"], when: { prev, next in
            prev == nil && !PhoneticLexicon.isVowel(next)  // work, word, world
        }),
        LTSRule("wr", ["R"], when: { prev, _ in prev == nil }),
        LTSRule("kn", ["N"], when: { prev, _ in prev == nil }),
        LTSRule("ps", ["S"], when: { prev, _ in prev == nil }),
        LTSRule("mb", ["M"], when: { _, next in next == nil }),
        LTSRule("oo", ["UW"]),
        LTSRule("ee", ["IY"]),
        LTSRule("ea", ["IY"]),
        LTSRule("ai", ["EY"]),
        LTSRule("ay", ["EY"]),
        LTSRule("oa", ["OW"]),
        LTSRule("ow", ["OW"]),
        LTSRule("ou", ["AW"]),
        LTSRule("oi", ["OY"]),
        LTSRule("oy", ["OY"]),
        LTSRule("au", ["AO"]),
        LTSRule("aw", ["AO"]),
        LTSRule("ie", ["IY"]),
        LTSRule("ei", ["EY"]),
        LTSRule("ey", ["EY"]),
        LTSRule("ue", ["UW"]),
        LTSRule("ui", ["UW"]),
        LTSRule("er", ["ER"]),
        LTSRule("ir", ["ER"]),
        LTSRule("ur", ["ER"]),
        LTSRule("or", ["AO", "R"]),
        LTSRule("ar", ["AA", "R"]),
        LTSRule("ll", ["L"]),
        LTSRule("ss", ["S"]),
        LTSRule("ff", ["F"]),
        LTSRule("zz", ["Z"]),
        LTSRule("tt", ["T"]),
        LTSRule("pp", ["P"]),
        LTSRule("bb", ["B"]),
        LTSRule("dd", ["D"]),
        LTSRule("gg", ["G"]),
        LTSRule("mm", ["M"]),
        LTSRule("nn", ["N"]),
        LTSRule("rr", ["R"]),
        LTSRule("cc", ["K"]),
    ]

    private static let ltsSingle: [Character: [String]] = [
        "a": ["AE"], "b": ["B"], "d": ["D"], "e": ["EH"], "f": ["F"],
        "h": ["HH"], "i": ["IH"], "j": ["JH"], "k": ["K"], "l": ["L"],
        "m": ["M"], "n": ["N"], "o": ["AA"], "p": ["P"], "q": ["K"],
        "r": ["R"], "t": ["T"], "u": ["AH"], "v": ["V"], "w": ["W"],
        "z": ["Z"],
    ]

    /// Rule-based grapheme→phoneme for a lowercase alphabetic token.
    static func lettersToSound(_ token: String) -> [String] {
        let chars = Array(token.lowercased().filter(\.isLetter))
        guard !chars.isEmpty else { return [] }
        var out: [String] = []
        var i = 0
        // Magic-e: final silent e that lengthens the previous vowel
        // (consonant-e ending on a token of ≥4 letters: "like", "cerite").
        let magicE = chars.count >= 4 && chars.last == "e"
            && !isVowel(chars[chars.count - 2])
            && isVowel(chars[chars.count - 3])
        let longVowel: [Character: [String]] = [
            "a": ["EY"], "e": ["IY"], "i": ["AY"], "o": ["OW"], "u": ["UW"], "y": ["AY"],
        ]
        let magicVowelIndex = magicE ? chars.count - 3 : -1

        while i < chars.count {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            var matched = false
            for rule in ltsMultiRules {
                let g = Array(rule.grapheme)
                guard i + g.count <= chars.count,
                      Array(chars[i..<(i + g.count)]) == g else { continue }
                let next: Character? = i + g.count < chars.count ? chars[i + g.count] : nil
                if let cond = rule.when, !cond(prev, next) { continue }
                out += rule.phones
                i += g.count
                matched = true
                break
            }
            if matched { continue }

            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "e" where i == chars.count - 1 && magicE:
                break  // silent final e
            case _ where i == magicVowelIndex:
                out += longVowel[c] ?? ["AH"]
            case "c":
                out.append(softens(next) ? "S" : "K")
            case "g":
                out.append(softens(next) ? "JH" : "G")
            case "s":
                // intervocalic s often voices ("visa"), default S elsewhere
                out.append(isVowel(prev) && isVowel(next) ? "Z" : "S")
            case "x":
                out += ["K", "S"]
            case "y":
                out.append(isVowel(prev) || i == 0 ? "Y" : (i == chars.count - 1 ? "IY" : "IH"))
            case "e" where i == chars.count - 1 && chars.count >= 3:
                break  // other final e: usually silent ("apple" handled by l)
            default:
                out += ltsSingle[c] ?? []
            }
            i += 1
        }
        return out
    }
}
