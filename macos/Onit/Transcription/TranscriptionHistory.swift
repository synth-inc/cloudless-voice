// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionHistory.swift
//  Onit
//
//  Created for transcription history/playback feature.
//

import Foundation
import GRDB

/// Represents a saved transcription with its audio for history/playback.
struct TranscriptionHistory: Codable, Identifiable, Sendable, Equatable {

    /// Unique identifier (auto-incremented by the database)
    let id: Int64?
    
    /// The raw ASR output before any cleanup
    let rawTranscription: String

    /// The final transcription text (after any cleanup, and the rewrite when one ran)
    let cleanedTranscription: String

    /// What the Rewrite stage (the user's own model, Settings > Rewrite) was given and
    /// changed: the Smart Cleanup result, or the raw transcript when cleanup was off.
    /// This is the recognizer's output, so the row shows it with the cleanup diff and
    /// Review corrects it, not the model's prose. nil when nothing was rewritten.
    let rewriteSourceText: String?

    /// The model that produced `cleanedTranscription` from `rewriteSourceText`, as the
    /// user named it in Settings ("gemma3:1b"). nil when nothing was rewritten.
    let rewriteModel: String?

    /// The user's manually corrected transcription, if any
    let correctedTranscription: String?

    /// Filename of the associated audio file (stored in `transcription_history_audio/`)
    let audioFilename: String

    /// Duration of the audio in seconds
    let audioDuration: Double

    /// Name of the app where transcription was used
    let appName: String?

    /// Bundle ID of the app where transcription was used
    let appBundleId: String?

    /// The cleanup method used, if any (e.g., `smart_formatting`)
    /// nil if no cleanup was applied
    let cleanupMethod: String?

    /// Text that appeared before the cursor when transcription started
    let precedingText: String?

    /// Text that appeared after the cursor when transcription started
    let followingText: String?

    /// Whether the dictation landed in an email composer (`EmailComposer`).
    /// nil when it was not checked: rows older than v12, or the email layout was off.
    let inEmailComposer: Bool?

    /// JSON-encoded array of `CleanupLogEntry` dicts captured during the cleanup request.
    /// nil if cleanup was not attempted or the server returned no log.
    let cleanupLogEntries: String?

    /// Filename of a screenshot captured at dictation start (debug builds only).
    /// Stored in `transcription_history_screenshots/`. nil in release builds or if
    /// screen recording permission was unavailable at the time of capture.
    let screenshotFilename: String?

    /// JSON-encoded full-window AX context captured at dictation start (debug builds only).
    /// Contains the complete text content of the frontmost window from `AccessibilityParsingManager`.
    /// nil in release builds or if accessibility permission was unavailable.
    let windowContextSnapshot: String?

    /// The text after Auto-Edit rewriting (DEBUG/BETA builds only). nil if Auto-Edit was
    /// not enabled or produced no change.
    let autoEditText: String?

    /// The ASR glossary prompt staged for the model on this transcription (Qwen3/
    /// Granite prompt biasing), captured for debug/replay. nil when no biasing was
    /// applied (or in release, where it isn't captured).
    let asrPrompt: String?

    /// ASR model id that produced `rawTranscription` (e.g. "qwen3-asr-1.7b-4bit").
    let asrModel: String?

    /// Name of the audio file the user picked when this transcript came from a file
    /// (`FileTranscriptionService`). nil for a live dictation, including every pre-v13 row.
    let sourceFilename: String?

    /// User-driven review state. Defaults to `.unreviewed` for new and pre-v8 rows;
    /// the v8 migration backfills `.corrected` for rows that already had a manual correction.
    let reviewStatus: ReviewStatus

    /// Word count derived from `rawTranscription` at save time using Unicode word boundaries.
    let wordCount: Int?

    /// Wall-clock moment the user last engaged with this row as a review:
    /// either marking it `.reviewed` / `.corrected` for the first time,
    /// **or** editing the saved correction text on a row that was already
    /// `.corrected` (the edit re-stamps so the row counts as today's work).
    /// Cleared back to nil when the user reverts to `.unreviewed` or when a
    /// re-transcription resets the workflow state. Populated by the
    /// manager's update paths - never touched directly by callers. Powers
    /// the "+N today" badge in the review modal toolbar (counted via
    /// `reviewedAt` falling within the current calendar day).
    let reviewedAt: Date?

