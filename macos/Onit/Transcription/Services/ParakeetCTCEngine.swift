// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ParakeetCTCEngine.swift
//  Onit
//
//  CoreML inference engine for the parakeet-ctc-110m model.
//  Runs MelSpectrogram + AudioEncoder (with CTC head) to produce per-frame log probabilities.
//  Used by CustomDictionaryService for vocabulary biasing.
//

import CoreML
import Foundation

// MARK: - Errors

enum ParakeetCTCError: LocalizedError {
    case modelNotLoaded
    case modelsNotFound(path: String)
    case tokenizerNotFound
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Parakeet CTC model is not loaded."
        case .modelsNotFound(let p):
            return "Parakeet CTC models not found at \(p)"
        case .tokenizerNotFound:
            return "Parakeet CTC tokenizer.json not found"
        case .inferenceError(let m):
            return "Parakeet CTC inference error: \(m)"
        }
    }
}

// MARK: - Engine

/// CoreML inference engine for parakeet-ctc-110m.
///
/// Loads two models: `MelSpectrogram.mlmodelc` and `AudioEncoder.mlmodelc`.
/// Takes raw 16 kHz audio samples and returns per-frame CTC log probabilities.
actor ParakeetCTCEngine {

    static let shared = ParakeetCTCEngine()

    // MARK: - Constants

    /// Maximum audio samples the CTC model accepts: 15s × 16kHz
    private static let maxModelSamples = 240_000
    private static let sampleRate = 16_000
    /// Dimension of the encoder's hidden state (encoder_output_embeds).
    static let embeddingDim = 512

    // MARK: - State

    // All mutable state is actor-isolated. `nonisolated(unsafe)` was previously
    // used here to expose a synchronous `isLoaded` accessor, but that defeated
    // the actor: writes from `ensureLoaded()` raced reads from any thread.
    // There are no external callers of `isLoaded`, and all call sites already
    // `await` into the actor, so the escape hatches were dropped entirely.
    private var melModel: MLModel?
    private var encoderModel: MLModel?
    private var tokenizer: BpeTokenizer?
    private var _isLoaded = false

    // MARK: - Paths

    private static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models/parakeet-ctc-110m-coreml")
    }

    private init() {}

    // MARK: - Load

    func ensureLoaded() async throws {
        guard !_isLoaded else { return }

        let dir = Self.modelsDir

        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw ParakeetCTCError.modelsNotFound(path: dir.path)
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let melPath = dir.appendingPathComponent("MelSpectrogram.mlmodelc")
        let encoderPath = dir.appendingPathComponent("AudioEncoder.mlmodelc")

        melModel = try await MLModel.load(contentsOf: melPath, configuration: config)
        encoderModel = try await MLModel.load(contentsOf: encoderPath, configuration: config)

        // Load BPE tokenizer directly from tokenizer.json (no HuggingFace network call needed)
        tokenizer = try BpeTokenizer.load(from: dir)

        _isLoaded = true
        log.info("ParakeetCTCEngine: Loaded successfully")
    }

    // MARK: - Tokenization

    /// Tokenize a term to CTC token IDs (no BOS token added).
    func tokenize(_ text: String) throws -> [Int] {
        guard let tok = tokenizer else { throw ParakeetCTCError.modelNotLoaded }
        // BpeTokenizer lowercases internally - no BOS/EOS for CTC
        return tok.encode(text)
    }

    // MARK: - CTC Inference

    /// Compute CTC log probabilities for the given audio samples.
    ///
    /// - Parameter audioSamples: Raw 16 kHz mono float32 audio.
    /// - Returns: `(logProbs, frameDuration)` where `logProbs[t]` is a vocab-size
    ///   vector of log probabilities at frame `t`, and `frameDuration` is seconds per frame.
    func computeLogProbs(for audioSamples: [Float]) async throws -> (logProbs: [[Float]], frameDuration: Double) {
        let (logProbs, _, frameDuration) = try await computeLogProbsAndEmbeddings(for: audioSamples)
        return (logProbs, frameDuration)
    }

    /// Compute CTC log probabilities AND encoder embeddings for the given audio samples.
    ///
    /// - Parameter audioSamples: Raw 16 kHz mono float32 audio.
    /// - Returns: `(logProbs, embeddings, frameDuration)` where `embeddings[t]` is the
    ///   512-dim encoder hidden state at frame `t`. `embeddings` is nil for clips that
    ///   require chunked processing (>15s) or when the model doesn't expose the output.
    func computeLogProbsAndEmbeddings(for audioSamples: [Float]) async throws -> (logProbs: [[Float]], embeddings: [[Float]]?, frameDuration: Double) {
        guard _isLoaded else { throw ParakeetCTCError.modelNotLoaded }
        guard !audioSamples.isEmpty else { return ([], nil, 0) }

        if audioSamples.count > Self.maxModelSamples {
            // Chunked path doesn't merge embeddings - return nil for embeddings.
            let (logProbs, frameDuration) = try await computeLogProbsChunked(audioSamples: audioSamples)
            return (logProbs, nil, frameDuration)
        }

        return try await computeWithStagedModels(audioSamples: audioSamples)
    }

    // MARK: - Private: Chunked processing

    private func computeLogProbsChunked(audioSamples: [Float]) async throws -> (logProbs: [[Float]], frameDuration: Double) {
        // Chunked path: collect only log probs, discard embeddings.
        let results = try await computeLogProbsAndEmbeddingsChunked(audioSamples: audioSamples)
        return (results.logProbs, results.frameDuration)
    }

    private func computeLogProbsAndEmbeddingsChunked(audioSamples: [Float]) async throws -> (logProbs: [[Float]], frameDuration: Double) {
        let chunkSize = Self.maxModelSamples
        let overlap = chunkSize / 4  // 25% overlap
        let stride = chunkSize - overlap

        var chunks: [(start: Int, end: Int)] = []
        var start = 0
        while start < audioSamples.count {
            let end = min(start + chunkSize, audioSamples.count)
            chunks.append((start: start, end: end))
            if end >= audioSamples.count { break }
            start += stride
        }

        var chunkResults: [(logProbs: [[Float]], frameDuration: Double)] = []
        for chunk in chunks {
            let chunkAudio = Array(audioSamples[chunk.start..<chunk.end])
            let result = try await computeWithStagedModels(audioSamples: chunkAudio)
            chunkResults.append((result.logProbs, result.frameDuration))
        }

        guard !chunkResults.isEmpty else { return ([], 0) }

        let frameDuration = chunkResults[0].frameDuration
        guard frameDuration > 0 else { return ([], 0) }

        let overlapFrames = Int(Double(overlap) / Double(Self.sampleRate) / frameDuration)

        var concatenated: [[Float]] = []
        for (idx, result) in chunkResults.enumerated() {
            let logProbs = result.logProbs
            guard !logProbs.isEmpty else { continue }

            if idx == 0 {
                concatenated.append(contentsOf: logProbs)
            } else {
                let overlapCount = min(overlapFrames, concatenated.count, logProbs.count)
                if overlapCount > 0 {
                    let existingStart = concatenated.count - overlapCount
                    for i in 0..<overlapCount {
                        let existingIdx = existingStart + i
                        let newFrame = logProbs[i]
                        let existingFrame = concatenated[existingIdx]
                        // NOTE: this is an arithmetic mean of log-probabilities, not a
                        // proper log-space merge. A correct fusion would be
                        // `logsumexp(a, b) - log 2` which represents the average of
                        // the underlying probabilities. The arithmetic mean is a
                        // usable approximation at the chunk overlap (~25 %) where
                        // the two frames typically disagree very little, but it is
                        // mathematically wrong at the margins. Good enough for BETA
                        // rescoring where we only care about relative scores.
                        var averaged = [Float](repeating: 0, count: existingFrame.count)
                        for v in 0..<existingFrame.count {
                            averaged[v] = (existingFrame[v] + newFrame[v]) / 2.0
                        }
                        concatenated[existingIdx] = averaged
                    }
                }
                if overlapCount < logProbs.count {
                    concatenated.append(contentsOf: logProbs.suffix(from: overlapCount))
                }
            }
        }

        return (concatenated, frameDuration)
    }

    // MARK: - Private: Single-chunk inference

    private func computeWithStagedModels(audioSamples: [Float]) async throws -> (logProbs: [[Float]], embeddings: [[Float]]?, frameDuration: Double) {
        guard let melModel = melModel, let encoderModel = encoderModel else {
            throw ParakeetCTCError.modelNotLoaded
        }

        let clampedCount = min(audioSamples.count, Self.maxModelSamples)

        // --- Build audio input array ---
        // Detect rank from model description (rank 1 [samples] or rank 2 [1, samples])
        let audioDesc = melModel.modelDescription.inputDescriptionsByName["audio"]
        let expectedRank = audioDesc?.multiArrayConstraint?.shape.count ?? 1
        let dataType: MLMultiArrayDataType =
            audioDesc?.multiArrayConstraint?.dataType == .float16 ? .float16 : .float32

        let audioArray: MLMultiArray
        if expectedRank == 2 {
            audioArray = try MLMultiArray(shape: [1, NSNumber(value: Self.maxModelSamples)], dataType: dataType)
        } else {
            audioArray = try MLMultiArray(shape: [NSNumber(value: Self.maxModelSamples)], dataType: dataType)
        }
        for i in 0..<clampedCount {
            audioArray[i] = NSNumber(value: audioSamples[i])
        }

        let audioLengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        audioLengthArray[0] = NSNumber(value: clampedCount)

        let melInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLengthArray),
        ])

        // --- Run MelSpectrogram ---
        let predictionOptions = MLPredictionOptions()
        let melOutput = try await melModel.compatPrediction(from: melInput, options: predictionOptions)

        guard let melFeatures = melOutput.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
            throw ParakeetCTCError.inferenceError("Missing melspectrogram_features from CTC MelSpectrogram model")
        }

        var melLengthValue =
            melOutput.featureValue(for: "mel_length")?.multiArrayValue?[0].intValue
            ?? melFeatures.shape.last?.intValue
        if melFeatures.shape.count == 4 {
            melLengthValue = melFeatures.shape[2].intValue
        }

        // --- Build encoder input ---
        let lengthValue = melLengthValue ?? melFeatures.shape.last?.intValue ?? 0
        guard lengthValue > 0 else {
            throw ParakeetCTCError.inferenceError("Invalid mel_length for CTC encoder input")
        }

        let melLengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        melLengthArray[0] = NSNumber(value: lengthValue)

        var encoderDict: [String: MLFeatureValue] = [
            "melspectrogram_features": MLFeatureValue(multiArray: melFeatures),
            "mel_length": MLFeatureValue(multiArray: melLengthArray),
        ]
        // Some exported variants of the AudioEncoder model declare an extra
        // `input_1` tensor that must be supplied even though the value is
        // unused inside the graph (a residual of the PyTorch → CoreML export).
        // Feeding a 1×1×1×1 float16 tensor containing `1.0` satisfies the
        // shape constraint on those variants; newer exports without the
        // field simply ignore the key in the feature dictionary.
        if let input1 = try? MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16) {
            input1[0] = 1
            encoderDict["input_1"] = MLFeatureValue(multiArray: input1)
        }

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: encoderDict)

        // --- Run AudioEncoder ---
        let encoderOutput = try await encoderModel.compatPrediction(from: encoderInput, options: predictionOptions)

        // Prefer raw logits over post-softmax output
        let ctcRaw =
            encoderOutput.featureValue(for: "ctc_head_raw_output")?.multiArrayValue
            ?? encoderOutput.featureValue(for: "ctc_head_output")?.multiArrayValue

        guard let ctcRaw else {
            throw ParakeetCTCError.inferenceError("Missing CTC head output from encoder model")
        }

        // --- Convert logits to log-probabilities ---
        let allLogProbs = try makeLogProbs(
            from: ctcRaw,
            temperature: ContextBiasingConstants.ctcTemperature,
            blankBias: ContextBiasingConstants.blankBias,
            blankId: ContextBiasingConstants.defaultBlankId
        )
        let trimmed = trimLogProbs(allLogProbs, audioSampleCount: clampedCount)
        let frameCount = trimmed.count

        let frameDuration = frameCount > 0
            ? Double(clampedCount) / Double(frameCount) / Double(Self.sampleRate)
            : 0

        // Extract encoder hidden states (encoder_output_embeds) for Contrastive DTW.
        // Shape: [1, 512, 1, T] - stride-aware extraction handles non-C-contiguous layouts.
        let embeddings: [[Float]]? = {
            guard let embRaw = encoderOutput.featureValue(for: "encoder_output_embeds")?.multiArrayValue else {
                return nil
            }
            guard embRaw.shape.count == 4 else { return nil }
            let T = embRaw.shape[3].intValue
            let dim = Self.embeddingDim
            guard T > 0, embRaw.shape[1].intValue >= dim else { return nil }

            let s1 = embRaw.strides[1].intValue  // stride along embedding dim
            let s3 = embRaw.strides[3].intValue  // stride along time

            var embs = [[Float]](repeating: [Float](repeating: 0, count: dim), count: T)
            if embRaw.dataType == .float16 {
                let ptr = embRaw.dataPointer.bindMemory(to: UInt16.self, capacity: embRaw.count)
                for t in 0..<T {
                    for d in 0..<dim {
                        embs[t][d] = Self.float16ToFloat32(ptr[s1 * d + s3 * t])
                    }
                }
            } else {
                let ptr = embRaw.dataPointer.bindMemory(to: Float.self, capacity: embRaw.count)
                for t in 0..<T {
                    for d in 0..<dim {
                        embs[t][d] = ptr[s1 * d + s3 * t]
                    }
                }
            }
            // Trim to valid frames (same as logProbs trim)
            let validT = min(T, frameCount)
            return validT < T ? Array(embs.prefix(validT)) : embs
        }()

        return (trimmed, embeddings, frameDuration)
    }

    private static func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign    = UInt32(bits >> 15) << 31
        let exp16   = Int32((bits >> 10) & 0x1F)
        let mant16  = UInt32(bits & 0x3FF)
        if exp16 == 0 {
            if mant16 == 0 { return Float(bitPattern: sign) }
            // Subnormal
            var m = mant16; var e = Int32(-14)
            while m & 0x400 == 0 { m <<= 1; e -= 1 }
            let exp32 = UInt32(bitPattern: e + 127) << 23
            return Float(bitPattern: sign | exp32 | ((m & 0x3FF) << 13))
        } else if exp16 == 31 {
            return mant16 == 0
                ? Float(bitPattern: sign | 0x7F80_0000)
                : Float(bitPattern: sign | 0x7FC0_0000 | (mant16 << 13))
        }
        let exp32 = UInt32(bitPattern: exp16 - 15 + 127) << 23
        return Float(bitPattern: sign | exp32 | (mant16 << 13))
    }

    // MARK: - Private: Log probability conversion

    private func makeLogProbs(
        from ctcOutput: MLMultiArray,
        temperature: Float,
        blankBias: Float,
        blankId: Int
    ) throws -> [[Float]] {
        let rank = ctcOutput.shape.count
        guard rank == 3 || rank == 4 else {
            throw ParakeetCTCError.inferenceError("Unexpected CTC output rank: \(ctcOutput.shape)")
        }

        let vocabSize: Int
        let timeSteps: Int
        let indexBuilder: (Int, Int) -> [NSNumber]

        if rank == 3 {
            // [1, timeSteps, vocabSize]
            timeSteps = ctcOutput.shape[1].intValue
            vocabSize = ctcOutput.shape[2].intValue
            indexBuilder = { t, v in [0, t, v].map { NSNumber(value: $0) } }
        } else {
            // [1, vocabSize, 1, timeSteps]
            vocabSize = ctcOutput.shape[1].intValue
            timeSteps = ctcOutput.shape[3].intValue
            indexBuilder = { t, v in [0, v, 0, t].map { NSNumber(value: $0) } }
        }

        guard vocabSize > 0 && timeSteps > 0 else { return [] }

        var logProbs: [[Float]] = Array(
            repeating: Array(repeating: 0, count: vocabSize),
            count: timeSteps
        )

        for t in 0..<timeSteps {
            var logits = [Float](repeating: 0, count: vocabSize)
            for v in 0..<vocabSize {
                logits[v] = ctcOutput[indexBuilder(t, v)].floatValue
            }

            var row = logSoftmax(logits, temperature: temperature)

            if blankBias != 0.0 && blankId < row.count {
                row[blankId] -= blankBias
            }

            logProbs[t] = row
        }

        return logProbs
    }

    private func logSoftmax(_ logits: [Float], temperature: Float) -> [Float] {
        guard !logits.isEmpty else { return [] }
        let scaled = temperature != 1.0 ? logits.map { $0 / temperature } : logits
        let maxLogit = scaled.max() ?? 0
        var sumExp: Float = 0
        for x in scaled { sumExp += expf(x - maxLogit) }
        let logSumExp = logf(sumExp)
        return scaled.map { ($0 - maxLogit) - logSumExp }
    }

    private func trimLogProbs(_ logProbs: [[Float]], audioSampleCount: Int) -> [[Float]] {
        guard !logProbs.isEmpty else { return logProbs }
        let totalFrames = logProbs.count
        if audioSampleCount >= Self.maxModelSamples { return logProbs }
        let samplesPerFrame = Double(Self.maxModelSamples) / Double(totalFrames)
        let validFrames = Int(ceil(Double(audioSampleCount) / samplesPerFrame))
        let clampedFrames = max(1, min(validFrames, totalFrames))
        return Array(logProbs.prefix(clampedFrames))
    }
}

// MARK: - MLModel compat extension

private extension MLModel {
    /// Wrapper that works for both older and newer CoreML API surfaces.
    func compatPrediction(from input: MLFeatureProvider, options: MLPredictionOptions) async throws -> MLFeatureProvider {
        return try await self.prediction(from: input, options: options)
    }
}
