// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryStore.swift
//  Onit
//
//  Local SQLite store for the persistent term memory: accumulates per-term
//  sighting evidence in the Petrov k=2 summary form (total weighted evidence + the two
//  most recent events), plus generated aliases and a rolling 90-day sighting
//  log for later parameter fitting. Archive-forever by design: activation
//  handles "forgetting" by demotion below the bias threshold, never by
//  deletion - deletion exists only as user-facing removal and log hygiene.
//  Privacy: terms and counts only, never sentences; the log holds
//  term + app-bundle + timestamp.
//
//  All methods are synchronous and thread-safe (GRDB DatabaseQueue);
//  `TermMemoryService` calls them from its background queue.
//

import Foundation
import GRDB

final class TermMemoryStore: @unchecked Sendable {

    enum Source: String, Sendable {
        case ocr           // passive OCR sighting at dictation start (weight 1)
        case nearCursor    // AX text near the cursor (weight 2)
        case ambient       // background focus-change capture, AX or OCR (weight 1)
        case dictated      // dictated and kept (weight 3)
        case correction    // introduced by a user correction (weight 10, pins)

        var weight: Double {
            switch self {
            case .ocr, .ambient: return TermMemoryActivation.weightOCR
            case .nearCursor: return TermMemoryActivation.weightNearCursor
            case .dictated: return TermMemoryActivation.weightDictatedKept
            case .correction: return TermMemoryActivation.weightCorrection
            }
        }

        /// Passive sources collapse to one event per term per app per hour
        /// (OCR re-sees static windows; ACT-R traces are per presentation).
        /// Deliberate usage events always count.
        var isPassive: Bool { self == .ocr || self == .nearCursor || self == .ambient }
    }

    struct Sighting: Sendable {
        var term: String       // display surface as mined ("Kalender")
        var source: Source
        var appBundle: String?
        var ts: Double         // unix seconds
    }

    struct TermRecord: Sendable {
        var term: String       // normalized (lowercased) key
        var display: String
        var evidence: TermMemoryActivation.Evidence
        var daysSeen: Int
        var nOCR: Int
        var nDict: Int
        var nCorr: Int
        var pinned: Bool
        var phones: [String]?
        var aliasesDone: Bool
    }

    enum AliasTier: String, Sendable {
        case unconditional  // passed the real-word guard - safe trie rewrite
        case gated          // post-ASR fuzzy matcher only
    }

    static let sightingLogRetentionDays = 90.0
    private static let passiveDedupSeconds = 3600.0

    private let dbQueue: DatabaseQueue

    /// Failable: a broken DB must never take dictation down. Callers hold an
    /// optional and degrade to no-memory behavior.
    init?(path: String) {
        do {
            let queue = try DatabaseQueue(path: path)
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
        } catch {
            log.error("[TermMemoryStore] setup failed: \(error)")
            return nil
        }
    }

