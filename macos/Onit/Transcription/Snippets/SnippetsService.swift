// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SnippetsService.swift
//  Onit
//
//  Created by Kévin Naudin on 17/06/2026.
//

import Defaults
import Foundation
import SwiftUI

/// Singleton store for user snippets + the dictation-time expansion engine.
///
/// All state lives on the main actor; CRUD is synchronous so read-modify-write is
/// atomic-by-actor (the dictation pipeline reads `snippets` on the same actor, so
/// there is no parallel data race). The expansion itself (`expand(in:snippets:keyword:)`)
/// is a `nonisolated static` pure function: it takes a snapshot and never touches
/// shared state, which keeps the pipeline hook synchronous and makes the matcher
/// unit-testable in isolation.
@MainActor
final class SnippetsService: ObservableObject {

    // MARK: - Singleton

    static let shared = SnippetsService()

    // MARK: - Published State

    /// Whether snippet auto-expansion runs during dictation. Auto-enabled on the
    /// first user add; seeded examples alone leave it off.
    @Published private(set) var isEnabled = false
    @Published var snippets: [Snippet] = []

    // MARK: - Initialization

    private init() {
        isEnabled = Defaults[.snippetsEnabled]
        snippets = Defaults[.snippetsV1]
        migrateSnippetKeywordIfNeeded()
    }

    // MARK: - Keyword Migration

    /// One-shot migration from the welded-suffix era. Historically the trigger
    /// keyword " snippet" was baked into `Snippet.name` at save time. This splits
    /// it back out so `Defaults.snippetKeyword` becomes the single source of truth:
    /// names that ended in " snippet" (case-insensitive) keep `appendsKeyword = true`
    /// with the suffix stripped; every other name opts out (`appendsKeyword = false`)
    /// so it keeps matching exactly as stored. Guarded by `snippetsKeywordMigrated`.
    private func migrateSnippetKeywordIfNeeded() {
        guard let migrated = Self.migratedSnippets(
            snippets,
            alreadyMigrated: Defaults[.snippetsKeywordMigrated]
        ) else { return }
        snippets = migrated
        Defaults[.snippetsKeywordMigrated] = true
        persist()
    }

    /// Pure, testable core of `migrateSnippetKeywordIfNeeded`. Returns the migrated
    /// snippets, or `nil` when the migration already ran (the idempotency guard) so
    /// stored names are never re-stripped on a second pass.
    ///
    /// Ambiguity note: a base name a user legitimately ended in " snippet" is
    /// indistinguishable from a welded suffix, so it is treated as welded (stripped
    /// + `appendsKeyword = true`). The effective trigger is unchanged for the
    /// default keyword, so this is behavior-preserving in practice.
    nonisolated static func migratedSnippets(
        _ snippets: [Snippet],
        alreadyMigrated: Bool
    ) -> [Snippet]? {
        guard !alreadyMigrated else { return nil }
        let legacySuffix = " snippet"
        return snippets.map { snippet in
            var migrated = snippet
            let name = snippet.name
            if name.lowercased().hasSuffix(legacySuffix), name.count > legacySuffix.count {
                migrated.name = String(name.dropLast(legacySuffix.count))
                migrated.appendsKeyword = true
            } else {
                migrated.appendsKeyword = false
            }
            return migrated
        }
    }

