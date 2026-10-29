// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXScoringEngine+Cleanup.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Smart Cleanup's view of the engine: its `ScoringEngine` conformance from the
//  closed TranscriptionCleanup library. The engine itself is open; only this
//  adapter is compiled out of a fully open build (`scripts/build-fully-open.sh`).
//

#if canImport(TranscriptionCleanup)

import Foundation
import TranscriptionCleanup

// MARK: - MLXScoringEngineAdapter

/// Adapter that bridges `MLXScoringEngine` to the `ScoringEngine`
/// protocol from the TranscriptionCleanup package.
///
/// Avoids direct conformance on `MLXScoringEngine` to prevent name collisions
/// (e.g. `tokenScores` returns different tuple labels) and to provide the required
/// protocol properties.
actor MLXScoringEngineAdapter: ScoringEngine {

    private let engine: MLXScoringEngine

    // outlierThreshold / capThreshold are satisfied by the ScoringEngine
    // protocol extension defaults.

    init(engine: MLXScoringEngine = .shared) {
        self.engine = engine
    }

    /// Flat per-token score handed to the pipeline where no scorer can run.
    ///
    /// The value is arbitrary; only its uniformity matters. It mirrors the
    /// package's own `MockPerplexityEngine`, which the framework's tests use to
    /// exercise the deterministic generators without a model.
    private static let neutralScore: Float = 2.0

    func tokenScores(_ text: String) async throws -> (tokenIDs: [Int], scores: [Float]) {
        // Where MLX cannot run (Intel - see `MLXRuntime`), answer neutrally
        // instead of throwing. `ComboSearch` scores EVERY slot, so a throw here
        // propagates out of the whole pipeline and the user gets raw,
        // uncleaned text - lists, punctuation, fillers and all. Verified
        // against the framework sources: with a flat-score engine the
        // deterministic generators still produce
        // "bullet point buy milk" -> "- Buy milk".
        guard MLXRuntime.isSupported else {
            let words = text.split(separator: " ")
            // At least one id: the real engine tokenizes "" to a BOS token, so it
            // never returns an empty array, and callers derive indices from
            // `count - 1` (`scoreTrailingPunctuation` below does exactly that).
            return (
                tokenIDs: Array(0..<max(words.count, 1)),
                scores: Array(repeating: Self.neutralScore, count: max(words.count - 1, 0))
            )
        }
        let result = try await engine.tokenScores(text)
        return (tokenIDs: result.tokenIds, scores: result.scores)
    }

    func scoreTrailingPunctuation(
        _ text: String,
        punctuation: [String]
    ) async throws -> (avgScore: Float, punctScores: [String: Float]) {
        // Unreachable on Intel in practice - `buildSwiftPipelineConfig` turns
        // `trailingPunctScoringEnabled` off there - but kept symmetric so no
        // caller can reintroduce the throw.
        guard MLXRuntime.isSupported else {
            return (
                avgScore: Self.neutralScore,
                punctScores: Dictionary(
                    uniqueKeysWithValues: punctuation.map { ($0, Self.neutralScore) }
                )
            )
        }
        return try await engine.scoreTrailingPunctuation(text, punctuation: punctuation)
    }
}

#endif // canImport(TranscriptionCleanup)
