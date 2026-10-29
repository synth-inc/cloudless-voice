// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailLayoutTermsManager.swift
//  Onit
//
//  Owns the user-customizable layer for the email layout: the greeting and
//  sign-off word lists, and the "email composer" app / webmail allowlist.
//
//  Each of the four lists is a built-in default set with two user overrides
//  layered on top - an "add" list and a "remove" list - so a user can both
//  extend the defaults (add "sup" as a greeting, add an unlisted mail app) and
//  turn a built-in off (stop treating "hey" as a greeting, drop Outlook).
//
//  Built-in defaults come from the single source of truth in each case:
//  - greetings / sign-offs: the vendored TranscriptionCleanup framework
//    (`SmartFormattingDefaults.emailGreetings/emailSignOffs(locale:)`).
//  - apps / hosts: `EmailComposer.mailAppBundleIds` / `webmailHosts`.
//
//  The add/remove lists are stored in Defaults; `EmailComposer` and
//  `TranscriptionConfig.buildSwiftPipelineConfig` read those same Defaults keys
//  directly so the customization actually takes effect. This manager is the
//  UI-facing layer (Settings) and is `@MainActor` - never read it off the main
//  actor; read the Defaults keys instead.
//

import Combine
import Defaults
import Foundation
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// One of the four customizable email-layout lists.
enum EmailTermList: CaseIterable {
    case greetings
    case signOffs
    case composerApps
    case composerHosts
}

/// Where a displayed entry comes from.
enum EmailTermState {
    /// A built-in default, currently active.
    case builtIn
    /// A built-in default the user turned off.
    case removed
    /// A user addition.
    case added
}

/// A row for the settings list: the term plus where it came from.
struct EmailTermEntry: Identifiable {
    let term: String
    let state: EmailTermState
    var id: String { term }
}

@MainActor
final class EmailLayoutTermsManager: ObservableObject {

    // MARK: - Singleton

    static let shared = EmailLayoutTermsManager()

    // MARK: - State

    private struct Overrides {
        var add: [String]
        var remove: [String]
    }

    /// The user's add/remove lists per list, seeded from Defaults. `@Published`
    /// so the settings UI refreshes on every edit.
    @Published private var overrides: [EmailTermList: Overrides]

    private init() {
        overrides = [
            .greetings: .init(
                add: Defaults[ConfigKeys.emailGreetingAddTriggers],
                remove: Defaults[ConfigKeys.emailGreetingRemoveTriggers]
            ),
            .signOffs: .init(
                add: Defaults[ConfigKeys.emailSignOffAddTriggers],
                remove: Defaults[ConfigKeys.emailSignOffRemoveTriggers]
            ),
            .composerApps: .init(
                add: Defaults[ConfigKeys.emailComposerAddBundleIds],
                remove: Defaults[ConfigKeys.emailComposerRemoveBundleIds]
            ),
            .composerHosts: .init(
                add: Defaults[ConfigKeys.emailComposerAddHosts],
                remove: Defaults[ConfigKeys.emailComposerRemoveHosts]
            ),
        ]
    }

    // MARK: - Defaults

    /// Built-in defaults for a list, in a stable display order. Greetings and
    /// sign-offs follow the framework's own order; the allowlist sets are sorted.
    func builtInDefaults(for list: EmailTermList) -> [String] {
        switch list {
        // Without the TranscriptionCleanup library (a fully open build) there is
        // no email layout, so no built-in greetings or sign-offs.
        #if canImport(TranscriptionCleanup)
        case .greetings:
            return SmartFormattingDefaults.emailGreetings(locale: TranscriptionConfig.shared.cleanupLocale.library)
        case .signOffs:
            return SmartFormattingDefaults.emailSignOffs(locale: TranscriptionConfig.shared.cleanupLocale.library)
        #else
        case .greetings, .signOffs:
            return []
        #endif
        case .composerApps:
            return EmailComposer.mailAppBundleIds.sorted()
        case .composerHosts:
            return EmailComposer.webmailHosts.sorted()
        }
    }

    // MARK: - Display

    /// The rows to show: every built-in (marked `.builtIn` or `.removed`) in
    /// order, then the user's additions (marked `.added`).
    func entries(for list: EmailTermList) -> [EmailTermEntry] {
        let defaults = builtInDefaults(for: list)
        let o = overrides[list] ?? Overrides(add: [], remove: [])
        let removed = Set(o.remove.map(Self.normalize))
        let defaultKeys = Set(defaults.map(Self.normalize))

        var rows = defaults.map { term in
            EmailTermEntry(term: term, state: removed.contains(Self.normalize(term)) ? .removed : .builtIn)
        }
        for addition in o.add where !defaultKeys.contains(Self.normalize(addition)) {
            rows.append(EmailTermEntry(term: addition, state: .added))
        }
        return rows
    }

