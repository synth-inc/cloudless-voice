// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HuggingFaceModelDownloader.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-19.
//

import Defaults
import Foundation
import WhisperKit

// MARK: - Download State

/// Progress state for a model download.
enum ModelDownloadState: Equatable {
    case idle
    case fetching
    case downloading
    case completed
    case failed
}

// MARK: - Thread-safe Progress

/// Lock-free progress value readable from any thread (including .eventTracking run loop mode).
/// Written by the URLSession delegate on a background queue, read by the UI timer on the main thread.
final class AtomicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func set(_ newValue: Double) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }
}

// MARK: - HuggingFace Model Downloader

/// Downloads model files from HuggingFace repositories with real-time progress tracking.
/// Models are stored in `~/Library/Application Support/Onit/Models/` so the Python server
/// can load them directly from disk without re-downloading.
@MainActor
final class HuggingFaceModelDownloader: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = HuggingFaceModelDownloader()

    // MARK: - State (triggers menu rebuild via status notifications)

    @Published private(set) var parakeetState: ModelDownloadState = .idle
    @Published private(set) var llamaState: ModelDownloadState = .idle
    @Published private(set) var qwenState: ModelDownloadState = .idle
    @Published private(set) var ctcState: ModelDownloadState = .idle
    /// Shared state for the active MLX model download (Qwen3, Granite, …).
    @Published private(set) var mlxModelState: ModelDownloadState = .idle

    // MARK: - Progress (thread-safe, polled by UI timer)

    let parakeetProgress = AtomicProgress()
    let llamaProgress = AtomicProgress()
    let qwenProgress = AtomicProgress()
    let ctcProgress = AtomicProgress()
    let mlxModelProgress = AtomicProgress()

    // MARK: - Configuration

    private static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Onit/Models")
    }()

    static let parakeetRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let parakeetDirectory: URL = modelsDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
    static let parakeetPatterns: [String] = [
        "Preprocessor.mlmodelc/",
        "Encoder.mlmodelc/",
        "Decoder.mlmodelc/",
        "JointDecision.mlmodelc/",
        "parakeet_v3_vocab.json",
        "parakeet_vocab.json",
    ]
    private static let parakeetRequiredDirs = [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
    ]

    // Canary-1B-v2 (attention encoder-decoder), int4 CoreML bundle (~573 MB).
    // Isolated CoreML ASR path (CanaryCoreMLEngine); macOS 15+ (int4 payloads).
    static let canaryRepo = "FluidInference/canary-1b-v2-coreml"
    static let canaryDirectory: URL = modelsDirectory.appendingPathComponent("canary-1b-v2-coreml")
    static let canaryPatterns: [String] = [
        "Preprocessor.mlmodelc/",
        "EncoderInt4.mlmodelc/",
        "DecoderInt4.mlmodelc/",
        "Projection.mlmodelc/",
        "vocab.json",
    ]
    private static let canaryRequiredDirs = [
        "Preprocessor.mlmodelc", "EncoderInt4.mlmodelc", "DecoderInt4.mlmodelc", "Projection.mlmodelc",
    ]

    /// Resolved from the user's selected scoring model so a language-specialized
    /// model (e.g. RoLlama) is downloaded instead of the English default.
    static var llamaRepo: String { ScoringModel.selected.hfRepo }
    static var llamaDirectory: URL { modelsDirectory.appendingPathComponent(ScoringModel.selected.dirName) }

    static let qwenRepo = "finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit"
    static let qwenDirectory: URL = modelsDirectory.appendingPathComponent("Qwen2.5-0.5B-Instruct-4bit")
    static let qwenPatterns: [String] = [
        "Qwen2.5-0.5B-Instruct-4bit.mlmodelc/",
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "tokenizer*",
    ]

    // Parakeet CTC head - used by Custom Dictionary for keyword-spotting rescoring.
    static let ctcRepo = "FluidInference/parakeet-ctc-110m-coreml"
    static let ctcDirectory: URL = modelsDirectory.appendingPathComponent("parakeet-ctc-110m-coreml")
    static let ctcPatterns: [String] = [
        "MelSpectrogram.mlmodelc/",
        "AudioEncoder.mlmodelc/",
        "tokenizer.json",
        "vocab.json",
    ]
    private static let ctcRequiredDirs = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"]
    private static let ctcRequiredFiles = ["tokenizer.json"]


    // Silero VAD CoreML - used to suppress accidental short trigger clicks (<2s).
    static let vadRepo = "FluidInference/silero-vad-coreml"
    static let vadModelName = "silero-vad-unified-256ms-v6.0.0.mlpackage"
    static let vadDirectory: URL = modelsDirectory.appendingPathComponent("silero-vad-coreml")
    static let vadPatterns: [String] = ["\(vadModelName)/"]

    // MARK: - Active Sessions

    /// In-flight URLSessions, keyed by ObjectIdentifier so they survive the closure
    /// scope of `withCheckedThrowingContinuation`. URLSession does NOT observe Swift
    /// Concurrency cancellation, so cancelling the surrounding Task alone leaves the
    /// network operation alive and any wrapping continuation hung. The onboarding
    /// retry path tears these down explicitly via `cancelActiveDownloads()`.
    private var activeSessions: [ObjectIdentifier: URLSession] = [:]

    /// In-flight single-file downloads keyed by destination path. Two downloads of the same file
    /// would otherwise both write its shared `<destination>.partial` sidecar and corrupt each other
    /// (e.g. an automatic warmup racing a picker install, or a retry starting before the cancelled
    /// attempt has torn down). A second request for the same destination awaits the first instead.
    /// `@MainActor` isolation makes the map access race-free.
    private var inFlightFileDownloads: [String: Task<Void, Error>] = [:]

    fileprivate func register(_ session: URLSession) {
        activeSessions[ObjectIdentifier(session)] = session
    }

    fileprivate func unregister(_ session: URLSession) {
        activeSessions.removeValue(forKey: ObjectIdentifier(session))
    }

    // MARK: - Initialization

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    /// Delete the Parakeet model directory so it will be fully re-downloaded on next attempt.
    func clearParakeetModel() {
        try? FileManager.default.removeItem(at: Self.parakeetDirectory)
        parakeetState = .idle
        parakeetProgress.set(0)
    }

    /// Invalidate every in-flight URLSession and reset partial states. Called by
    /// `TranscriptionManager.restartInitialization()` so a manual retry click while
    /// the download is stalled (HF unreachable, DNS hang, etc.) actually tears down
    /// the underlying network operation - `Task.cancel()` alone would leave it alive.
    func cancelActiveDownloads() {
        let sessions = Array(activeSessions.values)
        activeSessions = [:]
        for session in sessions {
            session.invalidateAndCancel()
        }
        if parakeetState != .completed {
            parakeetState = .idle
            parakeetProgress.set(0)
        }
        if llamaState != .completed {
            llamaState = .idle
            llamaProgress.set(0)
        }
        if qwenState != .completed {
            qwenState = .idle
            qwenProgress.set(0)
        }
        if ctcState != .completed {
            ctcState = .idle
            ctcProgress.set(0)
        }
        if mlxModelState != .completed {
            mlxModelState = .idle
            mlxModelProgress.set(0)
        }
    }

    /// Update parakeet download state (used by FluidAudioWarmupProvider to bridge download progress into UI).
    func updateParakeetState(_ state: ModelDownloadState) {
        parakeetState = state
    }

    /// Download Parakeet CoreML models if not already cached.
    /// Uses per-file size checking to resume partial downloads - does not short-circuit
    /// on directory existence, since directories may be created mid-download.
    func downloadParakeetIfNeeded() async throws {
        // Offline-first: if the models are already fully on disk, don't touch the
        // network. `downloadRepo` always does a `listFiles` HuggingFace API call to
        // resolve the file set - which fails "The Internet connection appears to be
        // offline" even when a complete model is present. This is the real no-wifi
        // warmup bug: the sibling downloadLlamaIfNeeded / downloadVADIfNeeded guard
        // on their is*Downloaded() check, but this method never did. Gated by the
        // debug toggle for A/B confirmation.
        let onDisk = isParakeetDownloaded()
        let offlineFixOn = Defaults[.parakeetOfflineWarmupEnabled]
        if offlineFixOn && onDisk {
            log.info("HuggingFaceModelDownloader: [parakeet-offline-fix ON, onDisk=true] Parakeet already downloaded - skipping network")
            parakeetProgress.set(1.0)   // model is fully present - reflect 100% (download path does this via downloadRepo)
            parakeetState = .completed
            return
        }
        log.info("HuggingFaceModelDownloader: [parakeet-offline-fix \(offlineFixOn ? "ON" : "OFF"), onDisk=\(onDisk)] proceeding to downloadRepo (network round-trip)")

        parakeetState = .fetching
        parakeetProgress.set(0)

        do {
            try await downloadRepo(
                repo: Self.parakeetRepo,
                patterns: Self.parakeetPatterns,
                destination: Self.parakeetDirectory,
                atomicProgress: parakeetProgress,
                onDownloadStart: { [weak self] in self?.parakeetState = .downloading }
            )
            parakeetState = .completed
            log.info("HuggingFaceModelDownloader: Parakeet models downloaded successfully")
        } catch {
            // A cancel arrives as `CancellationError` (file transfer) or
            // `URLError.cancelled` (the `listFiles` phase). Treat both as a return
            // to idle so a cancelled download never flashes a failure state.
            parakeetState = (Task.isCancelled || error is CancellationError) ? .idle : .failed
            throw error
        }
    }

    /// Download the Canary-1B-v2 int4 CoreML bundle if not already on disk.
    /// Offline-first, same as `downloadParakeetIfNeeded`: skip the network when the
    /// full model is present. Reuses the shared `parakeetOfflineWarmupEnabled`
    /// debug toggle since both are on-disk CoreML ASR bundles.
    func downloadCanaryIfNeeded(progress: AtomicProgress) async throws {
        let onDisk = isCanaryDownloaded()
        if Defaults[.parakeetOfflineWarmupEnabled] && onDisk {
            log.info("HuggingFaceModelDownloader: Canary already downloaded - skipping network")
            progress.set(1.0)
            return
        }
        progress.set(0)
        try await downloadRepo(
            repo: Self.canaryRepo,
            patterns: Self.canaryPatterns,
            destination: Self.canaryDirectory,
            atomicProgress: progress,
            onDownloadStart: {}
        )
        log.info("HuggingFaceModelDownloader: Canary models downloaded successfully")
    }

    /// Whether the Canary CoreML bundle is fully present (all 4 `.mlmodelc` dirs
    /// + vocab.json), distinguishing a complete install from an interrupted one.
    func isCanaryDownloaded() -> Bool {
        let fm = FileManager.default
        for dir in Self.canaryRequiredDirs {
            let path = Self.canaryDirectory.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: path.path, isDirectory: &isDir) || !isDir.boolValue { return false }
        }
        return fm.fileExists(atPath: Self.canaryDirectory.appendingPathComponent(CanaryConfig.vocabFile).path)
    }

    /// Download Silero VAD CoreML model if not already cached.
    func downloadVADIfNeeded() async throws {
        if isVADDownloaded() { return }
        try await downloadRepo(
            repo: Self.vadRepo,
            patterns: Self.vadPatterns,
            destination: Self.vadDirectory,
            atomicProgress: AtomicProgress(),
            onDownloadStart: {}
        )
        log.info("HuggingFaceModelDownloader: Silero VAD model downloaded successfully")
    }

    /// Check if VAD model is already downloaded (Manifest.json present in the .mlpackage).
    func isVADDownloaded() -> Bool {
        let manifestPath = Self.vadDirectory.appendingPathComponent(Self.vadModelName).appendingPathComponent("Manifest.json")
        return FileManager.default.fileExists(atPath: manifestPath.path)
    }

    /// Download Llama model for Smart Cleanup if not already cached.
    func downloadLlamaIfNeeded() async throws {
        if isLlamaDownloaded() {
            llamaState = .completed
            return
        }

        llamaState = .fetching
        llamaProgress.set(0)

        do {
            try await downloadRepo(
                repo: Self.llamaRepo,
                patterns: nil,
                destination: Self.llamaDirectory,
                atomicProgress: llamaProgress,
                onDownloadStart: { [weak self] in self?.llamaState = .downloading }
            )
            llamaState = .completed
            log.info("HuggingFaceModelDownloader: Llama model downloaded successfully")
        } catch {
            // A cancel arrives as `CancellationError` (file transfer) or
            // `URLError.cancelled` (the `listFiles` phase). Treat both as a return
            // to idle so a cancelled download never flashes a failure state.
            llamaState = (Task.isCancelled || error is CancellationError) ? .idle : .failed
            throw error
        }
    }

    /// Check if Parakeet models are already downloaded locally.
    func isParakeetDownloaded() -> Bool {
        let fm = FileManager.default
        for dir in Self.parakeetRequiredDirs {
            let path = Self.parakeetDirectory.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: path.path, isDirectory: &isDir) || !isDir.boolValue {
                return false
            }
        }
        // The engine also requires a vocab file at load time (parakeet_v3_vocab.json
        // preferred, else parakeet_vocab.json - see ParakeetCoreMLEngine.ensureLoaded).
        // Require it here too: otherwise a model with the .mlmodelc dirs but no vocab
        // would look "complete", skip the (online, self-repairing) download, and then
        // fail at load. Missing it → report not-downloaded so the normal path repairs.
        let hasVocab = ["parakeet_v3_vocab.json", "parakeet_vocab.json"].contains {
            fm.fileExists(atPath: Self.parakeetDirectory.appendingPathComponent($0).path)
        }
        return hasVocab
    }

    /// Check if the Llama model is already downloaded locally.
    func isLlamaDownloaded() -> Bool {
        let fm = FileManager.default
        let dir = Self.llamaDirectory.path
        guard fm.fileExists(atPath: dir) else { return false }

        let configPath = Self.llamaDirectory.appendingPathComponent("config.json").path
        guard fm.fileExists(atPath: configPath) else { return false }

        let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Download Qwen2.5-0.5B CoreML model for Smart Cleanup if not already cached.
    func downloadQwenIfNeeded() async throws {
        if isQwenDownloaded() {
            qwenState = .completed
            return
        }

        qwenState = .fetching
        qwenProgress.set(0)

        do {
            try await downloadRepo(
                repo: Self.qwenRepo,
                patterns: Self.qwenPatterns,
                destination: Self.qwenDirectory,
                atomicProgress: qwenProgress,
                onDownloadStart: { [weak self] in self?.qwenState = .downloading }
            )
            qwenState = .completed
            log.info("HuggingFaceModelDownloader: Qwen2.5-0.5B model downloaded successfully")
        } catch {
            // A cancel arrives as `CancellationError` (file transfer) or
            // `URLError.cancelled` (the `listFiles` phase). Treat both as a return
            // to idle so a cancelled download never flashes a failure state.
            qwenState = (Task.isCancelled || error is CancellationError) ? .idle : .failed
            throw error
        }
    }

    /// Check if the Qwen2.5-0.5B model is already downloaded locally.
    /// Requires at least one .mlmodelc directory and a tokenizer config file.
    func isQwenDownloaded() -> Bool {
        let fm = FileManager.default
        let dir = Self.qwenDirectory.path
        guard fm.fileExists(atPath: dir) else { return false }

        let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []

        // Must have at least one .mlmodelc directory
        let hasModel = contents.contains { $0.hasSuffix(".mlmodelc") }

        // Must have a tokenizer config
        let hasTokenizer = contents.contains { $0 == "tokenizer.json" || $0 == "tokenizer_config.json" }

        return hasModel && hasTokenizer
    }

    /// Download parakeet-ctc-110m CoreML models if not already cached.
    func downloadCtcIfNeeded() async throws {
        if isCtcDownloaded() {
            ctcState = .completed
            return
        }

        ctcState = .fetching
        ctcProgress.set(0)

        do {
            try await downloadRepo(
                repo: Self.ctcRepo,
                patterns: Self.ctcPatterns,
                destination: Self.ctcDirectory,
                atomicProgress: ctcProgress,
                onDownloadStart: { [weak self] in self?.ctcState = .downloading }
            )
            ctcState = .completed
            log.info("HuggingFaceModelDownloader: CTC models downloaded successfully")
        } catch {
            // A cancel arrives as `CancellationError` (file transfer) or
            // `URLError.cancelled` (the `listFiles` phase). Treat both as a return
            // to idle so a cancelled download never flashes a failure state.
            ctcState = (Task.isCancelled || error is CancellationError) ? .idle : .failed
            throw error
        }
    }

    /// Check if the CTC models are already downloaded locally.
    /// Validates both the `.mlmodelc` directories and `tokenizer.json` so that
    /// a partially-interrupted download (weights present, tokenizer missing) is
    /// not mistakenly treated as complete - which would cause `BpeTokenizer.load()`
    /// to throw and silently disable the feature on the next launch.
    func isCtcDownloaded() -> Bool {
        let fm = FileManager.default
        for dir in Self.ctcRequiredDirs {
            let path = Self.ctcDirectory.appendingPathComponent(dir)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: path.path, isDirectory: &isDir) || !isDir.boolValue {
                return false
            }
        }
        for file in Self.ctcRequiredFiles {
            let path = Self.ctcDirectory.appendingPathComponent(file)
            if !fm.fileExists(atPath: path.path) {
                return false
            }
        }
        return true
    }

    /// Download a Whisper model bundle via WhisperKit (which handles the
    /// `argmaxinc/whisperkit-coreml` HF repo + per-file caching internally).
    /// Idempotent: returns immediately when the bundle is already complete on disk
    /// (checked here, NOT delegated to `WhisperKit.download`). The optional
    /// `externalProgress` is teed from WhisperKit's `Progress` callback so the
    /// picker UI can show the same bar the manual "Download" button uses.
    func downloadWhisperIfNeeded(modelId: String, externalProgress: AtomicProgress? = nil) async throws {
        guard let variant = WhisperCoreMLEngine.whisperKitVariant(for: modelId) else {
            throw DownloadError.noFiles("Unknown Whisper model id: \(modelId)")
        }

        // Short-circuit when the bundle is already complete on disk. `WhisperKit
        // .download(variant:)` re-runs a live HubApi round-trip on EVERY call
        // (`getFilenames` + per-file `.metadata` re-validation) even when nothing
        // is left to fetch, which buys two failure modes and no benefit: a
        // `.metadata` sidecar HubApi can neither parse nor unlink wedges warmup
        // for good ("Invalid metadata: Could not remove corrupted metadata file
        // ... you don't have permission", reported on Whisper Medium), and the
        // network call makes an already-installed model unusable offline.
        // `ensureLoaded` already gates on this same `isModelComplete` to load
        // straight from `modelFolder`, so the downloader now simply agrees with
        // the load path.
        if WhisperCoreMLEngine.isModelComplete(forModelId: modelId) {
            externalProgress?.set(1.0)
            return
        }

        // Incomplete, so WhisperKit is about to download. Drop HubApi's download
        // sidecars for this variant first. `ASRModelDownloadManager.delete` and
        // the cancel cleanup only remove the model directory, so a reinstall
        // re-validates metadata describing files that are no longer there - and a
        // sidecar HubApi can neither parse nor unlink aborts the whole download
        // with the error above, which makes Delete + Download, the one recovery
        // the picker offers, land straight back on the reported failure.
        //
        // They live at the repo root, not under the variant directory: see
        // `repoMetadataDestination` in `HubApi.snapshot`. Scoped to this variant
        // so the other Whisper bundles keep their etag bookkeeping. Best-effort -
        // the cache is pure bookkeeping and a clean download rebuilds it.
        if let repoRoot = WhisperCoreMLEngine.expectedModelDirectory(forModelId: modelId)?
            .deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: repoRoot
                .appendingPathComponent(".cache/huggingface/download")
                .appendingPathComponent(variant))
        }

        // `downloadBase` keeps the bundle in Application Support instead of
        // HubApi's default `~/Documents/huggingface` - see
        // `WhisperCoreMLEngine.downloadBase`.
        _ = try await WhisperKit.download(
            variant: variant, downloadBase: WhisperCoreMLEngine.downloadBase
        ) { @Sendable progress in
            externalProgress?.set(progress.fractionCompleted)
        }
        externalProgress?.set(1.0)
    }

    // MARK: - MLX models (generic)

    /// Download the MLX bundle for `modelId` (Qwen3, Granite, …) if not already
    /// on disk. Repo, download patterns and the install-complete file list are
    /// resolved from `MLXModelRegistry`, so adding a model needs no downloader
    /// change. State/progress are shared because the catalog allows only one
    /// MLX model to warm/download at a time.
    func downloadMLXModelIfNeeded(modelId: String, externalProgress: AtomicProgress? = nil) async throws {
        guard let kind = MLXModelRegistry.kind(for: modelId),
              let repo = kind.hubRepo(modelId),
              let destination = MLXModelRegistry.expectedDirectory(for: modelId) else {
            throw MLXASRError.unsupportedModel(id: modelId)
        }
        if isMLXModelDownloaded(modelId: modelId) {
            mlxModelState = .completed
            mlxModelProgress.set(1.0)
            externalProgress?.set(1.0)
            return
        }

        mlxModelState = .fetching
        mlxModelProgress.set(0)
        externalProgress?.set(0)

        // Tee into both the central progress and the per-model AtomicProgress
        // the picker UI reads.
        let tee = AtomicProgress()
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let v = tee.value
                self?.mlxModelProgress.set(v)
                externalProgress?.set(v)
                if v >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            }
        }
        defer { progressTask.cancel() }

        do {
            try await downloadRepo(
                repo: repo,
                patterns: kind.downloadPatterns,
                destination: destination,
                atomicProgress: tee,
                onDownloadStart: { [weak self] in self?.mlxModelState = .downloading }
            )
            mlxModelProgress.set(1.0)
            externalProgress?.set(1.0)
            mlxModelState = .completed
            log.info("HuggingFaceModelDownloader: \(repo) downloaded successfully")
        } catch {
            // A cancel arrives as `CancellationError` (file transfer) or
            // `URLError.cancelled` (the `listFiles` phase). Treat both as a return
            // to idle so a cancelled download never flashes a failure state.
            mlxModelState = (Task.isCancelled || error is CancellationError) ? .idle : .failed
            throw error
        }
    }

    /// Whether the MLX bundle for `modelId` is fully present on disk (every
    /// required file), so a partially-interrupted download isn't mistaken for
    /// a complete install.
    func isMLXModelDownloaded(modelId: String) -> Bool {
        guard let kind = MLXModelRegistry.kind(for: modelId),
              let dir = MLXModelRegistry.expectedDirectory(for: modelId) else {
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        for file in kind.requiredFiles {
            if !fm.fileExists(atPath: dir.appendingPathComponent(file).path) { return false }
        }
        return true
    }

    // MARK: - Moonshine (.ort)

    /// Download the Moonshine `.ort` bundle for the given model id if not
    /// already cached. Files live on the Moonshine-hosted CDN (the upstream
    /// HuggingFace mirror only ships `safetensors`, which the C++ runtime
    /// can't load), so we bypass `downloadRepo` entirely and fetch each file
    /// directly with `downloadSingleFile`.
    ///
    /// URL layout: `https://download.moonshine.ai/model/<variant>/quantized/<variant>/<file>` -
    /// matches the upstream Python downloader (`moonshine/python/src/moonshine_voice/download.py`).
    func downloadMoonshineIfNeeded(modelId: String, externalProgress: AtomicProgress? = nil) async throws {
        if isMoonshineDownloaded(modelId: modelId) {
            externalProgress?.set(1.0)
            return
        }

        guard let urlBase = MoonshineEngine.downloadURLBase(for: modelId),
              let destination = MoonshineEngine.expectedModelDirectory(forModelId: modelId)
        else {
            throw DownloadError.noFiles("Unknown Moonshine model id: \(modelId)")
        }

        let files = MoonshineEngine.requiredFiles(for: modelId)
        guard !files.isEmpty else {
            throw DownloadError.noFiles("No Moonshine files configured for model id: \(modelId)")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // HEAD each pending file once up-front so we have a total-byte
        // denominator for the progress bar. Without it we'd only know per-file
        // fractions and the bar would jump in big steps as each file finishes.
        struct PendingFile {
            let name: String
            let url: URL
            let dest: URL
            let size: Int64
        }
        var pending: [PendingFile] = []
        var alreadyDownloadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        for file in files {
            let fileURL = urlBase.appendingPathComponent(file)
            let fileDest = destination.appendingPathComponent(file)
            let remoteSize = try await contentLength(of: fileURL)
            totalBytes += remoteSize

            if fm.fileExists(atPath: fileDest.path),
               let attrs = try? fm.attributesOfItem(atPath: fileDest.path),
               let local = attrs[.size] as? Int64,
               local == remoteSize
            {
                alreadyDownloadedBytes += remoteSize
                continue
            }
            pending.append(PendingFile(name: file, url: fileURL, dest: fileDest, size: remoteSize))
        }

        log.info("HuggingFaceModelDownloader: Moonshine \(modelId) - \(pending.count)/\(files.count) files to download (\(totalBytes / 1_048_576)MB total, \(alreadyDownloadedBytes / 1_048_576)MB cached)")

        if pending.isEmpty {
            externalProgress?.set(1.0)
            return
        }

        var completedBytes = alreadyDownloadedBytes
        for file in pending {
            let fileStartBytes = completedBytes
            try await downloadSingleFile(
                from: file.url,
                to: file.dest,
                expectedSize: file.size,
                onProgress: { fileProgress in
                    let current = fileStartBytes + Int64(Double(file.size) * fileProgress)
                    let overall = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                    externalProgress?.set(min(overall, 1.0))
                }
            )
            completedBytes += file.size
            if totalBytes > 0 {
                externalProgress?.set(Double(completedBytes) / Double(totalBytes))
            }
        }
        externalProgress?.set(1.0)
        log.info("HuggingFaceModelDownloader: Moonshine \(modelId) downloaded successfully")
    }

    /// Per-file presence check for the Moonshine bundle. Validates every
    /// `.ort` + tokenizer file rather than the directory alone - a partially-
    /// interrupted download would otherwise be mistaken for a complete one
    /// and the engine load path would throw deep inside the C runtime with a
    /// less-clear error.
    func isMoonshineDownloaded(modelId: String) -> Bool {
        guard let dir = MoonshineEngine.expectedModelDirectory(forModelId: modelId) else {
            return false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }

        for file in MoonshineEngine.requiredFiles(for: modelId) {
            let path = dir.appendingPathComponent(file).path
            if !fm.fileExists(atPath: path) { return false }
        }
        return true
    }

    /// HEAD request to fetch a file's `Content-Length` without downloading the
    /// body. Used to build the progress denominator before kicking off the
    /// per-file `downloadSingleFile` calls.
    private func contentLength(of url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        register(session)
        defer {
            unregister(session)
            session.finishTasksAndInvalidate()
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DownloadError.apiError("HEAD \(url.lastPathComponent) returned HTTP \(code)")
        }
        let length = http.value(forHTTPHeaderField: "Content-Length")
            .flatMap { Int64($0) } ?? 0
        return length
    }

    // MARK: - Private: Repository Download

    private func downloadRepo(
        repo: String,
        patterns: [String]?,
        destination: URL,
        atomicProgress: AtomicProgress,
        onDownloadStart: @escaping () -> Void
    ) async throws {
        // 1. List files from HuggingFace API (state is .fetching during this phase)
        let allFiles = try await listFiles(repo: repo)
        let filesToDownload = filterFiles(allFiles, patterns: patterns)

        for file in filesToDownload where !Self.isSafeRepoPath(file.path, within: destination) {
            throw DownloadError.apiError("File path escapes the model folder in \(repo): \(file.path)")
        }

        guard !filesToDownload.isEmpty else {
            throw DownloadError.noFiles("No matching files found in \(repo)")
        }

        // 2. Compute total size, skipping already-downloaded files
        let fm = FileManager.default
        var totalBytes: Int64 = 0
        var alreadyDownloadedBytes: Int64 = 0

        for file in filesToDownload {
            totalBytes += file.size
            let filePath = destination.appendingPathComponent(file.path)
            if fm.fileExists(atPath: filePath.path),
               let attrs = try? fm.attributesOfItem(atPath: filePath.path),
               let fileSize = attrs[.size] as? Int64,
               fileSize == file.size
            {
                alreadyDownloadedBytes += file.size
            }
        }

        let pendingFiles = filesToDownload.filter { file in
            let filePath = destination.appendingPathComponent(file.path)
            guard let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                  let fileSize = attrs[.size] as? Int64 else { return true }
            return fileSize != file.size
        }

        log.info("HuggingFaceModelDownloader: \(repo) - \(pendingFiles.count)/\(filesToDownload.count) files to download (\(totalBytes / 1_048_576)MB total, \(alreadyDownloadedBytes / 1_048_576)MB cached)")

        if pendingFiles.isEmpty {
            atomicProgress.set(1.0)
            return
        }

        guard totalBytes > 0 else {
            log.warning("HuggingFaceModelDownloader: totalBytes is 0, skipping download for \(repo)")
            return
        }

        // 3. Create destination directory
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Transition from .fetching → .downloading
        onDownloadStart()

        // 4. Download pending files
        var completedBytes = alreadyDownloadedBytes

        for file in pendingFiles {
            let fileDestination = destination.appendingPathComponent(file.path)

            // Create parent directories
            try fm.createDirectory(
                at: fileDestination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let fileStartBytes = completedBytes
            try await downloadSingleFile(
                from: file.downloadURL,
                to: fileDestination,
                expectedSize: file.size,
                onProgress: { fileProgress in
                    // Called from background thread - writes directly to atomic progress
                    let currentBytes = fileStartBytes + Int64(Double(file.size) * fileProgress)
                    let overallProgress = Double(currentBytes) / Double(totalBytes)
                    atomicProgress.set(min(overallProgress, 1.0))
                }
            )

            completedBytes += file.size
            atomicProgress.set(Double(completedBytes) / Double(totalBytes))
        }
    }

    // MARK: - Private: HuggingFace API

    /// Whether a repo-relative file path is safe to join onto a local folder: not empty, not
    /// absolute, no `..` component, no backslash or NUL, and (when `destination` is given) still
    /// inside it once resolved lexically.
    nonisolated static func isSafeRepoPath(_ path: String, within destination: URL? = nil) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return false }
        guard let destination else { return true }
        let root = destination.standardizedFileURL.path
        let resolved = destination.appendingPathComponent(path).standardizedFileURL.path
        return resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Represents a file in a HuggingFace repository.
    private struct HFFile {
        let path: String
        let size: Int64
        let downloadURL: URL
    }

    /// Result of inspecting a HF repo for MLX-loadability (PRO custom models).
    enum MLXRepoCheck: Equatable {
        case ok(sizeMB: Int)
        case notFound
        case gguf
        case adapterOnly
        case noConfig
        case noSafetensors
        case failed(String)

        /// User-facing error message (nil when ok).
        var errorMessage: String? {
            switch self {
            case .ok: return nil
            case .notFound: return "Repository not found on HuggingFace. Check the id (e.g. mlx-community/Llama-3.2-1B-Instruct-8bit)."
            case .gguf: return "This model is in GGUF format, which isn't MLX-compatible. Use an MLX (safetensors) build - look for one under mlx-community."
            case .adapterOnly: return "This is a LoRA adapter, not a full model. It must be merged into its base and converted to MLX first."
            case .noConfig: return "No config.json found - this doesn't look like a loadable model."
            case .noSafetensors: return "No .safetensors weights found. MLX needs safetensors; this repo isn't MLX-compatible."
            case .failed(let m): return "Couldn't check this model: \(m)"
            }
        }
    }

    /// Inspect a HF repo to decide whether it's an MLX-loadable model WITHOUT
    /// downloading the weights (file-list API only, fast). Used by the PRO
    /// custom-scoring-model add flow to reject GGUF / adapter / non-MLX repos up
    /// front. A supported architecture is still confirmed at actual load time.
    func inspectMLXModelRepo(_ repo: String) async -> MLXRepoCheck {
        let files: [HFFile]
        do {
            files = try await listFiles(repo: repo)
        } catch {
            let msg = "\(error)"
            if msg.contains("404") || msg.contains("401") { return .notFound }
            return .failed(msg)
        }
        return Self.classifyMLXRepo(files.map { (path: $0.path, size: $0.size) })
    }

    /// Pure classification of a repo's file list - MLX-loadable or why not.
    /// Extracted so the heuristic is unit-testable without the network.
    nonisolated static func classifyMLXRepo(_ files: [(path: String, size: Int64)]) -> MLXRepoCheck {
        let paths = files.map { $0.path.lowercased() }
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let hasGGUF = paths.contains { $0.hasSuffix(".gguf") }
        let hasAdapterConfig = names.contains("adapter_config.json")
        let hasConfig = names.contains("config.json")
        // A "model" safetensors is a safetensors that isn't the adapter file.
        let hasModelSafetensors = paths.contains { $0.hasSuffix(".safetensors") && !$0.contains("adapter") }

        if hasGGUF && !hasModelSafetensors { return .gguf }
        if hasAdapterConfig && !hasModelSafetensors { return .adapterOnly }
        if !hasConfig { return .noConfig }
        if !hasModelSafetensors { return .noSafetensors }

        let bytes = files
            .filter { $0.path.lowercased().hasSuffix(".safetensors") }
            .reduce(Int64(0)) { $0 + $1.size }
        return .ok(sizeMB: max(1, Int(bytes / 1_000_000)))
    }

    /// List all files in a HuggingFace repository.
    private func listFiles(repo: String) async throws -> [HFFile] {
        guard let apiURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            throw DownloadError.apiError("Invalid API URL for \(repo)")
        }

        // Custom session - URLSession.shared keeps its 60s default and ignores a
        // smaller per-request timeout in practice, which leaves the warmup state
        // at .fetching long enough to render as a silent spinner in the onboarding UI.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        register(session)
        defer {
            unregister(session)
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(from: apiURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DownloadError.apiError("HuggingFace API returned HTTP \(statusCode) for \(repo)")
        }

        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.apiError("Invalid JSON response from HuggingFace API")
        }

        // A repo (custom MLX repos are user supplied) controls every `path`; refuse the
        // whole listing rather than download part of a repo that tries to escape.
        for item in jsonArray {
            if let path = item["path"] as? String, !Self.isSafeRepoPath(path) {
                throw DownloadError.apiError("Unsafe file path in \(repo): \(path)")
            }
        }

        return jsonArray.compactMap { item -> HFFile? in
            guard let type = item["type"] as? String, type == "file",
                  let path = item["path"] as? String
            else { return nil }

            // JSONSerialization stores numbers as NSNumber.
            // Cast via NSNumber.int64Value since `as? Int64` fails for JSON integers.
            let size: Int64
            if let lfs = item["lfs"] as? [String: Any],
               let lfsSize = (lfs["size"] as? NSNumber)?.int64Value, lfsSize > 0 {
                size = lfsSize
            } else if let fileSize = (item["size"] as? NSNumber)?.int64Value, fileSize > 0 {
                size = fileSize
            } else {
                return nil
            }

            guard let downloadURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)") else {
                return nil
            }

            return HFFile(path: path, size: size, downloadURL: downloadURL)
        }
    }

    /// Filter files by prefix patterns.
    private func filterFiles(_ files: [HFFile], patterns: [String]?) -> [HFFile] {
        guard let patterns = patterns else { return files }

        return files.filter { file in
            patterns.contains { pattern in
                if pattern.hasSuffix("/") {
                    // Directory pattern - match files inside
                    return file.path.hasPrefix(pattern)
                }
                // Exact file match
                return file.path == pattern
            }
        }
    }

    // MARK: - Private: Single File Download

    /// Single-flight wrapper over `performSingleFileDownload`: coalesces concurrent requests for the
    /// same destination so they can't both write the shared `.partial` sidecar. The first caller
    /// owns the transfer (and drives its cancellation); any caller arriving while it runs awaits the
    /// same result instead of starting a competing download.
    private func downloadSingleFile(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let key = destination.path

        if let existing = inFlightFileDownloads[key] {
            // Someone is already downloading this exact file - wait for their result.
            try await existing.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performSingleFileDownload(
                from: url, to: destination, expectedSize: expectedSize, onProgress: onProgress)
        }
        inFlightFileDownloads[key] = task
        defer { inFlightFileDownloads[key] = nil }

        // Owner path: propagate this caller's cancellation into the owned task, whose
        // `performSingleFileDownload` tears the URLSession down through its own handler.
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Download a single file with **resume support**. Bytes already fetched into a
    /// `<destination>.partial` sidecar are kept, and each attempt issues an HTTP
    /// `Range: bytes=<offset>-` request that appends from where the last one stopped.
    /// This is what lets a multi-GB model survive the 30s no-data stall + retry loop
    /// instead of restarting from zero every time - HF now serves large files via the
    /// Xet CDN behind a 302 redirect, which is exactly where the stalls happen. The
    /// file is committed to `destination` only after its size matches `expectedSize`,
    /// so a truncated transfer can never masquerade as a complete download.
    ///
    /// Callers go through `downloadSingleFile`, which guarantees only one of these runs per
    /// destination at a time (the `.partial` sidecar is not safe for concurrent writers).
    private func performSingleFileDownload(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        try Task.checkCancellation()

        let fm = FileManager.default
        let partial = destination.appendingPathExtension("partial")

        // Resume offset = bytes already on disk from a prior interrupted attempt. A
        // `.partial` at/over the expected size is stale/corrupt - start clean.
        var startOffset: Int64 = 0
        if let size = (try? fm.attributesOfItem(atPath: partial.path))?[.size] as? Int64 {
            switch Self.resumePlan(partialSize: size, expectedSize: expectedSize) {
            case .fresh:
                try? fm.removeItem(at: partial)
            case .resume(let offset):
                startOffset = offset
            }
        }

        if startOffset > 0 {
            let pct = expectedSize > 0 ? Int((Double(startOffset) / Double(expectedSize)) * 100) : 0
            log.info("[range-resume] \(destination.lastPathComponent): RESUMING from \(startOffset)/\(expectedSize) bytes (\(pct)%) - sending Range header")
        } else {
            log.info("[range-resume] \(destination.lastPathComponent): fresh download (\(expectedSize) bytes)")
        }

        // `URLSession` ignores Swift-concurrency cancellation, so wrap the
        // continuation in `withTaskCancellationHandler`: when the surrounding
        // download Task is cancelled, `onCancel` invalidates the session through
        // the box, which fires `didCompleteWithError` and resumes the continuation
        // instead of leaving it (and the network transfer) hung.
        let sessionBox = CancellableSessionBox()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let delegate = ResumableFileDownloadDelegate(
                        destination: destination,
                        partial: partial,
                        startOffset: startOffset,
                        expectedSize: expectedSize,
                        onProgress: onProgress,
                        continuation: continuation
                    )

                    // 30s per-request timeout still detects a genuine stall (no bytes for
                    // 30s); the difference now is that the stall resumes from the partial
                    // instead of throwing away progress. Resource cap stays generous.
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 7200

                    // Session lifetime is owned by the delegate, which calls
                    // session.invalidateAndCancel() in didCompleteWithError on every path.
                    let session = URLSession(
                        configuration: config,
                        delegate: delegate,
                        delegateQueue: nil
                    )
                    // Register so a manual retry from the onboarding UI can invalidate the
                    // session externally - Task cancellation does not reach URLSession.
                    delegate.downloader = self
                    self.register(session)

                    var request = URLRequest(url: url)
                    if startOffset > 0 {
                        request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
                    }

                    // Create and start the task atomically with the cancellation check
                    // (under the box's lock) so a concurrent `onCancel` cannot invalidate
                    // the session in the window before its task exists.
                    let started = sessionBox.startTask(session) { $0.dataTask(with: request) }
                    if !started {
                        self.unregister(session)
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                sessionBox.cancel()
            }
        } catch {
            // An invalidated session surfaces as `URLError.cancelled`, not
            // `CancellationError`. Normalise it so callers up the chain (and the
            // download manager's state machine + analytics) can treat a user cancel
            // uniformly rather than booking it as a network failure.
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    // MARK: - Resume / Commit Decisions (pure, unit-tested)

    /// How a fresh attempt should treat a `<destination>.partial` already on disk.
    enum ResumePlan: Equatable {
        /// No usable partial - request the whole file and write from byte 0.
        case fresh
        /// Append to the partial, requesting `Range: bytes=<offset>-`.
        case resume(offset: Int64)
    }

    /// Decide whether a leftover partial can be resumed. A partial at/over the expected size is
    /// stale or complete-but-uncommitted - safer to re-fetch than to trust - so it restarts clean.
    nonisolated static func resumePlan(partialSize: Int64, expectedSize: Int64) -> ResumePlan {
        guard partialSize > 0 else { return .fresh }
        if expectedSize > 0, partialSize >= expectedSize { return .fresh }
        return .resume(offset: partialSize)
    }

    /// What to do with a `.partial` once the transfer completes without a transport error.
    enum CommitDecision: Equatable {
        /// Size matches (or is unknown) - rename the partial onto the destination.
        case commit
        /// Larger than expected → corrupt. Delete the partial and fail so the retry starts clean.
        case discardAndFail
        /// Smaller than expected → a valid prefix the server closed early. Keep it and fail so the
        /// next attempt resumes from here.
        case keepAndFail
    }

    nonisolated static func commitDecision(downloadedSize: Int64, expectedSize: Int64) -> CommitDecision {
        if expectedSize <= 0 || downloadedSize == expectedSize { return .commit }
        return downloadedSize > expectedSize ? .discardAndFail : .keepAndFail
    }

    /// Start byte of an HTTP `Content-Range: bytes <start>-<end>/<total>` header, or `nil` if the
    /// header is absent/unparseable (e.g. `bytes */1234`). Used to confirm a 206 resumes at the
    /// exact offset we requested before appending its body.
    nonisolated static func contentRangeStart(_ header: String?) -> Int64? {
        guard let spec = header?.split(separator: " ").last,
              let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[spec.startIndex..<dash])
    }

    // MARK: - Errors

    enum DownloadError: LocalizedError {
        case apiError(String)
        case noFiles(String)

        var errorDescription: String? {
            switch self {
            case .apiError(let msg), .noFiles(let msg):
                return msg
            }
        }
    }
}

