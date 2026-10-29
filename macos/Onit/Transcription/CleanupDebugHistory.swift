// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupDebugHistory.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-14.
//
//  In-memory ring buffer of recent cleanup decisions for the Scoring Debug window.
//  Replaces PythonCleanupService.debugHistory which was removed with the Python server.
//  Entries are appended by TranscriptionManager after every cleanup call and consumed
//  by ScoringDebugView.
//

import Foundation
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

#if DEBUG || ONIT_BETA
struct CleanupDebugEntry: Identifiable {
    let id = UUID()
    let date: Date
    let info: CleanupDebugInfo
    let precedingText: String?
    let followingText: String?
    let logEntries: [CleanupLogEntry]?
    let deletePrecedingChars: Int?
    /// Preformatted decision report from the CleanupResult (cap/trailing
    /// punct/space winners, scores and candidates as opaque text).
    var debugReport: String? = nil
    /// True when the trailing-punct gate was skipped because the user's final
    /// dictated token was itself punctuation/symbol/formatting.
    var suppressedTrailingPunct: Bool = false
    /// Dictated trailing line break re-attached to preserve formatting (if any).
    var trailingFormattingSuffix: String? = nil
    /// Set after AutoEdit completes (may arrive later than the cleanup entry itself).
    var autoEditText: String? = nil
    /// The dictionary glossary prompt staged for the ASR model (Qwen3/Granite),
    /// captured from `ASRPromptContext`. nil when prompt-biasing was off/empty.
    var asrPrompt: String? = nil
    /// Layer C - terms mined from the on-screen OCR this session, the raw OCR
    /// blob, the per-token decision trace, the saved screenshot filename, and
    /// whether the OOV word-list loaded.
    var onScreenTerms: [String] = []
    var onScreenOCRText: String? = nil
    /// Where the mining text came from: "OCR (…)" or "Accessibility (…)".
    var onScreenSource: String? = nil
    var onScreenDecisions: [CapsTermSelector.Decision] = []
    var onScreenScreenshot: String? = nil
    var onScreenHasCommonList: Bool = true
    /// Layer-B format matcher: ASR text before/after dictionary-format restore,
    /// plus status so the Cleanup tab can always explain what the matcher did
    /// (or why it did nothing).
    var formatBefore: String? = nil
    var formatAfter: String? = nil
    var formatEnabled: Bool = false
    var formatTermCount: Int = 0
    /// "spoken span → Term" rows, one per replacement.
    var formatReplacements: [String] = []
    /// Merges the perplexity gate vetoed (kept as the natural phrase).
    var formatVetoed: [String] = []
}

@MainActor
final class CleanupDebugHistory: ObservableObject {

    static let shared = CleanupDebugHistory()

    @Published private(set) var debugHistory: [CleanupDebugEntry] = []
    private let maxHistoryCount = 20

    private init() {}

    /// Append an entry built from a Swift cleanup result. Keeps the most recent
    /// `maxHistoryCount` entries (newest first).
    func record(entry: CleanupDebugEntry) {
        debugHistory.insert(entry, at: 0)
        if debugHistory.count > maxHistoryCount {
            debugHistory = Array(debugHistory.prefix(maxHistoryCount))
        }
    }

    /// Patches the most recent entry with the AutoEdit output (called after AutoEdit completes).
    func setAutoEditText(_ text: String) {
        guard !debugHistory.isEmpty else { return }
        debugHistory[0].autoEditText = text
    }

    #if canImport(TranscriptionCleanup)
    /// Best-effort conversion from a library-level CleanupResult into the Python-shaped
    /// CleanupDebugInfo used by the debug view. Token-level Score breakdowns and variant
    /// evaluations are not plumbed from the Swift pipeline yet, so those fields are empty;
    /// decisions are populated from the slot-level choices.
    nonisolated static func makeDebugInfo(from result: CleanupResult) -> CleanupDebugInfo {
        let decisions: [CleanupDebugInfo.Decision] = (result.changes ?? []).map { c in
            CleanupDebugInfo.Decision(
                span_start: 0,
                span_end: c.originalText.count,
                original_text: c.originalText,
                full_original_text: nil,
                original_tokens: nil,
                original_sum_score: nil,
                candidates: [],
                chosen_replacement: c.replacement,
                chosen_rule: c.ruleName,
                kept_original: c.replacement == nil,
                final_score: 0
            )
        }
        let numKept = decisions.filter { !$0.kept_original }.count
        let numReverted = decisions.filter { $0.kept_original }.count
        return CleanupDebugInfo(
            input_text: result.inputText,
            final_output: result.finalOutput,
            decisions: decisions,
            variant_groups: [],
            num_kept: numKept,
            num_reverted: numReverted
        )
    }
    #endif
}
#endif
