// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupPipelineBridge.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-08.
//

#if canImport(TranscriptionCleanup)

import Foundation
import TranscriptionCleanup

/// Result of the cleanup pipeline surfaced to the app.
struct CleanupPipelineResult {
    let text: String
    let candidateCount: Int
    let categoriesEvaluated: [String: Int]
    let categoriesApplied: [String: Int]
    let chunkCount: Int
    let deletePrecedingChars: Int
    /// Preformatted decision report from the package (debug/logging only).
    let debugReport: String?
    /// True when the package pipeline handled trailing-space insertion itself.
    let trailingSpaceHandled: Bool
}

/// Bridges the shared TranscriptionCleanup package pipeline for use in Onit.
/// Uses MLXScoringEngineAdapter to conform to ScoringEngine.
class CleanupPipelineBridge: @unchecked Sendable {

    private let pipeline: TranscriptionCleanup.CleanupPipeline<MLXScoringEngineAdapter>

    // `@MainActor` because we capture `TranscriptionLLMService.shared`,
    // itself isolated to the main actor. Call sites (TranscriptionManager)
    // already run on the main actor so this is invisible to callers.
    @MainActor
    init(engine: MLXScoringEngine = .shared) {
        let adapter = MLXScoringEngineAdapter(engine: engine)
        // Inject the shared LLM service so the package pipeline runs an
        // optional correction cleanup pass before its deterministic
        // generators. The service short-circuits when the model isn't
        // loaded or no marker is detected, so it's safe to wire in
        // unconditionally.
        self.pipeline = TranscriptionCleanup.CleanupPipeline(
            engine: adapter,
            llmCleanup: TranscriptionLLMService.shared
        )
    }

    /// Legacy convenience - returns only the cleaned text.
    func process(_ text: String, config: TranscriptionCleanup.PipelineConfig? = nil) async throws -> String {
        let result = try await processDetailed(text, config: config)
        return result.text
    }

    /// Detailed cleanup that uses sentence-boundary chunking for long inputs and
    /// surfaces candidate counts + per-category evaluated/applied breakdown.
    /// When `precedingText` / `followingText` are provided AND the corresponding
    /// flags are set in `config`, runs Smart Capitalization and trailing-punct
    /// scoring as part of the pipeline.
    func processDetailed(
        _ text: String,
        config: TranscriptionCleanup.PipelineConfig? = nil,
        precedingText: String? = nil,
        followingText: String? = nil
    ) async throws -> CleanupPipelineResult {
        let cfg = config ?? .default()
        let result = try await pipeline.processChunked(
            text,
            config: cfg,
            precedingText: precedingText,
            followingText: followingText
        )
        let candidateCount = result.changes?.count ?? 0
        let evaluated = Dictionary(uniqueKeysWithValues: result.categoriesEvaluated.map { ($0.key.rawValue, $0.value) })
        let applied = Dictionary(uniqueKeysWithValues: result.categoriesApplied.map { ($0.key.rawValue, $0.value) })

        // Push a debug entry for the Scoring Debug window (DEBUG builds only).
        #if DEBUG
        let info = CleanupDebugHistory.makeDebugInfo(from: result)
        let precedingCapture = precedingText
        let followingCapture = followingText
        let asrPromptCapture = ASRPromptContext.shared.lastResolvedPrompt
        let onScreenTermsCapture = ASRPromptContext.shared.lastOnScreenTerms
        let onScreenOCRTextCapture = ASRPromptContext.shared.lastOnScreenOCRText
        let onScreenSourceCapture = ASRPromptContext.shared.lastOnScreenSource
        let onScreenDecisionsCapture = ASRPromptContext.shared.lastOnScreenDecisions
        let onScreenScreenshotCapture = ASRPromptContext.shared.lastOnScreenScreenshot
        let onScreenHasCommonCapture = ASRPromptContext.shared.lastOnScreenHasCommonList
        let formatBeforeCapture = ASRPromptContext.shared.lastFormatBefore
        let formatAfterCapture = ASRPromptContext.shared.lastFormatAfter
        let formatEnabledCapture = ASRPromptContext.shared.lastFormatEnabled
        let formatTermCountCapture = ASRPromptContext.shared.lastFormatTermCount
        let formatReplacementsCapture = ASRPromptContext.shared.lastFormatReplacements
            .map { "\($0.spoken) → \($0.term)" }
        let formatVetoedCapture = ASRPromptContext.shared.lastFormatVetoed
            .map { "\($0.spoken) ⊘ \($0.term)" }
        await MainActor.run {
            CleanupDebugHistory.shared.record(entry: CleanupDebugEntry(
                date: Date(),
                info: info,
                precedingText: precedingCapture,
                followingText: followingCapture,
                logEntries: nil,
                deletePrecedingChars: result.deletePrecedingChars,
                debugReport: result.debugReport,
                suppressedTrailingPunct: result.suppressedTrailingPunct,
                trailingFormattingSuffix: result.trailingFormattingSuffix,
                asrPrompt: asrPromptCapture,
                onScreenTerms: onScreenTermsCapture,
                onScreenOCRText: onScreenOCRTextCapture,
                onScreenSource: onScreenSourceCapture,
                onScreenDecisions: onScreenDecisionsCapture,
                onScreenScreenshot: onScreenScreenshotCapture,
                onScreenHasCommonList: onScreenHasCommonCapture,
                formatBefore: formatBeforeCapture,
                formatAfter: formatAfterCapture,
                formatEnabled: formatEnabledCapture,
                formatTermCount: formatTermCountCapture,
                formatReplacements: formatReplacementsCapture,
                formatVetoed: formatVetoedCapture
            ))
        }
        #endif

        return CleanupPipelineResult(
            text: result.outputText,
            candidateCount: candidateCount,
            categoriesEvaluated: evaluated,
            categoriesApplied: applied,
            chunkCount: result.chunkCount,
            deletePrecedingChars: result.deletePrecedingChars,
            debugReport: result.debugReport,
            trailingSpaceHandled: result.trailingSpaceHandled
        )
    }
}

#endif // canImport(TranscriptionCleanup)
