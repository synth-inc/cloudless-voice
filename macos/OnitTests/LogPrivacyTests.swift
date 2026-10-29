// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LogPrivacyTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  The log summary of user content carries a size and never the text, and the Debug
//  log directory and file are private to the user.
//

import Foundation
import Testing
@testable import Onit

struct LogPrivacyTests {
    @Test func summaryCarriesTheLengthAndNotTheText() {
        let dictated = "call maria at noon about the invoice"
        let line = "raw: \(LogPrivacy.summary(dictated))"
        #expect(line == "raw: \(dictated.count) chars")
        #expect(!line.contains("maria"))
        #expect(LogPrivacy.summary("") == "0 chars")
    }

    @Test func logFileIsPrivateToTheOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Logs", isDirectory: true)

        let file = try LogPrivacy.preparePrivateLogFile(named: "Onit.log", in: dir)

        #expect(try permissions(of: dir) == 0o700)
        #expect(try permissions(of: file) == 0o600)

        // A file left world-readable by an older run is tightened on the next call.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try LogPrivacy.preparePrivateLogFile(named: "Onit.log", in: dir)
        #expect(try permissions(of: file) == 0o600)
    }

    @Test func defaultLogDirectoryIsUnderTheUserLibrary() {
        let path = LogPrivacy.defaultLogDirectory().path
        #expect(path.hasSuffix("/Library/Logs/Cloudless Voice"))
        #expect(!path.hasPrefix("/tmp"))
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
