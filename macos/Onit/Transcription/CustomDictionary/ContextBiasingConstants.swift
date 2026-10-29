// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
// Portions derived from FluidAudio (https://github.com/FluidInference/FluidAudio),
// Copyright (c) FluidInference, licensed under the Apache License, Version 2.0.
// Modified by Synthetic Exploration, Inc. See THIRD_PARTY_NOTICES.md at the repository root.
//
//  ContextBiasingConstants.swift
//  Onit
//
//  Ported from FluidAudio - centralized constants for the CTC custom dictionary module.
//

import Foundation

/// Centralized constants for the CTC custom dictionary (context biasing) module.
///
/// Consolidates magic numbers and thresholds used across vocabulary biasing,
/// CTC keyword spotting, and rescoring components.
enum ContextBiasingConstants {

    // MARK: - Token IDs

    /// Sentinel value representing wildcard token ID for pattern matching in
    /// CTC dynamic programming paths.
    ///
    /// Represents "*" in keyword patterns that matches any token at zero cost.
    ///
    /// - Value: `-1` (matches any token during path scoring)
    static let wildcardTokenId: Int = -1

    /// Default blank token ID for CTC models.
    ///
    /// For parakeet-ctc-110m, the vocabulary has 1024 tokens (indices 0–1023),
    /// so the blank token is at index 1024.
    ///
    /// - Value: `1024`
    static let defaultBlankId: Int = 1024

    // MARK: - CTC Score Thresholds

    /// Default minimum CTC score for keyword spotting detections.
    ///
    /// Keywords with CTC scores below this threshold are filtered out as low-confidence.
    /// CTC scores are log-probabilities (negative values; higher = more confident).
    ///
    /// Historic calibration against the "Onit" eval set:
    ///   True positives  (user said app name):  -7.20 … -8.63
    ///   False positives (natural "on it"):     -9.86, -11.67
    ///
    /// The original threshold was -9.0, which comfortably rejected all known
    /// false positives. In practice that proved too strict for real-world
    /// French speakers trying to dictate short English proper nouns: observed
    /// scores for a genuine "Onit" utterance were stable around -9.80,
    /// below the cut-off, making the feature feel broken for the most obvious
    /// test case.
    ///
    /// Lowered to **-10.0** so that borderline genuine pronunciations pass the
    /// CTC gate. This re-admits the -9.86 false positive from the calibration
    /// set, so natural French "on it" *may* now be replaced with "Onit" when
    /// that proper noun is in the dictionary. The similarity gate
    /// (`defaultMinSimilarity = 0.70`) remains the downstream safety net, but
    /// it won't filter this specific case because "on it" normalises to
    /// "onit" (similarity 1.0). Users can delete mis-corrected terms from
    /// the Dictionary settings if this becomes a problem in their own
    /// vocabulary.
    ///
    /// - Value: `-10.0`
    static let defaultMinSpotterScore: Float = -10.0

    /// CTC temperature for softmax probability distribution.
    ///
    /// - Value: `1.0` (standard softmax)
    static let ctcTemperature: Float = 1.0

    /// Blank bias correction applied to CTC log-probabilities.
    ///
    /// Positive values penalize the blank token, making non-blank tokens more likely.
    ///
    /// - Value: `0.0` (no bias)
    static let blankBias: Float = 0.0

    // MARK: - Similarity Thresholds

    /// Default minimum similarity for vocabulary term matching.
    ///
    /// With N-gram span matching, "on it" normalizes to "onit" giving 1.0 similarity
    /// against "Onit". Raising to 0.70 prevents weak single-word partial matches
    /// (e.g. "on" vs "onit" = 0.5) from triggering.
    ///
    /// - Value: `0.70`
    static let defaultMinSimilarity: Float = 0.70

    /// Normalized CTC score margin above the gate threshold at which the similarity
    /// floor is lowered from `defaultMinSimilarity` to `highConfidenceSimilarity`.
    ///
    /// When `bestDetection.score > (adjustedMinScore + highConfidenceMargin)` the
    /// acoustic signal is strong enough to accept phonetically close but
    /// orthographically distant ASR confusions (e.g. TDT transcribes "Onit" as
    /// "audit", similarity 0.40). The rescorer switches to the lower floor so the
    /// best-matching word in the detection window is still corrected.
    ///
    /// At a threshold of −10.0, the high-confidence cutoff is −7.0.
    ///
    /// - Value: `3.0`
    static let highConfidenceMargin: Float = 3.0

    /// Lower similarity floor used when the CTC detection is high-confidence.
    ///
    /// Set to 0.30 - low enough to catch "audit"↔"Onit" (sim≈0.40) while still
    /// requiring at least some phonetic overlap and excluding completely unrelated words.
    ///
    /// - Value: `0.30`
    static let highConfidenceSimilarity: Float = 0.30

    // MARK: - Threshold Relaxation

    /// Baseline token count beyond which the CTC spotter threshold is relaxed.
    ///
    /// - Value: `3`
    ///
    /// TODO: calibrate from eval data. The current value is a heuristic -
    /// the observed ANE variance on multi-token phrases (e.g. Checkbin at 4
    /// tokens, a long multi-part company name at 9+) suggests the relaxation slope
    /// should be derived from an eval harness rather than set as a guess,
    /// and this baseline itself may not be the right pivot point.
    static let baselineTokenCountForThreshold: Int = 3

    /// Threshold relaxation amount per extra token beyond `baselineTokenCountForThreshold`.
    ///
    /// - Value: `1.0`
    ///
    /// TODO: calibrate from eval data. A linear 1 unit/token slope is a
    /// placeholder; per-term observed variance on the current eval set
    /// varies by ~3–5 units, so this formula under-compensates for longer
    /// phrases in practice (see `CustomDictionaryEvalTests` Checkbin
    /// expectation tiers).
    static let thresholdRelaxationPerToken: Float = 1.0

    /// Maximum total relaxation applied to any term regardless of token count.
    ///
    /// Without this cap a 13-token term gets `adjustedMinScore = -10 - 10×1.0 = -20.0`,
    /// which is below the normalized CTC score for random audio (~−8…−15) and causes
    /// long terms to match unconditionally. Capping at 4.0 keeps the floor at −14.0 so
    /// a genuine detection still needs to outscore random frames by a meaningful margin.
    ///
    /// - Value: `4.0`
    static let maxThresholdRelaxation: Float = 4.0
}
