// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXASREngine.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

import Defaults
import Foundation
import MLX

/// Generic actor wrapping any MLX-based ASR model (Qwen3, Granite, …). The
/// per-model specifics live in `MLXASRModelKind` (resolved from
/// `MLXModelRegistry`); this owns only the shared load/unload lifecycle, the
/// disk-presence check, and the scoped MLX cache cap. Mirrors the public
/// surface the routing layer expects, so a single `.mlx` backend handles every
/// MLX model.
actor MLXASREngine {

    static let shared = MLXASREngine()

    private var model: MLXTranscriber?
    private var loadedModelId: String?
    private var priorCacheLimit: Int?

    var isLoaded: Bool { model != nil }

    private init() {}

    static func makeForTesting() -> MLXASREngine { MLXASREngine() }

    // MARK: - Load

    /// Lazily load the MLX model for `modelId`. Idempotent. The weights must
    /// already be on disk (the download is owned by
    /// `HuggingFaceModelDownloader.downloadMLXModelIfNeeded`).
    func ensureLoaded(modelId: String) async throws {
        // Last line of defence: MLX is a hard crash on Intel (see `MLXRuntime`),
        // so refuse before any MLX symbol is touched rather than segfault.
        guard MLXRuntime.isSupported else { throw MLXRuntime.UnsupportedError() }
        if loadedModelId == modelId, model != nil { return }

        guard let kind = MLXModelRegistry.kind(for: modelId),
              let dir = MLXModelRegistry.expectedDirectory(for: modelId) else {
            throw MLXASRError.unsupportedModel(id: modelId)
        }

        let fm = FileManager.default
        for file in kind.requiredFiles {
            guard fm.fileExists(atPath: dir.appendingPathComponent(file).path) else {
                throw MLXASRError.loadFailed(
                    "MLX model files missing at \(dir.path) (\(file)) - re-download required")
            }
        }

        // If a different MLX model is currently loaded, drop it first so two
        // heavy models never coexist in memory.
        if model != nil { unload() }

        log.info("MLXASREngine: Loading \(modelId) from \(dir.path)")
        do {
            let loaded = try await kind.load(dir, modelId)
            model = loaded
            loadedModelId = modelId
            if let cap = Self.resolvedCacheLimit(modelDefault: kind.cacheLimitBytes),
               priorCacheLimit == nil {
                priorCacheLimit = MLX.Memory.cacheLimit
                MLX.Memory.cacheLimit = cap
            }
            log.info("MLXASREngine: \(modelId) loaded")
        } catch {
            model = nil
            loadedModelId = nil
            log.error("MLXASREngine: load failed - \(error.localizedDescription)")
            throw MLXASRError.loadFailed(error.localizedDescription)
        }
    }

    // MARK: - Transcribe

    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let model else { throw MLXASRError.modelNotLoaded }
        guard !samples.isEmpty else { return "" }
        return model.transcribe(samples: samples, language: language)
    }

    // MARK: - Teardown

    func unload() {
        model = nil
        loadedModelId = nil
        if let priorCacheLimit {
            MLX.Memory.cacheLimit = priorCacheLimit
            self.priorCacheLimit = nil
        }
        // Release the Metal buffer pool the model accumulated (process-global;
        // only flushes recyclable buffers, so other MLX models re-grow as needed).
        MLXRuntime.clearCache()
    }

    func unloadIfCurrent(modelId: String) {
        if loadedModelId == modelId { unload() }
    }

    // MARK: - Cache limit (user-configurable)

    /// Resolve the MLX recycle-pool cap (bytes): the user's override
    /// (`mlxCacheLimitMB`, where 0 = Auto) takes precedence over the per-model
    /// default declared by the adapter. `nil` = leave the process-wide limit
    /// untouched (only happens at Auto when the model also declares no default).
    nonisolated static func resolvedCacheLimit(modelDefault: Int?) -> Int? {
        let mb = Defaults[Defaults.Keys.TranscriptionConfigKeys.mlxCacheLimitMB]
        return mb > 0 ? mb * 1_000_000 : modelDefault
    }

    /// Apply the cap to the live, process-global MLX setting - e.g. when the
    /// Advanced Settings slider moves, for immediate feedback without a model
    /// reload. Returning to Auto re-applies the loaded model's declared default
    /// (or restores the prior process-wide limit when it declares none) instead
    /// of leaving the last manual cap stuck until unload. Capping only the
    /// recycle pool never evicts live weights, so this can lower RAM but never
    /// break a loaded model.
    func applyUserCacheLimitLive() {
        // Reachable from the Advanced Settings slider with no model loaded, so
        // it needs its own guard: writing `MLX.Memory.cacheLimit` reaches the
        // Metal allocator, which is fatal on Intel (see `MLXRuntime`).
        guard MLXRuntime.isSupported else { return }
        let mb = Defaults[Defaults.Keys.TranscriptionConfigKeys.mlxCacheLimitMB]
        if mb > 0 {
            MLX.Memory.cacheLimit = mb * 1_000_000
        } else if let loadedModelId,
                  let modelDefault = MLXModelRegistry.kind(for: loadedModelId)?.cacheLimitBytes {
            MLX.Memory.cacheLimit = modelDefault
        } else if let priorCacheLimit {
            // Keep `priorCacheLimit` set: unload() still owns the final restore.
            MLX.Memory.cacheLimit = priorCacheLimit
        } else {
            return
        }
        MLXRuntime.clearCache()  // drop buffers already over the new, lower cap
    }

    #if DEBUG
    /// Test-only memory snapshot (active / cache / peak bytes).
    static func mlxMemory() -> (active: Int, cache: Int, peak: Int) {
        (MLX.Memory.activeMemory, MLX.Memory.cacheMemory, MLX.Memory.peakMemory)
    }

    /// Drop the model WITHOUT clearing the MLX cache, so a test can observe the
    /// active->cache transition separately from the pool flush.
    func dropModelOnly() {
        model = nil
        loadedModelId = nil
        if let priorCacheLimit {
            MLX.Memory.cacheLimit = priorCacheLimit
            self.priorCacheLimit = nil
        }
    }

    /// Flush the MLX recyclable buffer pool (process-global).
    static func clearMLXCache() { MLXRuntime.clearCache() }
    #endif
}

// MARK: - StreamingASRCapable

extension MLXASREngine: StreamingASRCapable {

    /// Chunked-streaming seam: transcribe one recording segment, text only. The
    /// MLX transcriber exposes no per-word timing, so `wordTimestamps` is `nil`
    /// and the session degrades the run's timeline to `nil` (rescore uses its
    /// non-timed path).
    func transcribeSegment(
        samples: [Float],
        sampleRate: Int,
        language: String?
    ) async throws -> StreamingSegmentResult {
        // Defensive reload: an idle-unload can strike in the post-stop window.
        // `loadedModelId` is the model in use for the active dictation; fall back
        // to the currently-selected id if the engine was fully unloaded.
        let modelId: String
        if let loadedModelId {
            modelId = loadedModelId
        } else {
            modelId = await TranscriptionConfig.shared.selectedASRModelId
        }
        try await ensureLoaded(modelId: modelId)
        let text = try await transcribe(samples: samples, language: language)
        return StreamingSegmentResult(text: text, wordTimestamps: nil)
    }
}
