// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmojiTriggersManager.swift
//  Onit
//
//  Owns the user-customizable layer of the spoken-emoji trigger dictionary.
//
//  Built-in defaults live in `EmojiTriggers` (seeded from the vendored
//  TranscriptionCleanup framework). User additions/overrides are stored in
//  Defaults (`emojiCustomGlyphs`) and merged on top via `effectiveGlyphs`.
//  `effectiveGlyphs` is what Settings displays and what the transcription
//  pipeline passes into the cleanup emoji `CategoryConfig` so custom triggers
//  actually fire.
//

import Combine
import Defaults
import Foundation

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

@MainActor
final class EmojiTriggersManager: ObservableObject {

    // MARK: - Singleton

    static let shared = EmojiTriggersManager()

    // MARK: - Published State

    /// User-defined / overridden triggers (normalized spoken name -> glyph).
    @Published private(set) var customGlyphs: [String: String]

    private init() {
        customGlyphs = Defaults[ConfigKeys.emojiCustomGlyphs]
    }

    // MARK: - Derived

    /// Built-in defaults for the locale the cleanup pipeline will run with.
    /// This is what the framework would actually apply, so it's what we show.
    ///
    /// Routes through `TranscriptionConfig.cleanupLocale` rather than reading
    /// `transcriptionLanguages` again: a second copy of the FR-lock rule would
    /// let Settings list names the pipeline never matches.
    var visibleDefaults: [String: String] {
        EmojiTriggers.defaults(for: TranscriptionConfig.shared.cleanupLocale)
    }

    /// Language-appropriate defaults with user customizations layered on top
    /// (custom wins). This is the map shown in Settings.
    var effectiveGlyphs: [String: String] {
        visibleDefaults.merging(customGlyphs) { _, custom in custom }
    }

    var hasCustomizations: Bool { !customGlyphs.isEmpty }

    /// True when `name` is a user-added trigger (not present in the defaults).
    func isCustomAddition(_ name: String) -> Bool {
        let key = Self.normalize(name)
        return customGlyphs[key] != nil && visibleDefaults[key] == nil
    }

    /// True when `name` exists as a default but the user has overridden its glyph.
    func isOverriddenDefault(_ name: String) -> Bool {
        let key = Self.normalize(name)
        guard let custom = customGlyphs[key], let def = visibleDefaults[key] else { return false }
        return custom != def
    }

    // MARK: - Mutation

    /// Add a new trigger or override an existing one. Returns false when the
    /// input is empty/invalid or when it exactly matches the built-in default
    /// (nothing to store).
    @discardableResult
    func setTrigger(name rawName: String, glyph rawGlyph: String) -> Bool {
        let name = Self.normalize(rawName)
        let glyph = rawGlyph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !glyph.isEmpty else { return false }

        // Overriding a default back to its default value is a no-op removal.
        if visibleDefaults[name] == glyph {
            customGlyphs[name] = nil
            persist()
            return true
        }

        customGlyphs[name] = glyph
        persist()
        return true
    }

    /// Remove a user customization. For an overridden default this reverts to the
    /// built-in glyph; for a user addition it removes the trigger entirely.
    func removeCustom(name rawName: String) {
        let name = Self.normalize(rawName)
        guard customGlyphs[name] != nil else { return }
        customGlyphs[name] = nil
        persist()
    }

    /// Drop all user customizations (revert to built-in defaults).
    func restoreDefaults() {
        guard hasCustomizations else { return }
        customGlyphs = [:]
        persist()
    }

    // MARK: - Helpers

    /// Spoken names are matched lowercase and whitespace-collapsed by the emoji
    /// generator's `<name> emoji` grammar, so normalize on the way in.
    static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func persist() {
        Defaults[ConfigKeys.emojiCustomGlyphs] = customGlyphs
    }
}
