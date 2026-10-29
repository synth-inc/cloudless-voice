// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MoonshineEngine.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-19.
//

import Foundation
import MoonshineVoice

// MARK: - Errors

/// Local error surface for the `MoonshineEngine` wrapper.
///
/// Renamed from `MoonshineError` to avoid the symbol collision with
/// `MoonshineVoice.MoonshineError` exported by the upstream package - the
/// `MoonshineVoice` import below would otherwise make every bare reference
/// ambiguous inside this file.
enum MoonshineEngineError: Error, Equatable {
    case modelNotLoaded
    case unsupportedModel(id: String)
    case loadFailed(String)
    case inferenceFailed(String)
}

// MARK: - Engine

/// Thin actor wrapper around the Moonshine (Useful Sensors) `.ort` models
/// for on-device English speech transcription. Mirrors the public surface of
/// `WhisperCoreMLEngine` / `MLXASREngine` so the routing layer in
/// `TranscriptionManager` can treat all backends uniformly.
///
/// Inference (encoder + decoder ORT sessions + tokenizer) lives entirely
/// inside the `MoonshineVoice` SPM product - we only own the load/unload
/// lifecycle, the model-id ↔ download-folder mapping, and the cache
/// directory layout. Sharing `expectedModelDirectory` with both the
/// downloader (`HuggingFaceModelDownloader.downloadMoonshineIfNeeded()`)
/// and the install-state detection guarantees the disk-presence check and
/// the actual load path can never disagree.
actor MoonshineEngine {

    static let shared = MoonshineEngine()

    // MARK: - State

    /// Holds the live C++/ORT transcriber once loaded. `Transcriber.close()` is
    /// invoked in `unload()` before we drop the reference so the underlying
    /// handle is released deterministically rather than relying on `deinit`,
    /// which Swift may delay arbitrarily after the actor releases the value.
    private var transcriber: Transcriber?

    /// Set to the active model id whenever a session is loaded. Nil when not
    /// loaded. Compared in `ensureLoaded(modelId:)` to short-circuit redundant
    /// loads of the same variant.
    private var loadedVariant: String?

    var isLoaded: Bool { transcriber != nil }

    private init() {}

    // MARK: - Test seam

    /// Test-only constructor so tests can exercise the state machine without
    /// touching the production singleton.
    static func makeForTesting() -> MoonshineEngine { MoonshineEngine() }

    // MARK: - Variant mapping

    /// Map an `ASRModel.id` to the corresponding model folder name on disk and
    /// on the Moonshine download CDN (`https://download.moonshine.ai/model/<variant>/quantized/<variant>`).
    /// Returns nil for non-Moonshine model ids.
    static func huggingFaceVariant(for modelId: String) -> String? {
        switch modelId {
        case ASRModel.moonshineBaseId: return "moonshine-base"
        default:                       return nil
        }
    }

    /// Map an `ASRModel.id` to the C `ModelArch` enum the Moonshine runtime
    /// expects in `Transcriber.init`. Kept separate from the folder name so
    /// the on-disk layout convention stays decoupled from the binary ABI.
    private static func modelArch(for modelId: String) -> ModelArch? {
        switch modelId {
        case ASRModel.moonshineBaseId: return .base
        default:                       return nil
        }
    }

    /// Map an `ASRModel.id` to its download segment on the Moonshine CDN. The
    /// upstream Python downloader builds URLs as
    /// `https://download.moonshine.ai/model/<segment>/<file>` - see
    /// `MODEL_INFO["en"]["models"]` in `moonshine/python/src/moonshine_voice/download.py`.
    static func downloadURLBase(for modelId: String) -> URL? {
        switch modelId {
        case ASRModel.moonshineBaseId:
            return URL(string: "https://download.moonshine.ai/model/base-en/quantized/base-en")
        default:
            return nil
        }
    }

    /// Required `.ort` + tokenizer files for the active variant. Source: the
    /// upstream `get_components_for_model_info` in `download.py` - the
    /// English non-streaming bundle is the union of
    /// `["encoder_model.ort", "decoder_model_merged.ort", "tokenizer.bin"]`
    /// plus `decoder_with_attention.ort` (English only). Wrong list ⇒ load
    /// throws deep inside the C++ runtime with a less-useful error.
    static func requiredFiles(for modelId: String) -> [String] {
        switch modelId {
        case ASRModel.moonshineBaseId:
            return [
                "encoder_model.ort",
                "decoder_model_merged.ort",
                "tokenizer.bin",
                "decoder_with_attention.ort",
            ]
        default:
            return []
        }
    }

    /// Local filesystem location where the Moonshine `.ort` files live for a
    /// given model id. Centralised so install-state detection in
    /// `ASRModelDownloadManager` and the load path stay in sync. Mirrors the
    /// `Onit/Models/<variant>` convention used by the other engines.
    static func expectedModelDirectory(forModelId modelId: String) -> URL? {
        guard let variant = huggingFaceVariant(for: modelId) else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Onit/Models")
            .appendingPathComponent(variant)
    }

    // MARK: - Load

    /// Lazily load the Moonshine model for the given ASR model id.
    ///
    /// Idempotent: returns immediately if the model is already loaded for the
    /// requested id. The `.ort` files must already be present on disk - the
    /// download is owned by `HuggingFaceModelDownloader.downloadMoonshineIfNeeded()`
    /// which is invoked by `ASRModelDownloadManager.performDownload(.moonshineONNX)`
    /// before we ever get here. Construction of the `Transcriber` validates
    /// the file layout via the C runtime, so a partial download surfaces as
    /// `.loadFailed` instead of a silent SIGSEGV.
    func ensureLoaded(modelId: String) async throws {
        if let loadedVariant, loadedVariant == modelId, transcriber != nil { return }

        guard Self.huggingFaceVariant(for: modelId) != nil,
              let arch = Self.modelArch(for: modelId)
        else {
            throw MoonshineEngineError.unsupportedModel(id: modelId)
        }

        guard let modelDir = Self.expectedModelDirectory(forModelId: modelId) else {
            throw MoonshineEngineError.unsupportedModel(id: modelId)
        }

        // Disk-presence check: distinguishes "needs download" from
        // "download present but corrupt", so the UI surfaces a re-download
        // button instead of a generic crash. Mirrors the same pre-flight
        // gate used by `MLXASREngine` for the MLX bundle.
        let fm = FileManager.default
        for file in Self.requiredFiles(for: modelId) {
            let path = modelDir.appendingPathComponent(file).path
            guard fm.fileExists(atPath: path) else {
                throw MoonshineEngineError.loadFailed(
                    "Moonshine model files missing at \(modelDir.path) (\(file)) - re-download required"
                )
            }
        }

        log.info("MoonshineEngine: Loading model \(modelId) from \(modelDir.path)")

        // Tear down any previously-loaded transcriber before swapping in the
        // new one so the C++ side releases its session before we lose the
        // last Swift-side reference. Without this, switching between two
        // Moonshine variants would briefly double the resident set.
        if transcriber != nil {
            unload()
        }

        do {
            let t = try Transcriber(modelPath: modelDir.path, modelArch: arch)
            transcriber = t
            loadedVariant = modelId
            log.info("MoonshineEngine: Model loaded successfully")
        } catch {
            transcriber = nil
            loadedVariant = nil
            log.error("MoonshineEngine: Load failed - \(error.localizedDescription)")
            throw MoonshineEngineError.loadFailed(error.localizedDescription)
        }
    }

    // MARK: - Transcribe

    /// Transcribe a 16 kHz mono float32 buffer. Throws `.modelNotLoaded` if
    /// `ensureLoaded(modelId:)` hasn't run successfully yet.
    ///
    /// `language` is accepted to keep the signature uniform with the other
    /// backends; the English-only `moonshine-base` ignores it. Multilingual
    /// `moonshine-base-<lang>` variants would map to dedicated model ids
    /// (one per language) rather than a runtime switch, mirroring the
    /// upstream download layout.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let transcriber else { throw MoonshineEngineError.modelNotLoaded }
        guard !samples.isEmpty else { return "" }

        do {
            // Non-streaming path: hand the full clip to the C runtime, which
            // returns a list of completed `TranscriptLine`s. We join them
            // with a space because the runtime emits one line per logical
            // segment and the consumer just wants the flat string. Sample
            // rate is hard-coded to 16 kHz to match the rest of the pipeline.
            let transcript = try transcriber.transcribeWithoutStreaming(
                audioData: samples,
                sampleRate: 16_000,
                flags: 0
            )
            let text = transcript.lines
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text
        } catch {
            log.error("MoonshineEngine: Inference failed - \(error.localizedDescription)")
            throw MoonshineEngineError.inferenceFailed(error.localizedDescription)
        }
    }

    // MARK: - Teardown

    func unload() {
        transcriber?.close()
        transcriber = nil
        loadedVariant = nil
    }

    /// Conditional unload: drops the session only if the currently loaded
    /// variant matches the model whose files are about to disappear from disk.
    /// No-op otherwise. Used by `ASRModelDownloadManager.delete(_:)` to avoid
    /// holding a reference to deleted `.ort` files.
    func unloadIfCurrent(modelId: String) {
        guard Self.huggingFaceVariant(for: modelId) != nil else { return }
        if loadedVariant == modelId {
            unload()
        }
    }
}
