// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartFormattingTriggersManager.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-24.
//

import Foundation
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

// MARK: - Data Model

/// Custom trigger overrides for smart formatting categories.
/// Uses typed properties instead of type-erased dictionaries.
struct SmartFormattingTriggers: Codable, Equatable {
    /// Punctuation: symbol → [verbal triggers] (e.g. "." → ["period", "full stop", "dot"])
    var punctuation: [String: [String]]?

    /// Formatting: symbol → [verbal triggers] (e.g. "\\n" → ["new line", "next line"])
    var formatting: [String: [String]]?

    /// Fillers: flat list of filler words to remove
    var fillers: [String]?

    /// True only when NO category carries an override. An emptied category is
    /// still an override: collapsing it to `nil` would silently restore the very
    /// defaults the user just deleted, one trigger at a time.
    var isEmpty: Bool {
        punctuation == nil && formatting == nil && fillers == nil
    }
}

// MARK: - Manager

/// Manages custom trigger words for smart formatting categories.
///
/// Triggers are stored as a JSON file in Application Support. When no custom
/// triggers are set, the defaults from `TranscriptionCleanup.SmartFormattingDefaults`
/// are used (single in-process Swift source of truth - same constants the cleanup
/// pipeline reads). Defaults are loaded synchronously on first access; the
/// `fetchDefaults()` async signature is preserved for call-site compatibility.
@MainActor
final class SmartFormattingTriggersManager: ObservableObject {

    // MARK: - Singleton

    static let shared = SmartFormattingTriggersManager()

    // MARK: - Published Properties

    /// Custom trigger overrides (nil = using defaults for all categories)
    @Published private(set) var customTriggers: SmartFormattingTriggers?

    /// Defaults sourced from `TranscriptionCleanup.SmartFormattingDefaults`,
    /// keyed by category.
    @Published private(set) var defaultPunctuation: [String: [String]]?
    @Published private(set) var defaultFormatting: [String: [String]]?
    @Published private(set) var defaultFillers: [String]?

    /// Whether defaults have been loaded. Always `true` after `init` - kept for
    /// call-site compatibility with the previous async-fetch model.
    @Published private(set) var isDefaultsLoaded = false

