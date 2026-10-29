// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MiniLMEmojiEmbedder.swift
//  Onit
//
//  On-device MiniLM (all-MiniLM-L6-v2) sentence embedder used to semantically
//  match spoken descriptors to emoji. Bundles a CoreML model (`MiniLMEmoji`,
//  int8, mean-pool + L2-norm baked in) plus a precomputed 2,056-emoji anchor
//  table so the whole matcher stays offline.
//
//  Model inputs: `input_ids` + `attention_mask`, Int32 MLMultiArray [1, 64].
//  Output: feature `embedding`, Float32 [1, 384] - already L2-normalized, so
//  cosine similarity against an anchor row is a plain dot product.
//
//  Compute units are pinned to `.cpuOnly`: GPU/ANE tripped an MPSGraph assertion
//  during asset validation. ANE is worth re-testing on real hardware later (same
//  caveat as CanaryCoreMLEngine).
//
//  `@unchecked Sendable`: the lazily-built model/anchor state is guarded by `lock`.
//  Runs off the main actor.
//

import CoreML
import Foundation

final class MiniLMEmojiEmbedder: @unchecked Sendable {

    static let shared = MiniLMEmojiEmbedder()

    private init() {}

    static let embeddingDim = 384
    private static let anchorCount = 2056

    // MARK: - State (lock-guarded)

    private let lock = NSLock()
    private var model: MLModel?
    private var tokenizer: BertWordPieceTokenizer?
    /// Flat row-major anchor matrix: anchorCount * embeddingDim Float32, unit-norm rows.
    private var anchorMatrix: [Float] = []
    private var anchorGlyphs: [String] = []
    private var anchorNames: [String] = []
    private var loadAttempted = false
    private var loadFailed = false

    // MARK: - Public

    struct AnchorMatch {
        let glyph: String
        let name: String
        let cosine: Float
        /// Cosine of the runner-up anchor (soft-signal margin = cosine - secondCosine).
        let secondCosine: Float
    }

    /// Ensure model + tokenizer + anchors are loaded. Idempotent; returns false if
    /// loading has permanently failed. Fails closed (leaves text unchanged upstream).
    @discardableResult
    func ensureLoaded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if model != nil && tokenizer != nil && !anchorMatrix.isEmpty { return true }
        if loadAttempted { return !loadFailed }
        loadAttempted = true
        do {
            try loadLocked()
            return true
        } catch {
            loadFailed = true
            log.error("MiniLMEmojiEmbedder: load failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Tokenize → CoreML predict → 384-d unit vector, or nil on failure.
    func embed(_ text: String) -> [Float]? {
        guard ensureLoaded() else { return nil }
        lock.lock()
        let model = self.model
        let tokenizer = self.tokenizer
        lock.unlock()
        guard let model, let tokenizer else { return nil }

        let encoded = tokenizer.encode(text)
        do {
            let ids = try makeInt32MultiArray(encoded.inputIds)
            let mask = try makeInt32MultiArray(encoded.attentionMask)
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ])
            let result = try model.prediction(from: provider)
            guard let out = result.featureValue(for: "embedding")?.multiArrayValue else {
                log.warning("MiniLMEmojiEmbedder: missing `embedding` output")
                return nil
            }
            var vec = readFloat(out, count: Self.embeddingDim)
            // Cheap re-normalization insurance against int8 rounding.
            l2NormalizeInPlace(&vec)
            return vec
        } catch {
            log.warning("MiniLMEmojiEmbedder: inference error: \(error.localizedDescription)")
            return nil
        }
    }

    /// argmax dot product of `unit` over the 2,056 anchor rows (both unit-norm).
    func bestAnchor(_ unit: [Float]) -> AnchorMatch? {
        guard unit.count == Self.embeddingDim else { return nil }
        lock.lock()
        let matrix = anchorMatrix
        let glyphs = anchorGlyphs
        let names = anchorNames
        lock.unlock()
        guard !matrix.isEmpty else { return nil }

        let dim = Self.embeddingDim
        let rows = glyphs.count
        var bestIdx = -1
        var bestCos: Float = -.infinity
        var secondCos: Float = -.infinity

        unit.withUnsafeBufferPointer { u in
            matrix.withUnsafeBufferPointer { m in
                for r in 0..<rows {
                    let base = r * dim
                    var c: Float = 0
                    for i in 0..<dim { c += u[i] * m[base + i] }
                    if c > bestCos {
                        secondCos = bestCos
                        bestCos = c
                        bestIdx = r
                    } else if c > secondCos {
                        secondCos = c
                    }
                }
            }
        }
        guard bestIdx >= 0 else { return nil }
        return AnchorMatch(glyph: glyphs[bestIdx], name: names[bestIdx],
                           cosine: bestCos, secondCosine: secondCos)
    }

