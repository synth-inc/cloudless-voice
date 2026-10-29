// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupProvider.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  On-device Smart Cleanup: the closed TranscriptionCleanup pipeline
//  (`CleanupPipelineBridge`) followed by the semantic emoji pass, run one at a
//  time on the shared scorer. The only place in the app that runs the pipeline;
//  everything else reaches it through `CleanupService`.
//

#if canImport(TranscriptionCleanup)

import Defaults
import Foundation
import TranscriptionCleanup

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

@MainActor
final class SmartCleanupProvider: CleanupProvider {
    let id = CleanupProviderID.smart
    var displayName: String { String.localized("Smart Cleanup", table: "Settings") }

    private let config: TranscriptionConfig
    private let pipeline: CleanupPipelineBridge

    init(config: TranscriptionConfig = .shared, pipeline: CleanupPipelineBridge = CleanupPipelineBridge()) {
        self.config = config
        self.pipeline = pipeline
    }

    /// No limit: the on-device pipeline has always run to completion on a live
    /// dictation, and it can't be interrupted once started, so a timeout would only
    /// hand back raw text while the scorer stays busy.
    var timeout: Duration? { nil }

    var availability: ProviderAvailability {
        get async {
            // Callers reload idle-unloaded models first
            // (`CleanupModelLifecycleService.ensureResidentForCleanup`): that also
            // covers models other features share, so it runs even with cleanup off.
            guard await MLXScoringEngine.shared.isCleanupReady else {
                return .needsSetup(reason: "Cleanup model still loading")
            }
            return .ready
        }
    }

    func cleanup(_ input: CleanupInput) async throws -> CleanupOutput {
        let locale = input.locale.library
        // The scorer is one model: a dictation's cleanup and a file job's must not
        // run through it at the same time. A live dictation goes first.
        let result: CleanupPipelineResult
        do {
            result = try await ASREngineGate.cleanup.withEngine(jumpQueue: input.isLive) {
                // The gate's queue ignores cancellation: a live cleanup that timed out
                // while queued still gets the scorer later, with nobody waiting for its
                // result. Hand it straight back rather than run the pipeline for nothing
                // (and make the next dictation wait behind it). Live only: `CleanupService`
                // cancels a live cleanup on timeout alone, while an offline job keeps its
                // old behaviour of finishing its pass when cancelled.
                if input.isLive { try Task.checkCancellation() }
                let pipelineConfig = config.buildSwiftPipelineConfig(
                    inEmailComposer: input.inEmailComposer,
                    locale: locale
                )
                return try await pipeline.processDetailed(
                    input.transcript,
                    config: pipelineConfig,
                    precedingText: input.precedingText,
                    followingText: input.followingText
                )
            }
        } catch let error as CleanupEntitlementError {
            // The library's paywall refused the run (free words used up, or no free tier
            // in this build). `CleanupService` keeps the raw transcript; the caller reads
            // the reason from `SmartCleanupEntitlement.usage` for the upgrade prompt.
            if case .notEntitled(let usage) = error {
                log.info("[smartCleanup] not entitled: reason=\(error.reason) plan=\(usage.plan.rawValue) words=\(usage.wordsUsed)/\(usage.wordLimit.map(String.init) ?? "unlimited")")
            }
            SmartCleanupEntitlement.shared.reload()
            throw CleanupError.notEntitled
        }
        // [Prototype] Semantic emoji pass runs after exact matching, so it only sees
        // leftover "<words> <trigger>" spans ("crying emoji"). Applied on every path:
        // a re-transcription of the same audio has to produce the same text.
        let text = SemanticEmojiMatcher.shared.applyIfEnabled(to: result.text, locale: locale)
        return CleanupOutput(
            text: text,
            stats: .init(
                candidateCount: result.candidateCount,
                categoriesEvaluated: result.categoriesEvaluated,
                categoriesApplied: result.categoriesApplied,
                chunkCount: result.chunkCount,
                deletePrecedingChars: result.deletePrecedingChars,
                trailingSpaceHandled: result.trailingSpaceHandled,
                debugReport: result.debugReport
            )
        )
    }
}

// MARK: - Library mapping

extension CleanupLocale {
    /// The library's locale for these rules.
    var library: TranscriptionCleanup.SupportedLocale {
        switch self {
        case .english: .english
        case .french: .french
        }
    }
}

// MARK: - Pipeline config

extension TranscriptionConfig {

