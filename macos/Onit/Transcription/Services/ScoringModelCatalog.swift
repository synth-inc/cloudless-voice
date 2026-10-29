// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringModelCatalog.swift
//  Onit
//
//  The perplexity-scoring LM used by MLXScoringEngine (n-best selection, the
//  dictionary NLL gate, etc.) defaults to an English-centric Llama 3.2 1B, which
//  scores non-English text poorly. This catalog makes the scoring model
//  user-selectable: the engine and the downloader both resolve their HF repo and
//  local directory from `ScoringModel.selected`.
//
//  Two tiers:
//   • built-ins (English Llama default + Qwen 2.5 1.5B multilingual), and
//   • PRO: user-added custom models - any MLX-format HuggingFace repo the user
//     pastes in. Persisted in Defaults so they survive relaunch. The weights must
//     be MLX-loadable (mlx-community-style safetensors); the add flow validates
//     this against the HF file list and rejects GGUF / LoRA-adapter / non-MLX
//     repos before downloading.
//

import Defaults
import Foundation

/// A selectable perplexity-scoring model. Codable so user-added entries persist
/// in Defaults.
struct ScoringModel: Identifiable, Equatable, Hashable, Codable, Sendable, Defaults.Serializable {
    let id: String
    let displayName: String
    /// Informational language hint (BCP-47-ish); not used for matching.
    let languageCode: String
    /// HuggingFace repo the downloader pulls from.
    let hfRepo: String
    /// Local subdirectory under `Onit/Models` the weights live in.
    let dirName: String
    /// Rough on-disk size, for the pre-download disk-space check.
    let approxSizeMB: Int
    /// User-added (vs a built-in). Only custom models can be removed.
    var isCustom: Bool = false

    // MARK: - Built-ins

    /// Default - English-centric Llama 3.2 1B (8-bit). Unchanged behavior; this
    /// is what every existing user has and stays selected unless changed.
    static let englishLlama = ScoringModel(
        id: "en-llama-3.2-1b-8bit",
        displayName: "Llama 3.2 1B - default (English)",
        languageCode: "en",
        hfRepo: "mlx-community/Llama-3.2-1B-Instruct-8bit",
        dirName: "Llama-3.2-1B-Instruct-8bit",
        approxSizeMB: 1300
    )

    /// Multilingual - Qwen 2.5 1.5B Instruct (4-bit). Scores non-English text
    /// (French, Spanish, German, …) far better than the English Llama; needed
    /// for the FR cleanup pipeline to land its transformations without the
    /// scorer over-vetoing legitimate FR candidates.
    static let qwenMultilingual = ScoringModel(
        id: "qwen-2.5-1.5b-instruct-4bit",
        displayName: "Qwen 2.5 1.5B - multilingual",
        languageCode: "multi",
        hfRepo: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        dirName: "Qwen2.5-1.5B-Instruct-4bit",
        approxSizeMB: 880
    )

    // Other language-specialized models aren't shipped built-in - users add
    // their own MLX model via the PRO "add a custom model" flow (see below).

    static let builtIns: [ScoringModel] = [englishLlama, qwenMultilingual]

    /// Built-ins + the user's custom (PRO) models.
    static var all: [ScoringModel] {
        builtIns + Defaults[.customScoringModels]
    }

    static func model(withId id: String) -> ScoringModel {
        all.first { $0.id == id } ?? englishLlama
    }

    /// The user's current selection (falls back to the English default).
    static var selected: ScoringModel {
        model(withId: Defaults[.selectedScoringModelId])
    }

    // MARK: - Custom model management (PRO)

    /// Build a custom entry from a validated HuggingFace repo id. The local dir
    /// name is the repo id with `/` sanitized so it's a safe folder name.
    static func makeCustom(hfRepo: String, sizeMB: Int) -> ScoringModel {
        let safeDir = hfRepo.replacingOccurrences(of: "/", with: "_")
        return ScoringModel(
            id: "custom-\(safeDir.lowercased())",
            displayName: hfRepo,               // show the repo id; it's the clearest label
            languageCode: "",
            hfRepo: hfRepo,
            dirName: safeDir,
            approxSizeMB: max(1, sizeMB),
            isCustom: true
        )
    }

    /// Add (or refresh) a custom model and persist it. No-op-duplicate safe.
    static func addCustom(_ model: ScoringModel) {
        var list = Defaults[.customScoringModels]
        list.removeAll { $0.id == model.id }
        list.append(model)
        Defaults[.customScoringModels] = list
    }

    /// Remove a custom model. If it was selected, fall back to the English default.
    static func removeCustom(id: String) {
        Defaults[.customScoringModels].removeAll { $0.id == id }
        if Defaults[.selectedScoringModelId] == id {
            Defaults[.selectedScoringModelId] = englishLlama.id
        }
    }
}
