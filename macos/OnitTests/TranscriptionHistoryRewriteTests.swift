// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionHistoryRewriteTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-27.
//
//  A rewritten history row keeps the rewrite in `cleanedTranscription` and the
//  recognizer's text in `rewriteSourceText`: the v14 migration on an old row, the
//  round trip, and the readers that must keep using the recognizer text.
//

import Foundation
import GRDB
import Testing
@testable import Onit

struct TranscriptionHistoryRewriteTests {

    private func rewritten(corrected: String? = nil) -> TranscriptionHistory {
        TranscriptionHistory(
            rawTranscription: "bonjour tout le monde",
            cleanedTranscription: "Hello everyone.",
            correctedTranscription: corrected,
            rewriteSourceText: "Bonjour tout le monde.",
            rewriteModel: "gemma3:1b",
            audioFilename: "a.wav",
            audioDuration: 1
        )
    }

    // MARK: - Migration

    @Test func preV14RowReadsBackWithoutRewriteFields() throws {
        let queue = try DatabaseQueue()
        let migrator = TranscriptionHistoryManager.migrator
        try migrator.migrate(queue, upTo: "v13_addSourceFilename")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(TranscriptionHistory.databaseTableName)
                    (rawTranscription, cleanedTranscription, audioFilename, audioDuration, timestamp)
                    VALUES ('raw', 'old rewrite', 'old.wav', 2, ?)
                    """,
                arguments: [Date()]
            )
        }
        try migrator.migrate(queue)

        let rows = try queue.read { try TranscriptionHistory.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].cleanedTranscription == "old rewrite")
        #expect(rows[0].rewriteSourceText == nil)
        #expect(rows[0].rewriteModel == nil)
        #expect(rows[0].recognizerText == "old rewrite")
    }

    @Test func rewrittenRowRoundTrips() throws {
        let queue = try DatabaseQueue()
        try TranscriptionHistoryManager.migrator.migrate(queue)
        try queue.write { try rewritten().insert($0) }

        let row = try #require(try queue.read { try TranscriptionHistory.fetchOne($0) })
        #expect(row.cleanedTranscription == "Hello everyone.")
        #expect(row.rewriteSourceText == "Bonjour tout le monde.")
        #expect(row.rewriteModel == "gemma3:1b")
        #expect(row.recognizerText == "Bonjour tout le monde.")
    }

    // MARK: - Readers

    @Test func recognizerTextPrefersTheSource() {
        #expect(rewritten().recognizerText == "Bonjour tout le monde.")
        let plain = TranscriptionHistory(
            rawTranscription: "r", cleanedTranscription: "c", audioFilename: "a", audioDuration: 1
        )
        #expect(plain.recognizerText == "c")
    }

    @Test func correctionPairUsesTheRecognizerText() {
        let pair = rewritten(corrected: "Bonjour tout le monde !").correctionPair
        #expect(pair == CorrectionPair(raw: "Bonjour tout le monde.", corrected: "Bonjour tout le monde !"))
        // A correction equal to the recognizer text is not a correction, even though
        // it differs from the rewrite.
        #expect(rewritten(corrected: "Bonjour tout le monde.").correctionPair == nil)
        #expect(rewritten().correctionPair == nil)
    }

    @Test func correctionPairOfAPlainRowUsesTheCleanedText() {
        let plain = TranscriptionHistory(
            rawTranscription: "r", cleanedTranscription: "c", correctedTranscription: "d",
            audioFilename: "a", audioDuration: 1
        )
        #expect(plain.correctionPair == CorrectionPair(raw: "c", corrected: "d"))
    }

    @Test func pastedTextIsTheRewriteForARewrittenRow() {
        #expect(rewritten().pastedText == "Hello everyone.")
        #expect(rewritten(corrected: "Bonjour !").pastedText == "Hello everyone.")
        let plain = TranscriptionHistory(
            rawTranscription: "r", cleanedTranscription: "c", correctedTranscription: "d",
            audioFilename: "a", audioDuration: 1
        )
        #expect(plain.pastedText == "d")
        let uncorrected = TranscriptionHistory(
            rawTranscription: "r", cleanedTranscription: "c", audioFilename: "a", audioDuration: 1
        )
        #expect(uncorrected.pastedText == "c")
    }
}