// MARK: - Cancellable Session Box

/// Thread-safe holder that lets a `withTaskCancellationHandler`'s `onCancel`
/// tear down the in-flight `URLSession` even when cancellation fires before the
/// session is constructed. `URLSession` ignores Swift-concurrency cancellation,
/// so `invalidateAndCancel()` through this box is the only thing that actually
/// stops the bytes when a download Task is cancelled.
private final class CancellableSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var isCancelled = false

    /// Store the session and start its task atomically under the lock, so a
    /// concurrent `cancel()` can never invalidate the session in the window before
    /// its task exists - invalidating a task-less `URLSession` never fires
    /// `didCompleteWithError`, which would hang the wrapping continuation. Returns
    /// `false` if cancellation already landed (the session is invalidated and no
    /// task is started); the caller must then resume the continuation itself.
    func startTask(
        _ newSession: URLSession,
        makeTask: (URLSession) -> URLSessionTask
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            newSession.invalidateAndCancel()
            return false
        }
        session = newSession
        makeTask(newSession).resume()
        return true
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        session?.invalidateAndCancel()
        session = nil
    }
}

// MARK: - Resumable File Download Delegate

/// URLSession data-task delegate that streams a single file into a `<destination>.partial`
/// sidecar so an interrupted download resumes via HTTP `Range` instead of restarting.
/// Commits to `destination` only once the on-disk size matches `expectedSize`.
private final class ResumableFileDownloadDelegate: NSObject, URLSessionDataDelegate {