    // MARK: - Private Properties

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let onitDir = appSupport.appendingPathComponent("Onit")
        return onitDir.appendingPathComponent("smart_formatting_triggers.json")
    }

    // MARK: - Initialization

    private init() {
        loadFromDisk()
        loadStaticDefaults()
    }

    // MARK: - Public Methods

    /// Load defaults from the in-process `TranscriptionCleanup` package. Idempotent.
    /// Kept `async` so existing callers (`SettingsSmartFormatting.task { await … }`)
    /// don't need to change.
    func fetchDefaults() async {
        guard !isDefaultsLoaded else { return }
        loadStaticDefaults()
    }

    private func loadStaticDefaults() {
        guard !isDefaultsLoaded else { return }
        defaultPunctuation = Self.builtInPunctuation
        defaultFormatting = Self.builtInFormatting
        defaultFillers = Self.builtInFillers
        isDefaultsLoaded = true
        log.info(
            "SmartFormattingTriggersManager: Loaded defaults from TranscriptionCleanup "
            + "(\(Self.builtInPunctuation.count) punct symbols, "
            + "\(Self.builtInFormatting.count) formatting symbols, "
            + "\(Self.builtInFillers.count) fillers)"
        )
    }

    /// Get effective punctuation triggers (custom if set, else in-process defaults).
    func effectivePunctuation() -> [String: [String]]? {
        customTriggers?.punctuation ?? defaultPunctuation
    }

    /// Get effective formatting triggers (custom if set, else in-process defaults).
    func effectiveFormatting() -> [String: [String]]? {
        customTriggers?.formatting ?? defaultFormatting
    }

    /// Get effective filler words (custom if set, else in-process defaults).
    func effectiveFillers() -> [String]? {
        customTriggers?.fillers ?? defaultFillers
    }

    /// Add a custom trigger word for a symbol in the punctuation category.
    func addPunctuationTrigger(symbol: String, trigger: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var map = triggers.punctuation ?? effectivePunctuation() ?? [:]
        var list = map[symbol] ?? []

        guard !list.contains(trigger.lowercased()) else { return }
        list.append(trigger.lowercased())
        map[symbol] = list
        triggers.punctuation = map

        customTriggers = triggers
        saveToDisk()
    }

    /// Remove a trigger word for a symbol in the punctuation category.
    ///
    /// Seeds from the defaults exactly like ``addPunctuationTrigger``: removing a
    /// built-in trigger is the first edit a user makes as often as adding one, and
    /// bailing out when no custom map exists yet left the minus button dead on a
    /// fresh profile - the row didn't even disappear from the list.
    func removePunctuationTrigger(symbol: String, trigger: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var map = triggers.punctuation ?? effectivePunctuation() ?? [:]
        guard var list = map[symbol] else { return }

        list.removeAll { $0.lowercased() == trigger.lowercased() }
        if list.isEmpty {
            map.removeValue(forKey: symbol)
        } else {
            map[symbol] = list
        }
        triggers.punctuation = map
        customTriggers = triggers
        saveToDisk()
    }

    /// Add a custom trigger word for a symbol in the formatting category.
    func addFormattingTrigger(symbol: String, trigger: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var map = triggers.formatting ?? effectiveFormatting() ?? [:]
        var list = map[symbol] ?? []

        guard !list.contains(trigger.lowercased()) else { return }
        list.append(trigger.lowercased())
        map[symbol] = list
        triggers.formatting = map

        customTriggers = triggers
        saveToDisk()
    }

    /// Remove a trigger word for a symbol in the formatting category.
    /// Seeds from the defaults, see ``removePunctuationTrigger``.
    func removeFormattingTrigger(symbol: String, trigger: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var map = triggers.formatting ?? effectiveFormatting() ?? [:]
        guard var list = map[symbol] else { return }

        list.removeAll { $0.lowercased() == trigger.lowercased() }
        if list.isEmpty {
            map.removeValue(forKey: symbol)
        } else {
            map[symbol] = list
        }
        triggers.formatting = map
        customTriggers = triggers
        saveToDisk()
    }

    /// Add a custom filler word.
    func addFiller(_ filler: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var list = triggers.fillers ?? effectiveFillers() ?? []

        guard !list.contains(filler.lowercased()) else { return }
        list.append(filler.lowercased())
        triggers.fillers = list

        customTriggers = triggers
        saveToDisk()
    }

    /// Remove a filler word. Seeds from the defaults, see ``removePunctuationTrigger``.
    func removeFiller(_ filler: String) {
        var triggers = customTriggers ?? SmartFormattingTriggers()
        var list = triggers.fillers ?? effectiveFillers() ?? []

        list.removeAll { $0.lowercased() == filler.lowercased() }
        triggers.fillers = list
        customTriggers = triggers
        saveToDisk()
    }

    /// Restore defaults for a specific category.
    func restoreDefaults(for category: SmartFormattingCategory) {
        guard var triggers = customTriggers else { return }
        switch category {
        case .punctuation:
            triggers.punctuation = nil
        case .formatting:
            triggers.formatting = nil
        case .fillers:
            triggers.fillers = nil
        }
        customTriggers = triggers.isEmpty ? nil : triggers
        saveToDisk()
    }

    /// Restore all categories to defaults.
    func restoreAllDefaults() {
        customTriggers = nil
        saveToDisk()
    }

    // MARK: - Built-in Defaults

    // The cleanup framework's own trigger lists. Empty without the
    // TranscriptionCleanup library (a fully open build), where nothing consumes
    // the triggers.
    #if canImport(TranscriptionCleanup)
    private static var builtInPunctuation: [String: [String]] { SmartFormattingDefaults.punctuation }
    private static var builtInFormatting: [String: [String]] { SmartFormattingDefaults.formatting }
    private static var builtInFillers: [String] { SmartFormattingDefaults.fillers }
    #else
    private static var builtInPunctuation: [String: [String]] { [:] }
    private static var builtInFormatting: [String: [String]] { [:] }
    private static var builtInFillers: [String] { [] }
    #endif

    // MARK: - Pipeline Wiring

    /// Add / remove trigger lists in the shape `CategoryConfig` expects.
    struct TriggerDiff {
        var add: [String] = []
        var remove: [String] = []
    }

    /// Punctuation diff against the built-in defaults, `"trigger:symbol"` for adds.
    var punctuationDiff: TriggerDiff {
        Self.diff(custom: customTriggers?.punctuation, defaults: Self.builtInPunctuation)
    }

    /// Formatting diff against the built-in defaults, `"spoken:replacement"` for adds.
    var formattingDiff: TriggerDiff {
        Self.diff(custom: customTriggers?.formatting, defaults: Self.builtInFormatting)
    }

    /// Filler diff against the built-in defaults (flat lists on both sides).
    var fillersDiff: TriggerDiff {
        Self.diff(custom: customTriggers?.fillers, defaults: Self.builtInFillers)
    }

    /// Diff a customized `symbol -> [verbal]` map against the defaults.
    ///
    /// Only the delta travels to the pipeline, never the whole map: the defaults
    /// exposed here are the English ones, so replaying them wholesale would inject
    /// English triggers into a French run.
    ///
    /// A verbal moved from one symbol to another shows up as an add only - the
    /// pipeline applies removals before additions, and an add overwrites the key.
    ///
    /// ponytail: the manager freezes the whole default map on the first edit of a
    /// category - an addition or, since removals were wired up, a single click on
    /// the minus button. Both directions of a later framework update then read
    /// wrong against that frozen map: a trigger the framework ADDS looks like one
    /// the user removed, and a trigger the framework DROPS is still in the frozen
    /// map, so it is re-emitted as an addition and resurrected. Store per-symbol
    /// deltas instead of the whole map if that ever bites.
    static func diff(custom: [String: [String]]?, defaults: [String: [String]]) -> TriggerDiff {
        guard let custom else { return TriggerDiff() }

        var kept: Set<String> = []
        var add: [String] = []
        for (symbol, verbals) in custom {
            for verbal in verbals {
                let key = normalized(verbal)
                guard !key.isEmpty else { continue }
                kept.insert(key)
                // "trigger:replacement" is split on the FIRST colon, so a symbol
                // of ":" survives ("colon::") but a trigger containing one cannot.
                guard !verbal.contains(":") else { continue }
                if defaults[symbol]?.contains(where: { normalized($0) == key }) != true {
                    // Normalized, not raw: the generators match on a word boundary,
                    // so a stray space from a hand-edited JSON would key an entry
                    // that can never match.
                    add.append("\(key):\(symbol)")
                }
            }
        }

        let remove = defaults.values.flatMap { $0 }.filter { !kept.contains(normalized($0)) }

        return TriggerDiff(add: add.sorted(), remove: remove.sorted())
    }

    /// Diff a customized flat list (fillers) against the defaults.
    static func diff(custom: [String]?, defaults: [String]) -> TriggerDiff {
        guard let custom else { return TriggerDiff() }

        let customKeys = Set(custom.map(normalized))
        let defaultKeys = Set(defaults.map(normalized))

        return TriggerDiff(
            add: custom.filter { !defaultKeys.contains(normalized($0)) },
            remove: defaults.filter { !customKeys.contains(normalized($0)) }
        )
    }

    /// Same normalization the pipeline's merge helpers use (trimmed + lowercased).
    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Check if a trigger word is already used by another symbol in the same category.
    /// Returns the conflicting symbol, or nil if no conflict.
    func symbolUsingTrigger(_ trigger: String, in category: SmartFormattingCategory, excluding symbol: String) -> String? {
        let triggers: [String: [String]]?
        switch category {
        case .punctuation:
            triggers = effectivePunctuation()
        case .formatting:
            triggers = effectiveFormatting()
        case .fillers:
            return nil
        }
        guard let map = triggers else { return nil }
        for (sym, verbals) in map where sym != symbol {
            if verbals.contains(where: { $0.lowercased() == trigger.lowercased() }) {
                return sym
            }
        }
        return nil
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode(SmartFormattingTriggers.self, from: data)
            customTriggers = decoded.isEmpty ? nil : decoded
        } catch {
            log.error("SmartFormattingTriggersManager: Failed to load triggers: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            if let triggers = customTriggers {
                let data = try JSONEncoder().encode(triggers)
                try data.write(to: storageURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: storageURL)
            }
        } catch {
            log.error("SmartFormattingTriggersManager: Failed to save triggers: \(error.localizedDescription)")
        }
    }
}

// MARK: - Category Enum

enum SmartFormattingCategory: String, CaseIterable {
    case punctuation
    case formatting
    case fillers
}