    // MARK: - Enable / Disable

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        Defaults[.snippetsEnabled] = true
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        Defaults[.snippetsEnabled] = false
    }

    // MARK: - Account-Linked Snippet Sync

    /// Base names owned by the app. Used to detect whether the list is "fresh" (no
    /// user-created snippets). These are keyword-free bases; the trigger keyword is
    /// appended at match time.
    private static let seededSnippetNames: Set<String> = [
        "my email",
        "my invite",
        "follow-up email",
    ]

    /// True when every snippet in the list was placed there by the app (i.e. the user
    /// has not added anything of their own yet). Also true for an empty list.
    private var isInFreshSeedState: Bool {
        snippets.allSatisfy { Self.seededSnippetNames.contains($0.name) }
    }

    /// Called on every login / session restore. Updates the email snippet in place if
    /// it already exists; always creates it if missing. Also seeds the static follow-up
    /// template once for new users. Fixed epoch timestamps keep seeded snippets sorted
    /// below user-created ones in "Newest first" order.
    func syncAccountSnippets(email: String?) {
        var changed = false

        // Email snippet - always present for logged-in users.
        let emailName = "my email"
        if let email, !email.isEmpty {
            if let idx = snippets.firstIndex(where: { $0.name == emailName }) {
                if snippets[idx].replacement != email {
                    snippets[idx].replacement = email
                    changed = true
                }
            } else {
                snippets.append(Snippet(name: emailName, replacement: email, createdAt: Date(timeIntervalSince1970: 2), appendsKeyword: true))
                changed = true
            }
        }

        // Follow-up template - static, seed once for new users only.
        let followUpName = "follow-up email"
        if isInFreshSeedState, !snippets.contains(where: { $0.name == followUpName }) {
            snippets.append(Snippet(
                name: followUpName,
                replacement: "Hi [Name], just wanted to follow up on my previous message. Let me know if you have any questions or need anything else from me. Happy to jump on a call if that's easier.",
                createdAt: Date(timeIntervalSince1970: 0),
                appendsKeyword: true
            ))
            changed = true
        }

        if changed { persist() }
    }

    /// Called when the referral code loads or changes. Updates the invite snippet in
    /// place if it already exists; always creates it if missing.
    func syncInviteLinkSnippet(inviteURL: String) {
        guard !inviteURL.isEmpty else { return }
        let name = "my invite"
        if let idx = snippets.firstIndex(where: { $0.name == name }) {
            guard snippets[idx].replacement != inviteURL else { return }
            snippets[idx].replacement = inviteURL
        } else {
            snippets.append(Snippet(name: name, replacement: inviteURL, createdAt: Date(timeIntervalSince1970: 1), appendsKeyword: true))
        }
        persist()
    }

    /// Called on logout. Removes the email snippet (no email for logged-out users);
    /// the invite snippet is left in place and updated by ReferralManager once the
    /// anonymous referral code loads.
    func clearAccountSnippets() {
        let before = snippets.count
        snippets.removeAll { $0.name == "my email" }
        if snippets.count != before { persist() }
    }

    // MARK: - CRUD

    /// Add a new snippet. Auto-enables expansion on the first add. The name is
    /// trimmed; an empty name is rejected (returns `nil`). Duplicate names are
    /// allowed (the expansion precedence rule disambiguates deterministically).
    @discardableResult
    func addSnippet(name: String, replacement: String, appendsKeyword: Bool = true) -> Snippet? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let snippet = Snippet(name: trimmedName, replacement: replacement, appendsKeyword: appendsKeyword)
        snippets.append(snippet)
        persist()
        if !isEnabled { enable() }
        return snippet
    }

    /// Update an existing snippet in place. No-op if the `id` no longer exists
    /// (e.g. the row was deleted while its edit sheet was open) or the new name
    /// is empty. Preserves `id` and `createdAt`.
    func updateSnippet(_ updated: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == updated.id }) else { return }
        let trimmedName = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        var sanitized = updated
        sanitized.name = trimmedName
        snippets[idx] = sanitized
        persist()
    }

    /// Remove a snippet by its stable identifier. No-op if absent.
    func removeSnippet(id: UUID) {
        guard snippets.contains(where: { $0.id == id }) else { return }
        snippets.removeAll { $0.id == id }
        persist()
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    private func persist() {
        Defaults[.snippetsV1] = snippets
    }

    // MARK: - Dictation Expansion (pure, synchronous, unit-testable)

    /// Expand snippet triggers in `transcript`.
    ///
    /// Pure & synchronous so it can run on the main actor inside the dictation
    /// pipeline (no `await` → no re-entrancy on the snapshot) and be tested in
    /// isolation. Semantics:
    /// - The effective trigger for a snippet is its base `name` optionally
    ///   followed by the global `keyword` (when `appendsKeyword` is true and the
    ///   keyword is non-empty). An empty keyword matches the base alone, never a
    ///   trailing-space trigger.
    /// - Matching is **whole-trigger, case-insensitive, on word boundaries**;
    ///   diacritics are NOT folded ("café" ≠ "cafe").
    /// - All candidate ranges are computed against the **original** transcript;
    ///   overlapping matches are resolved **longest-trigger-first** (then oldest,
    ///   then id) so a longer trigger wins over a shorter one it contains.
    /// - The result is rebuilt by copying original segments and splicing
    ///   replacements: a `replacement` is **never re-scanned**, so there is no
    ///   cascading/infinite expansion.
    nonisolated static func expand(in transcript: String, snippets: [Snippet], keyword: String) -> String {
        guard !transcript.isEmpty, !snippets.isEmpty else { return transcript }

        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)

        // Effective dictation trigger: base name, optionally suffixed by the
        // global keyword. An empty keyword (or a snippet opting out) matches the
        // base name alone, never a trailing-space trigger.
        func trigger(for snippet: Snippet) -> String {
            snippet.appendsKeyword && !kw.isEmpty ? "\(snippet.name) \(kw)" : snippet.name
        }

        // Deterministic precedence: longest effective trigger first, then oldest, then id.
        let ordered = snippets
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsTrigger = trigger(for: lhs)
                let rhsTrigger = trigger(for: rhs)
                if lhsTrigger.count != rhsTrigger.count { return lhsTrigger.count > rhsTrigger.count }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard !ordered.isEmpty else { return transcript }

        struct Match { let range: Range<String.Index>; let replacement: String }
        var matches: [Match] = []
        var claimed: [Range<String.Index>] = []

        for snippet in ordered {
            let needle = trigger(for: snippet)
            // Case-insensitive search on the ORIGINAL string keeps the returned
            // ranges in the original index space (lowercasing first would break
            // index mapping for length-changing characters like ß / İ).
            var searchStart = transcript.startIndex
            while searchStart < transcript.endIndex,
                  let range = transcript.range(
                      of: needle,
                      options: [.caseInsensitive],
                      range: searchStart..<transcript.endIndex
                  )
            {
                searchStart = range.upperBound
                guard !range.isEmpty,
                      isWholeWord(range, in: transcript),
                      !claimed.contains(where: { $0.overlaps(range) })
                else { continue }
                claimed.append(range)
                matches.append(Match(range: range, replacement: snippet.replacement))
            }
        }

        guard !matches.isEmpty else { return transcript }

        // Rebuild left-to-right: copy original segments, splice replacements.
        let sorted = matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = transcript.startIndex
        for match in sorted {
            if cursor < match.range.lowerBound {
                result += transcript[cursor..<match.range.lowerBound]
            }
            result += match.replacement
            cursor = match.range.upperBound
        }
        result += transcript[cursor..<transcript.endIndex]
        return result
    }

    /// True when `range` is bounded by non-word characters (or string edges) on
    /// both sides - i.e. it's not a sub-span of a larger word.
    private nonisolated static func isWholeWord(
        _ range: Range<String.Index>,
        in string: String
    ) -> Bool {
        let beforeOK: Bool = {
            guard range.lowerBound > string.startIndex else { return true }
            return !isWordCharacter(string[string.index(before: range.lowerBound)])
        }()
        let afterOK: Bool = {
            guard range.upperBound < string.endIndex else { return true }
            return !isWordCharacter(string[range.upperBound])
        }()
        return beforeOK && afterOK
    }

    private nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        // Underscore counts as a word character (like `\w`) so a trigger isn't
        // spliced into the middle of an identifier such as `cat_dog`.
        if character == "_" { return true }
        return !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