    /// Date when the transcription was created
    let timestamp: Date

    // MARK: - Computed Properties

    var isFromFile: Bool {
        sourceFilename != nil
    }

    /// Whether any cleanup was applied to this transcription
    var wasCleanupApplied: Bool {
        cleanupMethod != nil
    }

    /// What the recognizer produced after cleanup, before any rewrite. For a rewritten
    /// row `cleanedTranscription` is the model's text, so the source is used; rows
    /// rewritten before v14 have no source and fall back to `cleanedTranscription`.
    /// Corrections, correction pairs and training data are all about this text.
    var recognizerText: String {
        rewriteSourceText ?? cleanedTranscription
    }

    /// What Copy and "Paste last transcription" put back. A rewritten row gives what
    /// was pasted (the rewrite): `correctedTranscription` corrects the recognizer's
    /// text, so it would silently drop the rewrite. Other rows give the correction
    /// when there is one.
    var pastedText: String {
        rewriteSourceText != nil
            ? cleanedTranscription
            : (correctedTranscription ?? cleanedTranscription)
    }

    /// The (recognizer text, user correction) pair the custom dictionary learns from;
    /// nil when there is no correction or it equals the recognizer text.
    var correctionPair: CorrectionPair? {
        guard let corrected = correctedTranscription, corrected != recognizerText else { return nil }
        return CorrectionPair(raw: recognizerText, corrected: corrected)
    }

    /// Whether the cleanup changed the text
    var cleanupChangedText: Bool {
        cleanedTranscription != rawTranscription
    }

    /// Which cleanup changed the text, for the label on the row; nil when none did
    /// (no cleanup, LM conditioning only, or a cleanup that left the text as is).
    var cleanupRoute: CleanupRoute? {
        guard cleanupChangedText, let cleanupMethod else { return nil }
        if cleanupMethod.hasSuffix(CleanupMethods.smartFormattingAndBYOK) { return .smartCleanupAndYourModel }
        if cleanupMethod.hasSuffix(CleanupMethods.byok) { return .yourModel }
        if cleanupMethod.hasSuffix(CleanupMethods.smartFormatting) { return .smartCleanup }
        return nil
    }

    enum CleanupRoute: Equatable {
        /// On-device Smart Cleanup.
        case smartCleanup
        /// The user's own model (Rewrite) alone.
        case yourModel
        /// Smart Cleanup, then the user's own model (Rewrite).
        case smartCleanupAndYourModel
    }

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        rawTranscription: String,
        cleanedTranscription: String,
        correctedTranscription: String? = nil,
        rewriteSourceText: String? = nil,
        rewriteModel: String? = nil,
        audioFilename: String,
        audioDuration: Double,
        appName: String? = nil,
        appBundleId: String? = nil,
        cleanupMethod: String? = nil,
        precedingText: String? = nil,
        followingText: String? = nil,
        inEmailComposer: Bool? = nil,
        cleanupLogEntries: String? = nil,
        screenshotFilename: String? = nil,
        windowContextSnapshot: String? = nil,
        autoEditText: String? = nil,
        reviewStatus: ReviewStatus = .unreviewed,
        wordCount: Int? = nil,
        reviewedAt: Date? = nil,
        asrPrompt: String? = nil,
        asrModel: String? = nil,
        sourceFilename: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.rawTranscription = rawTranscription
        self.cleanedTranscription = cleanedTranscription
        self.correctedTranscription = correctedTranscription
        self.rewriteSourceText = rewriteSourceText
        self.rewriteModel = rewriteModel
        self.audioFilename = audioFilename
        self.audioDuration = audioDuration
        self.appName = appName
        self.appBundleId = appBundleId
        self.cleanupMethod = cleanupMethod
        self.precedingText = precedingText
        self.followingText = followingText
        self.inEmailComposer = inEmailComposer
        self.cleanupLogEntries = cleanupLogEntries
        self.screenshotFilename = screenshotFilename
        self.windowContextSnapshot = windowContextSnapshot
        self.autoEditText = autoEditText
        self.reviewStatus = reviewStatus
        self.wordCount = wordCount
        self.reviewedAt = reviewedAt
        self.asrPrompt = asrPrompt
        self.asrModel = asrModel
        self.sourceFilename = sourceFilename
        self.timestamp = timestamp
    }
}

