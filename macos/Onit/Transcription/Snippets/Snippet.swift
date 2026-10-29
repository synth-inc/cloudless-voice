// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Snippet.swift
//  Onit
//
//  Created by Kévin Naudin on 17/06/2026.
//

import Defaults
import Foundation

/// A reusable text snippet.
///
/// The `name` is the **base** of the dictation trigger, the label shown in the
/// list, and the search target on the Snippets page. The effective trigger is
/// the base name optionally followed by the global keyword (`Defaults.snippetKeyword`)
/// when `appendsKeyword` is true; the keyword is the single source of truth, so
/// changing it retroactively re-targets every snippet that opts in.
struct Snippet: Codable, Hashable, Sendable, Identifiable, Defaults.Serializable {
    /// Stable identity - decoupled from `name` so renames keep the row.
    let id: UUID
    /// Base trigger phrase + display label + search target. Mutable to support editing.
    var name: String
    /// The text inserted when the snippet fires (may be multi-line).
    var replacement: String
    /// When the user created this snippet - used for Newest/Oldest sort.
    let createdAt: Date
    /// Whether the global trigger keyword is appended to `name` to form the
    /// dictation trigger. When false, the base name matches on its own.
    var appendsKeyword: Bool

    var nameLowercased: String { name.lowercased() }

    init(
        id: UUID = UUID(),
        name: String,
        replacement: String,
        createdAt: Date = Date(),
        appendsKeyword: Bool = true
    ) {
        self.id = id
        self.name = name
        self.replacement = replacement
        self.createdAt = createdAt
        self.appendsKeyword = appendsKeyword
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, replacement, createdAt, appendsKeyword
    }

    /// Tolerant decoding: only `id`/`name` are required so future schema
    /// additions (or partial data) don't wipe the user's snippets. Snippets
    /// stored before the keyword split default to `appendsKeyword = true`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        appendsKeyword = try c.decodeIfPresent(Bool.self, forKey: .appendsKeyword) ?? true
    }
}