    /// In-memory store for tests.
    init?(inMemory: ()) {
        do {
            let queue = try DatabaseQueue()
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
        } catch {
            return nil
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createTermMemory") { db in
            try db.execute(sql: """
                CREATE TABLE term_memory (
                  term TEXT PRIMARY KEY,
                  display TEXT NOT NULL,
                  W REAL NOT NULL,
                  n INTEGER NOT NULL,
                  t_first REAL NOT NULL,
                  t1 REAL NOT NULL, w1 REAL NOT NULL,
                  t2 REAL, w2 REAL,
                  n_ocr INTEGER NOT NULL DEFAULT 0,
                  n_dict INTEGER NOT NULL DEFAULT 0,
                  n_corr INTEGER NOT NULL DEFAULT 0,
                  pinned INTEGER NOT NULL DEFAULT 0,
                  phones TEXT,
                  probe_done INTEGER NOT NULL DEFAULT 0,
                  dictatable INTEGER NOT NULL DEFAULT 1,
                  pronounceable INTEGER NOT NULL DEFAULT 1,
                  days_seen INTEGER NOT NULL DEFAULT 1,
                  last_day INTEGER NOT NULL DEFAULT 0,
                  aliases_done INTEGER NOT NULL DEFAULT 0,
                  user_removed INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE term_alias (
                  term TEXT NOT NULL,
                  alias TEXT NOT NULL,
                  tier TEXT NOT NULL,
                  provenance TEXT NOT NULL,
                  created_at REAL NOT NULL,
                  PRIMARY KEY (term, alias)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE sighting_log (
                  term TEXT NOT NULL,
                  ts REAL NOT NULL,
                  source TEXT NOT NULL,
                  app_bundle TEXT,
                  kept INTEGER
                )
                """)
            try db.execute(sql:
                "CREATE INDEX idx_sighting_term_app ON sighting_log(term, app_bundle, ts)")
            try db.execute(sql: "CREATE INDEX idx_sighting_ts ON sighting_log(ts)")
            try db.execute(sql:
                "CREATE TABLE term_memory_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
            try db.execute(sql:
                "INSERT INTO term_memory_meta (key, value) VALUES ('version', 0)")
        }
        return migrator
    }

    // MARK: - Version (trie-cache invalidation)

    /// Monotonic counter bumped by every write batch. The bias-list cache and
    /// the decode-time trie key on it.
    var version: Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM term_memory_meta WHERE key = 'version'")
        }).flatMap { $0 } ?? 0
    }

    private static func bumpVersion(_ db: Database) throws {
        try db.execute(sql: "UPDATE term_memory_meta SET value = value + 1 WHERE key = 'version'")
    }

    // MARK: - Ingestion

    /// Record a batch of sightings. Admission gates are computed once per new
    /// term via `admission` (surface gates persist with the row so selection
    /// never re-runs them). Returns the number of events actually recorded
    /// (post-dedup).
    @discardableResult
    func recordSightings(_ sightings: [Sighting], admission: TermAdmission) -> Int {
        guard !sightings.isEmpty else { return 0 }
        var recorded = 0
        do {
            try dbQueue.write { db in
                for s in sightings {
                    let display = s.term.trimmingCharacters(in: .whitespaces)
                    let key = display.lowercased()
                    guard !key.isEmpty else { continue }

                    // Passive dedup: one event per term per app per hour.
                    if s.source.isPassive {
                        let lastTs = try Double.fetchOne(db, sql: """
                            SELECT MAX(ts) FROM sighting_log
                            WHERE term = ? AND app_bundle IS ?
                              AND source IN ('ocr', 'nearCursor', 'ambient')
                            """, arguments: [key, s.appBundle])
                        if let lastTs, s.ts - lastTs < Self.passiveDedupSeconds { continue }
                    }

                    let row = try Row.fetchOne(
                        db, sql: "SELECT * FROM term_memory WHERE term = ?", arguments: [key])
                    if row?["user_removed"] as Int? == 1 { continue }

                    let day = Int(s.ts / 86_400)
                    if let row {
                        let evidence = TermMemoryActivation.adding(
                            Self.evidence(from: row), ts: s.ts, weight: s.source.weight)
                        let newDay = (row["last_day"] as Int? ?? 0) != day
                        try db.execute(sql: """
                            UPDATE term_memory SET
                              W = ?, n = ?, t1 = ?, w1 = ?, t2 = ?, w2 = ?,
                              n_ocr = n_ocr + ?, n_dict = n_dict + ?, n_corr = n_corr + ?,
                              pinned = MAX(pinned, ?),
                              days_seen = days_seen + ?, last_day = ?
                            WHERE term = ?
                            """, arguments: [
                                evidence.W, evidence.n, evidence.t1, evidence.w1,
                                evidence.t2, evidence.w2,
                                s.source.isPassive ? 1 : 0,
                                s.source == .dictated ? 1 : 0,
                                s.source == .correction ? 1 : 0,
                                s.source == .correction ? 1 : 0,
                                newDay ? 1 : 0, day, key,
                            ])
                        // Keep the richer display casing: prefer a cased
                        // surface over an all-lowercase first sighting.
                        if let existing = row["display"] as String?,
                           existing == existing.lowercased(), display != display.lowercased() {
                            try db.execute(
                                sql: "UPDATE term_memory SET display = ? WHERE term = ?",
                                arguments: [display, key])
                        }
                    } else {
                        let dictatable = TermAdmission.isDictatable(display)
                        let pronounceable = dictatable && admission.isPronounceable(display)
                        try db.execute(sql: """
                            INSERT INTO term_memory
                              (term, display, W, n, t_first, t1, w1,
                               n_ocr, n_dict, n_corr, pinned,
                               dictatable, pronounceable, days_seen, last_day)
                            VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                            """, arguments: [
                                key, display, s.source.weight, s.ts, s.ts, s.source.weight,
                                s.source.isPassive ? 1 : 0,
                                s.source == .dictated ? 1 : 0,
                                s.source == .correction ? 1 : 0,
                                s.source == .correction ? 1 : 0,
                                dictatable ? 1 : 0, pronounceable ? 1 : 0, day,
                            ])
                    }
                    try db.execute(sql: """
                        INSERT INTO sighting_log (term, ts, source, app_bundle, kept)
                        VALUES (?, ?, ?, ?, NULL)
                        """, arguments: [key, s.ts, s.source.rawValue, s.appBundle])
                    recorded += 1
                }
                if recorded > 0 { try Self.bumpVersion(db) }
            }
        } catch {
            log.error("[TermMemoryStore] recordSightings failed: \(error)")
        }
        return recorded
    }

    private static func evidence(from row: Row) -> TermMemoryActivation.Evidence {
        TermMemoryActivation.Evidence(
            W: row["W"] ?? 0, n: row["n"] ?? 0,
            tFirst: row["t_first"] ?? 0,
            t1: row["t1"] ?? 0, w1: row["w1"] ?? 0,
            t2: row["t2"], w2: row["w2"])
    }

    private static func record(from row: Row) -> TermRecord {
        TermRecord(
            term: row["term"] ?? "",
            display: row["display"] ?? "",
            evidence: evidence(from: row),
            daysSeen: row["days_seen"] ?? 0,
            nOCR: row["n_ocr"] ?? 0,
            nDict: row["n_dict"] ?? 0,
            nCorr: row["n_corr"] ?? 0,
            pinned: (row["pinned"] as Int? ?? 0) == 1,
            phones: (row["phones"] as String?).map { $0.split(separator: " ").map(String.init) },
            aliasesDone: (row["aliases_done"] as Int? ?? 0) == 1)
    }

    // MARK: - Selection

    /// Bias-eligible terms ranked by activation: surface gates passed, the
    /// evidence gate met (≥2 distinct sighting days OR any dictated/correction
    /// event), activation above τ (pinned terms bypass τ). Top `limit` by B.
    func biasList(now: Double, limit: Int) -> [TermRecord] {
        let rows: [Row] = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM term_memory
                WHERE user_removed = 0 AND dictatable = 1 AND pronounceable = 1
                  AND (days_seen >= 2 OR n_dict > 0 OR n_corr > 0)
                """)
        }) ?? []
        let scored: [(Double, TermRecord)] = rows.compactMap { row in
            let record = Self.record(from: row)
            let b = TermMemoryActivation.baseLevel(record.evidence, now: now)
            guard b > TermMemoryActivation.biasThreshold || record.pinned else { return nil }
            return (b, record)
        }
        return scored
            .sorted { ($0.0, $0.1.term) > ($1.0, $1.1.term) }
            .prefix(limit)
            .map(\.1)
    }

    // MARK: - Aliases

    /// Aliases of the given tier for a set of terms (keys are normalized
    /// term keys; values best-first as stored).
    func aliases(forTerms terms: [String], tier: AliasTier) -> [String: [String]] {
        guard !terms.isEmpty else { return [:] }
        let keys = terms.map { $0.lowercased() }
        let rows: [Row] = (try? dbQueue.read { db in
            let marks = databaseQuestionMarks(count: keys.count)
            return try Row.fetchAll(db, sql: """
                SELECT term, alias FROM term_alias
                WHERE tier = ? AND term IN (\(marks))
                ORDER BY rowid
                """, arguments: StatementArguments([tier.rawValue] + keys))
        }) ?? []
        var out: [String: [String]] = [:]
        for row in rows {
            guard let term = row["term"] as String?, let alias = row["alias"] as String? else { continue }
            out[term, default: []].append(alias)
        }
        return out
    }

    /// Eligible terms whose alias prediction hasn't run yet (background work
    /// queue for `TermMemoryService`).
    func termsNeedingAliases(limit: Int) -> [TermRecord] {
        let rows: [Row] = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM term_memory
                WHERE aliases_done = 0 AND user_removed = 0
                  AND dictatable = 1 AND pronounceable = 1
                  AND (days_seen >= 2 OR n_dict > 0 OR n_corr > 0)
                ORDER BY W DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
        return rows.map(Self.record(from:))
    }

    /// Persist a term's predicted aliases + phone key and mark prediction done.
    func storePrediction(term: String, prediction: TermAliasPredictor.Prediction,
                         provenance: String = "g2p") {
        let key = term.lowercased()
        let now = Date().timeIntervalSince1970
        do {
            try dbQueue.write { db in
                for alias in prediction.unconditional {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO term_alias (term, alias, tier, provenance, created_at)
                        VALUES (?, ?, 'unconditional', ?, ?)
                        """, arguments: [key, alias, provenance, now])
                }
                for alias in prediction.gated {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO term_alias (term, alias, tier, provenance, created_at)
                        VALUES (?, ?, 'gated', ?, ?)
                        """, arguments: [key, alias, provenance, now])
                }
                try db.execute(sql: """
                    UPDATE term_memory SET phones = ?, aliases_done = 1 WHERE term = ?
                    """, arguments: [prediction.phones.joined(separator: " "), key])
                try Self.bumpVersion(db)
            }
        } catch {
            log.error("[TermMemoryStore] storePrediction failed: \(error)")
        }
    }

    /// A user-observed misrecognition (e.g. the raw span a correction fixed).
    func addObservedAlias(term: String, alias: String, unconditional: Bool) {
        let key = term.lowercased()
        let surface = alias.trimmingCharacters(in: .whitespaces)
        guard !surface.isEmpty, surface.lowercased() != key else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO term_alias (term, alias, tier, provenance, created_at)
                    VALUES (?, ?, ?, 'telemetry', ?)
                    """, arguments: [
                        key, surface,
                        unconditional ? AliasTier.unconditional.rawValue : AliasTier.gated.rawValue,
                        Date().timeIntervalSince1970,
                    ])
                try Self.bumpVersion(db)
            }
        } catch {
            log.error("[TermMemoryStore] addObservedAlias failed: \(error)")
        }
    }

    // MARK: - Maintenance / user editing

    /// Rolling retention for the parameter-fitting log (terms stay forever;
    /// the log is the only table that grows per-event).
    func pruneSightingLog(now: Double = Date().timeIntervalSince1970) {
        let cutoff = now - Self.sightingLogRetentionDays * 86_400
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sighting_log WHERE ts < ?", arguments: [cutoff])
        }
    }

    /// Retention window: hard-delete every term whose MOST RECENT event is
    /// older than `cutoff`, along with its aliases and log rows. This is the
    /// user-facing "forget terms unseen for N months" control - the
    /// activation model never needs it (stale terms demote below τ on their
    /// own), so it exists for privacy and store hygiene, not ranking.
    /// Tombstoned rows age out too: a term absent that long can earn its way
    /// back in from scratch. Returns the number of terms deleted.
    @discardableResult
    func pruneTermsUnseen(since cutoff: Double) -> Int {
        var deleted = 0
        do {
            try dbQueue.write { db in
                let keys = try String.fetchAll(
                    db, sql: "SELECT term FROM term_memory WHERE t1 < ?", arguments: [cutoff])
                guard !keys.isEmpty else { return }
                let marks = databaseQuestionMarks(count: keys.count)
                try db.execute(sql: "DELETE FROM term_alias WHERE term IN (\(marks))",
                               arguments: StatementArguments(keys))
                try db.execute(sql: "DELETE FROM sighting_log WHERE term IN (\(marks))",
                               arguments: StatementArguments(keys))
                try db.execute(sql: "DELETE FROM term_memory WHERE t1 < ?", arguments: [cutoff])
                deleted = keys.count
                try Self.bumpVersion(db)
            }
        } catch {
            log.error("[TermMemoryStore] pruneTermsUnseen failed: \(error)")
        }
        return deleted
    }

    /// User-facing removal: tombstone the term (never re-admitted) and drop
    /// its aliases.
    func removeTerm(_ term: String) {
        let key = term.lowercased()
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE term_memory SET user_removed = 1, pinned = 0 WHERE term = ?",
                arguments: [key])
            try db.execute(sql: "DELETE FROM term_alias WHERE term = ?", arguments: [key])
            try Self.bumpVersion(db)
        }
    }

    /// All stored terms for the (future) dictionary-view editor + debug UI.
    func allTerms(limit: Int = 10_000) -> [TermRecord] {
        let rows: [Row] = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM term_memory WHERE user_removed = 0
                ORDER BY W DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
        return rows.map(Self.record(from:))
    }

    var termCount: Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM term_memory WHERE user_removed = 0")
        }).flatMap { $0 } ?? 0
    }
}