// MARK: - ReviewStatus

extension TranscriptionHistory {
    /// User workflow state for a transcription, persisted in column `reviewStatus`.
    /// `.corrected` is set automatically when the user saves a manual correction.
    enum ReviewStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case unreviewed
        case reviewed
        case corrected
    }
}

extension TranscriptionHistory.ReviewStatus {
    /// Statuses a filter pill of this value should match against when
    /// querying the DB. The "Reviewed" filter in the UI is intentionally
    /// inclusive of `.corrected` - corrected rows are a strict subset of
    /// "rows the user has marked as reviewed", and surfacing them under
    /// the same pill matches the user's mental model. `.unreviewed` and
    /// `.corrected` keep their strict 1-to-1 mapping.
    var includedStatuses: [TranscriptionHistory.ReviewStatus] {
        switch self {
        case .reviewed:
            return [.reviewed, .corrected]
        case .unreviewed, .corrected:
            return [self]
        }
    }
}

// MARK: - CleanupLogEntry

/// A single structured log entry from the transcription cleanup pipeline.
struct CleanupLogEntry: Codable {
    let event: String
    let tsMs: Double?
    let reason: String?
    let textLength: Int?
    let totalDurationMs: Double?
    let replacements: Int?
    let kept: Int?
    let candidateCount: Int?
    let spanCount: Int?
    let error: String?
    /// Full scoring candidate data - only present on `debug_info_snapshot` entries.
    let debugInfo: CleanupDebugInfo?
    // Capitalization decision fields (present on `capitalization_decided` events).
    let winner: String?
    let choseLower: Bool?
    let upperScore: Double?
    let lowerScore: Double?
    let consumePunctScore: Double?
    let upperCandidate: String?
    let lowerCandidate: String?
    let consumePunctCandidate: String?

    enum CodingKeys: String, CodingKey {
        case event
        case tsMs = "ts_ms"
        case reason
        case textLength = "text_length"
        case totalDurationMs = "total_duration_ms"
        case replacements
        case kept
        case candidateCount = "candidate_count"
        case spanCount = "span_count"
        case error
        case debugInfo = "debug_info"
        case winner
        case choseLower = "chose_lower"
        case upperScore = "upper_score"
        case lowerScore = "lower_score"
        case consumePunctScore = "consume_punct_score"
        case upperCandidate = "upper_candidate"
        case lowerCandidate = "lower_candidate"
        case consumePunctCandidate = "consume_punct_candidate"
    }

    init(
        event: String,
        tsMs: Double? = nil,
        reason: String? = nil,
        textLength: Int? = nil,
        totalDurationMs: Double? = nil,
        replacements: Int? = nil,
        kept: Int? = nil,
        candidateCount: Int? = nil,
        spanCount: Int? = nil,
        error: String? = nil,
        debugInfo: CleanupDebugInfo? = nil,
        winner: String? = nil,
        choseLower: Bool? = nil,
        upperScore: Double? = nil,
        lowerScore: Double? = nil,
        consumePunctScore: Double? = nil,
        upperCandidate: String? = nil,
        lowerCandidate: String? = nil,
        consumePunctCandidate: String? = nil
    ) {
        self.event = event
        self.tsMs = tsMs
        self.reason = reason
        self.textLength = textLength
        self.totalDurationMs = totalDurationMs
        self.replacements = replacements
        self.kept = kept
        self.candidateCount = candidateCount
        self.spanCount = spanCount
        self.error = error
        self.debugInfo = debugInfo
        self.winner = winner
        self.choseLower = choseLower
        self.upperScore = upperScore
        self.lowerScore = lowerScore
        self.consumePunctScore = consumePunctScore
        self.upperCandidate = upperCandidate
        self.lowerCandidate = lowerCandidate
        self.consumePunctCandidate = consumePunctCandidate
    }
}

