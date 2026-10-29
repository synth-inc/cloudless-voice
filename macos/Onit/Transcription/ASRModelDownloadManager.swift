// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelDownloadManager.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation

// MARK: - Install State

enum ModelInstallState: Equatable {
    case notInstalled
    case downloading
    case installed
    case failed(String)
}

// MARK: - Disk Space

/// Surfaced before the download starts to give the user a clean, actionable
/// failure message ("Needs 4.9 GB free, you have 3.1 GB") instead of letting
/// `URLSessionDownloadTask` fail mid-transfer with `NSFileWriteOutOfSpaceError`
/// after the user has already waited several minutes. Worded with "disk space"
/// so `ASRModelDownloadManager.performDownload` buckets the analytics under
/// `.insufficientDiskSpace`.
struct DiskSpaceError: LocalizedError {
    /// The model's published on-disk size. The precheck guards against this
    /// size *plus* a safety multiplier (see `diskSpaceSafetyMultiplier`), but
    /// we quote the unpadded value to the user so the error matches the size
    /// shown in the picker.
    let modelSizeBytes: Int64
    let availableBytes: Int64

    var errorDescription: String? {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let need = formatter.string(fromByteCount: modelSizeBytes)
        let have = formatter.string(fromByteCount: availableBytes)
        // Worded with "disk space" so `ASRModelDownloadManager.download(_:)`
        // buckets the analytics under `.insufficientDiskSpace`.
        return "Not enough disk space - model needs \(need) free, you have \(have) available."
    }
}

// MARK: - Manager

/// Tracks install state, progress, and triggers downloads for every model in
/// `ASRModel.catalog`. Parakeet routes through the existing
/// `HuggingFaceModelDownloader` (which wraps the per-backend SDKs internally -
/// WhisperKit, MoonshineVoice, Qwen3ASRModel - and exposes a uniform
/// `download<Backend>IfNeeded(...)` surface).
///
/// The manager intentionally stays thin: state is derived from the filesystem
/// (presence of the expected model directory) and from in-flight tasks tracked
/// in this class. There is no separate database - restarting the app rebuilds
/// install state from disk in a single call.
@MainActor
final class ASRModelDownloadManager: ObservableObject {

    static let shared = ASRModelDownloadManager()

    // MARK: - Published

    @Published private(set) var states: [String: ModelInstallState] = [:]
    private var progresses: [String: AtomicProgress] = [:]

    /// Active downloads keyed by model id, so we can cancel.
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Monotonically increasing token per model id. `download()` captures the value
    /// at spawn time; the completion handler only commits state if the token still
    /// matches the latest value. This prevents a cancelled task's late completion
    /// from overwriting the state of a newly-launched download (cancel→download
    /// spam race).
    private var downloadTokens: [String: Int] = [:]

    private init() {
        // Hydrate initial state from disk so the picker doesn't show every model as "Download"
        // on first appearance.
        for model in ASRModel.catalog {
            progresses[model.id] = AtomicProgress()
            states[model.id] = Self.isInstalledOnDisk(model) ? .installed : .notInstalled
        }
    }

    // MARK: - Public API

    func installState(for model: ASRModel) -> ModelInstallState {
        states[model.id] ?? .notInstalled
    }

    func progress(for model: ASRModel) -> AtomicProgress {
        if let existing = progresses[model.id] { return existing }
        let new = AtomicProgress()
        progresses[model.id] = new
        return new
    }

