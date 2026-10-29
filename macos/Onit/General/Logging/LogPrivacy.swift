// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LogPrivacy.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-10-29.
//
//  Keeps user content out of the logs. Dictated, cleaned or screen text is never
//  interpolated into a log line: `LogPrivacy.summary` gives its size instead. The
//  Debug log file also lives in the user's own Library, readable by the owner only.
//

import Foundation

enum LogPrivacy {
    /// Size-only description of user content, safe to put in a log line.
    static func summary(_ text: String) -> String {
        "\(text.count) chars"
    }

    /// `~/Library/Logs/Cloudless Voice`: private to the user, unlike `/tmp`.
    static func defaultLogDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Cloudless Voice", isDirectory: true)
    }

    /// Creates the log directory (0700) and the log file (0600) if needed and returns
    /// the file URL. The permissions are enforced on every call, so a file left by an
    /// older run keeps being tightened. SwiftyBeaver's `FileDestination` creates the
    /// file itself when it first writes, with the process umask (normally 0644): this
    /// precreates it, so the destination only appends to an already private file.
    @discardableResult
    static func preparePrivateLogFile(named name: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
