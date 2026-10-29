// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionUploadConsentTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  Corrections recorded before uploads required an explicit "Request fix" must never be
//  uploaded implicitly. The v5 migration stamps them, and only rows created afterwards
//  with an explicit request stay eligible. In-memory database, no network, no audio.
//

import Foundation
import GRDB
import Testing
@testable import Onit

struct CorrectionUploadConsentTests {

    private static let table = TranscriptionCorrection.databaseTableName

    private func insert(
        _ db: Database, _ name: String, excludedReason: String?, firestoreUploaded: Bool = false
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO \(Self.table)
            (originalTranscription, correctedTranscription, audioFilename, timestamp,
             excludedReason, firestoreUploadedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [name, name + " fixed", name + ".wav", Date(), excludedReason,
                        firestoreUploaded ? Date() : nil]
        )
    }

    private func reason(_ db: Database, _ name: String) throws -> String? {
        try String?.fetchOne(
            db, sql: "SELECT excludedReason FROM \(Self.table) WHERE originalTranscription = ?",
            arguments: [name]) ?? nil
    }

    @Test func legacyPendingRowsAreExcludedButUploadedAndExplicitStatesAreKept() throws {
        let queue = try DatabaseQueue()
        let migrator = TranscriptionCorrectionManager.migrator
        try migrator.migrate(queue, upTo: "v4_addSnippetExpanded")
        try queue.write { db in
            try insert(db, "legacyPending", excludedReason: nil)
            try insert(db, "legacyUploaded", excludedReason: nil, firestoreUploaded: true)
            try insert(db, "optOut", excludedReason: TranscriptionCorrection.ExclusionReason.optOut)
            try insert(db, "noEdit", excludedReason: TranscriptionCorrection.ExclusionReason.noEdit)
        }

        try migrator.migrate(queue)

        try queue.read { db in
            let r_legacyPending = try reason(db, "legacyPending")
            #expect(r_legacyPending == TranscriptionCorrection.ExclusionReason.legacyUnconsented)
            let r_legacyUploaded = try reason(db, "legacyUploaded")
            #expect(r_legacyUploaded == nil)
            let r_optOut = try reason(db, "optOut")
            #expect(r_optOut == TranscriptionCorrection.ExclusionReason.optOut)
            let r_noEdit = try reason(db, "noEdit")
            #expect(r_noEdit == TranscriptionCorrection.ExclusionReason.noEdit)
        }
    }

    @Test func noRowIsEligibleForUploadAfterMigration() throws {
        let queue = try DatabaseQueue()
        let migrator = TranscriptionCorrectionManager.migrator
        try migrator.migrate(queue, upTo: "v4_addSnippetExpanded")
        try queue.write { db in
            for i in 0..<20 { try insert(db, "row\(i)", excludedReason: nil) }
        }
        try migrator.migrate(queue)
        let pending = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.table) WHERE excludedReason IS NULL AND firestoreUploadedAt IS NULL")
        }
        #expect(pending == 0)
    }

    @Test func rowsRequestedAfterMigrationStayEligibleAndMigrationDoesNotRerun() throws {
        let queue = try DatabaseQueue()
        let migrator = TranscriptionCorrectionManager.migrator
        try migrator.migrate(queue)
        try queue.write { db in
            try insert(db, "requested", excludedReason: nil)
        }
        // A later launch runs the migrator again: an explicit request must survive it.
        try migrator.migrate(queue)
        try queue.read { db in
            let r_requested = try reason(db, "requested")
            #expect(r_requested == nil)
        }
    }
}
