// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FluidAudioWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 07/04/2026.
//

import Defaults
import FluidAudio
import Foundation

/// Warmup provider for the FluidAudio ASR transcription backend.
/// Handles model migration from Onit's directory to FluidAudio's directory via symlink,
/// then downloads/loads models and bridges progress into HuggingFaceModelDownloader for UI.
@MainActor
final class FluidAudioWarmupProvider: WarmupProvider, ObservableObject {

    // MARK: - Singleton

    static let shared = FluidAudioWarmupProvider()

    // MARK: - WarmupProvider

    let identifier = "fluidAudio"
    let priority = 1

    var isEnabled: Bool {
        Defaults[.transcriptionEnabled] && Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .fluidAudio
    }

    @Published private(set) var isWarmedUp = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func warmup() async throws {
        guard !isWarmedUp else { return }

        log.info("FluidAudioWarmupProvider: Starting warmup...")

        // Migrate existing models from Onit's directory to FluidAudio's expected location
        await migrateModelsIfNeeded()

        let downloader = HuggingFaceModelDownloader.shared

        // Signal that we're downloading (drives onboarding + menubar UI)
        downloader.updateParakeetState(.fetching)
        downloader.parakeetProgress.set(0)

        do {
            // FluidAudio handles download internally; mark as downloading for UI
            downloader.updateParakeetState(.downloading)

            // Offline-first: when the models are already on disk, load them
            // directly instead of going through `downloadAndLoad`. The latter
            // always performs a HuggingFace Hub round-trip to resolve the repo
            // snapshot - even when nothing needs downloading - and that call has
            // no timeout, so a stalled/absent connection hangs warmup for up to
            // ~15 min and then fails with "The Internet connection appears to be
            // offline" even though a fully-downloaded model is sitting right
            // there. `loadFromCache` reads straight from the cache directory
            // (the same path `migrateModelsIfNeeded` populates) with no network.
            // DEBUG A/B: `parakeetOfflineWarmupEnabled` gates the offline fix so it
            // can be flipped on/off at runtime to confirm it's what avoids the
            // no-wifi hang. OFF forces the old `downloadAndLoad` (network) path.
            let offlineFixOn = Defaults[.parakeetOfflineWarmupEnabled]
            let onDisk = Self.modelsExistOnDisk()
            let models: AsrModels
            if offlineFixOn && onDisk {
                log.info("FluidAudioWarmupProvider: [parakeet-offline-fix ON, onDisk=true] loading offline via loadFromCache (no network)")
                models = try await AsrModels.loadFromCache(version: .v3)
            } else {
                log.info("FluidAudioWarmupProvider: [parakeet-offline-fix \(offlineFixOn ? "ON" : "OFF"), onDisk=\(onDisk)] calling AsrModels.downloadAndLoad (network round-trip)")
                models = try await AsrModels.downloadAndLoad(version: .v3)
            }

            downloader.parakeetProgress.set(0.8)
            log.info("FluidAudioWarmupProvider: Models downloaded, initializing ASR manager...")

            try await FluidAudioASRService.shared.initialize(models: models)

            downloader.parakeetProgress.set(1.0)
            downloader.updateParakeetState(.completed)

            isWarmedUp = true
            log.info("FluidAudioWarmupProvider: Warmup complete")

        } catch is CancellationError {
            downloader.updateParakeetState(.idle)
            throw WarmupError.cancelled
        } catch {
            downloader.updateParakeetState(.failed)
            log.error("FluidAudioWarmupProvider: Warmup failed: \(error.localizedDescription)")
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }
    }

    /// Reset the warmup state. Called when the user switches to a different ASR
    /// backend: dropping the FluidAudio `AsrManager` reclaims ~700 MB of CoreML
    /// model memory that would otherwise stay resident for the whole app session.
    func reset() {
        isWarmedUp = false
        FluidAudioASRService.shared.unload()
    }

    // MARK: - Private Methods

    /// FluidAudio's expected model location - the cache directory `loadFromCache`
    /// reads from, and the symlink target `migrateModelsIfNeeded` creates.
    /// `nil` only if Application Support is somehow unavailable.
    private static func fluidAudioModelsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")
    }

    /// Whether the Parakeet models are present at FluidAudio's cache path (a real
    /// directory or the symlink created by `migrateModelsIfNeeded`). Gates the
    /// offline load path so a network round-trip is only attempted when the model
    /// genuinely needs downloading.
    private static func modelsExistOnDisk() -> Bool {
        guard let dir = fluidAudioModelsDirectory() else { return false }
        // Require an actual directory (follows symlinks), not just any path - a
        // zero-byte file or stale symlink target must not be trusted as a model.
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Creates a symlink from FluidAudio's expected model directory to Onit's downloaded models,
    /// so existing users don't need to re-download 600MB of model files.
    private func migrateModelsIfNeeded() async {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        // Onit's existing model location (where HuggingFaceModelDownloader stores them)
        let onitModelsDir = appSupport
            .appendingPathComponent("Onit/Models/parakeet-tdt-0.6b-v3-coreml")

        // FluidAudio's expected model location
        let fluidAudioModelsDir = appSupport
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")

        // If FluidAudio path already exists (real dir or symlink), nothing to do
        guard !fileManager.fileExists(atPath: fluidAudioModelsDir.path) else {
            log.info("FluidAudioWarmupProvider: FluidAudio model path already exists, skipping migration")
            return
        }

        // If Onit's models don't exist either, let FluidAudio download fresh
        guard fileManager.fileExists(atPath: onitModelsDir.path) else {
            log.info("FluidAudioWarmupProvider: No existing models found, FluidAudio will download fresh")
            return
        }

        // Create FluidAudio's parent directory and symlink to Onit's models
        let fluidAudioParent = fluidAudioModelsDir.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: fluidAudioParent, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: fluidAudioModelsDir, withDestinationURL: onitModelsDir)
            log.info("FluidAudioWarmupProvider: Created symlink \(fluidAudioModelsDir.path) → \(onitModelsDir.path)")
        } catch {
            log.warning("FluidAudioWarmupProvider: Could not create model symlink: \(error.localizedDescription) - FluidAudio will re-download")
        }
    }
}
