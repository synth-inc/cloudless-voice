// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Qwen3MLXAdapter.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation
import Qwen3ASR

/// Bridges the vendored `Qwen3ASR` package to the generic MLX ASR backend.
/// `Qwen3ASRModel.fromPretrained` auto-detects model size (0.6B vs 1.7B) and
/// quantization (4-bit/8-bit) from the repo id, so the only per-variant data is
/// the id -> repo map.
enum Qwen3MLXAdapter {

    static func hubRepo(for modelId: String) -> String? {
        switch modelId {
        case ASRModel.qwen3ASRId:        return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case ASRModel.qwen3ASR17B4bitId: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case ASRModel.qwen3ASR17B8bitId: return "mlx-community/Qwen3-ASR-1.7B-8bit"
        default:                         return nil
        }
    }

    static let kind = MLXASRModelKind(
        hubRepo: hubRepo(for:),
        requiredFiles: [
            "config.json",
            "model.safetensors",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "preprocessor_config.json",
            "generation_config.json",
        ],
        downloadPatterns: nil, // full repo (safetensors + tokenizer + preprocessor)
        honorsForcedLanguage: true, // Qwen3-ASR is multilingual and honors the hint
        // Bound the MLX Metal recycle pool. Without this it grew unbounded
        // across dictations (~12 GB observed via `footprint`, almost all
        // IOAccelerator). Qwen3-1.7B-4bit weights are ~1 GB and one inference's
        // working set is sub-1 GB, so 1.5 GB is comfortably above the working
        // set (no thrashing) while holding total footprint to ~2-3 GB. The user
        // can override this via Advanced Settings (`mlxCacheLimitMB`).
        cacheLimitBytes: 1_500_000_000,
        load: { directory, modelId in
            guard let repo = hubRepo(for: modelId) else {
                throw MLXASRError.unsupportedModel(id: modelId)
            }
            // offlineMode: true - the Onit downloader has already populated the
            // directory; this keeps fromPretrained from re-probing the Hub.
            let model = try await Qwen3ASRModel.fromPretrained(
                modelId: repo, cacheDir: directory, offlineMode: true, progressHandler: nil)
            return Qwen3Transcriber(model: model)
        }
    )
}

private struct Qwen3Transcriber: MLXTranscriber, @unchecked Sendable {
    let model: Qwen3ASRModel

    func transcribe(samples: [Float], language: String?) -> String {
        // Scale the decode budget with the audio length (see GraniteTranscriber):
        // a fixed 448 silently truncated long dictations. Keeps 448 as the floor
        // so short utterances behave exactly as before.
        let seconds = Double(samples.count) / 16_000.0
        let maxTokens = min(2_048, max(448, Int(seconds * 8.0)))
        let promptContext = ASRPromptContext.shared
        // `context:` is a system message; nil when dictionary prompt-biasing is
        // off (TranscriptionManager stages the glossary before each transcribe).
        let systemPrompt = promptContext.qwenSystemPrompt()

        let (boostTerms, settings) = promptContext.trieBoostStaging()
        if !boostTerms.isEmpty {
            let options = Qwen3DecodingOptions(
                maxTokens: maxTokens,
                language: language,
                context: systemPrompt,
                boostTerms: boostTerms,
                boostStrength: settings.strength,
                boostMaxBacktracks: settings.maxBacktracks,
                boostAliases: settings.aliases)
            return model.transcribe(audio: samples, sampleRate: 16_000, options: options)
        }

        return model.transcribe(
            audio: samples, sampleRate: 16_000, language: language,
            maxTokens: maxTokens, context: systemPrompt)
    }
}
