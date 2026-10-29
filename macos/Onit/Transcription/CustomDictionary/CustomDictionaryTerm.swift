// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryTerm.swift
//  Onit
//
//  Vocabulary term for CTC biasing.
//

import Defaults
import Foundation

/// Calibration state for the NLL gate.
enum CalibrationState: String, Codable, Sendable {
    case uncalibrated   // no calibration data yet
    case calibrated     // threshold computed from examples
}

/// A single vocabulary term for keyword spotting.
struct CustomDictionaryTerm: Codable, Hashable, Sendable, Identifiable, Defaults.Serializable {
    /// Stable identity - survives rename operations and is decoupled from `text`.
    let id: UUID
    /// The word/phrase to boost (as typed by user). Mutable to support rename.
    var text: String
    /// When the user added this term - used for sort by Newest/Oldest.
    let createdAt: Date
    /// Pre-tokenized CTC token IDs. Populated transiently by the rescorer; not persisted.
    /// Default `nil` is required so the synthesized `init(from decoder:)` (which skips
    /// this property via the explicit `CodingKeys`) can still initialise the struct.
    var ctcTokenIds: [Int]? = nil

    /// Additional KWS keyword strings learned from user corrections (e.g. `["▁AUD IT"]`).
    /// Persisted so the KWS set grows over time without re-enrollment.
    var learnedKeywords: [String] = []

    /// Proxy word used for Llama NLL validation (e.g. "Safari" for "Arc").
    /// When non-nil, NLL(orig) vs NLL(orig_with_proxy) is compared at detection time.
    var proxyWord: String? = nil

    /// Per-term NLL delta-norm threshold. Escape hatch - leave nil to use
    /// `CustomDictionaryNLLGate.defaultThreshold` (currently 0.0, the static
    /// boundary validated by the production-derived `prod_*` cases in
    /// `NLLGateProxyThresholdEvalTests`). Enrollment no longer auto-populates
    /// this; only set explicitly if a term needs a non-default cutoff.
    var nllThreshold: Double? = nil

    /// Per-term Whisper KWS forced-decode threshold (mean log-prob over phrase tokens,
    /// max across sliding windows). Falls back to the service default when nil
    /// (Fernardo-class ≈ −5.96, Onit-class ≈ −7.00). Auto-calibrated from the user's
    /// accept/reject decisions during the history-scan step.
    var kwsThreshold: Double? = nil

    /// Pre-tokenized whisper-base BPE token IDs for this term (no decoder prefix -
    /// just the body tokens). Populated at term-add time via `WhisperBPETokenizer`
    /// and persisted so we don't re-tokenize on every detection call.
    var whisperTokenIds: [Int]? = nil

    /// User-curated common Parakeet mishearings of this term, e.g. for "Raudin"
    /// the user might list `["not in", "nodding"]`. At rescore time, an exact
    /// (case-insensitive) substring match against any entry triggers a synthetic
    /// detection that flows through the same replacement + NLL gate pipeline as
    /// the audio-based detections. Persisted across launches.
    var commonMistakes: [String] = []

    /// Whether this term has been through the calibration flow.
    var calibrationState: CalibrationState = .uncalibrated

    var textLowercased: String { text.lowercased() }

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        ctcTokenIds: [Int]? = nil,
        learnedKeywords: [String] = [],
        proxyWord: String? = nil,
        nllThreshold: Double? = nil,
        kwsThreshold: Double? = nil,
        whisperTokenIds: [Int]? = nil,
        commonMistakes: [String] = [],
        calibrationState: CalibrationState = .uncalibrated
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.ctcTokenIds = ctcTokenIds
        self.learnedKeywords = learnedKeywords
        self.proxyWord = proxyWord
        self.nllThreshold = nllThreshold
        self.kwsThreshold = kwsThreshold
        self.whisperTokenIds = whisperTokenIds
        self.commonMistakes = commonMistakes
        self.calibrationState = calibrationState
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, learnedKeywords, proxyWord, nllThreshold,
             kwsThreshold, whisperTokenIds, commonMistakes, calibrationState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        learnedKeywords = try c.decodeIfPresent([String].self, forKey: .learnedKeywords) ?? []
        proxyWord = try c.decodeIfPresent(String.self, forKey: .proxyWord)
        nllThreshold = try c.decodeIfPresent(Double.self, forKey: .nllThreshold)
        kwsThreshold = try c.decodeIfPresent(Double.self, forKey: .kwsThreshold)
        whisperTokenIds = try c.decodeIfPresent([Int].self, forKey: .whisperTokenIds)
        commonMistakes = try c.decodeIfPresent([String].self, forKey: .commonMistakes) ?? []
        calibrationState = try c.decodeIfPresent(CalibrationState.self, forKey: .calibrationState) ?? .uncalibrated
    }
}
