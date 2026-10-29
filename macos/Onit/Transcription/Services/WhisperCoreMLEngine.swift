// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperCoreMLEngine.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import WhisperKit

// MARK: - Errors

enum WhisperCoreMLError: Error, Equatable {
    case modelNotLoaded
    case unsupportedModel(id: String)
    case loadFailed(String)
    case inferenceFailed(String)
}

// MARK: - Engine

/// Thin actor wrapper around WhisperKit for on-device Whisper transcription.
///
/// The heavy lifting (model download, mel extraction, encoder/decoder inference,
/// segment seeking) is delegated to WhisperKit. This engine only owns the kit
/// lifecycle and exposes a `transcribe(samples:language:)` surface that mirrors
/// `ParakeetCoreMLEngine` so the routing layer in `TranscriptionManager` can
/// treat both backends uniformly.
actor WhisperCoreMLEngine {

    static let shared = WhisperCoreMLEngine()

    // MARK: - State

    /// Marked `nonisolated(unsafe)` for the same reason as `WhisperLanguageDetector`:
    /// the upstream `WhisperKit` class is not `Sendable`, but every read/write here
    /// happens inside an actor-isolated method, so the actor serialises access.
    nonisolated(unsafe) private var kit: WhisperKit?
    private var loadedVariant: String?

    var isLoaded: Bool { kit != nil }

    private init() {}

    // MARK: - Test seam

    /// Test-only constructor so tests can exercise the state machine without
    /// touching the production singleton.
    static func makeForTesting() -> WhisperCoreMLEngine { WhisperCoreMLEngine() }

    // MARK: - Variant mapping

    /// Map an `ASRModel.id` to the corresponding WhisperKit variant string
    /// (the name used under `argmaxinc/whisperkit-coreml`). Returns nil for
    /// non-Whisper models.
    /// WhisperKit's HF folder convention uses an underscore before `turbo` on the
    /// large-v3 variant (`openai_whisper-large-v3_turbo`), not a hyphen - confirmed
    /// against the `argmaxinc/whisperkit-coreml` tree on HuggingFace. Getting this
    /// wrong yields a "modelsUnavailable" download error at warmup time.
    static func whisperKitVariant(for modelId: String) -> String? {
        switch modelId {
        case ASRModel.whisperLargeTurboV3Id: return "openai_whisper-large-v3_turbo"
        case ASRModel.whisperMediumId:       return "openai_whisper-medium"
        default:                             return nil
        }
    }

    // MARK: - Storage location

    /// Base directory handed to WhisperKit as `downloadBase`, and through it to
    /// `HubApi`. Whisper used to inherit HubApi's default, `~/Documents/huggingface/`,
    /// which made it the only ASR backend living outside Application Support:
    /// macOS gates `~/Documents` behind a Files & Folders consent prompt that is
    /// bound to the code signature (a denial survives a clean reinstall), and
    /// iCloud Drive syncs that folder when "Desktop & Documents Folders" is on,
    /// which uploads up to ~3 GB of weights and can hand them back as dataless
    /// placeholders that fault on read.
    ///
    /// HubApi appends `models/<repo-id>` to this base, hence the extra
    /// `huggingface` component: it keeps that whole repo tree inside one folder
    /// next to the other model bundles instead of scattering a `models/`
    /// directory across `Onit/Models`.
    static let downloadBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Onit/Models/huggingface")

    /// Repo directory holding the CoreML bundles, relative to a HubApi base.
    static let modelRepoPath = "models/argmaxinc/whisperkit-coreml"

    /// Parent of the `openai/whisper-*` tokenizer snapshots, relative to a HubApi
    /// base. The tokenizer lives in a second HF repo that `WhisperKit.download`
    /// never fetches: it is resolved at load time from `tokenizerFolder`, which
    /// WhisperKit defaults to `downloadBase`. It therefore has to follow the
    /// weights, or half the install stays behind in `~/Documents`.
    static let tokenizerRepoParent = "models/openai"

    /// Local filesystem location WhisperKit reads/writes for a given model id.
    /// Single source of truth: the install-state detection in
    /// `ASRModelDownloadManager` and the load path taken by `WhisperKitConfig`
    /// both resolve through it, which is why the legacy migration runs here: no
    /// caller can observe the new location before a pre-existing `~/Documents`
    /// install has been moved into it.
    static func expectedModelDirectory(forModelId modelId: String) -> URL? {
        guard let variant = whisperKitVariant(for: modelId) else { return nil }
        migrateLegacyStorageIfNeeded()
        return downloadBase
            .appendingPathComponent(modelRepoPath)
            .appendingPathComponent(variant)
    }

    /// The CoreML model components WhisperKit requires to load a bundle. Mirrors
    /// the load-time guard in `WhisperKit.loadModels(...)`, which throws
    /// `modelsUnavailable` unless all three `.mlmodelc` directories are present.
    private static let requiredModelComponents = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    /// Leaf files checked inside each required component. HubApi creates a
    /// component directory as soon as its *first* file lands, so directory
    /// existence alone reports a download killed mid-transfer as complete.
    ///
    /// Checking a single leaf is not enough: `HubApi.getFilenames` ends on
    /// `Array(selected)` over a `Set`, whose iteration order is unspecified and
    /// randomised per process, so no one file is guaranteed to land last. These
    /// three carry essentially all of a component's bytes and are the ones
    /// `MLModel` reads, so a component holding all three is loadable in practice.
    /// Verified present in every required component of both supported variants
    /// (`openai_whisper-medium`, `openai_whisper-large-v3_turbo`).
    private static let requiredComponentLeaves = [
        "coremldata.bin",
        "model.mil",
        "weights/weight.bin",
    ]

    /// Whether every required CoreML component for `modelId` is fully on disk.
    ///
    /// Three call sites depend on it, and they must agree: `isInstalledOnDisk` (so
    /// the picker never offers a partial bundle that throws `modelsUnavailable` on
    /// load), `ensureLoaded` (which points WhisperKit straight at `modelFolder`
    /// when true, skipping HubApi), and `downloadWhisperIfNeeded` (which skips the
    /// download entirely when true). That last one is why the leaf-file check
    /// matters: a false positive no longer merely mis-labels the model as
    /// installed, it also removes the re-download that used to repair it.
    static func isModelComplete(forModelId modelId: String) -> Bool {
        guard let directory = expectedModelDirectory(forModelId: modelId) else { return false }
        let fileManager = FileManager.default
        for component in requiredModelComponents {
            let componentURL = directory.appendingPathComponent(component)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: componentURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  requiredComponentLeaves.allSatisfy({
                      fileManager.fileExists(atPath: componentURL.appendingPathComponent($0).path)
                  })
            else {
                return false
            }
        }
        return true
    }

    // MARK: - Legacy storage migration

    /// HubApi's default `downloadBase`, where every Whisper install made before
    /// the move to Application Support still sits.
    private static let legacyDownloadBase: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface")

    /// One-shot move of a pre-existing `~/Documents` install into `downloadBase`,
    /// run at most once per process: a `static let` initialiser is lazy and
    /// thread-safe, so the first caller performs the move and every later one is
    /// a no-op. Without it, changing the path would report an installed model as
    /// not installed and re-download 1.5 GB (Medium) or ~3 GB (large-v3-turbo).
    ///
    /// It runs from the two places that resolve a WhisperKit path, so the first
    /// trigger is whichever comes first: opening the ASR model settings, where the
    /// picker hydrates itself through `isInstalledOnDisk`, or a Whisper warmup.
    /// Not app launch: `ASRModelDownloadManager.shared` is referenced only from
    /// Settings views, so its `static let` stays uninitialised until one of them
    /// appears. `~/Documents`, and the Files & Folders consent prompt it can
    /// raise, therefore stay untouched for anyone who never goes near a Whisper
    /// model. Install state is also exactly what the migration must precede, so
    /// resolving it here leaves no window where a caller sees the new location
    /// while the files are still in the old one.
    ///
    /// Synchronous, on the caller's thread. Both bases sit under the home
    /// directory, so the move is a rename and returns immediately. The
    /// cross-volume copy fallback would instead block that thread for the size of
    /// the bundle: the price of never letting a caller observe the new location
    /// before the files are actually there.
    private static let legacyStorageMigration: Void = {
        migrateLegacyStorage(from: legacyDownloadBase, to: downloadBase)
    }()

    /// Runs that one-shot migration. Every path about to resolve a WhisperKit
    /// storage location calls it first: `expectedModelDirectory` for the two
    /// catalog models, and `WhisperLanguageDetector` for the `whisper-base`
    /// bundle it loads on the Parakeet multi-language path.
    static func migrateLegacyStorageIfNeeded() {
        _ = legacyStorageMigration
    }

    /// Repo directories Whisper owns under a HubApi base, as paths relative to it:
    /// the CoreML weights plus whichever `openai/whisper-*` tokenizer snapshots
    /// are actually there. HubApi's `.cache/huggingface/download/<variant>`
    /// sidecars sit at the repo root, inside `whisperkit-coreml`, so they travel
    /// with the weights and keep agreeing with them.
    static func whisperRepoRelativePaths(in base: URL) -> [String] {
        var paths = [modelRepoPath]
        let tokenizerRoot = base.appendingPathComponent(tokenizerRepoParent)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tokenizerRoot.path)) ?? []
        paths += entries.filter { $0.hasPrefix("whisper-") }.map { "\(tokenizerRepoParent)/\($0)" }
        return paths
    }

    /// Move every Whisper repo found under `legacyBase` to the same relative path
    /// under `base`. Idempotent: a repo already present at the destination is left
    /// alone, so a half-finished migration resumes on the next launch.
    ///
    /// Returns whether anything moved (used by the tests; callers ignore it).
    @discardableResult
    static func migrateLegacyStorage(from legacyBase: URL, to base: URL) -> Bool {
        let fileManager = FileManager.default
        var moved = false
        for relativePath in whisperRepoRelativePaths(in: legacyBase) {
            let source = legacyBase.appendingPathComponent(relativePath)
            let destination = base.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path)
            else { continue }

            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    // Both paths live under the home directory, so in any realistic
                    // setup this is a rename: instant, and it needs no free space
                    // for a bundle that can reach ~3 GB.
                    try fileManager.moveItem(at: source, to: destination)
                } catch {
                    // Separate volumes, or a rename the OS refuses. Copy first and
                    // only unlink the original once the copy is on disk.
                    try fileManager.copyItem(at: source, to: destination)
                    try? fileManager.removeItem(at: source)
                }
                moved = true
                log.info("WhisperCoreMLEngine: migrated \(relativePath) out of the legacy model store")
            } catch {
                // Nothing of the original is destroyed on failure. This is exactly
                // the population that may be hitting a Files & Folders denial on
                // `~/Documents`, and it has to lose disk space at worst, never a
                // working install: the normal download path takes over and refetches
                // into the new location. Drop a partial copy so the next launch
                // retries instead of seeing a destination that already "exists".
                try? fileManager.removeItem(at: destination)
                log.warning(
                    "WhisperCoreMLEngine: could not migrate \(relativePath): \(error.localizedDescription)")
            }
        }

        // Leave no empty `huggingface` skeleton behind: an unexplained folder in
        // Documents is a third of why this moved at all. Deepest first, and only
        // when the directory is genuinely empty, so anything another app parked
        // under HubApi's default base survives untouched.
        if moved {
            let leftovers = [
                legacyBase.appendingPathComponent(tokenizerRepoParent),
                legacyBase.appendingPathComponent(modelRepoPath).deletingLastPathComponent(),
                legacyBase.appendingPathComponent("models"),
                legacyBase,
            ]
            for directory in leftovers
            where (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: directory)
            }
        }
        return moved
    }

    // MARK: - Load

    /// Lazily load the WhisperKit model for the given ASR model id. Subsequent
    /// calls with the same id are no-ops; a different id triggers a reload.
    func ensureLoaded(modelId: String) async throws {
        if let loadedVariant, loadedVariant == modelId, kit != nil { return }

        guard let variant = Self.whisperKitVariant(for: modelId) else {
            throw WhisperCoreMLError.unsupportedModel(id: modelId)
        }

        do {
            let config: WhisperKitConfig
            if Self.isModelComplete(forModelId: modelId),
               let directory = Self.expectedModelDirectory(forModelId: modelId) {
                // Already fully downloaded - point WhisperKit straight at the local
                // bundle, matching how every other backend (Parakeet, Moonshine,
                // MLX) loads. Without `modelFolder`, `WhisperKitConfig.download`
                // defaults to true and WhisperKit always does a live HubApi file
                // listing + snapshot to resolve the folder, even when nothing
                // needs downloading. That network round-trip has no timeout, so a
                // slow/stalled connection hangs `ensureLoaded` indefinitely - and
                // since the backtest runner only checks for cancellation between
                // cases, Cancel does nothing while stuck here.
                // `downloadBase` is still passed with `modelFolder`: WhisperKit
                // derives `tokenizerFolder` from it, and the tokenizer is a
                // separate HF repo that is fetched (or found) at load time.
                config = WhisperKitConfig(
                    model: variant, downloadBase: Self.downloadBase,
                    modelFolder: directory.path, verbose: false, load: true)
            } else {
                config = WhisperKitConfig(
                    model: variant, downloadBase: Self.downloadBase, verbose: false, load: true)
            }
            kit = try await WhisperKit(config)
            loadedVariant = modelId
        } catch {
            throw WhisperCoreMLError.loadFailed(error.localizedDescription)
        }
    }

    // MARK: - Transcribe

    /// Transcribe a 16 kHz mono float32 buffer. Throws `.modelNotLoaded` if
    /// `ensureLoaded(modelId:)` hasn't run successfully yet.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let kit else { throw WhisperCoreMLError.modelNotLoaded }
        guard !samples.isEmpty else { return "" }

        do {
            let options = DecodingOptions(language: language)
            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw WhisperCoreMLError.inferenceFailed(error.localizedDescription)
        }
    }

    // MARK: - Teardown

    func unload() {
        kit = nil
        loadedVariant = nil
    }

    /// Conditional unload: drops the kit only if the currently loaded model matches
    /// the one whose files are about to disappear from disk. No-op otherwise.
    /// Used by `ASRModelDownloadManager.delete(_:)` to avoid holding a reference
    /// to deleted `.mlmodelc` files - the next `transcribe(...)` would otherwise
    /// crash deep inside WhisperKit.
    ///
    /// `loadedVariant` actually stores the **ASRModel id** (e.g. `"whisper-medium"`),
    /// not the WhisperKit folder name - see `ensureLoaded(modelId:)`. Compare to
    /// `modelId` directly; do not look up the variant string.
    func unloadIfCurrent(modelId: String) {
        if loadedVariant == modelId {
            unload()
        }
    }
}

// `WhisperKit: @unchecked @retroactive Sendable` lives in WhisperKit+Sendable.swift.
