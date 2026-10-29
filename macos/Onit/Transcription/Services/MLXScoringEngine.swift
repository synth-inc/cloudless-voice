// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXScoringEngine.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-09.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

// MARK: - MLXScoringEngine

/// MLX-based scoring engine using the Llama 3.2 1B model.
///
/// Performs a **single pass** for all tokens (a single pass) to compute
/// per-token Scores, which is significantly faster than the CoreML token-by-token
/// approach used by `QwenScoringEngine`.
///
/// The engine uses MLX Swift for GPU-accelerated inference via Metal.
actor MLXScoringEngine {

    // MARK: - Singleton

    static let shared = MLXScoringEngine()

    // MARK: - Constants

    /// Maximum sequence length for a single pass.
    static let maxSequenceLength = 512

    // MARK: - Private State

    private var modelContainer: ModelContainer?
    private var _tokenizer: Tokenizer?
    /// In-flight load, so concurrent `ensureLoaded()` callers coalesce onto one
    /// container allocation instead of each loading their own ~1.25 GB copy.
    private var loadTask: Task<Void, Error>?

    // MARK: - Paths

    private static var modelsBaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models")
    }

    /// Resolved from the user's selected scoring model (see `ScoringModel`), so
    /// the engine loads whichever language-specialized model is selected.
    static var llamaDirectory: URL {
        modelsBaseURL.appendingPathComponent(ScoringModel.selected.dirName)
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Whether the MLX model and tokenizer are fully loaded and ready for inference.
    var isLoaded: Bool { modelContainer != nil && _tokenizer != nil }

    /// Whether the cleanup pipeline should run now.
    ///
    /// Only the scoring-based generators (capitalization, trailing
    /// punctuation/space) consume this engine - every other cleanup category is
    /// deterministic and needs no model at all. So the pipeline waits for the
    /// scorer where it can eventually arrive, and runs without it where it never
    /// will: on Intel, MLX cannot load (see `MLXRuntime`), and gating on
    /// `isLoaded` alone would strand Smart Cleanup on "still loading" forever.
    ///
    /// `TranscriptionConfig.buildSwiftPipelineConfig()` turns the scoring-backed
    /// categories off in that case, so nothing reaches the adapter.
    nonisolated var isCleanupReady: Bool {
        get async { await isLoaded || !MLXRuntime.isSupported }
    }

    /// Load the Llama 3.2 1B model from the local directory using MLX Swift.
    ///
    /// The model weights are expected to already be downloaded at `llamaDirectory`
    /// by `HuggingFaceModelDownloader.downloadLlamaIfNeeded()`.
    func ensureLoaded() async throws {
        // Last line of defence: MLX is a hard crash on Intel (see `MLXRuntime`).
        guard MLXRuntime.isSupported else { throw MLXRuntime.UnsupportedError() }
        if modelContainer != nil { return }
        // Coalesce concurrent loads onto one task. Without this, two callers (e.g.
        // a re-arm from a live dictation and `ensureResidentForCleanup()` on the
        // reTranscribe path) both pass the nil check and each allocate a ~1.25 GB
        // container - a transient 2× spike in a feature meant to reclaim RAM.
        if let loadTask { return try await loadTask.value }
        let task = Task { try await self.performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        guard modelContainer == nil else { return }

        let modelDir = Self.llamaDirectory
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw MLXScoringError.modelNotFound
        }

        log.info("MLXScoringEngine: Loading Llama 3.2 1B from \(modelDir.path)...")

        let configuration = ModelConfiguration(directory: modelDir)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        )

        self.modelContainer = container
        self._tokenizer = await container.tokenizer

        log.info("MLXScoringEngine: Model loaded successfully")
    }

    /// Run a minimal inference to warm up the MLX model and Metal pipeline.
    func warmUp() async {
        _ = try? await tokenScores("hello")
    }

    /// Drop the loaded model container + tokenizer. Called when smart formatting /
    /// LM conditioning is disabled so the ~1.25 GB MLX/Metal allocation backing
    /// Llama 3.2 1B is reclaimed instead of staying resident for the whole session.
    /// The caller is responsible for flushing the MLX buffer pool (`MLX.Memory.clearCache()`)
    /// - kept out of here so the engine has no dependency on the `MLX` umbrella.
    func unload() {
        modelContainer = nil
        _tokenizer = nil
    }

    // MARK: - Core Score Computation

    /// Compute per-token token scores via a single batch pass.
    ///
    /// Feeds all tokens at once through the model to get logits for every position,
    /// then computes Score using the model output.
    ///
    /// - Returns: `(tokenIds, scores)` where `scores[i] is the model's per-token score (lower = better fit)`.
    ///   `scores` has length `tokenIds.count - 1`.
    func tokenScores(_ text: String) async throws -> (tokenIds: [Int], scores: [Float]) {
        guard let container = modelContainer, let tokenizer = _tokenizer else {
            throw MLXScoringError.modelNotLoaded
        }

        let tokens = tokenizer.encode(text: text)
        guard tokens.count >= 2 else { return (tokens, []) }

        let seqLen = min(tokens.count, Self.maxSequenceLength)
        let truncatedTokens = Array(tokens.prefix(seqLen))

        // Pass token data as Sendable values into the perform closure
        let tokenInt32 = truncatedTokens.map { Int32($0) }

        // Forward pass: get logits [1, seqLen, vocabSize] for all positions
        let scores: [Float] = await container.perform { context in
            // Create MLX input array inside the closure to avoid Sendable issues
            let inputIds = MLXArray(tokenInt32).reshaped([1, seqLen])
            let inputText = LMInput.Text(tokens: inputIds)

            // Create fresh KV cache for each pass (no state carried over)
            let cache = context.model.newCache(parameters: nil)

            // Run the model on all tokens at once
            let output = context.model(inputText, cache: cache, state: nil)
            let logits = output.logits  // [1, seqLen, vocabSize]

            // Compute the model output along the vocabulary axis
            let logProbs = logSoftmax(logits, axis: -1)  // [1, seqLen, vocabSize]

            // Extract Score for each next-token prediction
            // score[i] = -logProbs[0, i, truncatedTokens[i+1]]
            var scoreValues: [Float] = []
            scoreValues.reserveCapacity(seqLen - 1)

            for i in 0..<(seqLen - 1) {
                let nextToken = Int(tokenInt32[i + 1])
                let score = -logProbs[0, i, nextToken].item(Float.self)
                scoreValues.append(score)
            }

            // Force evaluation of all lazy MLX operations before leaving the closure
            eval(logProbs)

            return scoreValues
        }

        return (truncatedTokens, scores)
    }

    /// Return the top-K most likely next tokens after `prefix`.
    ///
    /// Runs a single pass on `prefix` and reads the full vocabulary
    /// distribution at the last position. Used by `CustomDictionaryProxySelector`
    /// to auto-select a proxy word for the Score gate.
    ///
    /// - Returns: Array of `(token, probability)` sorted by probability descending.
    func topKNext(prefix: String, k: Int = 20) async throws -> [(token: String, prob: Float)] {
        guard let container = modelContainer, let tokenizer = _tokenizer else {
            throw MLXScoringError.modelNotLoaded
        }

        let tokens = tokenizer.encode(text: prefix)
        guard !tokens.isEmpty else { return [] }

        let seqLen = min(tokens.count, Self.maxSequenceLength)
        let truncatedTokens = Array(tokens.prefix(seqLen))
        let tokenInt32 = truncatedTokens.map { Int32($0) }

        let topKRaw: [(Int, Float)] = await container.perform { context in
            let inputIds = MLXArray(tokenInt32).reshaped([1, seqLen])
            let inputText = LMInput.Text(tokens: inputIds)
            let cache = context.model.newCache(parameters: nil)
            let output = context.model(inputText, cache: cache, state: nil)
            let logits = output.logits  // [1, seqLen, vocabSize]

            // Last-position logits → softmax probabilities
            let lastLogits = logits[0, seqLen - 1]   // [vocabSize]
            let probs = softmax(lastLogits.flattened(), axis: -1)
            eval(probs)

            let probArray = probs.asArray(Float.self)
            return probArray.enumerated()
                .sorted { $0.element > $1.element }
                .prefix(k)
                .map { ($0.offset, $0.element) }
        }

        return topKRaw.compactMap { tokenId, prob in
            let decoded = tokenizer.decode(tokens: [tokenId]).trimmingCharacters(in: .whitespaces)
            guard !decoded.isEmpty else { return nil }
            return (decoded, prob)
        }
    }

    /// Generate a short sentence using the loaded Llama model.
    ///
    /// Uses a `ChatSession` for autoregressive generation. Reuses the same
    /// `ModelContainer` as Score scoring - no extra memory overhead.
    func generateText(prompt: String) async throws -> String {
        guard let container = modelContainer else {
            throw MLXScoringError.modelNotLoaded
        }
        nonisolated(unsafe) let session = ChatSession(
            container,
            instructions: "You write short, natural sentences. Respond with only the sentence, nothing else.",
            generateParameters: GenerateParameters(temperature: 0.8, topP: 0.9)
        )
        return try await session.respond(to: prompt)
    }

    /// Score potential trailing punctuation characters.
    ///
    /// For each punctuation character `p`, appends it to `text`, runs a pass,
    /// and reads the Score of the punctuation token. Uses separate passes per
    /// punctuation variant.
    ///
    /// - Returns: `(avgScore, punctScores)` where `avgScore` is the mean Score over the
    ///   existing tokens in `text`, and `punctScores` maps each punctuation character to
    ///   its Score if appended.
    func scoreTrailingPunctuation(
        _ text: String,
        punctuation: [String] = [".", "?", "!"]
    ) async throws -> (avgScore: Float, punctScores: [String: Float]) {
        let (baseTokenIds, baseScores) = try await tokenScores(text)
        let avgScore = baseScores.isEmpty ? 0 : baseScores.reduce(0, +) / Float(baseScores.count)

        // The Score of a punctuation token appended to `text` is at index
        // `baseTokenIds.count - 1` in the Score array of `text + p`.
        let punctIdx = baseTokenIds.count - 1

        var punctScores: [String: Float] = [:]
        for p in punctuation {
            let (_, pScores) = try await tokenScores(text + p)
            if punctIdx < pScores.count {
                punctScores[p] = pScores[punctIdx]
            } else {
                punctScores[p] = .infinity
            }
        }

        return (avgScore, punctScores)
    }

}

// MARK: - Errors

enum MLXScoringError: LocalizedError {
    case modelNotFound
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Llama model directory not found at expected path"
        case .modelNotLoaded:
            return "MLX scoring model is not loaded"
        }
    }
}