    // MARK: - Loading (called under lock)

    private func loadLocked() throws {
        let bundle = Bundle.main

        // Tokenizer vocab.
        guard let vocabURL = bundle.url(forResource: "vocab", withExtension: "txt"),
              let tok = BertWordPieceTokenizer(vocabURL: vocabURL) else {
            throw EmbedderError.resourceMissing("vocab.txt")
        }
        self.tokenizer = tok

        // MiniLMEmoji.mlpackage is compiled to .mlmodelc by Xcode at build time.
        guard let modelURL = bundle.url(forResource: "MiniLMEmoji", withExtension: "mlmodelc") else {
            throw EmbedderError.resourceMissing("MiniLMEmoji.mlmodelc")
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly // ANE/GPU crashed MPSGraph during validation; re-test on device.
        self.model = try MLModel(contentsOf: modelURL, configuration: config)

        // Anchors: JSON metadata (ordered) + flat f32 matrix (same row order).
        guard let jsonURL = bundle.url(forResource: "emoji_anchors", withExtension: "json"),
              let binURL = bundle.url(forResource: "emoji_anchors.f32", withExtension: "bin") else {
            throw EmbedderError.resourceMissing("emoji_anchors")
        }
        try loadAnchors(jsonURL: jsonURL, binURL: binURL)

        log.info("MiniLMEmojiEmbedder: loaded model + \(self.anchorGlyphs.count) anchors from \(modelURL.lastPathComponent)")
    }


    private struct AnchorEntry: Decodable { let glyph: String; let name: String }

    private func loadAnchors(jsonURL: URL, binURL: URL) throws {
        let jsonData = try Data(contentsOf: jsonURL)
        let entries = try JSONDecoder().decode([AnchorEntry].self, from: jsonData)

        let binData = try Data(contentsOf: binURL)
        let expectedFloats = entries.count * Self.embeddingDim
        guard binData.count == expectedFloats * MemoryLayout<Float>.size else {
            throw EmbedderError.anchorShapeMismatch(
                bytes: binData.count, expected: expectedFloats * MemoryLayout<Float>.size)
        }

        // Little-endian Float32; host is arm64 (little-endian) so a direct copy is exact.
        var matrix = [Float](repeating: 0, count: expectedFloats)
        _ = matrix.withUnsafeMutableBytes { dst in
            binData.copyBytes(to: dst)
        }

        self.anchorMatrix = matrix
        self.anchorGlyphs = entries.map { $0.glyph }
        self.anchorNames = entries.map { $0.name }
    }

    // MARK: - MLMultiArray helpers

    private func makeInt32MultiArray(_ values: [Int32]) throws -> MLMultiArray {
        let mla = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        let ptr = mla.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { ptr[i] = values[i] }
        return mla
    }

    private func readFloat(_ mla: MLMultiArray, count: Int) -> [Float] {
        if mla.dataType == .float32 {
            let ptr = mla.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        // Defensive: coerce other dtypes element-wise.
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = mla[i].floatValue }
        return out
    }

    private func l2NormalizeInPlace(_ v: inout [Float]) {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let mag = sumSq.squareRoot()
        guard mag > 1e-12 else { return }
        for i in 0..<v.count { v[i] /= mag }
    }
}

// MARK: - Errors

enum EmbedderError: LocalizedError {
    case resourceMissing(String)
    case anchorShapeMismatch(bytes: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): return "MiniLMEmojiEmbedder: bundled resource missing: \(name)"
        case .anchorShapeMismatch(let bytes, let expected):
            return "MiniLMEmojiEmbedder: anchor bin size \(bytes) != expected \(expected)"
        }
    }
}
