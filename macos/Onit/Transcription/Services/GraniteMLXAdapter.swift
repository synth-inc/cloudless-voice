// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  GraniteMLXAdapter.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation
import GraniteSpeech
import MLX

/// Bridges the native MLX-Swift `GraniteSpeech` port to the generic MLX ASR
/// backend. Granite loads from a populated directory (the Onit downloader owns
/// the fetch), auto-detects language, and caps its MLX buffer pool.
enum GraniteMLXAdapter {

    static func hubRepo(for modelId: String) -> String? {
        modelId == ASRModel.graniteSpeechId ? "ibm-granite/granite-speech-4.1-2b" : nil
    }

    static let kind = MLXASRModelKind(
        hubRepo: hubRepo(for:),
        requiredFiles: [
            "config.json",
            "model.safetensors.index.json",
            "model-00001-of-00003.safetensors",
            "model-00002-of-00003.safetensors",
            "model-00003-of-00003.safetensors",
            "tokenizer.json",
            "tokenizer_config.json",
        ],
        // Explicit file list, not globs: the shared `downloadRepo` filter matches
        // patterns by exact filename / directory prefix, not fnmatch. A superset
        // of `requiredFiles` - adds the tokenizer auxiliaries `AutoTokenizer`
        // may read - while skipping the repo's redundant `out_llm.safetensors`,
        // `model.sig`, sample wav, README, and `.eval_results/`.
        downloadPatterns: [
            "config.json",
            "model.safetensors.index.json",
            "model-00001-of-00003.safetensors",
            "model-00002-of-00003.safetensors",
            "model-00003-of-00003.safetensors",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "merges.txt",
            "preprocessor_config.json",
            "chat_template.jinja",
        ],
        honorsForcedLanguage: false, // auto-detect only (no forced-language mode)
        cacheLimitBytes: 2_000_000_000, // bound the Metal pool (16->9 GB sustained)
        load: { directory, _ in
            GraniteTranscriber(model: try await GraniteSpeechModel.load(from: directory))
        }
    )
}

private struct GraniteTranscriber: MLXTranscriber, @unchecked Sendable {
    let model: GraniteSpeechModel

    func transcribe(samples: [Float], language: String?) -> String {
        // Scale the decode budget with the audio length: a fixed 256 silently
        // truncated dictations past ~90s. ~3 words/s of speech is ~4-5 BPE
        // tokens/s; 8/s leaves headroom for punctuation-dense output. Capped
        // well below the model context so a runaway decode stays bounded.
        let seconds = Double(samples.count) / 16_000.0
        let maxTokens = min(2_048, max(256, Int(seconds * 8.0)))
        // `userPrompt:` replaces Granite's default "transcribe…" instruction, so
        // granitePrompt() pairs the glossary with one. Nil when prompt-biasing
        // is off → Granite falls back to its own default prompt.
        return model.transcribe(MLXArray(samples),
                                userPrompt: ASRPromptContext.shared.granitePrompt(),
                                maxTokens: maxTokens)
    }
}
