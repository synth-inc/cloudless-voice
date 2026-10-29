// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXASRModel.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Foundation

/// A loaded MLX-based ASR model that can transcribe a 16 kHz mono float32
/// buffer. Per-package adapters bridge their vendored model to this seam so the
/// Onit integration treats every MLX model uniformly.
/// `Sendable` because the engine actor owns the loaded model; the concrete
/// adapters are `@unchecked Sendable` since the wrapped (non-Sendable) MLX model
/// is only ever touched inside that actor.
protocol MLXTranscriber: Sendable {
    func transcribe(samples: [Float], language: String?) -> String
}

/// Everything the generic MLX engine/service/warmup/downloader need that
/// *differs* between MLX models. Adding a new MLX ASR model is just a new
/// `MLXASRModelKind` + a catalog entry - no new engine, service, warmup
/// provider, `TranscriptionBackend` case, or routing switch arms.
struct MLXASRModelKind: Sendable {
    /// `ASRModel.id` -> HuggingFace repo, or `nil` if this kind doesn't own the id.
    let hubRepo: @Sendable (String) -> String?
    /// Files that must ALL be present for the on-disk bundle to count as a
    /// complete install (distinguishes "downloaded" from "interrupted").
    let requiredFiles: [String]
    /// Download globs passed to the downloader; `nil` = full-repo pull.
    let downloadPatterns: [String]?
    /// Whether the engine honors a user-forced transcription language. `false`
    /// = auto-detect only (the service returns `nil` from `resolveForcedLanguage`).
    let honorsForcedLanguage: Bool
    /// MLX recyclable-buffer-pool cap (bytes) applied while this model is
    /// loaded, restored on unload; `nil` = leave the process-wide limit alone.
    let cacheLimitBytes: Int?
    /// Load a transcriber from an already-populated local directory.
    let load: @Sendable (_ directory: URL, _ modelId: String) async throws -> MLXTranscriber
}

enum MLXASRError: Error, Equatable {
    case unsupportedModel(id: String)
    case modelNotLoaded
    case loadFailed(String)
}

/// The single place that knows which MLX ASR models exist. Maps an
/// `ASRModel.id` to its `MLXASRModelKind`.
enum MLXModelRegistry {

    static let kinds: [MLXASRModelKind] = [
        Qwen3MLXAdapter.kind,
        GraniteMLXAdapter.kind,
    ]

    static func kind(for modelId: String) -> MLXASRModelKind? {
        kinds.first { $0.hubRepo(modelId) != nil }
    }

    static func isMLXModel(_ modelId: String) -> Bool {
        kind(for: modelId) != nil
    }

    /// Local directory the downloader writes to and the engine loads from:
    /// `appSupport/Onit/Models/<repo-leaf>`. Shared by both so the install-check
    /// and the load path can never disagree.
    static func expectedDirectory(for modelId: String) -> URL? {
        guard let repo = kind(for: modelId)?.hubRepo(modelId) else { return nil }
        let leaf = repo.split(separator: "/").last.map(String.init) ?? repo
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Onit/Models")
            .appendingPathComponent(leaf)
    }
}
