// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionCorrection.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-01-24.
//

import Foundation
import GRDB

/// Represents a user correction to a transcription result.
/// Used to collect training data for improving transcription accuracy.
struct TranscriptionCorrection: Codable, Identifiable, Sendable, Equatable {

    /// Unique identifier (auto-incremented by the database)
    let id: Int64?

    /// Post-cleanup transcription that was shown to the user (after smart
    /// formatting). Kept under the legacy `originalTranscription` name in the
    /// local schema for UI compatibility - uploaded to Firestore as
    /// `cleanedTranscription`.
    let originalTranscription: String

    /// Raw ASR output, before any smart-formatting cleanup. Optional because
    /// older rows predate this column.
    let rawTranscription: String?

    /// Whether a user snippet expansion fired during the dictation this
    /// correction is derived from. Lets the training pipeline identify/filter
    /// snippet-affected pairs. Optional because older rows predate this column.
    let snippetExpanded: Bool?

    /// The corrected transcription from the user
    var correctedTranscription: String

    /// Filename of the associated audio file (stored in transcription_audio/)
    let audioFilename: String

    /// Text that appeared before the cursor when transcription started
    let precedingText: String?

    /// Text that appeared after the cursor when transcription started
    let followingText: String?

    /// Name of the app where transcription was used
    let appName: String?

    /// Bundle identifier of the app where transcription was used
    let appBundleId: String?

    /// id of the originating `transcription_history` row, when applicable.
    /// Used to dedupe corrections: re-editing the same history record
    /// updates the existing correction instead of creating a duplicate.
    let historyId: Int64?

    /// Reason for which this correction is excluded from the upload
    /// pipeline. `nil` means eligible. Decided at save time and (mostly)
    /// permanent. Cleared only by an explicit "Request fix" on this transcript.
    /// Values: see `ExclusionReason`.
    var excludedReason: String?

    /// Firebase UID of the user who was signed in at the moment the
    /// correction was saved. Keeps a row from being uploaded under another
    /// account on a shared Mac.
    let savedByAccountId: String?

    /// Date when the correction was saved
    let timestamp: Date

    // MARK: - Cloud sync state

    /// UUID assigned at the first cloud upload attempt and reused on retries
    /// so Storage path and Firestore docId stay stable (idempotent uploads).
    var cloudCorrectionId: String?

    /// Firebase UID under which this correction was uploaded. Used to skip
    /// retries if a different user is now signed in.
    var uploadedForAccountId: String?

    /// Set when the audio file has been pushed to Cloud Storage.
    var audioUploadedAt: Date?

    /// Set when the Firestore document has been written. Cleared by
    /// `TranscriptionCorrectionManager.update(_:)` so a local edit triggers
    /// a re-push.
    var firestoreUploadedAt: Date?

    /// Set the FIRST time both Storage + Firestore succeed for this row.
    /// Never cleared. Used to distinguish a first upload (which counts
    /// toward the contributions counter) from a re-upload after edit
    /// (which does not).
    var everUploadedAt: Date?

    /// Monotonic counter incremented on every local edit (`update(_:)`).
    /// The uploader captures this value at snapshot time and `markFirestoreUploaded`
    /// only stamps the row when the persisted version still matches - that way
    /// a stale upload that was racing a fresh edit can't suppress the next push.
    var editVersion: Int64

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        originalTranscription: String,
        rawTranscription: String? = nil,
        snippetExpanded: Bool? = nil,
        correctedTranscription: String,
        audioFilename: String,
        precedingText: String? = nil,
        followingText: String? = nil,
        appName: String? = nil,
        appBundleId: String? = nil,
        historyId: Int64? = nil,
        excludedReason: String? = nil,
        savedByAccountId: String? = nil,
        timestamp: Date = Date(),
        cloudCorrectionId: String? = nil,
        uploadedForAccountId: String? = nil,
        audioUploadedAt: Date? = nil,
        firestoreUploadedAt: Date? = nil,
        everUploadedAt: Date? = nil,
        editVersion: Int64 = 0
    ) {
        self.id = id
        self.originalTranscription = originalTranscription
        self.rawTranscription = rawTranscription
        self.snippetExpanded = snippetExpanded
        self.correctedTranscription = correctedTranscription
        self.audioFilename = audioFilename
        self.precedingText = precedingText
        self.followingText = followingText
        self.appName = appName
        self.appBundleId = appBundleId
        self.historyId = historyId
        self.excludedReason = excludedReason
        self.savedByAccountId = savedByAccountId
        self.timestamp = timestamp
        self.cloudCorrectionId = cloudCorrectionId
        self.uploadedForAccountId = uploadedForAccountId
        self.audioUploadedAt = audioUploadedAt
        self.firestoreUploadedAt = firestoreUploadedAt
        self.everUploadedAt = everUploadedAt
        self.editVersion = editVersion
    }
}

