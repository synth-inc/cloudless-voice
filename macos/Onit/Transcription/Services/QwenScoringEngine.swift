// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  QwenScoringEngine.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-09.
//

import CoreML
import Foundation
import Tokenizers

// MARK: - QwenScoringEngine

/// Stateful CoreML scoring engine using the Qwen2.5-0.5B-Instruct-4bit model.
///
/// Feeds tokens one at a time through a stateful KV-cache model (requires macOS 15+).
/// Uses `finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit` pre-compiled `.mlmodelc`.
///
/// Adapted from the iOS `CoreMLScoringEngine`.
actor QwenScoringEngine {

    // MARK: - Singleton

    static let shared = QwenScoringEngine()

    // MARK: - Constants

    /// Maximum sequence length supported by the model
    static let maxSequenceLength = 2048

    // MARK: - Configurable Thresholds

    /// Tokens with Score above this in shared regions are excluded from averages in `compare()`.
    private(set) var outlierThreshold: Float

    /// Threshold used to cap infinite Score tokens in sumScore.
    private(set) var capThreshold: Float

    /// Minimum score improvement to trigger replacement.
    let threshold: Float

    // MARK: - Private State

    // nonisolated(unsafe) avoids the Sendable-crossing error for isLoaded.
    // The actor serialises all access, so there is no actual data race.
    nonisolated(unsafe) private var model: MLModel?
    nonisolated(unsafe) private var tokenizer: Tokenizer?

    // MARK: - Paths

    private static var modelsBaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models")
    }

    static var qwenDirectory: URL {
        modelsBaseURL.appendingPathComponent("Qwen2.5-0.5B-Instruct-4bit")
    }

    // MARK: - Initialization

    private init(threshold: Float = 0.0, outlierThreshold: Float = 18.0, capThreshold: Float = 18.0) {
        self.threshold = threshold
        self.outlierThreshold = outlierThreshold
        self.capThreshold = capThreshold
    }

    // MARK: - Public API

    /// Whether the CoreML model and tokenizer are fully loaded and ready for inference.
    nonisolated var isLoaded: Bool {
        model != nil && tokenizer != nil
    }

    /// Update Score thresholds after calibration.
    func updateThresholds(outlier: Float, cap: Float) {
        outlierThreshold = outlier
        capThreshold = cap
    }

    /// Load CoreML model and tokenizer from a directory.
    /// Defaults to `qwenDirectory` if no explicit directory is provided.
    func ensureLoaded(modelDirectory: URL? = nil) async throws {
        guard model == nil else { return }

        let directory = modelDirectory ?? Self.qwenDirectory
        let compiledModelURL = try findCompiledModel(in: directory)

        let config = MLModelConfiguration()
        // macOS has full GPU access - use all compute units
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: compiledModelURL, configuration: config)

        self.tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    }

    /// Run a minimal inference to warm up the CoreML model.
    func warmUp() {
        _ = try? tokenScores("hello")
    }

    // MARK: - Private: Model Discovery

    private func findCompiledModel(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        // Look for .mlmodelc (pre-compiled) - preferred
        if let compiled = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
            return compiled
        }

        // Look for .mlpackage and compile on-the-fly
        if let package = contents.first(where: { $0.pathExtension == "mlpackage" }) {
            let compiledURL = try MLModel.compileModel(at: package)
            let destination = directory.appendingPathComponent(
                package.deletingPathExtension().lastPathComponent + ".mlmodelc"
            )
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: compiledURL, to: destination)
            return destination
        }

        throw QwenEngineError.modelNotFound
    }

    // MARK: - Core Score Computation

    /// Compute per-token token scores via a single pass.
    ///
    /// Sends all tokens at once with a causal mask so the model computes logits
    /// for every position in a single pass. Falls back to token-by-token
    /// if the model doesn't support the batch input shape.
    ///
    /// - Returns: `(tokenIds, scores)` where `scores[i] is the model's per-token score (lower = better fit)`.
    ///   `scores` has length `tokenIds.count - 1`.
    func tokenScores(_ text: String) throws -> ([Int], [Float]) {
        guard let model = model, let tokenizer = tokenizer else { return ([], []) }

        let tokens = tokenizer.encode(text: text)
        guard tokens.count >= 2 else { return (tokens, []) }

        let seqLen = min(tokens.count, Self.maxSequenceLength)

        guard #available(macOS 15.0, *) else { return (tokens, []) }

        // Try a single pass first (all tokens in one pass)
        if let result = try? batchTokenScores(tokens: Array(tokens.prefix(seqLen)), model: model) {
            return result
        }

        // Fallback: token-by-token with KV cache
        return try tokenByTokenScores(tokens: Array(tokens.prefix(seqLen)), model: model)
    }

    /// Batch prefill: send all N tokens at once, get logits [1, N, vocab] in one pass.
    @available(macOS 15.0, *)
    private func batchTokenScores(tokens: [Int], model: MLModel) throws -> ([Int], [Float]) {
        let seqLen = tokens.count
        let state = model.makeState()

        // input_ids: [1, N]
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let inputPtr = inputArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<seqLen {
            inputPtr[i] = Int32(tokens[i])
        }

        // causal_mask: [1, 1, N, N] - lower-triangular (causal)
        // 0 = attend, -inf (large negative) = mask
        let maskArray = try MLMultiArray(shape: [1, 1, NSNumber(value: seqLen), NSNumber(value: seqLen)], dataType: .float16)
        let maskPtr = maskArray.dataPointer.assumingMemoryBound(to: UInt16.self)
        let zeroFP16: UInt16 = 0x0000       // float16 zero (attend)
        let negInfFP16: UInt16 = 0xFC00     // float16 -inf (mask)
        for i in 0..<seqLen {
            for j in 0..<seqLen {
                maskPtr[i * seqLen + j] = (j <= i) ? zeroFP16 : negInfFP16
            }
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray),
            "causal_mask": MLFeatureValue(multiArray: maskArray),
        ])

        let output = try model.prediction(from: inputFeatures, using: state)

        guard let logitsArray = output.featureValue(for: "logits")?.multiArrayValue else {
            throw QwenEngineError.outputNotFound
        }

        // logits shape: [1, N, vocab_size]
        guard logitsArray.shape.count >= 3 else {
            throw QwenEngineError.outputNotFound
        }
        let outSeqLen = logitsArray.shape[1].intValue
        let vocabSize = logitsArray.shape[2].intValue
        guard outSeqLen >= seqLen && vocabSize > 0 else {
            throw QwenEngineError.outputNotFound
        }

        // Compute Score for each position: score[i] = -log_softmax(logits[i])[token[i+1]]
        var scores: [Float] = []
        let logitsPtr = logitsArray.dataPointer.assumingMemoryBound(to: UInt16.self)

        for i in 0..<(seqLen - 1) {
            let nextToken = tokens[i + 1]
            let offset = i * vocabSize

            // the model output for numerical stability
            var maxLogit: Float = -.greatestFiniteMagnitude
            for v in 0..<vocabSize {
                let val = Float16Bits.toFloat(logitsPtr[offset + v])
                if val > maxLogit { maxLogit = val }
            }
            var sumExp: Float = 0
            for v in 0..<vocabSize {
                sumExp += exp(Float16Bits.toFloat(logitsPtr[offset + v]) - maxLogit)
            }
            let logSumExp = maxLogit + Foundation.log(sumExp)
            let score = -(Float16Bits.toFloat(logitsPtr[offset + nextToken]) - logSumExp)
            scores.append(score)
        }

        return (tokens, scores)
    }

    /// Fallback: token-by-token with KV cache (slower but always works).
    @available(macOS 15.0, *)
    private func tokenByTokenScores(tokens: [Int], model: MLModel) throws -> ([Int], [Float]) {
        let seqLen = tokens.count
        let state = model.makeState()
        var scores: [Float] = []

        for i in 0..<(seqLen - 1) {
            let inputArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
            inputArray[0] = NSNumber(value: Int32(tokens[i]))

            let maskArray = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16)
            maskArray[0] = NSNumber(value: Float(0.0))

            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputArray),
                "causal_mask": MLFeatureValue(multiArray: maskArray),
            ])

            let output = try model.prediction(from: inputFeatures, using: state)

            guard let logitsArray = output.featureValue(for: "logits")?.multiArrayValue else {
                throw QwenEngineError.outputNotFound
            }

            guard let vocabSize = logitsArray.shape.last?.intValue, vocabSize > 0 else {
                throw QwenEngineError.outputNotFound
            }
            let nextToken = tokens[i + 1]

            var maxLogit: Float = -.greatestFiniteMagnitude
            for v in 0..<vocabSize {
                let val = logitsArray[v].floatValue
                if val > maxLogit { maxLogit = val }
            }
            var sumExp: Float = 0
            for v in 0..<vocabSize {
                sumExp += exp(logitsArray[v].floatValue - maxLogit)
            }
            let logSumExp = maxLogit + Foundation.log(sumExp)
            let score = -(logitsArray[nextToken].floatValue - logSumExp)
            scores.append(score)
        }

        return (tokens, scores)
    }

    /// Score potential trailing punctuation using stateful token-by-token inference.
    /// Returns (avgScore of existing tokens, {punct: Score for that punct at end}).
    func scoreTrailingPunctuation(
        _ text: String,
        punctuation: [String] = [".", "?", "!"]
    ) throws -> (Float, [String: Float]) {
        guard let model = model, let tokenizer = tokenizer else {
            return (0.0, Dictionary(uniqueKeysWithValues: punctuation.map { ($0, Float.infinity) }))
        }

        let tokens = tokenizer.encode(text: text)
        guard tokens.count >= 2 else {
            return (0.0, Dictionary(uniqueKeysWithValues: punctuation.map { ($0, Float.infinity) }))
        }

        guard #available(macOS 15.0, *) else {
            return (0.0, Dictionary(uniqueKeysWithValues: punctuation.map { ($0, Float.infinity) }))
        }

        let seqLen = min(tokens.count, Self.maxSequenceLength)
        let state = model.makeState()
        var scores: [Float] = []
        var lastLogits: MLMultiArray?

        // Feed all tokens, collecting Scores and keeping last logits
        for i in 0..<seqLen {
            let inputArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
            inputArray[0] = NSNumber(value: Int32(tokens[i]))
            let maskArray = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16)
            maskArray[0] = NSNumber(value: Float(0.0))

            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": inputArray,
                "causal_mask": maskArray,
            ])
            let output = try model.prediction(from: inputFeatures, using: state)
            guard let logitsArray = output.featureValue(for: "logits")?.multiArrayValue else {
                throw QwenEngineError.outputNotFound
            }

            if i < seqLen - 1 {
                guard let vocabSize = logitsArray.shape.last?.intValue, vocabSize > 0 else {
                    throw QwenEngineError.outputNotFound
                }
                let nextToken = tokens[i + 1]
                var maxLogit: Float = -.greatestFiniteMagnitude
                for v in 0..<vocabSize { maxLogit = max(maxLogit, logitsArray[v].floatValue) }
                var sumExp: Float = 0
                for v in 0..<vocabSize { sumExp += exp(logitsArray[v].floatValue - maxLogit) }
                let score = -(logitsArray[nextToken].floatValue - (maxLogit + Foundation.log(sumExp)))
                scores.append(score)
            }
            lastLogits = logitsArray
        }

        let avgScore = scores.isEmpty ? 0.0 : scores.reduce(0.0, +) / Float(scores.count)

        // Score each candidate punctuation using the last position's logits
        var punctScores: [String: Float] = [:]
        if let logits = lastLogits, let vocabSize = logits.shape.last?.intValue, vocabSize > 0 {
            var maxLogit: Float = -.greatestFiniteMagnitude
            for v in 0..<vocabSize { maxLogit = max(maxLogit, logits[v].floatValue) }
            var sumExp: Float = 0
            for v in 0..<vocabSize { sumExp += exp(logits[v].floatValue - maxLogit) }
            let logSumExp = maxLogit + Foundation.log(sumExp)

            for p in punctuation {
                let pTokens = tokenizer.encode(text: p)
                let realTokens = pTokens.count > 1 ? Array(pTokens.dropFirst()) : pTokens
                if let firstToken = realTokens.first {
                    punctScores[p] = -(logits[firstToken].floatValue - logSumExp)
                } else {
                    punctScores[p] = Float.infinity
                }
            }
        }

        return (avgScore, punctScores)
    }

}

// MARK: - Errors

enum QwenEngineError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case outputNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "No .mlmodelc or .mlpackage found in Qwen model directory"
        case .modelNotLoaded:
            return "Qwen CoreML model not loaded"
        case .outputNotFound:
            return "Qwen CoreML model did not produce 'logits' output"
        }
    }
}