    func download(_ model: ASRModel) {
        guard activeTasks[model.id] == nil else { return }
        let token = (downloadTokens[model.id] ?? 0) + 1
        downloadTokens[model.id] = token
        states[model.id] = .downloading
        progress(for: model).set(0)

        AnalyticsManager.AsrModel.modelDownloadStarted(
            modelId: model.id,
            backend: model.backend.rawValue
        )
        let startedAt = Date()

        let task = Task { [weak self] in
            do {
                try await self?.performDownload(model)
                // `performDownload` can return *without throwing* even when the
                // download was cancelled: swift-transformers' `snapshot` (the
                // WhisperKit path) returns early at a file boundary on cancel
                // rather than throwing. Honour the Task's own cancellation flag no
                // matter how the download returned, so a cancel never books a false
                // "completed" nor leaves a partial bundle occupying disk.
                if Task.isCancelled {
                    self?.handleCancelledDownload(token: token, model: model, startedAt: startedAt)
                } else {
                    self?.commitIfCurrent(token: token, modelId: model.id, state: .installed)
                    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    AnalyticsManager.AsrModel.modelDownloadCompleted(
                        modelId: model.id,
                        backend: model.backend.rawValue,
                        durationMs: durationMs
                    )
                }
            } catch {
                // A user cancel surfaces differently per backend: our own
                // `downloadSingleFile` path normalises it to `CancellationError`,
                // while the swift-transformers / WhisperKit path throws
                // `URLError.cancelled`. Detect it uniformly via the Task's own
                // cancellation flag so *every* model treats a cancel the same way -
                // never booking it as a download failure and never leaving a partial
                // bundle behind to reappear as "installed" on the next launch.
                if Task.isCancelled || error is CancellationError {
                    self?.handleCancelledDownload(token: token, model: model, startedAt: startedAt)
                } else {
                    self?.commitIfCurrent(token: token, modelId: model.id, state: .failed(error.localizedDescription))
                    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    // Bucket the failure for funnel analysis: network errors
                    // (NSURLErrorDomain) vs the explicit unsupported-model
                    // errors thrown by `performDownload` per-backend vs the
                    // long tail (disk pressure, decoder, etc.).
                    let reason: AnalyticsManager.AsrModel.DownloadFailureReason
                    if (error as NSError).domain == NSURLErrorDomain {
                        reason = .network
                    } else {
                        let description = error.localizedDescription.lowercased()
                        if description.contains("unsupported") {
                            reason = .unsupportedModel
                        } else if description.contains("disk") || description.contains("space") {
                            reason = .insufficientDiskSpace
                        } else {
                            reason = .other
                        }
                    }
                    AnalyticsManager.AsrModel.modelDownloadFailed(
                        modelId: model.id,
                        backend: model.backend.rawValue,
                        reason: reason,
                        durationMs: durationMs,
                        errorDescription: error.localizedDescription
                    )
                }
            }
            self?.clearActiveTaskIfCurrent(token: token, modelId: model.id)
        }
        activeTasks[model.id] = task
    }

    func cancel(_ model: ASRModel) {
        // Invalidate the in-flight download's token *first*. `URLSession` ignores
        // Swift-concurrency cancellation, so even after `Task.cancel()` the network
        // operation can run to completion and resume the wrapping Task. Bumping the
        // token here guarantees that any late completion - success, failure, or
        // cancellation - is rejected by `commitIfCurrent`, so a cancelled download
        // can never silently flip the model back to `.installed`.
        downloadTokens[model.id] = (downloadTokens[model.id] ?? 0) + 1
        activeTasks[model.id]?.cancel()
        activeTasks[model.id] = nil
        if case .downloading = states[model.id] {
            states[model.id] = .notInstalled
        }
    }

    /// Delete the on-disk model. The order is deliberate: cancel any in-flight
    /// download → await engine unload → only then remove files from disk. Earlier
    /// versions removed files first and then awaited unload, which left a window
    /// where a concurrent transcribe could re-read a tokenizer / config file after
    /// it had already been unlinked (POSIX keeps open file handles valid, but lazy
    /// re-reads inside WhisperKit / Moonshine / MLX hit ENOENT). Awaiting unload
    /// first ensures the engine has dropped every reference before the files go.
    func delete(_ model: ASRModel) async {
        cancel(model)

        await ASRBackendRegistry.descriptor(for: model.backend).unloadForReplacedDownload(model.id)

        if let dir = Self.installDirectory(for: model) {
            try? FileManager.default.removeItem(at: dir)
        }
        states[model.id] = .notInstalled
        progress(for: model).set(0)
    }

    // MARK: - Token-guarded state commits

    private func commitIfCurrent(token: Int, modelId: String, state: ModelInstallState) {
        guard downloadTokens[modelId] == token else { return }
        states[modelId] = state
    }

    private func clearActiveTaskIfCurrent(token: Int, modelId: String) {
        guard downloadTokens[modelId] == token else { return }
        activeTasks[modelId] = nil
    }