// MARK: - CleanupDebugInfo

/// Detailed scoring scoring debug data captured during cleanup.
struct CleanupDebugInfo: Codable {
    struct TokenScore: Codable {
        let t: String
        let score: Double?
    }
    struct Candidate: Codable {
        let rule_name: String
        let original: String
        let replacement: String
        let full_text: String?
        let tokens: [TokenScore]?
        let sum_score: Double?
    }
    struct Decision: Codable {
        let span_start: Int
        let span_end: Int
        let original_text: String
        let full_original_text: String?
        let original_tokens: [TokenScore]?
        let original_sum_score: Double?
        let candidates: [Candidate]
        let chosen_replacement: String?
        let chosen_rule: String?
        let kept_original: Bool
        let final_score: Double
    }
    struct VariantEval: Codable {
        let variant: [Int]
        let text: String
        let score: Double
        let choices: [Int]
        let is_original: Bool
        let tokens: [TokenScore]?
    }
    let input_text: String
    let final_output: String
    let decisions: [Decision]
    let variant_groups: [[VariantEval]]
    let num_kept: Int
    let num_reverted: Int
}

// MARK: - GRDB Extensions

extension TranscriptionHistory: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription_history"

    /// Live dictations only. For every feature about what the user dictated (last
    /// transcription, dictionary learning): a file transcript is someone's recording,
    /// not the user's dictation.
    static var dictations: QueryInterfaceRequest<TranscriptionHistory> {
        filter(Columns.sourceFilename == nil)
    }

    enum Columns: String, ColumnExpression {
        case id
        case rawTranscription
        case cleanedTranscription
        case correctedTranscription
        case audioFilename
        case audioDuration
        case appName
        case appBundleId
        case cleanupMethod
        case precedingText
        case followingText
        case inEmailComposer
        case cleanupLogEntries
        case screenshotFilename
        case windowContextSnapshot
        case autoEditText
        case reviewStatus
        case wordCount
        case reviewedAt
        case asrPrompt
        case asrModel
        case sourceFilename
        case rewriteSourceText
        case rewriteModel
        case timestamp
    }

    init(row: Row) throws {
        id = row[Columns.id]
        rawTranscription = row[Columns.rawTranscription]
        // Pre-v2-migration rows have the column named 'transcription'. Fall back so
        // old rows don't crash when the v2 migration hasn't run yet on this device.
        let cleanedOpt: String? = row["cleanedTranscription"]
        cleanedTranscription = cleanedOpt ?? (row["transcription"] as String?) ?? ""
        correctedTranscription = row[Columns.correctedTranscription]
        audioFilename = row[Columns.audioFilename]
        audioDuration = row[Columns.audioDuration]
        appName = row[Columns.appName]
        appBundleId = row[Columns.appBundleId]
        cleanupMethod = row[Columns.cleanupMethod]
        precedingText = row[Columns.precedingText]
        followingText = row[Columns.followingText]
        // Pre-v12 rows have no inEmailComposer column: nil, "not checked".
        inEmailComposer = row["inEmailComposer"]
        cleanupLogEntries = row[Columns.cleanupLogEntries]
        screenshotFilename = row[Columns.screenshotFilename]
        windowContextSnapshot = row[Columns.windowContextSnapshot]
        autoEditText = row[Columns.autoEditText]
        // Pre-v8 rows have no reviewStatus column; treat them as unreviewed.
        let rawStatus: String? = row["reviewStatus"]
        reviewStatus = rawStatus.flatMap(ReviewStatus.init(rawValue:)) ?? .unreviewed
        wordCount = row[Columns.wordCount]
        // Pre-v10 rows have no `reviewedAt` column - fall back to nil so a
        // legacy row's existing reviewStatus stays consistent without a
        // synthetic timestamp.
        reviewedAt = row["reviewedAt"]
        // Pre-v11 rows have no asrPrompt/asrModel columns - graceful nil.
        asrPrompt = row["asrPrompt"]
        asrModel = row["asrModel"]
        // Pre-v13 rows have no sourceFilename column: nil, a live dictation.
        sourceFilename = row["sourceFilename"]
        // Pre-v14 rows have no rewrite columns: nil, nothing was rewritten.
        rewriteSourceText = row["rewriteSourceText"]
        rewriteModel = row["rewriteModel"]
        timestamp = row[Columns.timestamp]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.rawTranscription] = rawTranscription
        container[Columns.cleanedTranscription] = cleanedTranscription
        container[Columns.correctedTranscription] = correctedTranscription
        container[Columns.audioFilename] = audioFilename
        container[Columns.audioDuration] = audioDuration
        container[Columns.appName] = appName
        container[Columns.appBundleId] = appBundleId
        container[Columns.cleanupMethod] = cleanupMethod
        container[Columns.precedingText] = precedingText
        container[Columns.followingText] = followingText
        container[Columns.inEmailComposer] = inEmailComposer
        container[Columns.cleanupLogEntries] = cleanupLogEntries
        container[Columns.screenshotFilename] = screenshotFilename
        container[Columns.windowContextSnapshot] = windowContextSnapshot
        container[Columns.autoEditText] = autoEditText
        container[Columns.reviewStatus] = reviewStatus
        container[Columns.wordCount] = wordCount
        container[Columns.reviewedAt] = reviewedAt
        container[Columns.asrPrompt] = asrPrompt
        container[Columns.asrModel] = asrModel
        container[Columns.sourceFilename] = sourceFilename
        container[Columns.rewriteSourceText] = rewriteSourceText
        container[Columns.rewriteModel] = rewriteModel
        container[Columns.timestamp] = timestamp
    }
}

