// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BertWordPieceTokenizer.swift
//  Onit
//
//  Swift port of the bert-base-uncased WordPiece tokenizer used by
//  sentence-transformers/all-MiniLM-L6-v2, reproducing HuggingFace
//  `BertTokenizer` byte-for-byte so the emitted ids match the embeddings
//  baked into the precomputed emoji anchor table.
//
//  Pipeline (per emoji_assets/TOKENIZER_NOTES.md):
//    1. BasicTokenizer (do_lower_case=True): clean control/whitespace, lowercase,
//       strip accents (NFD + drop Mn), split on whitespace, split punctuation into
//       its own tokens, isolate CJK ideographs.
//    2. WordPiece greedy longest-match with `##` continuation; >100 chars → [UNK].
//    3. Assemble `[CLS] … [SEP]`, truncate to 64, pad with [PAD]=0, mask=1 on real
//       tokens.
//
//  Special ids: [PAD]=0, [UNK]=100, [CLS]=101, [SEP]=102 (0-based line numbers in
//  vocab.txt). No token_type_ids.
//

import Foundation

final class BertWordPieceTokenizer {

    static let maxSeqLen = 64
    private static let maxCharsPerWord = 100

    private let padId: Int32 = 0
    private let unkId = 100
    private let clsId: Int32 = 101
    private let sepId: Int32 = 102

    private let vocab: [String: Int]

    /// Load vocab.txt from the bundle (token id = 0-based line index).
    init?(vocabURL: URL) {
        guard let raw = try? String(contentsOf: vocabURL, encoding: .utf8) else { return nil }
        // Split on newlines; the id of a token is its 0-based line number. Trailing
        // newline yields an empty final element which we drop.
        var map: [String: Int] = [:]
        map.reserveCapacity(30600)
        var idx = 0
        raw.enumerateLines { line, _ in
            map[line] = idx
            idx += 1
        }
        guard map["[CLS]"] == 101, map["[SEP]"] == 102, map["[UNK]"] == 100 else { return nil }
        self.vocab = map
    }

    // MARK: - Public

    struct Encoded {
        let inputIds: [Int32]      // length maxSeqLen
        let attentionMask: [Int32] // length maxSeqLen
    }

    func encode(_ text: String) -> Encoded {
        var pieces: [Int32] = []
        for token in basicTokenize(text) {
            for id in wordPiece(token) { pieces.append(Int32(id)) }
        }

        // [CLS] + up to 62 pieces + [SEP] = 64.
        let maxPieces = Self.maxSeqLen - 2
        if pieces.count > maxPieces { pieces = Array(pieces[0..<maxPieces]) }

        var ids: [Int32] = [clsId]
        ids.append(contentsOf: pieces)
        ids.append(sepId)

        var mask = [Int32](repeating: 0, count: Self.maxSeqLen)
        for i in 0..<ids.count { mask[i] = 1 }
        while ids.count < Self.maxSeqLen { ids.append(padId) }

        return Encoded(inputIds: ids, attentionMask: mask)
    }

    // MARK: - Basic tokenizer

    /// Full BasicTokenizer with do_lower_case=True.
    private func basicTokenize(_ text: String) -> [String] {
        let cleaned = cleanText(text)
        let spaced = tokenizeChineseChars(cleaned)
        var out: [String] = []
        for token in whitespaceSplit(spaced) {
            // Lowercase, then strip accents (matches HF ordering).
            let lowered = token.lowercased()
            let stripped = stripAccents(lowered)
            out.append(contentsOf: splitOnPunctuation(stripped))
        }
        return out
    }

    /// Remove invalid chars & control chars; normalize any whitespace to a space.
    private func cleanText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD || isControl(s) { continue }
            if isWhitespace(s) {
                scalars.append(" ")
            } else {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    /// Surround CJK ideographs with spaces so each becomes its own token.
    private func tokenizeChineseChars(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isCJK(s.value) {
                scalars.append(" ")
                scalars.append(s)
                scalars.append(" ")
            } else {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    private func whitespaceSplit(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// NFD-normalize and drop nonspacing marks (Mn).
    private func stripAccents(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            if s.properties.generalCategory == .nonspacingMark { continue }
            scalars.append(s)
        }
        return String(scalars)
    }

    /// Split a token so every punctuation char becomes its own token.
    private func splitOnPunctuation(_ token: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for s in token.unicodeScalars {
            if isPunctuation(s) {
                if !current.isEmpty { result.append(String(current)); current = String.UnicodeScalarView() }
                result.append(String(s))
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    // MARK: - WordPiece

    /// Greedy longest-match-first over vocab; every non-initial piece looked up
    /// with a `##` prefix. Whole word → [UNK] if any piece fails or >100 chars.
    private func wordPiece(_ token: String) -> [Int] {
        let scalars = Array(token.unicodeScalars)
        if scalars.isEmpty { return [] }
        if scalars.count > Self.maxCharsPerWord { return [unkId] }

        var subTokens: [Int] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var matchedId: Int? = nil
            while start < end {
                var piece = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { piece = "##" + piece }
                if let id = vocab[piece] { matchedId = id; break }
                end -= 1
            }
            guard let id = matchedId else { return [unkId] }
            subTokens.append(id)
            start = end
        }
        return subTokens
    }

    // MARK: - Character class predicates (BERT semantics)

    private func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        default: return s.properties.generalCategory == .spaceSeparator
        }
    }

    private func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0D: return false // treated as whitespace
        default: break
        }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    private func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let cp = s.value
        if (cp >= 33 && cp <= 47) || (cp >= 58 && cp <= 64)
            || (cp >= 91 && cp <= 96) || (cp >= 123 && cp <= 126) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private func isCJK(_ cp: UInt32) -> Bool {
        (cp >= 0x4E00 && cp <= 0x9FFF)
            || (cp >= 0x3400 && cp <= 0x4DBF)
            || (cp >= 0x20000 && cp <= 0x2A6DF)
            || (cp >= 0x2A700 && cp <= 0x2B73F)
            || (cp >= 0x2B740 && cp <= 0x2B81F)
            || (cp >= 0x2B820 && cp <= 0x2CEAF)
            || (cp >= 0xF900 && cp <= 0xFAFF)
            || (cp >= 0x2F800 && cp <= 0x2FA1F)
    }
}
