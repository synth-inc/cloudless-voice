// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
// Portions derived from FluidAudio (https://github.com/FluidInference/FluidAudio),
// Copyright (c) FluidInference, licensed under the Apache License, Version 2.0.
// Modified by Synthetic Exploration, Inc. See THIRD_PARTY_NOTICES.md at the repository root.
//
//  BpeTokenizer.swift
//  Onit
//
//  BPE tokenizer that loads directly from tokenizer.json (HuggingFace format).
//  Used by ParakeetCTCEngine for CTC vocabulary biasing.
//
//  Ported from FluidAudio/BpeTokenizer.swift.
//

import Foundation

/// BPE tokenizer for CTC vocabulary boosting.
/// Only implements encoding - no decoding, chat templates, or other LLM features.
/// Supports the specific tokenizer.json format used by Parakeet CTC models.
///
/// Text normalization: **lowercasing** + NFKC normalization before BPE encoding,
/// matching the standard NeMo CTC tokenization pipeline. Callers that care
/// about case preservation (e.g. `CustomDictionaryService` storing a user-typed
/// term) must remember that the returned token IDs correspond to the
/// lowercased form, not the original text.
final class BpeTokenizer: Sendable {
    private let vocab: [String: Int]
    /// Pair → priority lookup used by `encode` to avoid a linear scan of the
    /// entire merges list on every inner iteration. Lower priority wins.
    private let mergeRank: [MergePair: Int]
    private let addedTokens: [String: Int]

    /// Hashable pair of subword strings, indexed in `mergeRank`.
    private struct MergePair: Hashable {
        let first: String
        let second: String
    }

    enum BpeTokenizerError: LocalizedError {
        case fileNotFound(URL)
        case invalidJSON(String)
        case missingField(String)
        case unsupportedType(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):  return "tokenizer.json not found at \(url.path)"
            case .invalidJSON(let msg):   return "Invalid JSON in tokenizer.json: \(msg)"
            case .missingField(let f):    return "tokenizer.json missing field: \(f)"
            case .unsupportedType(let t): return "Unsupported tokenizer type '\(t)' - only BPE supported"
            }
        }
    }

    // MARK: - Factory

    /// Load a BPE tokenizer from a directory containing `tokenizer.json`.
    static func load(from directory: URL) throws -> BpeTokenizer {
        let path = directory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BpeTokenizerError.fileNotFound(path)
        }

        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BpeTokenizerError.invalidJSON("root is not a dictionary")
        }

        guard let model = json["model"] as? [String: Any] else {
            throw BpeTokenizerError.missingField("model")
        }
        guard let modelType = model["type"] as? String else {
            throw BpeTokenizerError.missingField("model.type")
        }
        guard modelType == "BPE" else {
            throw BpeTokenizerError.unsupportedType(modelType)
        }
        guard let vocabDict = model["vocab"] as? [String: Int] else {
            throw BpeTokenizerError.missingField("model.vocab")
        }
        guard let mergesArray = model["merges"] as? [String] else {
            throw BpeTokenizerError.missingField("model.merges")
        }

        // Build the rank table directly so `encode` gets O(1) pair lookup.
        // The order of `mergesArray` is the training-time merge priority -
        // lower index = higher priority.
        var mergeRank: [MergePair: Int] = [:]
        mergeRank.reserveCapacity(mergesArray.count)
        for (idx, s) in mergesArray.enumerated() {
            let parts = s.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let pair = MergePair(first: String(parts[0]), second: String(parts[1]))
            if mergeRank[pair] == nil {
                mergeRank[pair] = idx
            }
        }

        var addedTokens: [String: Int] = [:]
        for token in (json["added_tokens"] as? [[String: Any]]) ?? [] {
            if let content = token["content"] as? String, let id = token["id"] as? Int {
                addedTokens[content] = id
            }
        }

        return BpeTokenizer(vocab: vocabDict, mergeRank: mergeRank, addedTokens: addedTokens)
    }

    private init(vocab: [String: Int], mergeRank: [MergePair: Int], addedTokens: [String: Int]) {
        self.vocab = vocab
        self.mergeRank = mergeRank
        self.addedTokens = addedTokens
    }

    // MARK: - Encoding

    /// Encode `text` to token IDs using BPE.
    /// Does NOT prepend BOS or append EOS - CTC models don't use them.
    func encode(_ text: String) -> [Int] {
        // Normalize: lowercase + NFKC (matches NeMo CTC training pipeline)
        let normalized = text.lowercased().precomposedStringWithCompatibilityMapping

        // Pre-tokenize: leading ▁ + replace spaces with ▁ (sentencepiece style)
        let preprocessed = "▁" + normalized.replacingOccurrences(of: " ", with: "▁")

        // Guard empty or single-character input before the `0..<word.count - 1`
        // loop - the previous implementation underflowed `Int` for empty
        // strings and short-circuited awkwardly for single chars.
        var word = preprocessed.map { String($0) }
        if word.isEmpty { return [] }
        if word.count == 1 {
            guard let id = tokenId(for: word[0]) else { return [] }
            return [id]
        }

        // Apply BPE merges iteratively until no more merges apply. O(1) pair
        // lookup via `mergeRank`; the previous `merges.firstIndex(where:)`
        // scan was O(|merges|) per pair per iteration (~20 K × |word|²).
        while true {
            var bestRank: Int?
            var bestPair: MergePair?

            for i in 0..<(word.count - 1) {
                let pair = MergePair(first: word[i], second: word[i + 1])
                guard let rank = mergeRank[pair] else { continue }
                if bestRank.map({ rank < $0 }) ?? true {
                    bestRank = rank
                    bestPair = pair
                }
            }

            guard let pair = bestPair else { break }

            var newWord: [String] = []
            newWord.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == pair.first, word[i + 1] == pair.second {
                    newWord.append(pair.first + pair.second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            if newWord.count == word.count { break }  // defensive - no merge applied
            word = newWord
            if word.count < 2 { break }
        }

        // If any subword is OOV the token sequence is corrupt - return [] so
        // `buildVocabularyContext` skips the term instead of registering it with
        // token ID 0 in place of every unknown character.
        let ids = word.map { tokenId(for: $0) }
        guard !ids.contains(where: { $0 == nil }) else { return [] }
        return ids.compactMap { $0 }
    }

    /// Look up a single subword token id, returning `nil` if the token is truly OOV.
    ///
    /// The previous implementation fell back to `?? 0`, which silently mapped unknown
    /// subwords (accented characters, emoji, mixed-script terms) to token ID 0 - a real
    /// BPE token (`▁`). CTC DP then scored frames that strongly emit `▁` as if the
    /// keyword matched there, producing false positives for any term with OOV characters.
    ///
    /// Returning `nil` instead lets `encode` detect incomplete tokenisation and return
    /// `[]`, which causes `buildVocabularyContext` to skip the term rather than register
    /// it with a corrupted token sequence.
    private func tokenId(for token: String) -> Int? {
        addedTokens[token] ?? vocab[token] ?? addedTokens["<unk>"] ?? vocab["<unk>"]
    }
}