    private let destination: URL
    private let partial: URL
    private let startOffset: Int64
    private let expectedSize: Int64
    private let onProgress: (Double) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private let lock = NSLock()
    private var hasResumed = false
    /// Open handle on the `.partial` for the life of the transfer. Touched only on the
    /// (serial) delegate queue, so no extra locking is needed around it.
    private var handle: FileHandle?
    private var bytesOnDisk: Int64
    /// Set right after the owning `URLSession` is constructed so we can unregister it
    /// from the active-sessions registry once the download completes. Weak to avoid a
    /// retain cycle through `HuggingFaceModelDownloader.activeSessions → session → delegate`.
    weak var downloader: HuggingFaceModelDownloader?

    init(
        destination: URL,
        partial: URL,
        startOffset: Int64,
        expectedSize: Int64,
        onProgress: @escaping (Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.partial = partial
        self.startOffset = startOffset
        self.expectedSize = expectedSize
        self.onProgress = onProgress
        self.continuation = continuation
        self.bytesOnDisk = startOffset
    }

    /// HF's `/resolve/` URL 302-redirects to the Xet CDN; re-apply the `Range` header to
    /// the redirected request so the resume offset survives the hop (URLSession does not
    /// always carry non-standard headers across a cross-host redirect).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard startOffset > 0 else {
            completionHandler(request)
            return
        }
        var redirected = request
        redirected.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
        completionHandler(redirected)
    }

    /// Decide how to write based on the server's answer: `206 Partial Content` honored our
    /// Range → append to the partial; a `200` full body means the server ignored the Range,
    /// so rewrite the partial from scratch; any other status is a hard failure.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let fm = FileManager.default
        do {
            if status == 206 {
                // A 206 must resume exactly where we asked. Validate `Content-Range` before trusting
                // the body's position: a proxy/CDN answering with a different (or full) range would
                // otherwise be appended at the wrong offset and could still reach expectedSize and
                // commit a corrupt file (size is the only other integrity check). Require a live
                // partial, a real resume offset, and a range that starts at exactly that offset.
                let rangeStart = HuggingFaceModelDownloader.contentRangeStart(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
                guard startOffset > 0, fm.fileExists(atPath: partial.path), rangeStart == startOffset else {
                    completionHandler(.cancel)
                    try? fm.removeItem(at: partial)
                    resumeOnce(throwing: HuggingFaceModelDownloader.DownloadError.apiError(
                        "unexpected 206 (Content-Range start \(rangeStart.map(String.init) ?? "nil"), expected \(startOffset)) for \(destination.lastPathComponent)"))
                    return
                }
                log.info("[range-resume] \(destination.lastPathComponent): HTTP 206 Partial Content - APPENDING from byte \(startOffset)")
                let h = try FileHandle(forWritingTo: partial)
                handle = h              // assign before seek so cleanup always closes it
                try h.seekToEnd()
                bytesOnDisk = startOffset
            } else if (200...299).contains(status) {
                // Full body (200 - server ignored any Range - or another 2xx): (re)create the
                // partial from zero. `createFile` truncates any existing file; verify it succeeded
                // so a failed create can't leave us appending onto stale bytes.
                log.info("[range-resume] \(destination.lastPathComponent): HTTP \(status) - writing from byte 0")
                try? fm.removeItem(at: partial)
                guard fm.createFile(atPath: partial.path, contents: nil) else {
                    completionHandler(.cancel)
                    resumeOnce(throwing: HuggingFaceModelDownloader.DownloadError.apiError(
                        "could not create \(partial.lastPathComponent)"))
                    return
                }
                handle = try FileHandle(forWritingTo: partial)
                bytesOnDisk = 0
            } else {
                completionHandler(.cancel)
                resumeOnce(throwing: HuggingFaceModelDownloader.DownloadError.apiError(
                    "HTTP \(status) for \(destination.lastPathComponent)"))
                return
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            resumeOnce(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let handle else { return }
        do {
            // Called on the delegate's serial background queue - safe to write + publish
            // progress directly (onProgress targets a lock-free AtomicProgress).
            try handle.write(contentsOf: data)
            bytesOnDisk += Int64(data.count)
            if expectedSize > 0 {
                onProgress(min(Double(bytesOnDisk) / Double(expectedSize), 1.0))
            }
        } catch {
            // Local write failure (e.g. disk full) - stop consuming and fail. The partial
            // stays on disk; the next attempt resumes from whatever landed.
            self.handle = nil
            dataTask.cancel()
            resumeOnce(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        try? handle?.close()
        handle = nil

        let fm = FileManager.default
        if let error = error {
            // Network error / stall / cancel: keep the `.partial` so the next attempt
            // resumes from here instead of restarting.
            log.info("[range-resume] \(destination.lastPathComponent): INTERRUPTED at \(bytesOnDisk)/\(expectedSize) bytes - partial kept for resume (\(error.localizedDescription))")
            resumeOnce(throwing: error)
        } else {
            // Transfer finished cleanly - but "cleanly" is not "completely". Commit ONLY
            // when the size matches; a body the server closed short of Content-Length must
            // never be mistaken for a finished download.
            let size = (try? fm.attributesOfItem(atPath: partial.path))?[.size] as? Int64 ?? -1
            switch HuggingFaceModelDownloader.commitDecision(downloadedSize: size, expectedSize: expectedSize) {
            case .commit:
                do {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: partial, to: destination)
                    log.info("[range-resume] \(destination.lastPathComponent): COMPLETE (\(size) bytes) - committed to destination")
                    resumeOnce()
                } catch {
                    resumeOnce(throwing: error)
                }
            case .discardAndFail:
                // Over-sized → corrupt. Discard so the retry starts clean.
                try? fm.removeItem(at: partial)
                resumeOnce(throwing: HuggingFaceModelDownloader.DownloadError.apiError(
                    "oversized download for \(destination.lastPathComponent): got \(size), expected \(expectedSize)"))
            case .keepAndFail:
                // Short body, no transport error - the prefix on disk is valid, so keep it
                // and fail; the next attempt resumes from `size`.
                resumeOnce(throwing: HuggingFaceModelDownloader.DownloadError.apiError(
                    "incomplete download for \(destination.lastPathComponent): got \(size)/\(expectedSize)"))
            }
        }

        // Drop the session from the active registry on the MainActor before invalidating -
        // otherwise the registry would leak invalidated sessions across the app's lifetime.
        if let downloader = downloader {
            Task { @MainActor in
                downloader.unregister(session)
            }
        }
        session.invalidateAndCancel()
    }

    private func resumeOnce(throwing error: Error? = nil) {
        lock.lock()
        guard !hasResumed else {
            lock.unlock()
            return
        }
        hasResumed = true
        lock.unlock()

        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