    /// Apply the terminal state for a cancelled download: roll back to
    /// `.notInstalled` (token-guarded), delete any abandoned partial bundle, and
    /// log the cancel. Shared by the throwing-cancel path and the WhisperKit
    /// silent-return-on-cancel path so both behave identically.
    private func handleCancelledDownload(token: Int, model: ASRModel, startedAt: Date) {
        commitIfCurrent(token: token, modelId: model.id, state: .notInstalled)
        cleanupPartialDownloadIfAbandoned(model: model)
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        AnalyticsManager.AsrModel.modelDownloadCancelled(
            modelId: model.id,
            backend: model.backend.rawValue,
            durationMs: durationMs
        )
    }

    /// Remove a half-finished download's files after a cancel so a partial bundle
    /// isn't left occupying disk. Guarded on the absence of a live task for this
    /// model id: `cancel()` clears `activeTasks[id]`, and a subsequent `download()`
    /// repopulates it, so a non-nil entry means a *replacement* download is already
    /// in flight (the cancel→re-download race) and we must not delete the files it
    /// has begun writing. A later download for the same model resumes from whatever
    /// survives regardless, since `downloadRepo` does per-file size checks.
    private func cleanupPartialDownloadIfAbandoned(model: ASRModel) {
        guard activeTasks[model.id] == nil else { return }
        if let dir = Self.installDirectory(for: model) {
            try? FileManager.default.removeItem(at: dir)
        }
        progress(for: model).set(0)
    }

    // MARK: - Disk Space Precheck

    /// Conservative free-space requirement: model size × 1.3 (covers tokenizer
    /// configs, temporary unzip buffers, and the Hub API's two-stage write -
    /// it streams to a temp file before atomic-rename, briefly doubling space
    /// usage for the largest single file). Stays a multiplier rather than a
    /// fixed pad so it scales correctly for sub-100 MB models and 5 GB models.
    private static let diskSpaceSafetyMultiplier = 1.3

    /// Throws `DiskSpaceError` if the target volume can't hold the model. Reads
    /// free-space via `MacHelpers.getRemainingStorageInBytes` (which has the
    /// Important → Available → Opportunistic fallback chain that some external
    /// / SMB volumes require). No-op when MacHelpers returns 0 (probe failure):
    /// we don't want to hard-fail downloads on a sensor glitch, the download
    /// path will surface a real filesystem error later if there's an actual
    /// disk-full condition.
    static func precheckDiskSpace(for model: ASRModel) throws {
        let targetDir = installDirectory(for: model)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let available = Int64(MacHelpers.getRemainingStorageInBytes(directoryUrl: targetDir))
        guard available > 0 else { return }
        let required = Int64(Double(model.sizeBytes) * diskSpaceSafetyMultiplier)
        guard available < required else { return }
        // The user-facing message quotes the actual model size, not the padded
        // `required` figure - otherwise the picker reads "4.0 GB" but the error
        // claims the model "needs 5.2 GB", which sounds like the app is lying.
        throw DiskSpaceError(modelSizeBytes: model.sizeBytes, availableBytes: available)
    }

    // MARK: - Implementation

    private func performDownload(_ model: ASRModel) async throws {
        // Pre-flight check so a 5 GB Granite-Speech download doesn't fail
        // mid-transfer after 10 minutes with a vague NSError. Cheap (a
        // single `getattrlist` syscall) and surfaces a clear "Needs X GB
        // free" message via the per-model state.
        try Self.precheckDiskSpace(for: model)
        log.info("ASRModelDownloadManager: starting download \(model.id) (\(model.backend.rawValue))")
        try await ASRBackendRegistry.descriptor(for: model.backend)
            .download(model, progress(for: model))
        log.info("ASRModelDownloadManager: download complete \(model.id)")
    }

    // MARK: - Disk presence

    @MainActor
    static func isInstalledOnDisk(_ model: ASRModel) -> Bool {
        // Multi-file bundles (MLX, Moonshine `.ort`) check each required file;
        // CoreML backends use directory existence - encapsulated per backend in
        // the registry descriptor.
        ASRBackendRegistry.descriptor(for: model.backend).isInstalledOnDisk(model)
    }

    static func installDirectory(for model: ASRModel) -> URL? {
        // Each backend owns its canonical local dir (engine for CoreML/MLX,
        // a fixed dir for Parakeet) - see the registry descriptor.
        ASRBackendRegistry.descriptor(for: model.backend).installDirectory(model)
    }
}
