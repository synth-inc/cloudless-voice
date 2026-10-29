// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CanaryTokenizer.swift
//  Onit
//
//  SentencePiece detokenizer for the NVIDIA Canary-1B-v2 CoreML vocab.json
//  (`{"<id>": "<piece>"}`, 16384 pieces). `▁` (U+2581) marks a leading space;
//  `<|…|>` control tokens and `<unk>`/`<pad>`/`<s>`/`</s>` specials are dropped;
//  `<0xNN>` byte-fallback pieces are reassembled into UTF-8 (needed for the
//  model's 25 European languages). Mirrors FluidAudio's Canary decode contract.
//

import Foundation

struct CanaryTokenizer {
    private let idToPiece: [Int: String]
    private let pieceToId: [String: Int]

    init(vocabURL: URL) throws {
        let data = try Data(contentsOf: vocabURL)
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var map: [Int: String] = [:]
        var reverse: [String: Int] = [:]
        map.reserveCapacity(raw.count)
        reverse.reserveCapacity(raw.count)
        for (key, piece) in raw {
            if let id = Int(key) {
                map[id] = piece
                reverse[piece] = id
            }
        }
        idToPiece = map
        pieceToId = reverse
    }

    /// The control-token id for a language, e.g. `forCode: "es"` → the id of the
    /// `<|es|>` piece. nil if this vocab has no such token. Used to build the
    /// Canary decoder prompt that forces the transcription language.
    func languageTokenId(forCode code: String) -> Int32? {
        guard let id = pieceToId["<|\(code.lowercased())|>"] else { return nil }
        return Int32(id)
    }

    /// Decode token ids to text: concatenate pieces (`▁`→space), reassemble
    /// `<0xNN>` byte-fallback pieces, and drop control/special tokens.
    func decode(ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let piece = idToPiece[id] else { continue }
            // Control tokens like "<|en|>", "<|pnc|>" and structural specials.
            if piece.hasPrefix("<|") && piece.hasSuffix("|>") { continue }
            if piece == "<unk>" || piece == "<pad>" || piece == "<s>" || piece == "</s>" { continue }
            // Byte-fallback piece, e.g. "<0x0A>".
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let b = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(b)
                continue
            }
            bytes.append(contentsOf: Array(piece.replacingOccurrences(of: "\u{2581}", with: " ").utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