    /// Build a `PipelineConfig` for the Swift cleanup pipeline from the current SF settings.
    ///
    /// - Parameters:
    ///   - inEmailComposer: Whether this dictation lands in an email composer (see
    ///     `EmailComposer`). The email layout only runs there.
    ///   - locale: Cleanup rules to run. Defaults to `cleanupLocale`.
    func buildSwiftPipelineConfig(
        inEmailComposer: Bool,
        locale: TranscriptionCleanup.SupportedLocale? = nil
    ) -> TranscriptionCleanup.PipelineConfig {
        // Custom trigger words the user edited in Settings. Without these the
        // pipeline runs on the framework defaults and every customization is
        // silently inert.
        //
        // Adds and removals both land everywhere now. The framework used to leak
        // removals through the paths that never took a config (the bracket table,
        // the English aggressive pass, the spoken-formatting composites); that is
        // fixed in the vendored TranscriptionCleanup, which holds every candidate
        // to the user's removals in one place.
        let triggers = SmartFormattingTriggersManager.shared
        let punctuationTriggers = triggers.punctuationDiff
        let formattingTriggers = triggers.formattingDiff
        let fillerTriggers = triggers.fillersDiff
        let categories: [TranscriptionCleanup.CleanupCategory: TranscriptionCleanup.CategoryConfig] = [
            .punctuation: .init(
                enabled: sfPunctuationEnabled,
                addTriggers: punctuationTriggers.add,
                removeTriggers: punctuationTriggers.remove
            ),
            .emoji: .init(enabled: sfEmojiEnabled, customGlyphs: EmojiTriggersManager.shared.customGlyphs),
            .formatting: .init(
                enabled: sfFormattingEnabled,
                addTriggers: formattingTriggers.add,
                removeTriggers: formattingTriggers.remove
            ),
            .fillers: .init(
                enabled: sfFillersEnabled,
                addTriggers: fillerTriggers.add,
                removeTriggers: fillerTriggers.remove
            ),
            .emailUrl: .init(enabled: sfEmailsUrlsEnabled),
            .stutters: .init(enabled: sfDuplicatesEnabled),
            .numbers: .init(enabled: sfNumbersEnabled),
            .acronyms: .init(enabled: true),
            .pairedBrackets: .init(enabled: true),
        ]
        let style: TranscriptionCleanup.NumberStyle =
            TranscriptionCleanup.NumberStyle(rawValue: sfNumberStyle) ?? .withComma
        let locale = locale ?? cleanupLocale.library
        // These three are the only categories that call into the scoring engine.
        // Where MLX cannot run (Intel - see `MLXRuntime`) they are forced off, so
        // the deterministic generators still run instead of the whole pipeline
        // waiting on a model that will never load.
        let scoringEnabled = sfCapitalizationEnabled && MLXRuntime.isSupported
        return TranscriptionCleanup.PipelineConfig(
            categories: categories,
            numberStyle: style,
            abbreviateLargeNumbers: sfAbbreviateLargeNumbers,
            capitalizationEnabled: scoringEnabled,
            trailingPunctScoringEnabled: scoringEnabled,
            trailingSpaceScoringEnabled: scoringEnabled,
            locale: locale,
            // Deterministic removal: when a category toggle is on, always remove
            // (no perplexity veto); when off, the category generates no candidates
            // at all. The rule-based exclusion guards still run at generation time.
            forceRemoveFillers: sfFillersEnabled,
            forceRemoveStutters: sfDuplicatesEnabled,
            // Email layout is a deterministic post-process, not a category: it
            // reflows the final text rather than competing for a slot. It runs
            // only in an email composer, and there only on a text the formatter
            // recognizes as an email.
            emailFormattingEnabled: sfEmailLayoutEnabled && inEmailComposer,
            // The user's greeting / sign-off edits (Settings → Email Layout).
            // Read straight from Defaults, like the sf* toggles above.
            emailGreetingAddTriggers: Defaults[ConfigKeys.emailGreetingAddTriggers],
            emailGreetingRemoveTriggers: Defaults[ConfigKeys.emailGreetingRemoveTriggers],
            emailSignOffAddTriggers: Defaults[ConfigKeys.emailSignOffAddTriggers],
            emailSignOffRemoveTriggers: Defaults[ConfigKeys.emailSignOffRemoveTriggers]
        )
    }
}

#endif // canImport(TranscriptionCleanup)
