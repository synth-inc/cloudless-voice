// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionHistoryManager.swift
//  Onit
//
//  Created for transcription history/playback feature.
//

import Combine
import CoreGraphics
import Defaults
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

// MARK: - Lifetime Transcription Stats

/// Aggregate lifetime stats computed from `transcription_history`.
///
/// All members reflect the union of completed transcriptions on the local device.
/// The `nil` published value on `TranscriptionHistoryManager.lifetimeStats` means the stats haven't been computed yet (manager just initialized, or the underlying query failed).
struct LifetimeTranscriptionStats: Equatable, Sendable {
    /// Sum of non-nil `wordCount` across all transcription rows.
    let totalWords: Int

    /// Sum of `audioDuration` across all transcription rows. Reflects "time spent dictating".
    let totalDictationSeconds: Double

    /// Count of distinct non-NULL `appBundleId` values across all transcription rows.
    let distinctAppsUsedCount: Int

    /// Weighted lifetime WPM: `totalWords / totalDictationMinutes`.
    ///
    /// Weighted-by-duration (rather than per-session arithmetic mean) prevents short sessions from skewing the average.
    /// For example:
    ///     * **Session 1**: 200 words in 60 seconds
    ///     * **Session 2**: 5 words in 1 second
    ///     * **Total**: 205 words in 61 seconds → 61/60 ≈ 1.017 minutes
    ///     * **averageWPM** = 205 / 1.017 ≈ 201.6 WPM
    var averageWPM: Double {
        guard totalDictationSeconds > 0 else { return 0 }
        return Double(totalWords) / (totalDictationSeconds / 60.0)
    }
    
    /// 45 WPM is the midpoint of the commonly-cited 40-50 average adult range.
    static let averageAdultWPM: Int = 45
    static let wordCountUnlockThreshold: Int = 100

    /// Estimated seconds saved versus typing the same word count at the supplied `typingSpeedWPM`.
    ///
    /// Formula: `(totalWords / typingWPM) * 60 - totalDictationSeconds`
    /// Clamped to 0 so users who somehow dictate slower than their assumed typing speed don't see a negative number.
    func timeSavedSeconds(typingSpeedWPM: Int) -> Double {
        guard typingSpeedWPM > 0 else { return 0 }
        let typingSeconds = (Double(totalWords) / Double(typingSpeedWPM)) * 60.0
        return max(0, typingSeconds - totalDictationSeconds)
    }

    /// The most appropriate unit tier for displaying "Time Saved", given the user's current totals.
    ///
    /// Picks the largest unit that yields a meaningful (≥ 1) value so the UI never shows an uninformative "0.0 h" when the user actually saved several minutes or seconds.
    /// Hours and minutes are kept as `Double` (the views format with one decimal place).
    /// Seconds are returned as `Int` since fractional seconds aren't meaningful here.
    enum TimeSavedDisplay: Equatable, Sendable {
        case hours(Double)
        case minutes(Double)
        case seconds(Int)
    }

    /// Returns the appropriate `TimeSavedDisplay` tier for the user's lifetime totals at the given typing-speed assumption.
    /// Threshold ladder:
    ///   * `seconds >= 3600` → `.hours`
    ///   * `60 <= seconds < 3600` → `.minutes`
    ///   * `seconds < 60` → `.seconds`
    func timeSavedDisplay(typingSpeedWPM: Int = Self.averageAdultWPM) -> TimeSavedDisplay {
        let seconds = timeSavedSeconds(typingSpeedWPM: typingSpeedWPM)
        if seconds >= 3600 {
            return .hours(seconds / 3600)
        } else if seconds >= 60 {
            return .minutes(seconds / 60)
        } else {
            return .seconds(Int(seconds.rounded()))
        }
    }
}

// MARK: - Transcription History Manager

/// Manages local storage of transcription history for playback.
/// Stores all transcriptions in a SQLite database and audio files in Application Support.
final class TranscriptionHistoryManager: ObservableObject, @unchecked Sendable {

    // MARK: - Types

    enum SortOrder {
        case newest
        case oldest
        case audioDuration
        case appName
    }

    // MARK: - Singleton

    @MainActor
    static let shared = TranscriptionHistoryManager()

    // MARK: - Database

    private var dbQueue: DatabaseQueue?
    private let dbFile = "transcription_history.sqlite"
    private let audioDirectoryName = "transcription_history_audio"
    private let screenshotDirectoryName = "transcription_history_screenshots"

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

    var screenshotDirectoryURL: URL? {
        guard let onitURL = applicationSupportURL else { return nil }
        return onitURL.appendingPathComponent(screenshotDirectoryName)
    }

    // MARK: - Published

    @MainActor
    @Published var historyCount: Int = 0

    /// Number of items whose `reviewStatus == .corrected`. Driven by `updateCounts()`.
    @MainActor
    @Published var correctedCount: Int = 0

    /// Number of items whose `reviewStatus != .unreviewed` (i.e. `.reviewed` + `.corrected`).
    /// Drives the "X reviewed (Y%)" counter in the review modal toolbar.
    @MainActor
    @Published var reviewedCount: Int = 0

    /// Number of items reviewed/corrected within the current calendar day.
    /// Drives the "+N today" badge in the review modal toolbar. Recomputed
    /// from `reviewedAt` falling within `[startOfToday, startOfTomorrow)` on
    /// every `updateCounts()` call - naturally decrements on revert (since
    /// reverting clears `reviewedAt`) without any side-channel counter to
    /// keep in sync.
    @MainActor
    @Published var reviewedTodayCount: Int = 0

    /// The most recent live dictation. File transcripts are left out on purpose: every
    /// "last transcription" feature (copy, paste, correct and teach, menu bar preview)
    /// acts on what the user just dictated.
    @MainActor
    @Published var mostRecentTranscription: TranscriptionHistory? = nil

    /// The file transcript saved last. Lists observe it next to `mostRecentTranscription`,
    /// which never carries file transcripts. Cleared when that row is deleted, so no
    /// observer can re-insert a row that is gone.
    @MainActor
    @Published var lastFileTranscript: TranscriptionHistory? = nil

    /// Corrected rows a backtest could actually replay (dictations). The banner offers
    /// the test from this, not from `correctedCount`, which counts file rows too.
    @MainActor
    @Published var replayableCorrectedCount: Int = 0

