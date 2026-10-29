// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  QwenScoringEngine+Cleanup.swift
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

// MARK: - QwenScoringEngineAdapter

/// Adapter that bridges `QwenScoringEngine` to the `ScoringEngine`
/// protocol from the TranscriptionCleanup package.
///
/// Avoids direct conformance on `QwenScoringEngine` to prevent name collisions
/// (e.g. `tokenScores` returns different tuple labels) and to provide the required
/// protocol properties.
actor QwenScoringEngineAdapter: ScoringEngine {

    private let engine: QwenScoringEngine

    /// Default thresholds matching the engine's defaults.
    /// Stored locally so the protocol's synchronous property requirement is satisfied.
    let outlierThreshold: Float
    let capThreshold: Float

    init(engine: QwenScoringEngine = .shared, outlierThreshold: Float = 18.0, capThreshold: Float = 18.0) {
        self.engine = engine
        self.outlierThreshold = outlierThreshold
        self.capThreshold = capThreshold
    }

    func tokenScores(_ text: String) async throws -> (tokenIDs: [Int], scores: [Float]) {
        let result = try await engine.tokenScores(text)
        return (tokenIDs: result.0, scores: result.1)
    }

    func scoreTrailingPunctuation(
        _ text: String,
        punctuation: [String]
    ) async throws -> (avgScore: Float, punctScores: [String: Float]) {
        return try await engine.scoreTrailingPunctuation(text, punctuation: punctuation)
    }
}

#endif // canImport(TranscriptionCleanup)