// MARK: - GRDB Extensions

extension TranscriptionCorrection: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcription_corrections"

    enum Columns: String, ColumnExpression {
        case id
        case originalTranscription
        case rawTranscription
        case snippetExpanded
        case correctedTranscription
        case audioFilename
        case precedingText
        case followingText
        case appName
        case appBundleId
        case historyId
        case excludedReason
        case savedByAccountId
        case timestamp
        case cloudCorrectionId
        case uploadedForAccountId
        case audioUploadedAt
        case firestoreUploadedAt
        case everUploadedAt
        case editVersion
    }

    init(row: Row) throws {
        id = row[Columns.id]
        originalTranscription = row[Columns.originalTranscription]
        rawTranscription = row[Columns.rawTranscription]
        snippetExpanded = row[Columns.snippetExpanded]
        correctedTranscription = row[Columns.correctedTranscription]
        audioFilename = row[Columns.audioFilename]
        precedingText = row[Columns.precedingText]
        followingText = row[Columns.followingText]
        appName = row[Columns.appName]
        appBundleId = row[Columns.appBundleId]
        historyId = row[Columns.historyId]
        excludedReason = row[Columns.excludedReason]
        savedByAccountId = row[Columns.savedByAccountId]
        timestamp = row[Columns.timestamp]
        cloudCorrectionId = row[Columns.cloudCorrectionId]
        uploadedForAccountId = row[Columns.uploadedForAccountId]
        audioUploadedAt = row[Columns.audioUploadedAt]
        firestoreUploadedAt = row[Columns.firestoreUploadedAt]
        everUploadedAt = row[Columns.everUploadedAt]
        editVersion = row[Columns.editVersion] ?? 0
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.originalTranscription] = originalTranscription
        container[Columns.rawTranscription] = rawTranscription
        container[Columns.snippetExpanded] = snippetExpanded
        container[Columns.correctedTranscription] = correctedTranscription
        container[Columns.audioFilename] = audioFilename
        container[Columns.precedingText] = precedingText
        container[Columns.followingText] = followingText
        container[Columns.appName] = appName
        container[Columns.appBundleId] = appBundleId
        container[Columns.historyId] = historyId
        container[Columns.excludedReason] = excludedReason
        container[Columns.savedByAccountId] = savedByAccountId
        container[Columns.timestamp] = timestamp
        container[Columns.cloudCorrectionId] = cloudCorrectionId
        container[Columns.uploadedForAccountId] = uploadedForAccountId
        container[Columns.audioUploadedAt] = audioUploadedAt
        container[Columns.firestoreUploadedAt] = firestoreUploadedAt
        container[Columns.everUploadedAt] = everUploadedAt
        container[Columns.editVersion] = editVersion
    }
}

// MARK: - Excluded reason values

extension TranscriptionCorrection {
    /// Discriminator values used in the `excludedReason` column. Kept as
    /// String constants (rather than an enum on the model) so the column
    /// stays a free-form `text` and we can add new reasons via migration
    /// without breaking existing rows.
    enum ExclusionReason {
        static let noEdit = "noEdit"
        static let paused = "paused"
        static let optOut = "optOut"
        /// Stamped at insert time when the audio capture pipeline returned
        /// no samples. Without this guard the row would sit in the pending
        /// queue forever - the uploader bails as soon as the audio file is
        /// missing, generating retry noise without recourse.
        static let missingAudio = "missingAudio"
        /// Stamped by the `v5_excludeUnconsentedLegacyRows` migration on rows that
        /// were saved before uploads required an explicit "Request fix" and never
        /// reached the cloud. They are uploaded only if the user requests a fix.
        static let legacyUnconsented = "legacyUnconsented"
    }
}