    @MainActor
    @Published var lifetimeStats: LifetimeTranscriptionStats? = nil

    /// Fires after a row is updated (correctedTranscription, reviewStatus, etc.).
    /// Observed by list views (`AppHome`, `AppWindowPages`) so they can refresh
    /// the affected row without waiting for the user to navigate away and back.
    /// Carries the post-update row so the consumer can splice it into its
    /// snapshot via `refreshHistoryItem(_:)`. Set on every successful update,
    /// so equality on the whole `TranscriptionHistory` struct (e.g. updated
    /// `reviewedAt`) reliably fires `.onChange`.
    @MainActor
    @Published var recentlyUpdatedRow: TranscriptionHistory? = nil

    /// Wakes up at the next local midnight and re-runs `updateCounts()` so the
    /// "+N today" badge resets across day boundaries. Without this the counter
    /// stays frozen at yesterday's value until the user happens to do something
    /// that triggers a recount.
    @MainActor
    private var midnightRefreshTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        setupDatabase()
        setupAudioDirectory()
        setupScreenshotDirectory()
        Task { @MainActor in
            try? await updateCounts()
            await pruneOldDebugSnapshots()
            scheduleMidnightRefresh()
        }
        Task {
            /// Background task that ensures that legacy transcriptions have their `wordCount` property filled.
            /// `wordCount` is required to calculate the user's lifetime Dictation stats.
            await backfillWordCounts()
            /// Recompute counts once the backfill is done so that any stat depending on `wordCount` reflects the freshly populated rows.
            /// For example, `LifetimeTranscriptionStats.totalWords`.
            try? await updateCounts()
        }

