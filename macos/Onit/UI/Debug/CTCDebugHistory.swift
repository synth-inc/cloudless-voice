// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CTCDebugHistory.swift
//  Onit
//
//  In-memory ring buffer of CTC keyword-spotting results for the Perplexity Debug window.
//  Entries are appended by CustomDictionaryService after every rescore() call.
//

#if DEBUG

import Foundation

// MARK: - Per-term result

/// Detection result for a single dictionary term during one rescore() call.
struct CTCTermDebug: Identifiable {
    let id = UUID()

    let term: String
    let tokenCount: Int

    /// The effective minimum score that was required for this term.
    /// Accounts for token-count relaxation capped at `maxThresholdRelaxation`.
    let threshold: Float

    /// Best normalized CTC score from `ctcWordSpotConstrained` (global best, no floor).
    /// `nil` means no acoustic trace at all.
    let bestScore: Float?

    /// Whether `bestScore >= threshold` (acoustic gate passed).
    let passedThreshold: Bool

    /// Whether `ctcWordSpotMultiple` (the production-path algorithm) also fired above
    /// the threshold. When `passedThreshold` is true but `productionDetected` is false,
    /// the two algorithms disagree - this indicates a bug in `ctcWordSpotMultiple`.
    let productionDetected: Bool

    /// Whether this term was actually substituted in the transcript output.
    /// True iff the term text appears in `output` (as a normalized word) but not in `input`.
    let wasReplaced: Bool

    // MARK: - Convenience

    enum DetectionState {
        /// Term was substituted in the output - full pipeline success.
        case replaced
        /// Score cleared the threshold but no replacement occurred.
        /// Check `productionDetected` to distinguish algorithm mismatch from text-match failure.
        case acousticHit
        /// Score found but below threshold. Shows the gap so user knows how far to lower.
        case nearMiss(gap: Float)
        /// No acoustic signal at all - the word is phonetically absent from this audio.
        case noSignal
    }

    var detectionState: DetectionState {
        guard let score = bestScore else { return .noSignal }
        if wasReplaced { return .replaced }
        if passedThreshold { return .acousticHit }
        return .nearMiss(gap: threshold - score)  // positive = how far below threshold
    }

    /// The threshold value that WOULD have admitted this detection (== bestScore).
    /// Only relevant for .nearMiss entries so the user knows what to try.
    var thresholdNeeded: Float? {
        guard case .nearMiss = detectionState, let s = bestScore else { return nil }
        return s
    }
}

// MARK: - Entry

/// One debug entry per CustomDictionaryService.rescore() call.
struct CTCDebugEntry: Identifiable {
    let id = UUID()
    let date = Date()

    /// Original ASR transcript fed into rescore().
    let input: String

    /// Transcript after CTC rescoring (may equal input if nothing changed).
    let output: String

    let termDebug: [CTCTermDebug]
    let modelReady: Bool
    let dictionaryEnabled: Bool

    var anyApplied: Bool { input != output }
    var anyReplaced: Bool { termDebug.contains { $0.wasReplaced } }
    var anyDetected: Bool { termDebug.contains { $0.passedThreshold } }
    var anyAcousticHit: Bool { termDebug.contains { if case .acousticHit = $0.detectionState { return true }; return false } }
    var anyNearMiss: Bool { termDebug.contains { if case .nearMiss = $0.detectionState { return true }; return false } }
}

// MARK: - Singleton

@MainActor
final class CTCDebugHistory: ObservableObject {
    static let shared = CTCDebugHistory()
    @Published private(set) var entries: [CTCDebugEntry] = []
    private let maxEntries = 30
    private init() {}

    func record(_ entry: CTCDebugEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
    }
}

#endif