// MARK: - Cleanup Method Constants

extension TranscriptionHistory {
    /// Known cleanup method identifiers
    struct CleanupMethods {
        /// LM conditioning: acoustic branching + Llama rescoring to fix homophones
        static let lmConditioning = "lm_conditioning"
        /// LM conditioning followed by smart formatting
        static let lmConditioningAndSmartFormatting = "lm_conditioning+smart_formatting"
        /// Smart formatting cleanup (scoring-based rules via Python server)
        static let smartFormatting = "smart_formatting"
        /// Rewrite by the user's own model (`BYOKCleanupProvider`), with cleanup off
        static let byok = "byok"
        /// LM conditioning followed by the user's own model
        static let lmConditioningAndBYOK = "lm_conditioning+byok"
        /// Smart formatting followed by the user's own model (Rewrite)
        static let smartFormattingAndBYOK = "smart_formatting+byok"
        /// LM conditioning, smart formatting, then the user's own model
        static let lmConditioningAndSmartFormattingAndBYOK = "lm_conditioning+smart_formatting+byok"

        /// The method to record for a transcript. `smartChanged`: the first stage
        /// (Smart Cleanup) actually ran and changed the text. `rewritten`: the
        /// rewrite stage (the user's own model) ran and changed the text again.
        /// Nil when neither changed it.
        static func method(
            smartChanged: Bool, rewritten: Bool, lmConditioningApplied: Bool = false
        ) -> String? {
            let route: String? = switch (smartChanged, rewritten) {
            case (true, true): smartFormattingAndBYOK
            case (true, false): smartFormatting
            case (false, true): byok
            case (false, false): nil
            }
            switch (lmConditioningApplied, route) {
            case (false, let route): return route
            case (true, nil): return lmConditioning
            case (true, .some(let route)): return lmConditioning + "+" + route
            }
        }
    }
}

// MARK: - Word Count

extension TranscriptionHistory {
    /// Counts words using Unicode word boundaries via `enumerateSubstrings(.byWords)`.
    ///
    /// **Why Unicode boundaries**: Simple whitespace-splitting works for English/French but breaks for CJK (Chinese, Japanese, Korean) languages (no spaces between words).
    /// `.byWords` uses ICU's word-segmentation rules and correctly handles English, French, Chinese, Japanese, Korean, Arabic, etc.
    static func wordCount(of text: String) -> Int {
        var count = 0
        
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .byWords
        ) { _, _, _, _ in
            count += 1
        }
        
        return count
    }
}