        observeTranscriptionEnabled()
        observeTranscriptionHistoryEnabled()
    }

    /// Sleeps until the next local-midnight boundary, recomputes counts, then
    /// re-arms itself. Cooperative cancellation via `Task.sleep` so the task
    /// dies cleanly if the manager is ever torn down.
    @MainActor
    private func scheduleMidnightRefresh() {
        midnightRefreshTask?.cancel()
        midnightRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let calendar = Calendar.current
                let now = Date()
                guard let nextMidnight = calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: 0, minute: 0, second: 0),
                    matchingPolicy: .strict
                ) else { return }
                // Add a 1s buffer so the recount happens just after the
                // boundary, not racing it on slow clocks.
                let interval = nextMidnight.timeIntervalSince(now) + 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
                } catch {
                    return
                }
                try? await self?.updateCounts()
            }
        }
    }

    private func setupDatabase() {
        guard let dbPath = dbPath else {
            log.error("[TranscriptionHistoryManager] Could not determine database path")
            return
        }

        do {
            dbQueue = try DatabaseQueue(path: dbPath)

            try Self.migrator.migrate(dbQueue!)

            log.info("[TranscriptionHistoryManager] Database setup complete")
        } catch {
            log.error("[TranscriptionHistoryManager] Database setup failed: \(error)")
        }
    }

    /// Static so tests can migrate an in-memory database without the singleton.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTable") { db in
            try db.create(table: TranscriptionHistory.databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("transcription", .text).notNull()
                t.column("rawTranscription", .text).notNull()
                t.column("audioFilename", .text).notNull()
                t.column("audioDuration", .double).notNull()
                t.column("appName", .text)
                t.column("appBundleId", .text)
                t.column("cleanupMethod", .text)
                t.column("timestamp", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_renameAndAddColumns") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            let columnNames = Set(columns.map { $0.name })

            // Rename only if the old column exists and the new one doesn't yet.
            // (Some DBs were created before the migration system and may already
            // have the correct schema, which caused this migration to fail and
            // block all subsequent migrations.)
            if columnNames.contains("transcription") && !columnNames.contains("cleanedTranscription") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) RENAME COLUMN transcription TO cleanedTranscription"
                )
            }

            if !columnNames.contains("correctedTranscription") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN correctedTranscription TEXT"
                )
            }
        }

        migrator.registerMigration("v3_addContextColumns") { db in
            try db.execute(
                sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN precedingText TEXT"
            )
            try db.execute(
                sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN followingText TEXT"
            )
        }

        migrator.registerMigration("v4_addCleanupLogEntries") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("cleanupLogEntries") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN cleanupLogEntries TEXT"
                )
            }
        }

        migrator.registerMigration("v5_addScreenshotFilename") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("screenshotFilename") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN screenshotFilename TEXT"
                )
            }
        }

        migrator.registerMigration("v6_addWindowContextSnapshot") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("windowContextSnapshot") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN windowContextSnapshot TEXT"
                )
            }
        }

        migrator.registerMigration("v7_addAutoEditText") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("autoEditText") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN autoEditText TEXT"
                )
            }
        }

        migrator.registerMigration("v8_addReviewStatus") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            guard !Set(columns.map { $0.name }).contains("reviewStatus") else { return }

            try db.execute(
                sql: """
                    ALTER TABLE \(TranscriptionHistory.databaseTableName)
                    ADD COLUMN reviewStatus TEXT NOT NULL DEFAULT 'unreviewed'
                """
            )
            // SQLite's DEFAULT applies to existing rows, but we still need to backfill
            // the workflow status for rows that already had a manual correction.
            try db.execute(
                sql: """
                    UPDATE \(TranscriptionHistory.databaseTableName)
                    SET reviewStatus = 'corrected'
                    WHERE correctedTranscription IS NOT NULL
                """
            )
        }

        migrator.registerMigration("v9_addWordCount") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("wordCount") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN wordCount INTEGER"
                )
            }
        }

        // Tracks when each row was last marked reviewed/corrected so the
        // toolbar's "+N today" badge can be derived from the DB instead of a
        // separately-maintained Defaults counter (which was prone to drift on
        // revert and across day rollovers). Existing rows stay NULL - no
        // synthetic backfill, since we don't know when prior reviews happened.
        // The "today" count therefore starts fresh on first launch after the
        // migration; future reviews populate it normally.
        migrator.registerMigration("v10_addReviewedAt") { db in
            let columns = try db.columns(in: TranscriptionHistory.databaseTableName)
            if !Set(columns.map { $0.name }).contains("reviewedAt") {
                try db.execute(
                    sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN reviewedAt DATETIME"
                )
            }
        }

        // The ASR glossary prompt and the model id that produced the transcript -
        // so a dictation can be replayed against a new prompt/model offline.
        migrator.registerMigration("v11_addASRPromptAndModel") { db in
            let columns = Set(try db.columns(in: TranscriptionHistory.databaseTableName).map { $0.name })
            if !columns.contains("asrPrompt") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN asrPrompt TEXT")
            }
            if !columns.contains("asrModel") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN asrModel TEXT")
            }
        }

        migrator.registerMigration("v12_addInEmailComposer") { db in
            let columns = Set(try db.columns(in: TranscriptionHistory.databaseTableName).map { $0.name })
            if !columns.contains("inEmailComposer") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN inEmailComposer BOOLEAN")
            }
        }

        migrator.registerMigration("v13_addSourceFilename") { db in
            let columns = Set(try db.columns(in: TranscriptionHistory.databaseTableName).map { $0.name })
            if !columns.contains("sourceFilename") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN sourceFilename TEXT")
            }
        }

        // The Rewrite stage: what the model was given, and which model.
        migrator.registerMigration("v14_addRewriteColumns") { db in
            let columns = Set(try db.columns(in: TranscriptionHistory.databaseTableName).map { $0.name })
            if !columns.contains("rewriteSourceText") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN rewriteSourceText TEXT")
            }
            if !columns.contains("rewriteModel") {
                try db.execute(sql: "ALTER TABLE \(TranscriptionHistory.databaseTableName) ADD COLUMN rewriteModel TEXT")
            }
        }

        return migrator
    }

    private func setupAudioDirectory() {
        guard let audioURL = audioDirectoryURL else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: audioURL, withIntermediateDirectories: true)
    }

    private func setupScreenshotDirectory() {
        guard let screenshotURL = screenshotDirectoryURL else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: screenshotURL, withIntermediateDirectories: true)
    }
    
    // MARK: - Observers
    
    private var cancellables = Set<AnyCancellable>()
    
    private func observeTranscriptionEnabled() {
        Defaults.publisher(.transcriptionEnabled)
            .removeDuplicates()
            .sink { _ in
                Task { @MainActor in
                    await TranscriptionHistoryManager.shared.refreshMostRecentTranscription()
                }
            }
            .store(in: &cancellables)
    }

    private func observeTranscriptionHistoryEnabled() {
        Defaults.publisher(.transcriptionHistoryEnabled)
            .removeDuplicates()
            .sink { _ in
                Task { @MainActor in
                    await TranscriptionHistoryManager.shared.refreshMostRecentTranscription()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Most Recent Transcription

    private func refreshMostRecentTranscription() async {
        guard Defaults[.transcriptionEnabled],
              Defaults[.transcriptionHistoryEnabled]
        else {
            await MainActor.run {
                self.mostRecentTranscription = nil
            }
            return
        }

        guard let dbQueue = dbQueue
        else {
            await MainActor.run {
                self.mostRecentTranscription = nil
            }
            return
        }

        do {
            let mostRecentTranscription = try await dbQueue.read { db in
                try TranscriptionHistory.dictations
                    .order(TranscriptionHistory.Columns.timestamp.desc)
                    .limit(1)
                    .fetchOne(db)
            }
            await MainActor.run {
                self.mostRecentTranscription = mostRecentTranscription
            }
            // Every delete path lands here: drop the published file transcript once its
            // row is gone, so no observer can re-insert it into a list.
            if let fileId = await MainActor.run(resultType: Int64?.self, body: { self.lastFileTranscript?.id }),
               await fetch(id: fileId) == nil {
                await MainActor.run { self.lastFileTranscript = nil }
            }
        } catch {
            log.error("[TranscriptionHistoryManager] refreshMostRecentTranscription() failed: \(error)")
        }
    }

    // MARK: - Save Operations

    /// Saves a transcription with its associated audio to history
    /// - Parameters:
    ///   - rawTranscription: The raw ASR output (before any cleanup)
    ///   - cleanedTranscription: The final transcription text (after any cleanup)
    ///   - audioSamples: Raw audio samples (mono, Float, 16kHz)
    ///   - sampleRate: Sample rate of the audio (typically 16000)
    ///   - appName: Name of the app where transcription was used
    ///   - appBundleId: Bundle ID of the app
    ///   - cleanupMethod: The cleanup method used (e.g., "smart_formatting"), or nil if none
    /// - Returns: The ID of the newly created history record
    @discardableResult
    nonisolated func saveTranscription(
        rawTranscription: String,
        cleanedTranscription: String,
        audioSamples: [Float]?,
        sampleRate: Int,
        appName: String?,
        appBundleId: String?,
        cleanupMethod: String?,
        cleanupLogEntries: String? = nil,
        precedingText: String? = nil,
        followingText: String? = nil,
        inEmailComposer: Bool? = nil,
        screenshotFilename: String? = nil,
        windowContextSnapshot: String? = nil,
        autoEditText: String? = nil,
        asrPrompt: String? = nil,
        asrModel: String? = nil,
        sourceFilename: String? = nil,
        rewriteSourceText: String? = nil,
        rewriteModel: String? = nil
    ) async throws -> Int64 {
        guard let dbQueue = dbQueue else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        // Generate unique filename
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let audioFilename = "history_\(timestamp).wav"

        // Calculate audio duration
        let audioDuration: Double
        if let samples = audioSamples, !samples.isEmpty {
            audioDuration = Double(samples.count) / Double(sampleRate)
        } else {
            audioDuration = 0
        }

        // Save audio file
        if let samples = audioSamples, !samples.isEmpty {
            try saveAudioToWAV(samples: samples, sampleRate: sampleRate, filename: audioFilename)
            log.info("[TranscriptionHistoryManager] Saved audio file: \(audioFilename) (\(String(format: "%.1f", audioDuration))s)")
        } else {
            log.warning("[TranscriptionHistoryManager] No audio samples to save")
        }

        // Create and save the history record
        let history = TranscriptionHistory(
            rawTranscription: rawTranscription,
            cleanedTranscription: cleanedTranscription,
            rewriteSourceText: rewriteSourceText,
            rewriteModel: rewriteModel,
            audioFilename: audioFilename,
            audioDuration: audioDuration,
            appName: appName,
            appBundleId: appBundleId,
            cleanupMethod: cleanupMethod,
            precedingText: precedingText,
            followingText: followingText,
            inEmailComposer: inEmailComposer,
            cleanupLogEntries: cleanupLogEntries,
            screenshotFilename: screenshotFilename,
            windowContextSnapshot: windowContextSnapshot,
            autoEditText: autoEditText,
            wordCount: TranscriptionHistory.wordCount(of: rawTranscription),
            asrPrompt: asrPrompt,
            asrModel: asrModel,
            sourceFilename: sourceFilename,
            timestamp: Date()
        )

        let insertedId = try await dbQueue.write { db -> Int64 in
            try history.insert(db)
            return db.lastInsertedRowID
        }

        try? await updateCounts()
        if sourceFilename != nil {
            if let saved = await fetch(id: insertedId) {
                await MainActor.run { self.lastFileTranscript = saved }
            }
        } else {
            await refreshMostRecentTranscription()
        }
        log.info("[TranscriptionHistoryManager] Saved transcription to history (\(LogPrivacy.summary(cleanedTranscription)))")

        return insertedId
    }

    /// Patches the autoEditText field on an existing history record (called after AutoEdit completes).
    nonisolated func updateAutoEditText(_ text: String, for id: Int64) async throws {
        guard let dbQueue else { throw TranscriptionHistoryError.databaseNotInitialized }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE \(TranscriptionHistory.databaseTableName) SET autoEditText = ? WHERE id = ?",
                arguments: [text, id]
            )
        }
    }

    // MARK: - Fetch Operations

    /// Fetches all history items from the database
    /// - Returns: Array of all history items, ordered by timestamp descending
    nonisolated func fetchAll() async -> [TranscriptionHistory] {
        guard let dbQueue = dbQueue else { return [] }

        do {
            return try await dbQueue.read { db in
                try TranscriptionHistory
                    .order(TranscriptionHistory.Columns.timestamp.desc)
                    .fetchAll(db)
            }
        } catch {
            log.error("[TranscriptionHistoryManager] fetchAll failed: \(error)")
            return []
        }
    }

    /// Fetches history items with pagination
    /// - Parameters:
    ///   - limit: Maximum number of items to fetch
    ///   - offset: Number of items to skip
    ///   - searchQuery: Optional text to search for in cleanedTranscription or correctedTranscription
    ///   - sortOrder: The sort order to apply to the results
    ///   - reviewStatus: When non-nil, restrict results to items in this workflow state
    /// - Returns: Array of history items in the specified sort order
    nonisolated func fetchPaginated(
        limit: Int,
        offset: Int,
        searchQuery: String? = nil,
        sortOrder: SortOrder = .newest,
        reviewStatus: TranscriptionHistory.ReviewStatus? = nil
    ) async -> [TranscriptionHistory] {
        guard let dbQueue = dbQueue else { return [] }

        let baseRequest = Self.orderedRequest(sortOrder: sortOrder)

        do {
            return try await dbQueue.read { db in
                var request = baseRequest

                if let reviewStatus {
                    let allowedStatuses = reviewStatus.includedStatuses.map(\.rawValue)
                    request = request.filter(allowedStatuses.contains(TranscriptionHistory.Columns.reviewStatus))
                }

                if let query = searchQuery,
                   !query.isEmpty
                {
                    let pattern = "%\(query)%"
                    request = request.filter(
                        TranscriptionHistory.Columns.cleanedTranscription.like(pattern) ||
                        TranscriptionHistory.Columns.correctedTranscription.like(pattern)
                    )
                }

                return try request
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
        } catch {
            log.error("[TranscriptionHistoryManager] fetchPaginated failed: \(error)")
            return []
        }
    }

    /// Fetches the total count of history items matching the given filters
    /// - Parameters:
    ///   - searchQuery: Optional text to search for in cleanedTranscription or correctedTranscription
    ///   - reviewStatus: When non-nil, restrict count to items in this workflow state
    /// - Returns: The number of matching history items
    nonisolated func fetchFilteredCount(
        searchQuery: String? = nil,
        reviewStatus: TranscriptionHistory.ReviewStatus? = nil
    ) async -> Int {
        guard let dbQueue = dbQueue else { return 0 }

        do {
            return try await dbQueue.read { db in
                var request = TranscriptionHistory.all()

                if let reviewStatus {
                    let allowedStatuses = reviewStatus.includedStatuses.map(\.rawValue)
                    request = request.filter(allowedStatuses.contains(TranscriptionHistory.Columns.reviewStatus))
                }

                if let query = searchQuery,
                   !query.isEmpty
                {
                    let pattern = "%\(query)%"
                    request = request.filter(
                        TranscriptionHistory.Columns.cleanedTranscription.like(pattern) ||
                        TranscriptionHistory.Columns.correctedTranscription.like(pattern)
                    )
                }

                return try request.fetchCount(db)
            }
        } catch {
            log.error("[TranscriptionHistoryManager] fetchFilteredCount failed: \(error)")
            return 0
        }
    }

    /// Fetches a single history item by ID
    nonisolated func fetch(id: Int64) async -> TranscriptionHistory? {
        guard let dbQueue = dbQueue else { return nil }

        do {
            return try await dbQueue.read { db in
                try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.id == id)
                    .fetchOne(db)
            }
        } catch {
            log.error("[TranscriptionHistoryManager] fetch(id:) failed: \(error)")
            return nil
        }
    }

    // MARK: - Screenshot Operations

    /// Returns the URL for a screenshot file, or nil if not present.
    nonisolated func screenshotFileURL(for history: TranscriptionHistory) -> URL? {
        guard let filename = history.screenshotFilename,
              let screenshotURL = screenshotDirectoryURL else { return nil }
        let fileURL = screenshotURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Saves a CGImage as a PNG into the screenshots directory.
    /// - Returns: The filename (not full path) on success, nil on failure.
    nonisolated func saveScreenshot(_ image: CGImage, filename: String) -> String? {
        guard let screenshotURL = screenshotDirectoryURL else { return nil }
        let fileURL = screenshotURL.appendingPathComponent(filename)
        let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        guard let dest else {
            log.warning("[TranscriptionHistoryManager] Could not create image destination for \(filename)")
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            log.warning("[TranscriptionHistoryManager] Could not write screenshot \(filename)")
            return nil
        }
        return filename
    }

    /// Caps the Layer C debug screenshots (`layerc_*.png`, one per dictation in
    /// DEBUG/BETA) to the most recent `keepLatest`. They're referenced nowhere
    /// in the database, so without this they accumulate without bound.
    nonisolated func pruneLayerCScreenshots(keepLatest: Int) {
        guard let dir = screenshotDirectoryURL else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        // Timestamped names sort chronologically.
        let layerC = files.filter { $0.hasPrefix("layerc_") }.sorted()
        guard layerC.count > keepLatest else { return }
        for name in layerC.dropLast(keepLatest) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Audio Operations

    /// Returns the URL for an audio file
    /// - Parameter history: The history item whose audio file URL to get
    /// - Returns: URL to the audio file, or nil if not found
    nonisolated func audioFileURL(for history: TranscriptionHistory) -> URL? {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let audioURL = appSupportURL.appendingPathComponent("Onit").appendingPathComponent(audioDirectoryName)
        let fileURL = audioURL.appendingPathComponent(history.audioFilename)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Loads audio samples from a history item's audio file
    /// - Parameter history: The history item whose audio to load
    /// - Returns: Array of Float samples, or nil if loading failed
    nonisolated func loadAudioSamples(for history: TranscriptionHistory) -> [Float]? {
        guard let audioURL = audioDirectoryURL else { return nil }
        let fileURL = audioURL.appendingPathComponent(history.audioFilename)

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
            log.error("[TranscriptionHistoryManager] Failed to load audio: \(error)")
            return nil
        }
    }

    // MARK: - Update Operations

    /// Updates a history item with correction data and optional context fields.
    /// Saving a non-nil correction automatically flips `reviewStatus` to `.corrected`,
    /// since `reviewStatus` is the source of truth for the workflow state.
    /// - Parameters:
    ///   - id: The ID of the history item to update
    ///   - correctedTranscription: The user's manually corrected transcription text
    ///   - precedingText: Text that appeared before the cursor when transcription started
    ///   - followingText: Text that appeared after the cursor when transcription started
    /// - Returns: The updated history item, or nil if not found
    @discardableResult
    nonisolated func update(
        id: Int64,
        correctedTranscription: String?,
        precedingText: String? = nil,
        followingText: String? = nil
    ) async throws -> TranscriptionHistory? {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        let updatedItem = try await dbQueue.write { db -> TranscriptionHistory? in
            // When a correction is saved, also promote the workflow status to `.corrected`
            // and stamp `reviewedAt` so the row counts toward today's review tally.
            // When the correction is being cleared (nil), leave reviewStatus AND
            // reviewedAt untouched - the user can still demote it manually via
            // updateReviewStatus(id:status:), which is where reviewedAt gets cleared.
            // The two SQL paths keep the reviewStatus value bound as a parameter
            // rather than string-interpolated into the statement.
            if correctedTranscription != nil {
                try db.execute(
                    sql: """
                        UPDATE \(TranscriptionHistory.databaseTableName)
                        SET correctedTranscription = ?,
                            precedingText = COALESCE(?, precedingText),
                            followingText = COALESCE(?, followingText),
                            reviewStatus = ?,
                            reviewedAt = ?
                        WHERE id = ?
                    """,
                    arguments: [
                        correctedTranscription,
                        precedingText,
                        followingText,
                        TranscriptionHistory.ReviewStatus.corrected.rawValue,
                        Date(),
                        id
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE \(TranscriptionHistory.databaseTableName)
                        SET correctedTranscription = ?,
                            precedingText = COALESCE(?, precedingText),
                            followingText = COALESCE(?, followingText)
                        WHERE id = ?
                    """,
                    arguments: [correctedTranscription, precedingText, followingText, id]
                )
            }

            return try TranscriptionHistory
                .filter(TranscriptionHistory.Columns.id == id)
                .fetchOne(db)
        }

        try? await updateCounts()
        await refreshMostRecentTranscription()
        log.info("[TranscriptionHistoryManager] Updated correction data for id: \(id)")
        if let updatedItem {
            await MainActor.run { self.recentlyUpdatedRow = updatedItem }
        }
        return updatedItem
    }

    /// Replaces the raw + cleaned text on an existing history record (used by
    /// the "Re-transcribe" action). The audio file, app metadata and timestamp
    /// are preserved.
    ///
    /// Because a re-transcription represents a fresh result starting from the
    /// audio, any prior manual correction is dropped and `reviewStatus` is
    /// reset to `.unreviewed` - otherwise the row would keep displaying the
    /// stale correction (priority over `cleanedTranscription`) and stay tagged
    /// as "corrected".
    @discardableResult
    nonisolated func updateTranscription(
        id: Int64,
        rawTranscription: String,
        cleanedTranscription: String,
        cleanupMethod: String? = nil,
        cleanupLogEntries: String? = nil,
        rewriteSourceText: String? = nil,
        rewriteModel: String? = nil
    ) async throws -> TranscriptionHistory? {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        let newWordCount = TranscriptionHistory.wordCount(of: rawTranscription)

        let updatedItem = try await dbQueue.write { db -> TranscriptionHistory? in
            try db.execute(
                sql: """
                    UPDATE \(TranscriptionHistory.databaseTableName)
                    SET rawTranscription = ?,
                        wordCount = ?,
                        cleanedTranscription = ?,
                        correctedTranscription = NULL,
                        reviewStatus = ?,
                        reviewedAt = NULL,
                        cleanupMethod = ?,
                        cleanupLogEntries = ?,
                        rewriteSourceText = ?,
                        rewriteModel = ?
                    WHERE id = ?
                """,
                arguments: [
                    rawTranscription,
                    newWordCount,
                    cleanedTranscription,
                    TranscriptionHistory.ReviewStatus.unreviewed.rawValue,
                    cleanupMethod,
                    cleanupLogEntries,
                    rewriteSourceText,
                    rewriteModel,
                    id
                ]
            )
            return try TranscriptionHistory
                .filter(TranscriptionHistory.Columns.id == id)
                .fetchOne(db)
        }

        try? await updateCounts()
        log.info("[TranscriptionHistoryManager] Re-transcribed id: \(id) - correctedTranscription cleared, reviewStatus reset to unreviewed, wordCount=\(newWordCount)")
        return updatedItem
    }

    /// Updates only the workflow status of a history item.
    /// Use this when transitioning between `.unreviewed` ↔ `.reviewed` (the user marking
    /// an item as reviewed without editing it). Saving a correction goes through `update(...)`.
    @discardableResult
    nonisolated func updateReviewStatus(
        id: Int64,
        status: TranscriptionHistory.ReviewStatus
    ) async throws -> TranscriptionHistory? {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        // `reviewedAt` is the source of truth for "today's reviews". Stamp it
        // when the row is moving INTO a reviewed/corrected state and clear it
        // on revert - the read path filters by date range over this column.
        let reviewedAt: Date? = (status == .unreviewed) ? nil : Date()

        let updatedItem = try await dbQueue.write { db -> TranscriptionHistory? in
            try db.execute(
                sql: """
                    UPDATE \(TranscriptionHistory.databaseTableName)
                    SET reviewStatus = ?,
                        reviewedAt = ?
                    WHERE id = ?
                """,
                arguments: [status.rawValue, reviewedAt, id]
            )
            return try TranscriptionHistory
                .filter(TranscriptionHistory.Columns.id == id)
                .fetchOne(db)
        }

        try? await updateCounts()
        log.info("[TranscriptionHistoryManager] Updated reviewStatus to \(status.rawValue) for id: \(id)")
        if let updatedItem {
            await MainActor.run { self.recentlyUpdatedRow = updatedItem }
        }
        return updatedItem
    }

    /// Fetches all (cleanedTranscription, correctedTranscription) pairs for suggestion detection.
    ///
    /// Only returns items where the user actually edited the text
    /// (i.e. correctedTranscription is present and differs from cleanedTranscription).
    /// Returns a named `CorrectionPair: Sendable` struct instead of a raw
    /// tuple so the result can cross the actor boundary to
    /// `CustomDictionaryService` (and any future off-main detection) under
    /// Swift 6 strict concurrency without per-call-site annotation.
    nonisolated func fetchAllCorrectionPairs() async -> [CorrectionPair] {
        guard let dbQueue = dbQueue else { return [] }
        do {
            return try await dbQueue.read { db in
                // Dictations only: the dictionary learns from how the user dictates, and
                // the word-level LCS below is quadratic (a 30 min file is ~5000 words).
                try TranscriptionHistory.dictations
                    .filter(TranscriptionHistory.Columns.correctedTranscription != nil)
                    .fetchAll(db)
                    .compactMap { $0.correctionPair }
            }
        } catch {
            log.error("[TranscriptionHistoryManager] fetchAllCorrectionPairs failed: \(error)")
            return []
        }
    }

    // MARK: - Delete Operations

    /// Deletes a history item and its associated audio file
    /// - Parameter id: The ID of the history item to delete
    nonisolated func delete(id: Int64) async throws {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        do {
            // Fetch and delete in a single transaction to avoid TOCTOU race.
            let historyItem = try await dbQueue.write { db -> TranscriptionHistory? in
                let item = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.id == id)
                    .fetchOne(db)
                try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.id == id)
                    .deleteAll(db)
                return item
            }

            // Delete the audio file if it exists.
            if let item = historyItem,
               let audioURL = audioDirectoryURL
            {
                let audioFileURL = audioURL.appendingPathComponent(item.audioFilename)
                try? FileManager.default.removeItem(at: audioFileURL)
            }
        } catch {
            throw TranscriptionHistoryError.deleteFailed(underlying: error)
        }

        // Cascade-delete the matching correction(s) so we don't leave
        // orphan audio + cloud copies pointing at a history row that no
        // longer exists.
        await TranscriptionCorrectionManager.shared.cascadeDeleteCorrections(forHistoryIds: [id])

        try? await updateCounts()
        await refreshMostRecentTranscription()
    }

    /// Deletes all history items and their associated audio files
    nonisolated func deleteAll() async throws {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        let allHistoryIds: [Int64]
        do {
            // Snapshot the ids so the cascade can target the matching
            // corrections with the same scope as the history wipe.
            allHistoryIds = try await dbQueue.read { db in
                try Int64.fetchAll(db, sql: "SELECT id FROM \(TranscriptionHistory.databaseTableName)")
            }

            // Delete database records.
            try await dbQueue.write { db in
                try TranscriptionHistory.deleteAll(db)
            }

            // Delete all audio files.
            if let audioURL = audioDirectoryURL {
                let fileManager = FileManager.default
                if let files = try? fileManager.contentsOfDirectory(at: audioURL, includingPropertiesForKeys: nil) {
                    for file in files {
                        try? fileManager.removeItem(at: file)
                    }
                }
            }

            log.info("[TranscriptionHistoryManager] Deleted all history")
        } catch {
            log.error("[TranscriptionHistoryManager] deleteAll failed: \(error)")
            throw TranscriptionHistoryError.deleteAllFailed(underlying: error)
        }

        await TranscriptionCorrectionManager.shared.cascadeDeleteCorrections(forHistoryIds: allHistoryIds)

        try? await updateCounts()
        await refreshMostRecentTranscription()
    }

    /// Deletes all history items in the `.corrected` workflow state and their associated audio files.
    /// Source of truth for "corrected" is the `reviewStatus` column (post-v8 migration).
    nonisolated func deleteAllCorrected() async throws {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        let deletedHistoryIds: [Int64]
        do {
            // Fetch and delete in a single transaction to avoid TOCTOU race.
            let deletedItems = try await dbQueue.write { db -> [TranscriptionHistory] in
                let items = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.reviewStatus == TranscriptionHistory.ReviewStatus.corrected.rawValue)
                    .fetchAll(db)
                try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.reviewStatus == TranscriptionHistory.ReviewStatus.corrected.rawValue)
                    .deleteAll(db)
                return items
            }
            deletedHistoryIds = deletedItems.compactMap { $0.id }

            // Delete audio files associated with corrected history items.
            if let audioURL = audioDirectoryURL {
                let fileManager = FileManager.default
                for correctedItem in deletedItems {
                    let audioFileURL = audioURL.appendingPathComponent(correctedItem.audioFilename)
                    try? fileManager.removeItem(at: audioFileURL)
                }
            }

            log.info("[TranscriptionHistoryManager] Deleted all corrected history items")
        } catch {
            log.error("[TranscriptionHistoryManager] deleteAllCorrected failed: \(error)")
            throw TranscriptionHistoryError.deleteAllCorrectedFailed(underlying: error)
        }

        await TranscriptionCorrectionManager.shared.cascadeDeleteCorrections(forHistoryIds: deletedHistoryIds)

        try? await updateCounts()
        await refreshMostRecentTranscription()
    }

    // MARK: - Maintenance

    /// Idempotent, batched backfill that fills `wordCount` for legacy transcription rows where it is `NULL`.
    /// `wordCount` is required to calculate the user's lifetime Dictation stats.
    ///
    /// Resumable across crashes and quits.
    ///     Each iteration's predicate is `wordCount IS NULL`, so an interrupted run is naturally picked up on the next launch - no checkpoint state to track.
    /// Yields between batches so cancellation propagates cleanly and other DB writers aren't starved.
    nonisolated func backfillWordCounts() async {
        guard let dbQueue = dbQueue else { return }

        let batchSize = 100
        var totalUpdated = 0

        while !Task.isCancelled {
            do {
                let nullWordCountBatch = try await dbQueue.read { db in
                    try TranscriptionHistory
                        .filter(sql: "wordCount IS NULL")
                        .limit(batchSize)
                        .fetchAll(db)
                }

                guard !nullWordCountBatch.isEmpty
                else {
                    if totalUpdated > 0 {
                        log.info("[TranscriptionHistoryManager] wordCount backfill complete (\(totalUpdated) rows)")
                    }
                    return
                }

                try await dbQueue.write { db in
                    for transcriptionRow in nullWordCountBatch {
                        guard let transcriptionId = transcriptionRow.id else { continue }
                        let wordCount = TranscriptionHistory.wordCount(of: transcriptionRow.rawTranscription)
                        try db.execute(
                            sql: "UPDATE \(TranscriptionHistory.databaseTableName) SET wordCount = ? WHERE id = ?",
                            arguments: [wordCount, transcriptionId]
                        )
                    }
                }

                totalUpdated += nullWordCountBatch.count
                await Task.yield()
            } catch {
                log.error("[TranscriptionHistoryManager] backfillWordCounts failed: \(error)")
                return
            }
        }
    }

    /// Strips `debug_info_snapshot` log entries from transcripts older than 30 days.
    /// The snapshot contains large score arrays useful for debugging but not worth keeping forever.
    nonisolated func pruneOldDebugSnapshots() async {
        guard let dbQueue = dbQueue else { return }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)

        do {
            // Fetch and update inside a single write transaction to avoid a race where a concurrent
            // correction save could overwrite an interim cleanupLogEntries value between transactions.
            let pruneCount = try await dbQueue.write { db -> Int in
                // Window AX context is a debug capture of whatever was on screen
                // (mail, messages, a password manager's notes field) and nothing
                // reads it back. Drop it on the same 30-day window as the rest.
                try db.execute(
                    sql: """
                        UPDATE \(TranscriptionHistory.databaseTableName)
                        SET windowContextSnapshot = NULL
                        WHERE windowContextSnapshot IS NOT NULL AND timestamp < ?
                        """,
                    arguments: [cutoff]
                )

                let candidates = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.timestamp < cutoff)
                    .filter(sql: "cleanupLogEntries LIKE '%\"debug_info_snapshot\"%'")
                    .fetchAll(db)

                var count = 0
                for item in candidates {
                    guard let id = item.id,
                          let json = item.cleanupLogEntries,
                          let data = json.data(using: .utf8)
                    else { continue }

                    guard let entries = try? JSONDecoder().decode([CleanupLogEntry].self, from: data) else {
                        // Malformed JSON - nil-out the column so it is excluded from future runs.
                        try db.execute(
                            sql: "UPDATE \(TranscriptionHistory.databaseTableName) SET cleanupLogEntries = NULL WHERE id = ?",
                            arguments: [id]
                        )
                        continue
                    }

                    let pruned = entries.filter { $0.event != "debug_info_snapshot" }
                    guard pruned.count < entries.count else { continue }

                    let prunedJSON: String?
                    if pruned.isEmpty {
                        prunedJSON = nil
                    } else if let prunedData = try? JSONEncoder().encode(pruned),
                              let s = String(data: prunedData, encoding: .utf8) {
                        prunedJSON = s
                    } else {
                        continue
                    }
                    try db.execute(
                        sql: "UPDATE \(TranscriptionHistory.databaseTableName) SET cleanupLogEntries = ? WHERE id = ?",
                        arguments: [prunedJSON, id]
                    )
                    count += 1
                }
                return count
            }

            guard pruneCount > 0 else { return }
            log.info("[TranscriptionHistoryManager] Pruned debug snapshots from \(pruneCount) entries older than 30 days")
        } catch {
            log.error("[TranscriptionHistoryManager] pruneOldDebugSnapshots failed: \(error)")
        }
    }

    // MARK: - Export Operations

    /// Exports all corrected history items to a zip file
    /// - Returns: URL to the created zip file (in temp directory)
    nonisolated func exportCorrectedToZip() async throws -> URL {
        guard let dbQueue = dbQueue else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        let correctedHistoryItems = try await dbQueue.read { db in
            try TranscriptionHistory
                .filter(TranscriptionHistory.Columns.reviewStatus == TranscriptionHistory.ReviewStatus.corrected.rawValue)
                .order(TranscriptionHistory.Columns.timestamp.desc)
                .fetchAll(db)
        }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let exportDir = tempDir.appendingPathComponent("transcription_export_\(Int(Date().timeIntervalSince1970))")
        let audioExportDir = exportDir.appendingPathComponent("audio")

        // Create export directory.
        try fileManager.createDirectory(at: audioExportDir, withIntermediateDirectories: true)

        // Copy audio files.
        if let audioURL = audioDirectoryURL {
            for correctedItem in correctedHistoryItems {
                let sourceURL = audioURL.appendingPathComponent(correctedItem.audioFilename)
                let destURL = audioExportDir.appendingPathComponent(correctedItem.audioFilename)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try? fileManager.copyItem(at: sourceURL, to: destURL)
                }
            }
        }

        // Create export data for `corrections.json`. precedingText /
        // followingText are intentionally excluded for the same privacy
        // reasons we exclude them from the cloud upload - they capture
        // arbitrary surrounding text in the user's target app and may
        // contain passwords, private messages, etc.
        let isoFormatter = ISO8601DateFormatter()
        let exportData = correctedHistoryItems.map { correctedItem in
            ExportedCorrectionData(
                originalTranscription: correctedItem.recognizerText,
                correctedTranscription: correctedItem.correctedTranscription ?? "",
                audioFilename: correctedItem.audioFilename,
                appName: correctedItem.appName,
                timestamp: isoFormatter.string(from: correctedItem.timestamp)
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(exportData)
        let jsonURL = exportDir.appendingPathComponent("corrections.json")
        try jsonData.write(to: jsonURL)

        // Create zip file using ditto.
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
            throw TranscriptionHistoryError.exportFailed
        }

        // Clean up export directory.
        try? fileManager.removeItem(at: exportDir)

        log.info("[TranscriptionHistoryManager] Exported \(correctedHistoryItems.count) corrected items")
        return zipURL
    }

    // MARK: - Private Helpers

    /// Builds a base ordered request for the given sort order
    private static func orderedRequest(sortOrder: SortOrder) -> QueryInterfaceRequest<TranscriptionHistory> {
        switch sortOrder {
        case .newest:
            return TranscriptionHistory.order(
                TranscriptionHistory.Columns.timestamp.desc
            )
        case .oldest:
            return TranscriptionHistory.order(
                TranscriptionHistory.Columns.timestamp.asc
            )
        case .audioDuration:
            return TranscriptionHistory.order(
                TranscriptionHistory.Columns.audioDuration.desc,
                TranscriptionHistory.Columns.timestamp.desc
            )
        case .appName:
            return TranscriptionHistory.order(
                TranscriptionHistory.Columns.appName == nil,
                TranscriptionHistory.Columns.appName.asc,
                TranscriptionHistory.Columns.timestamp.desc
            )
        }
    }

    /// Recomputes `historyCount`, `correctedCount`, and `lifetimeStats` from the database.
    /// Called internally after every save/update/delete; safe (and cheap) for views to
    /// invoke defensively from `.onAppear`.
    @MainActor
    func updateCounts() async throws {
        guard let dbQueue = dbQueue
        else {
            throw TranscriptionHistoryError.databaseNotInitialized
        }

        // "Today" boundaries are computed on the main actor and bound into
        // the read transaction. Capturing `Date()` once per call avoids any
        // race where startOfDay and startOfTomorrow could straddle midnight.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        do {
            let (
                totalHistoryCount,
                totalCorrectedCount,
                totalReplayableCorrectedCount,
                totalReviewedCount,
                reviewedTodayCount,
                totalWords,
                totalDuration,
                distinctApps
            ) = try await dbQueue.read { db -> (Int, Int, Int, Int, Int, Int, Double, Int) in
                let historyCount = try TranscriptionHistory.fetchCount(db)
                let correctedCount = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.reviewStatus == TranscriptionHistory.ReviewStatus.corrected.rawValue)
                    .fetchCount(db)
                let replayableCorrectedCount = try TranscriptionHistory.dictations
                    .filter(TranscriptionHistory.Columns.reviewStatus == TranscriptionHistory.ReviewStatus.corrected.rawValue)
                    .fetchCount(db)
                let reviewedCount = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.reviewStatus != TranscriptionHistory.ReviewStatus.unreviewed.rawValue)
                    .fetchCount(db)
                let reviewedTodayCount = try TranscriptionHistory
                    .filter(TranscriptionHistory.Columns.reviewedAt >= startOfToday)
                    .filter(TranscriptionHistory.Columns.reviewedAt < startOfTomorrow)
                    .fetchCount(db)

                /// Single aggregate row for lifetime stats.
                ///     `COALESCE(SUM(...), 0)` returns 0 for an empty table.
                ///     `COUNT(DISTINCT col)` already skips NULLs in SQLite.
                ///     File transcripts are not dictation: they stay out of the stats.
                let aggregateRowForLifetimeStats = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            COALESCE(SUM(wordCount), 0) AS totalWords,
                            COALESCE(SUM(audioDuration), 0) AS totalDuration,
                            COUNT(DISTINCT appBundleId) AS distinctApps
                        FROM \(TranscriptionHistory.databaseTableName)
                        WHERE sourceFilename IS NULL
                    """
                )

                let totalWords: Int = aggregateRowForLifetimeStats?["totalWords"] ?? 0
                let totalDuration: Double = aggregateRowForLifetimeStats?["totalDuration"] ?? 0
                let distinctApps: Int = aggregateRowForLifetimeStats?["distinctApps"] ?? 0

                return (historyCount, correctedCount, replayableCorrectedCount, reviewedCount, reviewedTodayCount, totalWords, totalDuration, distinctApps)
            }

            self.historyCount = totalHistoryCount
            self.correctedCount = totalCorrectedCount
            self.replayableCorrectedCount = totalReplayableCorrectedCount
            self.reviewedCount = totalReviewedCount
            self.reviewedTodayCount = reviewedTodayCount
            self.lifetimeStats = LifetimeTranscriptionStats(
                totalWords: totalWords,
                totalDictationSeconds: totalDuration,
                distinctAppsUsedCount: distinctApps
            )
        } catch {
            log.error("[TranscriptionHistoryManager] updateCounts failed: \(error)")
        }
    }

    /// Saves audio samples to a WAV file
    private func saveAudioToWAV(samples: [Float], sampleRate: Int, filename: String) throws {
        guard let audioURL = audioDirectoryURL
        else {
            throw TranscriptionHistoryError.audioDirectoryNotFound
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

enum TranscriptionHistoryError: Error, LocalizedError {
    case databaseNotInitialized
    case audioDirectoryNotFound
    case exportFailed
    case deleteFailed(underlying: Error)
    case deleteAllFailed(underlying: Error)
    case deleteAllCorrectedFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "History database not initialized"
        case .audioDirectoryNotFound:
            return "History audio directory not found"
        case .exportFailed:
            return "Failed to create export zip file"
        case .deleteFailed(let underlying):
            return "Failed to delete transcription: \(underlying.localizedDescription)"
        case .deleteAllFailed(let underlying):
            return "Failed to delete all transcriptions: \(underlying.localizedDescription)"
        case .deleteAllCorrectedFailed(let underlying):
            return "Failed to delete all corrected transcriptions: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Export Model

private struct ExportedCorrectionData: Codable {
    let originalTranscription: String
    let correctedTranscription: String
    let audioFilename: String
    let appName: String?
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case originalTranscription = "original_transcription"
        case correctedTranscription = "corrected_transcription"
        case audioFilename = "audio_filename"
        case appName = "app_name"
        case timestamp
    }
}
