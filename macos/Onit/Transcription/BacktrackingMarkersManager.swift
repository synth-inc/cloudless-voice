// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktrackingMarkersManager.swift
//  Onit
//

import Foundation

/// Manages the user-editable list of "backtracking" correction markers that
/// gate the LLM correction cleanup pass.
///
/// Defaults are Swift-side (not server-fetched). Persists custom overrides as
/// a JSON array in `~/Library/Application Support/Onit/backtracking_markers.json`.
///
/// Maintains a precompiled regex snapshot in a `nonisolated` static so the
/// cleanup gate (`LLMRefinement.mayApply`, fed by the cleanup service) can read
/// it from any actor context without recompiling 17 regexes per call.
@MainActor
final class BacktrackingMarkersManager: ObservableObject {

    // MARK: - Singleton

    static let shared = BacktrackingMarkersManager()

    // MARK: - Published Properties

    /// Custom marker overrides. `nil` ⇒ using `Self.defaults`.
    @Published private(set) var customMarkers: [String]?

    // MARK: - Defaults

    /// Built-in marker list. Mirrors the original `correctionMarkers`
    /// hardcoded in `TranscriptionLLMService`. Word-bounded, case-insensitive
    /// matching is applied in `compileRegexes`.
    nonisolated static let defaults: [String] = [
        "wait", "actually",
        "no wait", "wait no", "no sorry", "wait sorry", "sorry wait",
        "actually no", "or actually", "actually wait",
        "sorry", "sorry I mean", "sorry make it",
        "I mean", "I meant",
        "scratch that", "strike that",
        "or rather", "that's not right",
        "make it",
    ]

    // MARK: - Cross-actor Regex Snapshot

    nonisolated(unsafe) private static var _matcherRegexes: [NSRegularExpression] =
        BacktrackingMarkersManager.compileRegexes(for: BacktrackingMarkersManager.defaults)
    nonisolated(unsafe) private static let snapshotLock = NSLock()

    /// Thread-safe snapshot of precompiled regexes for the active marker list.
    /// Read by the cleanup gate (`LLMRefinement.mayApply`).
    nonisolated static var matcherRegexes: [NSRegularExpression] {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return _matcherRegexes
    }

    nonisolated private static func updateSnapshot(_ regexes: [NSRegularExpression]) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        _matcherRegexes = regexes
    }

    // MARK: - Initialization

    private init() {
        loadFromDisk()
        Self.updateSnapshot(Self.compileRegexes(for: effectiveMarkers()))
    }

    // MARK: - Public API

    /// Active marker list: custom overrides if present, else defaults.
    func effectiveMarkers() -> [String] {
        customMarkers ?? Self.defaults
    }

    var hasCustomMarkers: Bool {
        customMarkers != nil
    }

    /// Add a marker to the custom list. Whitespace-trimmed, lowercased,
    /// deduplicated. No-op for empty input or duplicates.
    func addMarker(_ marker: String) {
        let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }

        var list = effectiveMarkers().map { $0.lowercased() }
        guard !list.contains(trimmed) else { return }
        list.append(trimmed)

        customMarkers = list
        saveToDisk()
        Self.updateSnapshot(Self.compileRegexes(for: list))
    }

    /// Remove a marker from the custom list.
    func removeMarker(_ marker: String) {
        let target = marker.lowercased()
        var list = effectiveMarkers().map { $0.lowercased() }
        list.removeAll { $0 == target }

        customMarkers = list
        saveToDisk()
        Self.updateSnapshot(Self.compileRegexes(for: list))
    }

    /// Drop all custom overrides and restore the built-in defaults.
    func restoreDefaults() {
        customMarkers = nil
        saveToDisk()
        Self.updateSnapshot(Self.compileRegexes(for: Self.defaults))
    }

    // MARK: - Regex Compilation

    nonisolated static func compileRegexes(for markers: [String]) -> [NSRegularExpression] {
        markers.compactMap { marker in
            // Let the space between words in a multi-word marker span any run of non-word
            // characters. ASR routinely commas-off interjections ("no, sorry", "wait,",
            // "actually,"), and a literal space would miss those - skipping the backtracking pass
            // in exactly the natural-speech cases it's meant for. `\W+` only bridges punctuation /
            // whitespace, never an intervening word, so it can't widen a marker's meaning.
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let flexible = escaped.replacingOccurrences(of: " ", with: "\\W+")
            let pattern = "\\b" + flexible + "\\b"
            return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let onitDir = appSupport.appendingPathComponent("Onit")
        return onitDir.appendingPathComponent("backtracking_markers.json")
    }

    private func loadFromDisk() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            customMarkers = decoded
        } catch {
            log.error("BacktrackingMarkersManager: load failed: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        let url = Self.storageURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let list = customMarkers {
                let data = try JSONEncoder().encode(list)
                try data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            log.error("BacktrackingMarkersManager: save failed: \(error.localizedDescription)")
        }
    }
}
