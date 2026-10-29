// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SherpaTokenizer.swift
//  Onit
//
//  Greedy longest-match BPE tokenizer over the 500-token GigaSpeech vocabulary
//  bundled in Resources/tokens.txt. Used to convert user-typed
//  CustomDictionaryTerm text into the space-delimited BPE token strings that
//  SherpaKeywordSpottingService writes to its keywords file.
//

import Foundation

/// Converts English text to Sherpa KWS keyword strings (space-joined BPE tokens).
///
/// Uses greedy longest-match tokenisation, which matches the SentencePiece BPE
/// behaviour for this 500-token vocabulary in all tested cases.
///
/// Examples:
///   "Onit"  → `"▁ON IT"`
///   "ON IT" → `"▁ON ▁IT"`
///   "Tim"   → `"▁T IM"`
struct SherpaTokenizer: Sendable {

    /// All valid BPE tokens, sorted longest-first for greedy matching.
    private let sortedTokens: [String]

    // MARK: - Factory

    static func load() -> SherpaTokenizer? {
        guard let path = Bundle.main.path(forResource: "tokens.txt", ofType: nil) else { return nil }
        return load(from: URL(fileURLWithPath: path))
    }

    static func load(from url: URL) -> SherpaTokenizer? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var tokens: [String] = []
        for line in content.components(separatedBy: .newlines) {
            guard let token = line.components(separatedBy: " ").first,
                  !token.isEmpty,
                  !token.hasPrefix("<") else { continue }
            tokens.append(token)
        }
        return SherpaTokenizer(tokens: tokens)
    }

    private init(tokens: [String]) {
        self.sortedTokens = tokens.sorted { $0.count > $1.count }
    }

    // MARK: - Public API

    /// Convert `text` (as typed by the user) to a Sherpa keyword string.
    ///
    /// Returns `nil` when any character in the text falls outside the vocabulary.
    func keywordString(for text: String) -> String? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        let words = upper.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var allTokens: [String] = []
        for word in words {
            guard let tokens = tokenizeWord(word) else { return nil }
            allTokens.append(contentsOf: tokens)
        }

        return allTokens.joined(separator: " ")
    }

    /// Returns both the greedy keyword string and a word-forced variant where every
    /// sub-word BPE token is promoted to word-initial (▁-prefixed).
    ///
    /// The Sherpa Zipformer model decodes spoken words as separate word-initial tokens,
    /// so "Onit" (greedy: `▁ON IT`) also needs the variant `▁ON ▁IT` to fire reliably.
    ///
    /// Duplicates are omitted. Returns an empty array when the text can't be tokenized.
    func allKeywordVariants(for text: String) -> [String] {
        guard let primary = keywordString(for: text) else { return [] }
        let tokens = primary.components(separatedBy: " ")
        let forced = tokens.map { $0.hasPrefix("▁") ? $0 : "▁" + $0 }.joined(separator: " ")
        return forced == primary ? [primary] : [primary, forced]
    }

    // MARK: - Private

    /// Greedy longest-match over the vocabulary for a single uppercased word.
    /// Prepends `▁` to encode the word-initial position (SentencePiece convention).
    private func tokenizeWord(_ word: String) -> [String]? {
        var remaining = "▁" + word
        var result: [String] = []
        while !remaining.isEmpty {
            guard let match = sortedTokens.first(where: { remaining.hasPrefix($0) }) else {
                return nil
            }
            result.append(match)
            remaining = String(remaining.dropFirst(match.count))
        }
        return result
    }
}
