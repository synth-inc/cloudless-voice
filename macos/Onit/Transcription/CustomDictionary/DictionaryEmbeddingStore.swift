// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictionaryEmbeddingStore.swift
//  Onit
//
//  File-based persistence for per-term enrollment embeddings.
//  Each term gets one JSON file: <appSupport>/Onit/dictionary_embeddings/<termId>.json
//  Contents: [[[Float]]] - array of K templates, each template is [T × 512] frames.
//

import Foundation

struct DictionaryEmbeddingStore {

    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/dictionary_embeddings")
    }

    // MARK: - Public API

    static func save(_ templates: [[[Float]]], for termId: UUID) {
        let url = fileURL(for: termId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(for termId: UUID) -> [[[Float]]]? {
        guard let data = try? Data(contentsOf: fileURL(for: termId)) else { return nil }
        return try? JSONDecoder().decode([[[Float]]].self, from: data)
    }

    static func delete(for termId: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: termId))
    }

    /// Append one new template frame sequence, capping at `maxTemplates`.
    static func append(_ frames: [[Float]], to termId: UUID, maxTemplates: Int = 10) {
        guard !frames.isEmpty else { return }
        var existing = load(for: termId) ?? []
        existing.append(frames)
        if existing.count > maxTemplates {
            existing = Array(existing.suffix(maxTemplates))
        }
        save(existing, for: termId)
    }

    // MARK: - Private

    private static func fileURL(for termId: UUID) -> URL {
        dir.appendingPathComponent("\(termId.uuidString).json")
    }
}