    /// Whether the user has changed a list from its built-in defaults.
    func hasCustomizations(for list: EmailTermList) -> Bool {
        let o = overrides[list] ?? Overrides(add: [], remove: [])
        return !o.add.isEmpty || !o.remove.isEmpty
    }

    // MARK: - Mutation

    /// Add a term. A term matching a currently-removed built-in is restored
    /// rather than duplicated; an already-present term is a no-op. Returns false
    /// for blank input or a term already active.
    @discardableResult
    func add(_ raw: String, to list: EmailTermList) -> Bool {
        let term = Self.sanitize(raw, for: list)
        let key = Self.normalize(term)
        guard !key.isEmpty else { return false }

        var o = overrides[list] ?? Overrides(add: [], remove: [])
        let defaultKeys = Set(builtInDefaults(for: list).map(Self.normalize))

        if defaultKeys.contains(key) {
            // It's a built-in: adding means "make sure it's on".
            guard o.remove.contains(where: { Self.normalize($0) == key }) else { return false }
            o.remove.removeAll { Self.normalize($0) == key }
        } else {
            guard !o.add.contains(where: { Self.normalize($0) == key }) else { return false }
            o.add.append(term)
        }
        set(o, for: list)
        return true
    }

    /// Remove a term: turn a built-in off, or delete a user addition.
    func remove(_ term: String, from list: EmailTermList) {
        let key = Self.normalize(term)
        guard !key.isEmpty else { return }

        var o = overrides[list] ?? Overrides(add: [], remove: [])
        let defaultKeys = Set(builtInDefaults(for: list).map(Self.normalize))

        // Always drop any matching addition - including a stale one for a term
        // that has since been promoted into the built-in list, which would
        // otherwise keep the entry active behind an "Off" badge.
        o.add.removeAll { Self.normalize($0) == key }
        if defaultKeys.contains(key), !o.remove.contains(where: { Self.normalize($0) == key }) {
            o.remove.append(term)
        }
        set(o, for: list)
    }

    /// Bring a turned-off built-in back on (the inverse of removing it).
    func restore(_ term: String, in list: EmailTermList) {
        let key = Self.normalize(term)
        var o = overrides[list] ?? Overrides(add: [], remove: [])
        guard o.remove.contains(where: { Self.normalize($0) == key }) else { return }
        o.remove.removeAll { Self.normalize($0) == key }
        set(o, for: list)
    }

    /// Drop every customization for a list (back to built-in defaults).
    func restoreDefaults(for list: EmailTermList) {
        guard hasCustomizations(for: list) else { return }
        set(Overrides(add: [], remove: []), for: list)
    }

    // MARK: - Helpers

    /// The framework matches greetings / sign-offs trimmed + lowercased, and
    /// bundle ids / hosts are case-insensitive, so normalize the same way for
    /// dedup and comparison. Inner whitespace is collapsed for multi-word
    /// greetings ("good  morning" == "good morning").
    static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Clean a raw entry before storing. For webmail hosts, reduce a pasted URL
    /// to its bare host ("https://mail.proton.me/inbox" -> "mail.proton.me") so
    /// it matches what `EmailComposer` extracts from the page; other lists are
    /// only trimmed. Prevents the UI from accepting an entry that never matches.
    static func sanitize(_ raw: String, for list: EmailTermList) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard list == .composerHosts else { return trimmed }
        var s = trimmed
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        s = s.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? s
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s
    }

    private func set(_ o: Overrides, for list: EmailTermList) {
        overrides[list] = o
        switch list {
        case .greetings:
            Defaults[ConfigKeys.emailGreetingAddTriggers] = o.add
            Defaults[ConfigKeys.emailGreetingRemoveTriggers] = o.remove
        case .signOffs:
            Defaults[ConfigKeys.emailSignOffAddTriggers] = o.add
            Defaults[ConfigKeys.emailSignOffRemoveTriggers] = o.remove
        case .composerApps:
            Defaults[ConfigKeys.emailComposerAddBundleIds] = o.add
            Defaults[ConfigKeys.emailComposerRemoveBundleIds] = o.remove
        case .composerHosts:
            Defaults[ConfigKeys.emailComposerAddHosts] = o.add
            Defaults[ConfigKeys.emailComposerRemoveHosts] = o.remove
        }
    }
}
