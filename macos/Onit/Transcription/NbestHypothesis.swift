// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NbestHypothesis.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

import Foundation

/// Per-word timing produced by the ASR decoder. `startSec`/`endSec` are derived
/// from TDT encoder-frame indices, not interpolated - see
/// `ParakeetCoreMLEngine.wordTimestamps(...)`.
struct WordTimestamp: Codable, Equatable, Sendable {
    let word: String
    let startSec: Float
    let endSec: Float

    init(word: String, startSec: Float, endSec: Float) {
        self.word = word
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Represents a single transcription hypothesis from beam search decoding.
/// Used with Parakeet CoreML N-best output.
struct NbestHypothesis: Codable, Identifiable, Equatable, Sendable {
    /// Unique identifier for SwiftUI lists
    var id: String { text }

    /// The transcribed text (LM-conditioned if lm_condition was enabled, otherwise greedy)
    let text: String

    /// Raw greedy ASR text before LM conditioning (nil if conditioning was not applied or made no change)
    let raw_text: String?  // swiftlint:disable:this identifier_name

    /// Log probability score from beam search
    let score: Double

    /// Normalized confidence (0.0 - 1.0)
    let confidence: Double

    /// Per-word [startSec, endSec] timings from the TDT decoder. nil for ASR
    /// backends that don't expose per-token frame indices (FluidAudio) or for
    /// the chunked long-audio Parakeet path. Aligned to greedy `raw_text` when
    /// LM conditioning is enabled, otherwise to `text`.
    let wordTimestamps: [WordTimestamp]?

    init(
        text: String,
        rawText: String? = nil,
        score: Double,
        confidence: Double,
        wordTimestamps: [WordTimestamp]? = nil
    ) {
        self.text = text
        self.raw_text = rawText
        self.score = score
        self.confidence = confidence
        self.wordTimestamps = wordTimestamps
    }
}

// MARK: - Server Response Models

/// Response from /transcribe endpoint
struct TranscribeResponse: Codable {
    let hypotheses: [NbestHypothesis]
    let duration_ms: Double  // swiftlint:disable:this identifier_name
    let detected_language: String?  // swiftlint:disable:this identifier_name
    let vad_suppressed: Bool?  // swiftlint:disable:this identifier_name
}

/// Response from /transcribe/warmup endpoint
struct TranscribeWarmupResponse: Codable {
    let status: String
    let model: String
    let duration_ms: Double  // swiftlint:disable:this identifier_name
    let error: String?
}
