// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalRecordingManager.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-02-26.
//

import AppKit
import AVFoundation
import Foundation

// MARK: - Data Models

/// A flagged easy-fix case with a description of what's wrong
struct EasyFix: Codable {
    let index: Int
    let input: String
    let expected: String
    let category: String
    var description: String
    let flaggedAt: Date
    var rawSTT: String?
    var cleanedText: String?
    var audioFile: String?      // filename within easy_fix_audio/ directory

    enum CodingKeys: String, CodingKey {
        case index, input, expected, category, description, flaggedAt, rawSTT, cleanedText, audioFile
    }
}

/// A single test case loaded from validated_pairs.jsonl
struct EvalTestCase: Identifiable {
    let index: Int
    let input: String
    let expected: String
    let category: String
    let group: String?

    var id: Int { index }

    private struct Raw: Codable {
        let input: String
        let expected: String
        let category: String
        let group: String?
    }

    init(from data: Data, index: Int) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        self.index = index
        self.input = raw.input
        self.expected = raw.expected
        self.category = raw.category
        self.group = raw.group
    }
}

/// A saved recording entry stored in the per-session manifest.jsonl
struct EvalRecordingEntry: Codable {
    let index: Int
    let category: String
    let input: String
    let expected: String
    let rawSTT: String
    let cleanedTranscript: String
    let audioFile: String
    let recordedAt: Date
    let accountId: String
    let accountEmail: String?
    let session: String
}

// MARK: - Manager

@MainActor
final class EvalRecordingManager: ObservableObject {

    static let shared = EvalRecordingManager()

    @Published var testCases: [EvalTestCase] = []
    /// Tags per case index, account-level (persisted in case_tags.json)
    @Published var caseTags: [Int: Set<String>] = [:]
    /// Easy-fix flags, account-level (persisted in easy_fixes.json)
    @Published var easyFixes: [Int: EasyFix] = [:]
    /// Recorded indices per session name
    @Published var recordedIndicesBySession: [String: Set<Int>] = [:]
    /// Available session names (subdirectories under the account folder)
    @Published var availableSessions: [String] = []
    /// The active session name
    @Published var currentSession: String = "default"
    @Published var isLoading = false
    @Published var loadError: String?
    /// Paths that were tried when the file could not be found (for error display)
    @Published var triedPaths: [String] = []
    /// Progress during a retranscribeSession run
    @Published var retranscribeProgress: RetranscribeProgress? = nil
    @Published var retranscribeError: String? = nil
    /// User-selected path override (set via file picker)
    @Published var customDataPath: URL? = nil

    private(set) var currentAccountId: String = "anonymous"
    private(set) var currentAccountEmail: String? = nil

