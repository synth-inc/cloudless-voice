// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SileroVADWarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Defaults
import Foundation

/// Warmup provider for the Silero VAD CoreML model used to suppress accidental short-trigger
/// dictation clicks. Runs independently of the ASR provider so a VAD download/load failure
/// surfaces in the menu bar with its own retry button - without breaking the ASR warmup.
///
/// At runtime, `SileroVADService.isAudioSilent(_:)` still fails open if the model is missing,
/// so a long-term VAD failure degrades gracefully (no silence gating) rather than blocking
/// transcription.
@MainActor
final class SileroVADWarmupProvider: WarmupProvider, ObservableObject {

    // MARK: - Singleton

    static let shared = SileroVADWarmupProvider()

    // MARK: - WarmupProvider

    let identifier = "vad"
    /// Runs after the ASR providers (priority 1) so the model graph is settled when VAD loads.
    let priority = 2

    var isEnabled: Bool {
        guard FeatureFlagManager.shared.sileroVadEnabled else { return false }
        guard Defaults[.transcriptionEnabled] else { return false }
        // VAD runs for every ASR backend we ship - the earlier enumerated OR-chain
        // was a maintenance trap (adding a new backend silently disabled VAD for
        // it). If a future backend should opt out, gate explicitly here.
        return true
    }

    @Published private(set) var isWarmedUp = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    func warmup() async throws {
        guard !isWarmedUp else { return }

        let isFirstTime = !Defaults[.vadWarmupCompletedOnce]
        let warmupStart = Date()
        log.info("SileroVADWarmupProvider: Starting warmup (first_time=\(isFirstTime))...")
        AnalyticsManager.Transcription.warmupStarted(model: identifier, isFirstTime: isFirstTime)

        do {
            try await HuggingFaceModelDownloader.shared.downloadVADIfNeeded()
            try await SileroVADService.shared.ensureLoaded()
        } catch is CancellationError {
            throw WarmupError.cancelled
        } catch {
            let durationMs = Date().timeIntervalSince(warmupStart) * 1000
            AnalyticsManager.Transcription.warmupFailed(
                model: identifier, isFirstTime: isFirstTime,
                durationMs: durationMs, error: error.localizedDescription
            )
            log.error("SileroVADWarmupProvider: Warmup failed: \(error.localizedDescription)")
            throw WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
        }

        let durationMs = Date().timeIntervalSince(warmupStart) * 1000
        isWarmedUp = true
        Defaults[.vadWarmupCompletedOnce] = true
        // Register periodic keep-alive pings so the VAD CoreML model stays resident.
        KeepAliveService.shared.register(.init(
            identifier: identifier,
            isActive: { await SileroVADService.shared.isLoaded },
            ping: {
                // isAudioSilent is the VAD engine's only inference entry point; the
                // boolean result is discarded - the call exists only to touch the model.
                _ = await SileroVADService.shared.isAudioSilent(KeepAliveService.shared.silenceClip())
            }
        ))
        log.info("SileroVADWarmupProvider: Warmup complete in \(String(format: "%.0f", durationMs))ms")
        AnalyticsManager.Transcription.warmupCompleted(
            model: identifier, isFirstTime: isFirstTime, durationMs: durationMs
        )
    }

    func reset() {
        // We intentionally don't unload `SileroVADService.shared.model` here: a successful
        // previous load should survive a retry trigger. `ensureLoaded()` short-circuits when
        // the model is already loaded, so the next warmup will only redo the steps that
        // actually need it (e.g. re-download if the on-disk file was wiped).
        isWarmedUp = false
        KeepAliveService.shared.deregister(identifier)
    }
}
