// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionCorrectionManager.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-01-24.
//

import Defaults
import Foundation
import GRDB

/// Manages local storage of transcription corrections for training data collection.
/// Stores corrections in a SQLite database and audio files in Application Support.
final class TranscriptionCorrectionManager: ObservableObject, @unchecked Sendable {

    // MARK: - Singleton

    static let shared = TranscriptionCorrectionManager()

    // MARK: - Database

    private var dbQueue: DatabaseQueue?
    private let dbFile = "transcription_corrections.sqlite"
    private let audioDirectoryName = "transcription_audio"

    private var applicationSupportURL: URL? {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL.appendingPathComponent("Onit")
    }

    private var dbPath: String? {
        guard let onitURL = applicationSupportURL else { return nil }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: onitURL, withIntermediateDirectories: true)

        return onitURL.appendingPathComponent(dbFile).path
    }

    private var audioDirectoryURL: URL? {
        guard let onitURL = applicationSupportURL else { return nil }
        return onitURL.appendingPathComponent(audioDirectoryName)
    }

    // MARK: - Published

    @MainActor
    @Published var correctionsCount: Int = 0

    // MARK: - Initialization

    private init() {
        setupDatabase()
        setupAudioDirectory()
        Task {
            await updateCorrectionsCount()
        }
    }

    private func setupDatabase() {
        guard let dbPath = dbPath else {
            log.error("[TranscriptionCorrectionManager] Could not determine database path")
            return
        }

        do {
            let queue = try DatabaseQueue(path: dbPath)
            try Self.migrator.migrate(queue)
            dbQueue = queue
            log.info("[TranscriptionCorrectionManager] Database setup complete")
        } catch {
            log.error("[TranscriptionCorrectionManager] Database setup failed: \(error)")
        }
    }

    /// Schema migrations. Bootstraps from any of three pre-existing states:
    ///   1. Fresh install (no DB, no table) → `v1_initial` builds the full schema.
    ///   2. Legacy DB created before the migrator existed (table present, column
    ///      set varying with what the old `createTables` loop had run) →
    ///      `v1_initial`'s `IF NOT EXISTS` and column-level guards are no-ops
    ///      where state already matches.
    ///   3. DB upgraded across migrator-tracked versions → standard play-forward.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1: full current schema, idempotent against legacy pre-migrator DBs.
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: TranscriptionCorrection.databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("originalTranscription", .text).notNull()
                t.column("correctedTranscription", .text).notNull()
                t.column("audioFilename", .text).notNull()
                t.column("precedingText", .text)
                t.column("followingText", .text)
                t.column("appName", .text)
                t.column("timestamp", .datetime).notNull()
            }

            // Idempotent column adds - the table may pre-exist with any
            // subset of these from the old ad-hoc migration loop.
            let initialExtensions: [(name: String, type: Database.ColumnType, defaultLiteral: String?)] = [
                ("appBundleId", .text, nil),
                ("rawTranscription", .text, nil),
                ("historyId", .integer, nil),
                ("excludedReason", .text, nil),
                ("savedByAccountId", .text, nil),
                ("cloudCorrectionId", .text, nil),
                ("uploadedForAccountId", .text, nil),
                ("audioUploadedAt", .datetime, nil),
                ("firestoreUploadedAt", .datetime, nil),
                ("everUploadedAt", .datetime, nil),
                ("editVersion", .integer, "0"),
            ]
            let columns = Set(try db.columns(in: TranscriptionCorrection.databaseTableName).map { $0.name })
            for ext in initialExtensions where !columns.contains(ext.name) {
                let defaultClause = ext.defaultLiteral.map { " NOT NULL DEFAULT \($0)" } ?? ""
                try db.execute(sql: """
                    ALTER TABLE \(TranscriptionCorrection.databaseTableName)
                    ADD COLUMN \(ext.name) \(ext.type.rawValue)\(defaultClause)
                    """)
            }
        }

        // v2: backfill `cloudCorrectionId` for legacy rows so the uploader's
        // mint-at-insert invariant holds for every row in existence - closes
        // the original race where two concurrent uploads could each mint a
        // different UUID and orphan a Storage blob.
        migrator.registerMigration("v2_backfillCloudCorrectionIds") { db in
            let legacyIds = try Int64.fetchAll(
                db,
                sql: """
                SELECT id FROM \(TranscriptionCorrection.databaseTableName)
                WHERE cloudCorrectionId IS NULL
                """
            )
            for legacyId in legacyIds {
                let backfillId = UUID().uuidString.lowercased()
                try db.execute(
                    literal: """
                    UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                    SET cloudCorrectionId = \(backfillId)
                    WHERE id = \(legacyId) AND cloudCorrectionId IS NULL
                    """
                )
            }
            if !legacyIds.isEmpty {
                log.info("[TranscriptionCorrectionManager] Backfilled cloudCorrectionId for \(legacyIds.count) legacy row(s)")
            }
        }

        // v3: enforce the dedup-by-historyId invariant in the schema. The
        // partial WHERE clause is critical - full-row uniqueness on a
        // nullable column would treat every NULL as distinct in some
        // SQLite builds; here we bound the constraint to non-NULL ids so
        // historyless rows (e.g. dictation with history feature off) can
        // freely coexist.
        migrator.registerMigration("v3_uniqueHistoryIdIndex") { db in
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_corrections_unique_history
                ON \(TranscriptionCorrection.databaseTableName)(historyId)
                WHERE historyId IS NOT NULL
                """)
        }

        // v4: track whether a user snippet expansion fired during the dictation
        // this correction is derived from, so the training pipeline can filter
        // snippet-affected pairs. Stored as INTEGER (GRDB persists Bool as 0/1).
        migrator.registerMigration("v4_addSnippetExpanded") { db in
            let columns = Set(try db.columns(in: TranscriptionCorrection.databaseTableName).map { $0.name })
            if !columns.contains("snippetExpanded") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionCorrection.databaseTableName) ADD COLUMN snippetExpanded INTEGER")
            }
        }

        // v5: consent. Before the per-transcript "Request fix" agreement existed, rows
        // saved with no exclusion value were treated as eligible and were uploaded at
        // the next sign-in, without the user having asked. Stamp every such row that
        // has not reached the cloud so it is never uploaded implicitly. Only an explicit
        // "Request fix" (`markEligibleForUpload`) clears the stamp again. Rows created
        // after this migration are untouched: a NULL value now only means "requested".
        migrator.registerMigration("v5_excludeUnconsentedLegacyRows") { db in
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET excludedReason = \(TranscriptionCorrection.ExclusionReason.legacyUnconsented)
                WHERE excludedReason IS NULL AND firestoreUploadedAt IS NULL
                """
            )
            if db.changesCount > 0 {
                log.info("[TranscriptionCorrectionManager] Excluded \(db.changesCount) legacy row(s) from upload")
            }
        }

        return migrator
    }

    private func setupAudioDirectory() {
        guard let audioURL = audioDirectoryURL else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: audioURL, withIntermediateDirectories: true)
    }

    // MARK: - CRUD Operations

    /// Saves a transcription correction with its associated audio.
    ///
    /// `excludedReason` is resolved by the caller and passed in as-is here, with
    /// one exception: a no-edit save (original == corrected) is auto-stamped
    /// `noEdit` if the caller didn't already pick something more specific
    /// (e.g. `paused`). The opt-out vs eligible decision used to be inferred
    /// here from `Defaults`, but that read happened on a background actor and
    /// could observe a value the user had just toggled - callers now pass the
    /// snapshot they captured on the main actor before detaching.
    nonisolated func saveCorrection(
        originalTranscription: String,
        rawTranscription: String?,
        snippetExpanded: Bool? = nil,
        correctedTranscription: String,
        audioSamples: [Float]?,
        sampleRate: Int,
        precedingText: String?,
        followingText: String?,
        appName: String?,
        appBundleId: String?,
        historyId: Int64? = nil,
        excludedReason: String? = nil,
        savedByAccountId: String? = nil
    ) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }

        // Auto-stamp `noEdit` when the user didn't actually change anything
        // - keeps the noEdit detection in one place even though the rest of
        // the exclusion logic moved to the caller.
        var resolvedExcludedReason = excludedReason
        if resolvedExcludedReason == nil
            && originalTranscription == correctedTranscription {
            resolvedExcludedReason = TranscriptionCorrection.ExclusionReason.noEdit
        }

        // Dedup: if a correction already exists for this history record,
        // refresh ALL fields derived from the history row (raw + cleaned +
        // app metadata) before bumping the edit version. Re-transcribing the
        // history row between the original save and this edit changes those
        // fields underneath us - without this refresh, the cloud doc would
        // hold OLD raw/cleaned text alongside the user's NEW corrected text,
        // silently corrupting the training pair. The audio file isn't
        // touched (re-transcribe doesn't change the recording).
        //
        // Per EC7=A, "Mark as correct" (no-edit) on a row that already has a
        // real correction is a no-op - leave the previous correction intact.
        if let historyId, let existing = await fetchByHistoryId(historyId) {
            if resolvedExcludedReason == TranscriptionCorrection.ExclusionReason.noEdit {
                log.info("[TranscriptionCorrectionManager] No-edit on existing correction for historyId \(historyId), keeping it intact")
                return
            }
            try await applyEdit(
                id: existing.id!,
                correctedTranscription: correctedTranscription,
                originalTranscription: originalTranscription,
                rawTranscription: rawTranscription,
                appName: appName,
                appBundleId: appBundleId,
                excludedReason: resolvedExcludedReason
            )
            log.info("[TranscriptionCorrectionManager] Updated existing correction for historyId \(historyId) (excludedReason: \(resolvedExcludedReason ?? "eligible"))")
            return
        }

        // Audio is mandatory for the row to ever be useful. Stamp
        // `missingAudio` so the row is created (the user still sees their
        // edit reflected in the local DB) but is permanently excluded from
        // the upload pipeline rather than living in the pending queue
        // generating retry noise on every sign-in.
        let audioFilename = "correction_\(UUID().uuidString.lowercased()).wav"
        let hasAudio = (audioSamples?.isEmpty == false)
        if hasAudio {
            try saveAudioToWAV(samples: audioSamples!, sampleRate: sampleRate, filename: audioFilename)
            log.info("[TranscriptionCorrectionManager] Saved audio file: \(audioFilename) with \(audioSamples!.count) samples")
        } else {
            log.warning("[TranscriptionCorrectionManager] No audio samples for correction - stamping missingAudio")
            if resolvedExcludedReason == nil {
                resolvedExcludedReason = TranscriptionCorrection.ExclusionReason.missingAudio
            }
        }

        // Mint the cloud-side identifier upfront so the uploader never has to
        // race two concurrent attempts to assign one. With the id stamped at
        // insert time, every subsequent upload (initial save, retry, post-edit
        // re-push) shares the same Storage path / Firestore docId - uploads
        // are idempotent by construction, no orphan blobs.
        let cloudCorrectionId = UUID().uuidString.lowercased()

        let correction = TranscriptionCorrection(
            originalTranscription: originalTranscription,
            rawTranscription: rawTranscription,
            snippetExpanded: snippetExpanded,
            correctedTranscription: correctedTranscription,
            audioFilename: audioFilename,
            precedingText: precedingText,
            followingText: followingText,
            appName: appName,
            appBundleId: appBundleId,
            historyId: historyId,
            excludedReason: resolvedExcludedReason,
            savedByAccountId: savedByAccountId,
            timestamp: Date(),
            cloudCorrectionId: cloudCorrectionId
        )

        // `PersistableRecord.insert(_:)` is non-mutating, so the auto-incremented
        // id is not written back onto the local value. Read it from the
        // connection instead - `dbQueue.write` runs in a single transaction so
        // `lastInsertedRowID` is always the row we just wrote.
        let savedId: Int64 = try await dbQueue.write { db in
            try correction.insert(db)
            return db.lastInsertedRowID
        }

        await updateCorrectionsCount()
        log.info("[TranscriptionCorrectionManager] Saved correction: \(audioFilename) (id=\(savedId))")

        // Skip kicking the uploader for rows we already know are excluded -
        // it would just bail at the same gate, churning the actor's queue.
        guard resolvedExcludedReason == nil else { return }

        // Fire-and-forget the Firebase upload so the caller (e.g. the
        // review modal) doesn't block on a network round-trip before
        // advancing to the next transcript. Failures are picked up by
        // `retryPending()` on the next successful sign-in.
        Task.detached {
            await TranscriptionCorrectionFirebaseUploader.shared.upload(correctionId: savedId)
        }
    }

    /// Fetches a single correction by id, returning nil if it doesn't exist.
    nonisolated func fetchOne(id: Int64) async -> TranscriptionCorrection? {
        guard let dbQueue = dbQueue else { return nil }
        return try? await dbQueue.read { db in
            try TranscriptionCorrection.fetchOne(db, key: id)
        }
    }

    /// Fetches the correction tied to a given `transcription_history` row, if any.
    nonisolated func fetchByHistoryId(_ historyId: Int64) async -> TranscriptionCorrection? {
        guard let dbQueue = dbQueue else { return nil }
        return try? await dbQueue.read { db in
            try TranscriptionCorrection
                .filter(TranscriptionCorrection.Columns.historyId == historyId)
                .fetchOne(db)
        }
    }

    /// Fetches all corrections from the database
    /// - Returns: Array of all corrections, ordered by timestamp descending
    nonisolated func fetchAll() async -> [TranscriptionCorrection] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try await dbQueue.read { db in
                try TranscriptionCorrection
                    .order(TranscriptionCorrection.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            log.error("[TranscriptionCorrectionManager] fetchAll failed: \(error)")
            return []
        }
    }

    /// Fetches corrections with pagination
    /// - Parameters:
    ///   - limit: Maximum number of corrections to fetch
    ///   - offset: Number of corrections to skip
    /// - Returns: Array of corrections, ordered by timestamp descending
    nonisolated func fetchPaginated(limit: Int, offset: Int) async -> [TranscriptionCorrection] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try await dbQueue.read { db in
                try TranscriptionCorrection
                    .order(TranscriptionCorrection.Columns.timestamp.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            log.error("[TranscriptionCorrectionManager] fetchPaginated failed: \(error)")
            return []
        }
    }

    /// Updates an existing correction in the database, kept for the Settings
    /// UI which still hands back full structs. Forwards to `applyEdit(...)` so
    /// the same atomic write path is used everywhere - the editable surface is
    /// limited to `correctedTranscription` and `excludedReason`.
    /// - Parameter correction: The correction to update (must have a valid id)
    nonisolated func update(_ correction: TranscriptionCorrection) async throws {
        guard let id = correction.id else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        try await applyEdit(
            id: id,
            correctedTranscription: correction.correctedTranscription,
            originalTranscription: nil,
            rawTranscription: nil,
            appName: nil,
            appBundleId: nil,
            excludedReason: correction.excludedReason
        )
    }

    /// Applies a user edit to a correction atomically: refreshes the editable
    /// fields, bumps `editVersion`, clears `firestoreUploadedAt` so the
    /// uploader re-pushes, and triggers an immediate upload retry. The audio
    /// file is unchanged so we don't reset `audioUploadedAt`.
    ///
    /// `editVersion` is the linchpin of correctness: a stale upload that was
    /// in-flight when this edit landed will see a mismatched version when it
    /// tries to stamp `markFirestoreUploaded` and become a no-op, leaving the
    /// fresh re-upload free to succeed and stamp the new version.
    ///
    /// `originalTranscription`, `rawTranscription`, `appName`, `appBundleId`
    /// are optional refreshes - passed by the dedup save path to keep the
    /// correction in sync with the underlying history row after a
    /// re-transcription. The Settings UI edit path leaves them nil and only
    /// touches the corrected text + exclusion reason.
    nonisolated func applyEdit(
        id: Int64,
        correctedTranscription: String,
        originalTranscription: String?,
        rawTranscription: String?,
        appName: String?,
        appBundleId: String?,
        excludedReason: String?
    ) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        try await dbQueue.write { db in
            // Build the SET clause dynamically so a nil refresh field stays
            // untouched on disk (vs. being overwritten with NULL).
            var assignments: [String] = [
                "correctedTranscription = :correctedTranscription",
                "excludedReason = :excludedReason",
                "firestoreUploadedAt = NULL",
                "editVersion = editVersion + 1",
            ]
            var arguments: StatementArguments = [
                "correctedTranscription": correctedTranscription,
                "excludedReason": excludedReason,
                "id": id,
            ]
            if let originalTranscription {
                assignments.append("originalTranscription = :originalTranscription")
                arguments += ["originalTranscription": originalTranscription]
            }
            if let rawTranscription {
                assignments.append("rawTranscription = :rawTranscription")
                arguments += ["rawTranscription": rawTranscription]
            }
            if let appName {
                assignments.append("appName = :appName")
                arguments += ["appName": appName]
            }
            if let appBundleId {
                assignments.append("appBundleId = :appBundleId")
                arguments += ["appBundleId": appBundleId]
            }
            try db.execute(
                sql: """
                UPDATE \(TranscriptionCorrection.databaseTableName)
                SET \(assignments.joined(separator: ", "))
                WHERE id = :id
                """,
                arguments: arguments
            )
        }

        // Skip the upload kick when the row is already excluded - same
        // reasoning as in `saveCorrection(...)`.
        if excludedReason == nil {
            Task.detached {
                await TranscriptionCorrectionFirebaseUploader.shared.upload(correctionId: id)
            }
        }
    }

    // MARK: - Cloud sync helpers

    /// Atomically claims a correction for the given Firebase account at first
    /// upload. Idempotent: a row already claimed by another account is left
    /// alone, so the uploader's owner-mismatch guard fires correctly.
    /// Returns the account id the row belongs to after the call (the new
    /// claimant, or the pre-existing owner if any).
    nonisolated func claimForAccount(id: Int64, accountId: String) async throws -> String? {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        return try await dbQueue.write { db in
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET uploadedForAccountId = \(accountId)
                WHERE id = \(id) AND uploadedForAccountId IS NULL
                """
            )
            return try String.fetchOne(
                db,
                sql: """
                SELECT uploadedForAccountId FROM \(TranscriptionCorrection.databaseTableName)
                WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    /// Marks the audio file as uploaded to Cloud Storage. Single-flight: a
    /// concurrent caller that re-issues the write after another has already
    /// stamped it becomes a no-op rather than overwriting the timestamp.
    nonisolated func markAudioUploaded(id: Int64, at date: Date = Date()) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        try await dbQueue.write { db in
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET audioUploadedAt = \(date)
                WHERE id = \(id) AND audioUploadedAt IS NULL
                """
            )
        }
    }

    /// Marks the Firestore document as written, but only when the on-disk
    /// `editVersion` still matches the value the uploader captured at snapshot
    /// time. If a fresh `applyEdit(...)` bumped the version while the upload
    /// was in flight, this stamp is silently dropped - the post-edit re-upload
    /// will then run with current data instead of being suppressed.
    /// Returns true iff the stamp was applied.
    @discardableResult
    nonisolated func markFirestoreUploaded(
        id: Int64,
        expectedEditVersion: Int64,
        at date: Date = Date()
    ) async throws -> Bool {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        return try await dbQueue.write { db in
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET firestoreUploadedAt = \(date)
                WHERE id = \(id) AND editVersion = \(expectedEditVersion)
                """
            )
            return db.changesCount > 0
        }
    }

    /// Marks the row as having had its first successful upload (Storage +
    /// Firestore both written). Set once and never cleared, so a re-upload
    /// after a local edit doesn't re-trigger the contributions counter.
    /// Returns true iff this call actually stamped the row (vs. observing
    /// another caller had already stamped it). The caller uses the return
    /// value to decide whether to refresh the per-account contributions
    /// counter - the counter is now derived from SQL via
    /// `refreshContributionsCount`, no RMW on `Defaults` from background
    /// callers.
    @discardableResult
    nonisolated func markEverUploaded(id: Int64, at date: Date = Date()) async throws -> Bool {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        return try await dbQueue.write { db in
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET everUploadedAt = \(date)
                WHERE id = \(id) AND everUploadedAt IS NULL
                """
            )
            return db.changesCount > 0
        }
    }

    /// Recomputes the per-account contributions counter directly from SQL and
    /// writes it into `Defaults[.transcriptionContributionsByAccount]` on the
    /// main actor. The Defaults entry stays for SwiftUI binding ergonomics
    /// (`@Default` in the review end screen) but is no longer
    /// authoritative - the COUNT(*) query is the single source of truth and
    /// survives Defaults reset / cross-device sync hiccups.
    @MainActor
    func refreshContributionsCount(forAccountId accountId: String) async {
        guard let dbQueue = dbQueue else { return }
        do {
            let count = try await dbQueue.read { db -> Int in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM \(TranscriptionCorrection.databaseTableName)
                    WHERE everUploadedAt IS NOT NULL AND uploadedForAccountId = ?
                    """,
                    arguments: [accountId]
                ) ?? 0
            }
            var counts = Defaults[.transcriptionContributionsByAccount]
            counts[accountId] = count
            Defaults[.transcriptionContributionsByAccount] = counts
        } catch {
            log.error("[TranscriptionCorrectionManager] refreshContributionsCount failed: \(error)")
        }
    }

    /// Promotes the correction tied to the given `historyId` from any exclusion state back to upload-eligible (`excludedReason = NULL`) and kicks the Firebase uploader.
    /// Used by the review modal's Request fix / Save & request fix flow when the user explicitly opts in to sharing a specific correction that was previously saved as local-only.
    ///
    /// Distinct from `applyEdit(...)` in that it does NOT rewrite the corrected text or bump `editVersion` - a Request fix is a pure eligibility change, not an edit.
    nonisolated func markEligibleForUpload(historyId: Int64) async throws {
        guard let dbQueue = dbQueue else {
            throw TranscriptionCorrectionError.databaseNotInitialized
        }
        
        let correctionId: Int64? = try await dbQueue.write { db in
            let row = try TranscriptionCorrection
                .filter(TranscriptionCorrection.Columns.historyId == historyId)
                .fetchOne(db)
            
            guard let row,
                  let id = row.id
            else {
                return nil as Int64?
            }
            
            try db.execute(
                literal: """
                UPDATE \(sql: TranscriptionCorrection.databaseTableName)
                SET excludedReason = NULL
                WHERE id = \(id)
                """
            )
            
            return id
        }
        
        guard let correctionId else { return }
        
        Task.detached {
            await TranscriptionCorrectionFirebaseUploader.shared.upload(correctionId: correctionId)
        }
    }

    /// Returns corrections that still need to be uploaded for the given account.
    /// Either the audio or the Firestore document (or both) is missing, and the
    /// row was either never attempted or attempted under the same accountId.
    ///
    /// Account isolation: rows saved under a different signed-in user are
    /// excluded so that a shared Mac doesn't quietly route someone else's
    /// pending corrections to whichever account is currently logged in. Legacy
    /// rows from before `savedByAccountId` was introduced are still
    /// retroactively eligible (matched via `IS NULL`).
    nonisolated func fetchPendingUploads(forAccountId accountId: String) async -> [TranscriptionCorrection] {
        guard let dbQueue = dbQueue else { return [] }
        do {
            return try await dbQueue.read { db in
                try TranscriptionCorrection
                    .filter(
                        TranscriptionCorrection.Columns.audioUploadedAt == nil
                        || TranscriptionCorrection.Columns.firestoreUploadedAt == nil
                    )
                    .filter(
                        TranscriptionCorrection.Columns.uploadedForAccountId == nil
                        || TranscriptionCorrection.Columns.uploadedForAccountId == accountId
                    )
                    .filter(
                        TranscriptionCorrection.Columns.savedByAccountId == nil
                        || TranscriptionCorrection.Columns.savedByAccountId == accountId
                    )
                    .filter(TranscriptionCorrection.Columns.excludedReason == nil)
                    .order(TranscriptionCorrection.Columns.timestamp.asc)
                    .fetchAll(db)
            }
        } catch {
            log.error("[TranscriptionCorrectionManager] fetchPendingUploads failed: \(error)")
            return []
        }
    }

    /// Returns the URL for an audio file
    /// - Parameter correction: The correction whose audio file URL to get
    /// - Returns: URL to the audio file, or nil if not found
    nonisolated func audioFileURL(for correction: TranscriptionCorrection) -> URL? {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let audioURL = appSupportURL.appendingPathComponent("Onit").appendingPathComponent(audioDirectoryName)
        let fileURL = audioURL.appendingPathComponent(correction.audioFilename)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Loads audio samples from a correction's audio file
    /// - Parameter correction: The correction whose audio to load
    /// - Returns: Array of Float samples, or nil if loading failed
    nonisolated func loadAudioSamples(for correction: TranscriptionCorrection) -> [Float]? {
        guard let audioURL = audioDirectoryURL else { return nil }
        let fileURL = audioURL.appendingPathComponent(correction.audioFilename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)

            // Parse WAV header (skip first 44 bytes)
            guard data.count > 44 else { return nil }

            let audioData = data.dropFirst(44)
            let sampleCount = audioData.count / 2 // 16-bit samples

            var samples = [Float]()
            samples.reserveCapacity(sampleCount)

            audioData.withUnsafeBytes { buffer in
                let int16Buffer = buffer.bindMemory(to: Int16.self)
                for sample in int16Buffer {
                    samples.append(Float(sample) / Float(Int16.max))
                }
            }

            return samples
        } catch {
            log.error("[TranscriptionCorrectionManager] Failed to load audio: \(error)")
            return nil
        }
    }

    /// Deletes a correction and its associated audio file
    /// - Parameter id: The ID of the correction to delete
    nonisolated func delete(id: Int64) async throws {
        guard let dbQueue = dbQueue else { return }

        // First fetch the correction to get the audio filename
        let correction = try await dbQueue.read { db in
            try TranscriptionCorrection
                .filter(TranscriptionCorrection.Columns.id == id)
                .fetchOne(db)
        }

        // Delete the audio file if it exists
        if let correction = correction, let audioURL = audioDirectoryURL {
            let audioFileURL = audioURL.appendingPathComponent(correction.audioFilename)
            try? FileManager.default.removeItem(at: audioFileURL)
        }

        // Delete the database record
        try await dbQueue.write { db in
            try TranscriptionCorrection
                .filter(TranscriptionCorrection.Columns.id == id)
                .deleteAll(db)
        }

        await updateCorrectionsCount()
    }

    /// Cascade-deletes the correction(s) attached to the given history rows.
    /// Called by `TranscriptionHistoryManager` when it deletes history rows
    /// so we don't leave orphaned corrections (with stale historyId pointers,
    /// stale audio files, and stale cloud copies) behind.
    /// Returns the corrections that were removed, so the caller can also
    /// schedule the cloud-side delete of any rows that had been uploaded.
    @discardableResult
    nonisolated func cascadeDeleteCorrections(forHistoryIds historyIds: [Int64]) async -> [TranscriptionCorrection] {
        guard !historyIds.isEmpty, let dbQueue = dbQueue else { return [] }
        let removed: [TranscriptionCorrection]
        do {
            removed = try await dbQueue.write { db -> [TranscriptionCorrection] in
                let rows = try TranscriptionCorrection
                    .filter(historyIds.contains(TranscriptionCorrection.Columns.historyId))
                    .fetchAll(db)
                try TranscriptionCorrection
                    .filter(historyIds.contains(TranscriptionCorrection.Columns.historyId))
                    .deleteAll(db)
                return rows
            }
        } catch {
            log.error("[TranscriptionCorrectionManager] cascadeDeleteCorrections failed: \(error)")
            return []
        }

        if let audioURL = audioDirectoryURL {
            let fileManager = FileManager.default
            for row in removed {
                let audioFileURL = audioURL.appendingPathComponent(row.audioFilename)
                try? fileManager.removeItem(at: audioFileURL)
            }
        }

        if !removed.isEmpty {
            await updateCorrectionsCount()
            log.info("[TranscriptionCorrectionManager] Cascade-deleted \(removed.count) correction(s) for \(historyIds.count) history row(s)")
            // Best-effort cloud cleanup for the rows that had been uploaded.
            // Failures are silent - the row stays in the bucket as orphan
            // data until manually purged or until the per-user retention
            // policy kicks in (documented in TRANSCRIPTION_LLM.md).
            await TranscriptionCorrectionFirebaseUploader.shared.deleteUploaded(removed)
        }
        return removed
    }

    /// Deletes all corrections and their associated audio files
    nonisolated func clearAll() async {
        guard let dbQueue = dbQueue else { return }

        // Delete all audio files
        if let audioURL = audioDirectoryURL {
            let fileManager = FileManager.default
            if let files = try? fileManager.contentsOfDirectory(at: audioURL, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fileManager.removeItem(at: file)
                }
            }
        }

        // Delete all database records
        do {
            try await dbQueue.write { db in
                try TranscriptionCorrection.deleteAll(db)
            }
            await updateCorrectionsCount()
            log.info("[TranscriptionCorrectionManager] Cleared all corrections")
        } catch {
            log.error("[TranscriptionCorrectionManager] clearAll failed: \(error)")
        }
    }

    /// Exports all corrections to a zip file
    /// - Returns: URL to the created zip file (in temp directory)
    ///
    /// `precedingText` / `followingText` are deliberately NOT exported. They
    /// can contain arbitrary surrounding content from the user's target app
    /// (passwords, private messages, etc.) - already excluded from the cloud
    /// upload, and the local share-as-zip path needs the same treatment so a
    /// user accidentally sending the file to a colleague doesn't leak it.
    nonisolated func exportToZip() async throws -> URL {
        let corrections = await fetchAll()

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let exportDir = tempDir.appendingPathComponent("transcription_export_\(Int(Date().timeIntervalSince1970))")
        let audioExportDir = exportDir.appendingPathComponent("audio")

        // Create export directories
        try fileManager.createDirectory(at: audioExportDir, withIntermediateDirectories: true)

        // Copy audio files
        if let audioURL = audioDirectoryURL {
            for correction in corrections {
                let sourceURL = audioURL.appendingPathComponent(correction.audioFilename)
                let destURL = audioExportDir.appendingPathComponent(correction.audioFilename)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try? fileManager.copyItem(at: sourceURL, to: destURL)
                }
            }
        }

        // Create corrections.json
        let exportData = corrections.map { correction in
            ExportedCorrection(
                originalTranscription: correction.originalTranscription,
                correctedTranscription: correction.correctedTranscription,
                audioFilename: correction.audioFilename,
                appName: correction.appName,
                appBundleId: correction.appBundleId,
                timestamp: ISO8601DateFormatter().string(from: correction.timestamp)
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(exportData)
        let jsonURL = exportDir.appendingPathComponent("corrections.json")
        try jsonData.write(to: jsonURL)

        // Create zip file using ditto. Continuation pattern (vs. the
        // synchronous `waitUntilExit()`) keeps the calling Task cooperative
        // - the caller can be cancelled and we won't leave a zombie
        // ditto process holding the temp directory open.
        let zipURL = tempDir.appendingPathComponent("transcription_corrections_\(Int(Date().timeIntervalSince1970)).zip")

        let terminationStatus: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", exportDir.path, zipURL.path]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }

        guard terminationStatus == 0 else {
            throw TranscriptionCorrectionError.exportFailed
        }

        // Clean up export directory
        try? fileManager.removeItem(at: exportDir)

        log.info("[TranscriptionCorrectionManager] Exported \(corrections.count) corrections")
        return zipURL
    }

    // MARK: - Private Helpers

    @MainActor
    private func updateCorrectionsCount() async {
        guard let dbQueue = dbQueue else { return }

        do {
            let count = try await dbQueue.read { db in
                try TranscriptionCorrection.fetchCount(db)
            }
            self.correctionsCount = count
        } catch {
            log.error("[TranscriptionCorrectionManager] count failed: \(error)")
        }
    }

    /// Saves audio samples to a WAV file
    private func saveAudioToWAV(samples: [Float], sampleRate: Int, filename: String) throws {
        guard let audioURL = audioDirectoryURL else {
            throw TranscriptionCorrectionError.audioDirectoryNotFound
        }

        let fileURL = audioURL.appendingPathComponent(filename)

        // Convert Float samples to Int16
        var int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        // WAV header parameters
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // AudioFormat (PCM)
        header.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Write file
        var fileData = header
        int16Samples.withUnsafeBytes { buffer in
            fileData.append(contentsOf: buffer)
        }

        try fileData.write(to: fileURL)
    }
}

// MARK: - Errors

enum TranscriptionCorrectionError: Error, LocalizedError {
    case databaseNotInitialized
    case audioDirectoryNotFound
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Database not initialized"
        case .audioDirectoryNotFound:
            return "Audio directory not found"
        case .exportFailed:
            return "Failed to create export zip file"
        }
    }
}

// MARK: - Export Model

private struct ExportedCorrection: Codable {
    let originalTranscription: String
    let correctedTranscription: String
    let audioFilename: String
    let appName: String?
    let appBundleId: String?
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case originalTranscription = "original_transcription"
        case correctedTranscription = "corrected_transcription"
        case audioFilename = "audio_filename"
        case appName = "app_name"
        case appBundleId = "app_bundle_id"
        case timestamp
    }
}
