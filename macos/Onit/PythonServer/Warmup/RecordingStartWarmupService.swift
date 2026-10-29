// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RecordingStartWarmupService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-13.
//
//  Fires dummy inferences the moment the user starts a recording session,
//  so cold ANE/GPU models warm concurrently with the user speaking rather
//  than after they finish.
//
//  Without this, a session after a long idle period (OS evicted the models)
//  pays a 5–10 s cold-start penalty that the user perceives as ASR or cleanup
//  latency. The keep-alive pings (ASRModelLifecycleService, per-backend policy)
//  maintain warmth during an active session, but can't help after app launch or
//  a multi-hour gap (where the model has been unloaded-on-idle).
//
//  Three warmup tasks are fired concurrently:
//  1. ASR: tiny silent clip → ParakeetCoreMLEngine.transcribe()
//  2. Cleanup: single word → MLXScoringEngine.tokenScores(), which exercises
//     the MLX pipeline and pulls the model onto the GPU/ANE.
//  3. Improvement LLM (N-best / backtracking): tiny prompt →
//     TranscriptionLLMService.generateWithImprovementModel(), same MLX
//     pipeline as cleanup but a separate model container.
//

import Defaults
import Foundation

@MainActor
final class RecordingStartWarmupService {

    // MARK: - Singleton

    static let shared = RecordingStartWarmupService()

    // MARK: - Configuration

    /// Duration of the silent clip sent to the ASR engine (seconds at 16 kHz).
    private let silenceDuration: TimeInterval = 0.5
    private let targetSampleRate: Double = 16_000

    // MARK: - Init

    private init() {}

    // MARK: - Public

    /// Fire both warmup tasks concurrently. Call this when a recording session begins.
    /// Both tasks are fire-and-forget; their results are discarded.
    func warmModelsForRecording() {
        guard Defaults[.transcriptionEnabled] else { return }
        // Force the trigger store to load off the insertion path: the cleanup config
        // is built at the END of a dictation, and this singleton reads its JSON from
        // disk synchronously on first access. Cheap and idempotent.
        _ = SmartFormattingTriggersManager.shared.customTriggers
        Task { await warmASR() }
        Task { await warmCleanup() }
        Task { await warmImprovementLLM() }
    }

    // MARK: - Private

    private func warmASR() async {
        guard await ParakeetCoreMLEngine.shared.isLoaded else {
            log.debug("RecordingStartWarmupService: ASR engine not loaded, skipping")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_asr", durationMs: 0, status: "skipped")
            return
        }

        let sampleCount = Int(silenceDuration * targetSampleRate)
        let silence = [Float](repeating: 0, count: sampleCount)

        let start = Date()
        do {
            _ = try await ParakeetCoreMLEngine.shared.transcribe(silence, language: nil)
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.debug("RecordingStartWarmupService: ASR warmup ok (\(Int(durationMs))ms)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_asr", durationMs: durationMs, status: "ok")
        } catch {
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.warning("RecordingStartWarmupService: ASR warmup failed: \(error.localizedDescription)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_asr", durationMs: durationMs, status: "error")
        }
    }

    private func warmCleanup() async {
        guard await MLXScoringEngine.shared.isLoaded else {
            log.debug("RecordingStartWarmupService: Scoring engine not loaded, skipping")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_cleanup", durationMs: 0, status: "skipped")
            return
        }

        let start = Date()
        do {
            // Single short token - enough to exercise the MLX pipeline and pull the
            // model onto the GPU/ANE without doing meaningful work.
            _ = try await MLXScoringEngine.shared.tokenScores("test")
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.debug("RecordingStartWarmupService: cleanup warmup ok (\(Int(durationMs))ms)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_cleanup", durationMs: durationMs, status: "ok")
        } catch {
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.warning("RecordingStartWarmupService: cleanup warmup failed: \(error.localizedDescription)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_cleanup", durationMs: durationMs, status: "error")
        }
    }

    private func warmImprovementLLM() async {
        // Skip the ping if no consumer is enabled. The model can be resident
        // from a prior session even after the user disabled N-best / backtracking,
        // and we don't want to burn GPU/ANE time inferring for a feature that
        // won't fire.
        let nbest = Defaults[Defaults.Keys.TranscriptionConfigKeys.nbestSelectionEnabled]
        let smartFormatting = TranscriptionConfig.isSmartCleanupSelected
        let backtracking = Defaults[Defaults.Keys.TranscriptionConfigKeys.sfBacktrackingEnabled]
        guard nbest || (smartFormatting && backtracking) else {
            log.debug("RecordingStartWarmupService: Improvement LLM consumers disabled, skipping")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_improvement_llm", durationMs: 0, status: "skipped")
            return
        }

        let service = TranscriptionLLMService.shared
        guard service.isImprovementModelLoaded else {
            log.debug("RecordingStartWarmupService: Improvement LLM not loaded, skipping")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_improvement_llm", durationMs: 0, status: "skipped")
            return
        }

        let start = Date()
        do {
            // Tiny prompt - only purpose is to pull the model onto the GPU/ANE after
            // a long idle. Output is discarded. Timeout matches the production
            // correction path (5s) so a cold first inference on a chilled
            // model doesn't falsely log as a `status: "error"` ping.
            _ = try await service.generateWithImprovementModel(
                userPrompt: "x",
                timeoutSeconds: 5.0
            )
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.debug("RecordingStartWarmupService: improvement LLM warmup ok (\(Int(durationMs))ms)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_improvement_llm", durationMs: durationMs, status: "ok")
        } catch {
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.warning("RecordingStartWarmupService: improvement LLM warmup failed: \(error.localizedDescription)")
            AnalyticsManager.Transcription.modelPing(pingType: "recording_start_improvement_llm", durationMs: durationMs, status: "error")
        }
    }
}