    private static let customDataPathKey = "EvalRecordingManager.customDataPath"

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.customDataPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                customDataPath = url
            }
        }
    }

    // MARK: - Public API

    var recordedIndices: Set<Int> {
        recordedIndicesBySession[currentSession] ?? []
    }

    func load(accountId: String?, accountEmail: String? = nil) {
        currentAccountId = accountId ?? "anonymous"
        currentAccountEmail = accountEmail
        isLoading = true
        loadError = nil
        triedPaths = []

        let accountId = currentAccountId
        let override = customDataPath
        Task {
            do {
                let (cases, indicesBySession, sessions, tried) = try await Self.loadFromDisk(
                    accountId: accountId, customURL: override
                )
                self.testCases = cases
                self.recordedIndicesBySession = indicesBySession
                self.availableSessions = sessions
                if !sessions.contains(self.currentSession) {
                    self.currentSession = sessions.first ?? "default"
                }
                self.caseTags = (try? Self.loadCaseTags(accountId: accountId)) ?? [:]
                self.easyFixes = (try? Self.loadEasyFixes(accountId: accountId)) ?? [:]
                self.triedPaths = tried
                self.isLoading = false
            } catch {
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Switch to an existing session.
    func switchSession(_ session: String) {
        currentSession = session
    }

    /// Create a new session and switch to it.
    func createSession(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let accountId = currentAccountId
        Task {
            do {
                try await Self.ensureSessionDirectory(accountId: accountId, session: trimmed)
                if !self.availableSessions.contains(trimmed) {
                    self.availableSessions.append(trimmed)
                    self.availableSessions.sort()
                }
                self.currentSession = trimmed
            } catch {
                print("EvalRecordingManager: createSession failed: \(error)")
            }
        }
    }

    /// Open a file picker and reload with the chosen file.
    func chooseDataFile(accountId: String?) {
        let panel = NSOpenPanel()
        panel.title = String.localized("Choose validated_pairs.jsonl")
        panel.allowedContentTypes = [.init(filenameExtension: "jsonl")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customDataPath = url
            UserDefaults.standard.set(url.path, forKey: Self.customDataPathKey)
            load(accountId: accountId)
        }
    }

    func saveRecording(
        for testCase: EvalTestCase,
        audioURL: URL,
        rawSTT: String,
        cleanedTranscript: String
    ) {
        let accountId = currentAccountId
        let accountEmail = currentAccountEmail
        let session = currentSession
        let entry = EvalRecordingEntry(
            index: testCase.index,
            category: testCase.category,
            input: testCase.input,
            expected: testCase.expected,
            rawSTT: rawSTT,
            cleanedTranscript: cleanedTranscript,
            audioFile: String(format: "%04d_%@.m4a", testCase.index, testCase.category),
            recordedAt: Date(),
            accountId: accountId,
            accountEmail: accountEmail,
            session: session
        )
        Task {
            do {
                try await Self.persistRecording(entry: entry, audioURL: audioURL, accountId: accountId, session: session)
                var indices = self.recordedIndicesBySession[session] ?? []
                indices.insert(testCase.index)
                self.recordedIndicesBySession[session] = indices
            } catch {
                print("EvalRecordingManager: save failed: \(error)")
            }
        }
    }

    var categories: [String] {
        Array(Set(testCases.map { $0.category })).sorted()
    }

    func totalCount(for category: String?) -> Int {
        guard let category else { return testCases.count }
        return testCases.filter { $0.category == category }.count
    }

    func recordedCount(for category: String?) -> Int {
        let indices = recordedIndicesBySession[currentSession] ?? []
        return testCases
            .filter { category == nil || $0.category == category }
            .filter { indices.contains($0.index) }
            .count
    }

    func revealInFinder() {
        if let dir = try? Self.sessionDirectory(for: currentAccountId, session: currentSession) {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: - Tags

    var allTags: [String] {
        Array(Set(caseTags.values.flatMap { $0 })).sorted()
    }

    func tags(for index: Int) -> Set<String> {
        caseTags[index] ?? []
    }

    func addTag(_ tag: String, to index: Int) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        caseTags[index, default: []].insert(trimmed)
        persistTags()
    }

    func removeTag(_ tag: String, from index: Int) {
        caseTags[index]?.remove(tag)
        if caseTags[index]?.isEmpty == true { caseTags.removeValue(forKey: index) }
        persistTags()
    }

    private func persistTags() {
        let accountId = currentAccountId
        let snapshot = caseTags
        Task.detached(priority: .utility) {
            try? Self.saveCaseTags(snapshot, accountId: accountId)
        }
    }

    private nonisolated static func tagsFileURL(accountId: String) throws -> URL {
        try accountRootDirectory(for: accountId).appendingPathComponent("case_tags.json")
    }

    private nonisolated static func loadCaseTags(accountId: String) throws -> [Int: Set<String>] {
        let url = try tagsFileURL(accountId: accountId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode([String: [String]].self, from: data)
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            guard let i = Int(k) else { return nil }
            return (i, Set(v))
        })
    }

    private nonisolated static func saveCaseTags(_ tags: [Int: Set<String>], accountId: String) throws {
        let url = try tagsFileURL(accountId: accountId)
        let raw = Dictionary(uniqueKeysWithValues: tags.map { (String($0.key), Array($0.value).sorted()) })
        let data = try JSONEncoder().encode(raw)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Easy Fixes

    func flagEasyFix(_ fix: EasyFix, audioURL: URL? = nil) {
        var fix = fix
        let accountId = currentAccountId
        if let src = audioURL {
            let filename = String(format: "%04d_%@.m4a", fix.index, fix.category)
            fix.audioFile = filename
            Task.detached(priority: .utility) {
                do {
                    let dir = try Self.easyFixAudioDirectory(for: accountId)
                    let dest = dir.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: src, to: dest)
                } catch {
                    print("EvalRecordingManager: failed to save easy fix audio: \(error)")
                }
            }
        }
        easyFixes[fix.index] = fix
        let snapshot = easyFixes
        Task.detached(priority: .utility) {
            try? Self.saveEasyFixes(snapshot, accountId: accountId)
        }
    }

    private nonisolated static func easyFixAudioDirectory(for accountId: String) throws -> URL {
        let dir = try accountRootDirectory(for: accountId).appendingPathComponent("easy_fix_audio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func removeEasyFix(for index: Int) {
        easyFixes.removeValue(forKey: index)
        let accountId = currentAccountId
        let snapshot = easyFixes
        Task.detached(priority: .utility) {
            try? Self.saveEasyFixes(snapshot, accountId: accountId)
        }
    }

    private nonisolated static func easyFixesFileURL(accountId: String) throws -> URL {
        try accountRootDirectory(for: accountId).appendingPathComponent("easy_fixes.json")
    }

    private nonisolated static func loadEasyFixes(accountId: String) throws -> [Int: EasyFix] {
        let url = try easyFixesFileURL(accountId: accountId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let fixes = try JSONDecoder().decode([EasyFix].self, from: data)
        return Dictionary(uniqueKeysWithValues: fixes.map { ($0.index, $0) })
    }

    private nonisolated static func saveEasyFixes(_ fixes: [Int: EasyFix], accountId: String) throws {
        let url = try easyFixesFileURL(accountId: accountId)
        let sorted = fixes.values.sorted { $0.index < $1.index }
        let data = try JSONEncoder().encode(sorted)
        // Pretty-print for readability
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try pretty.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Re-transcription

    struct RetranscribeProgress {
        let current: Int
        let total: Int
    }

    /// Re-run every audio file in `source` through the current transcription pipeline
    /// (including DeepFilterNet3 if enabled) and write results to `destination` session.
    func retranscribeSession(source: String, destination: String) async {
        let accountId = currentAccountId
        let accountEmail = currentAccountEmail
        retranscribeError = nil

        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                try Self.loadManifestEntries(accountId: accountId, session: source)
            }.value

            guard !entries.isEmpty else {
                retranscribeError = "No entries found in session '\(source)'"
                return
            }

            retranscribeProgress = RetranscribeProgress(current: 0, total: entries.count)

            try await Self.ensureSessionDirectory(accountId: accountId, session: destination)
            if !availableSessions.contains(destination) {
                availableSessions.append(destination)
                availableSessions.sort()
            }

            for (i, entry) in entries.enumerated() {
                retranscribeProgress = RetranscribeProgress(current: i, total: entries.count)

                let audioURL: URL
                do {
                    audioURL = try Self.sessionDirectory(for: accountId, session: source)
                        .appendingPathComponent(entry.audioFile)
                } catch {
                    continue
                }
                guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

                // Decode .m4a → 16kHz mono Float32 samples
                let samples: [Float]
                do {
                    samples = try await Task.detached(priority: .userInitiated) {
                        try AudioResampling.decodeFile(at: audioURL)
                    }.value
                } catch {
                    print("EvalRecordingManager: decode failed for \(entry.audioFile): \(error)")
                    continue
                }

                // Wrap in an AVAudioPCMBuffer so the ASR service's appendAudio path is used
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let frameCount = AVAudioFrameCount(samples.count)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
                buffer.frameLength = frameCount
                samples.withUnsafeBufferPointer { ptr in
                    buffer.floatChannelData![0].assign(from: ptr.baseAddress!, count: ptr.count)
                }

                // Feed through the active ASR service; preprocessing (DeepFilterNet3 + normalize)
                // runs automatically inside transcribe() based on TranscriptionConfig settings.
                let rawSTT: String
                do {
                    ParakeetCoreMLASRService.shared.reset()
                    ParakeetCoreMLASRService.shared.appendAudio(buffer)
                    let (hypotheses, _, _) = try await ParakeetCoreMLASRService.shared.transcribe()
                    rawSTT = hypotheses.first?.text ?? ""
                } catch {
                    print("EvalRecordingManager: transcription failed for \(entry.audioFile): \(error)")
                    continue
                }

                let newEntry = EvalRecordingEntry(
                    index: entry.index,
                    category: entry.category,
                    input: entry.input,
                    expected: entry.expected,
                    rawSTT: rawSTT,
                    cleanedTranscript: rawSTT,
                    audioFile: entry.audioFile,
                    recordedAt: Date(),
                    accountId: accountId,
                    accountEmail: accountEmail,
                    session: destination
                )

                do {
                    try await Self.persistRecording(
                        entry: newEntry, audioURL: audioURL,
                        accountId: accountId, session: destination
                    )
                    var indices = recordedIndicesBySession[destination] ?? []
                    indices.insert(entry.index)
                    recordedIndicesBySession[destination] = indices
                } catch {
                    print("EvalRecordingManager: persist failed for index \(entry.index): \(error)")
                }
            }

            retranscribeProgress = nil
            currentSession = destination

        } catch {
            retranscribeError = error.localizedDescription
            retranscribeProgress = nil
        }
    }

    // MARK: - Static I/O (runs off main actor)

    private nonisolated static func loadFromDisk(
        accountId: String, customURL: URL?
    ) async throws -> ([EvalTestCase], [String: Set<Int>], [String], [String]) {
        try await Task.detached(priority: .userInitiated) {
            let (cases, tried) = try loadTestCases(customURL: customURL)
            let (indicesBySession, sessions) = (try? loadAllSessions(accountId: accountId)) ?? ([:], ["default"])
            return (cases, indicesBySession, sessions, tried)
        }.value
    }

    private nonisolated static func loadTestCases(customURL: URL?) throws -> ([EvalTestCase], [String]) {
        let (url, tried) = resolvedURL(customURL: customURL)
        guard let url else {
            throw CocoaError(.fileNoSuchFile,
                userInfo: [NSLocalizedDescriptionKey:
                    String(format: NSLocalizedString(
                        "validated_pairs.jsonl not found. Tried:\n%@",
                        comment: "Error shown when the eval test-case data file cannot be located"
                    ), tried.joined(separator: "\n"))])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let cases = try text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated()
            .map { index, line in
                guard let data = line.data(using: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try EvalTestCase(from: data, index: index)
            }
        // Shuffle with a fixed seed so order is consistent across restarts
        // but categories are interleaved rather than grouped.
        var rng = SeededRandomNumberGenerator(seed: 42)
        let shuffled = cases.shuffled(using: &rng)
        return (shuffled, tried)
    }

    /// Returns all sessions (subdirectories) under the account folder, plus recorded indices per session.
    private nonisolated static func loadAllSessions(
        accountId: String
    ) throws -> ([String: Set<Int>], [String]) {
        let accountDir = try accountRootDirectory(for: accountId)
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: accountDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var sessions: [String] = contents.compactMap { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? url.lastPathComponent : nil
        }.sorted()
        if sessions.isEmpty { sessions = ["default"] }

        var indicesBySession: [String: Set<Int>] = [:]
        for session in sessions {
            indicesBySession[session] = (try? loadRecordedIndices(accountId: accountId, session: session)) ?? []
        }
        return (indicesBySession, sessions)
    }

    private nonisolated static func loadRecordedIndices(accountId: String, session: String) throws -> Set<Int> {
        let entries: [EvalRecordingEntry] = try parseJSONL(
            at: sessionDirectory(for: accountId, session: session).appendingPathComponent("manifest.jsonl")
        )
        return Set(entries.map(\.index))
    }

    func deleteRecording(for testCase: EvalTestCase) {
        let accountId = currentAccountId
        let session = currentSession
        let audioFilename = String(format: "%04d_%@.m4a", testCase.index, testCase.category)
        let indexToRemove = testCase.index
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let dir = try Self.sessionDirectory(for: accountId, session: session)
                    let audioURL = dir.appendingPathComponent(audioFilename)
                    if FileManager.default.fileExists(atPath: audioURL.path) {
                        try FileManager.default.removeItem(at: audioURL)
                    }
                    try Self.removeManifestEntry(at: dir, matchingIndex: indexToRemove)
                }.value
                var indices = self.recordedIndicesBySession[session] ?? []
                indices.remove(indexToRemove)
                self.recordedIndicesBySession[session] = indices
            } catch {
                print("EvalRecordingManager: delete failed: \(error)")
            }
        }
    }

    private nonisolated static func persistRecording(
        entry: EvalRecordingEntry,
        audioURL: URL,
        accountId: String,
        session: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let dir = try sessionDirectory(for: accountId, session: session)
            let destURL = dir.appendingPathComponent(entry.audioFile)
            let fm = FileManager.default
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: audioURL, to: destURL)
            try writeManifestEntry(entry, sessionDir: dir)
        }.value
    }

    private nonisolated static func writeManifestEntry(_ entry: EvalRecordingEntry, sessionDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let newLine = String(data: try encoder.encode(entry), encoding: .utf8) else { return }

        let manifestURL = sessionDir.appendingPathComponent("manifest.jsonl")
        var entries: [EvalRecordingEntry] = (try? parseJSONL(at: manifestURL)) ?? []
        entries.removeAll { $0.index == entry.index }

        var lines = entries.compactMap { e -> String? in
            guard let data = try? encoder.encode(e) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        lines.append(newLine)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func ensureSessionDirectory(accountId: String, session: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            _ = try sessionDirectory(for: accountId, session: session)
        }.value
    }

    nonisolated static func loadManifestEntries(accountId: String, session: String) throws -> [EvalRecordingEntry] {
        let manifestURL = try sessionDirectory(for: accountId, session: session)
            .appendingPathComponent("manifest.jsonl")
        let entries: [EvalRecordingEntry] = (try? parseJSONL(at: manifestURL)) ?? []
        return entries.sorted { $0.index < $1.index }
    }

    // MARK: - JSONL Helpers

    /// Parse a JSONL file into an array of Decodable values, skipping malformed lines.
    nonisolated static func parseJSONL<T: Decodable>(at url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(T.self, from: data)
            }
    }

    /// Remove all manifest entries matching a given index, then rewrite the file.
    private nonisolated static func removeManifestEntry(at sessionDir: URL, matchingIndex index: Int) throws {
        let manifestURL = sessionDir.appendingPathComponent("manifest.jsonl")
        var entries: [EvalRecordingEntry] = (try? parseJSONL(at: manifestURL)) ?? []
        entries.removeAll { $0.index == index }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = entries.compactMap { e -> String? in
            guard let data = try? encoder.encode(e) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Paths

    nonisolated static func accountRootDirectory(for accountId: String) throws -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Onit/EvalRecordings/\(accountId)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func sessionDirectory(for accountId: String, session: String) throws -> URL {
        let root = try accountRootDirectory(for: accountId)
        let dir = root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the first valid URL for validated_pairs.jsonl, plus all paths tried.
    private nonisolated static func resolvedURL(customURL: URL?) -> (URL?, [String]) {
        var tried: [String] = []

        // 0. User-chosen override
        if let url = customURL {
            if FileManager.default.fileExists(atPath: url.path) { return (url, tried) }
            tried.append(url.path + " (custom, not found)")
        }

        // 1. App bundle resource
        if let url = Bundle.main.url(forResource: "validated_pairs", withExtension: "jsonl") {
            return (url, tried)
        }
        tried.append("(app bundle) validated_pairs.jsonl - not found")

        // 2. Repo-relative path via #file (works in Xcode debug builds with unremapped paths)
        let sourceFile = URL(fileURLWithPath: #file)
        let repoRoot = sourceFile
            .deletingLastPathComponent()  // Training
            .deletingLastPathComponent()  // Transcription
            .deletingLastPathComponent()  // Onit
            .deletingLastPathComponent()  // macos
        let repoPath = repoRoot.appendingPathComponent(
            "libs/transcription-cleanup/data/experiment/validated_pairs.jsonl"
        )
        tried.append(repoPath.path)
        if FileManager.default.fileExists(atPath: repoPath.path) { return (repoPath, tried) }

        return (nil, tried)
    }
}

// MARK: - Seeded RNG

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
