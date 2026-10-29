// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionLLMService+Cleanup.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  The improvement model's Smart Cleanup role: the backtracking correction pass
//  the TranscriptionCleanup pipeline injects (`CleanupLLMService`) and the raw
//  inference its prompt shaping calls (`RawTextInference`). The service itself is
//  open, since N-best selection uses the same model; only this is compiled out of
//  a fully open build (`scripts/build-fully-open.sh`).
//

#if canImport(TranscriptionCleanup)

import Foundation
import TranscriptionCleanup

// MARK: - CleanupLLMService

extension TranscriptionLLMService: TranscriptionCleanup.CleanupLLMService {

    /// Inference timeout for the correction pass. 5s is enough for
    /// ~50-token outputs on Apple Silicon with the fine-tuned Llama 3.2 1B.
    static let correctionTimeoutSeconds: Double = 5.0

    /// Run a correction-focused cleanup pass on the raw ASR text.
    /// Conforms to `TranscriptionCleanup.CleanupLLMService` so the
    /// shared pipeline can call it via dependency injection.
    /// Returns the text unchanged on missing model / no marker detected /
    /// timeout / parse failure so callers can chain it transparently before
    /// the deterministic pipeline.
    func cleanup(_ text: String) async -> String {
        let timeoutSeconds = Self.correctionTimeoutSeconds
        guard TranscriptionConfig.shared.sfBacktrackingEnabled else {
            log.info("TranscriptionLLMService: correction skipped (disabled by user)")
            return text
        }
        guard isImprovementModelLoaded else {
            log.info("TranscriptionLLMService: correction skipped (model not loaded)")
            // Treat "model not loaded" as a failed cleanup attempt for
            // funnel visibility - distinguishes "feature available but
            // model isn't warm" from "no marker so we skipped."
            AnalyticsManager.TranscriptionLLM.cleanupFailed(
                textLength: text.count,
                reason: .notLoaded,
                durationMs: 0
            )
            return text
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }

        // Cheap gate: skip the model when no plausible marker is present.
        guard LLMRefinement.mayApply(text, markers: BacktrackingMarkersManager.matcherRegexes) else {
            log.info("TranscriptionLLMService: correction bypassed (no marker)")
            return text
        }

        AnalyticsManager.TranscriptionLLM.cleanupAttempted(textLength: text.count)

        log.info("TranscriptionLLMService: correction running - input \(LogPrivacy.summary(text))")
        let startedAt = Date()

        do {
            // The package owns the prompt and input shaping; we inject raw
            // inference and parse the result here.
            let cleaned = Self.cleanLLMResponse(
                try await LLMRefinement.apply(text, using: self)
            )
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)

            let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedTrimmed.isEmpty {
                log.warning("TranscriptionLLMService: correction returned empty output (\(elapsedMs)ms), keeping raw")
                AnalyticsManager.TranscriptionLLM.cleanupFailed(
                    textLength: text.count,
                    reason: .other,
                    durationMs: elapsedMs,
                    errorDescription: "empty_output"
                )
                return text
            }
            let changed = cleaned != text
            log.info("TranscriptionLLMService: correction \(changed ? "changed" : "unchanged") (\(elapsedMs)ms) - output \(LogPrivacy.summary(cleaned))")
            AnalyticsManager.TranscriptionLLM.cleanupCompleted(
                textLength: text.count,
                durationMs: elapsedMs,
                wasModified: changed
            )
            return cleaned
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log.warning("TranscriptionLLMService: correction failed in \(elapsedMs)ms (\(error.localizedDescription)), keeping raw")
            // `generateWithImprovementModel` re-throws TimeoutError as
            // `.inferenceTimeout`; everything else funnels into `.other`.
            if case TranscriptionLLMError.inferenceTimeout = error {
                AnalyticsManager.TranscriptionLLM.cleanupTimeout(
                    textLength: text.count,
                    timeoutSeconds: timeoutSeconds,
                    durationMs: elapsedMs
                )
            } else {
                AnalyticsManager.TranscriptionLLM.cleanupFailed(
                    textLength: text.count,
                    reason: .other,
                    durationMs: elapsedMs,
                    errorDescription: error.localizedDescription
                )
            }
            return text
        }
    }
}

// MARK: - RawTextInference

extension TranscriptionLLMService: RawTextInference {

    /// Entry point the cleanup package calls to run inference. The package
    /// owns the prompt and input shaping; we only run the model and return
    /// its raw output, under the correction timeout.
    func generate(system: String, user: String) async throws -> String {
        try await generateRaw(
            system: system,
            user: user,
            timeoutSeconds: Self.correctionTimeoutSeconds
        )
    }
}

#endif // canImport(TranscriptionCleanup)
