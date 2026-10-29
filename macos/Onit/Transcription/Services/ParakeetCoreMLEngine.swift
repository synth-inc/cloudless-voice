// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ParakeetCoreMLEngine.swift
//  Onit
//
//  Swift port of coreml_transcriber.py - Parakeet TDT 0.6b v3 CoreML inference.
//  Replaces the Python server `/transcribe` endpoint entirely.
//

import CoreML
import Foundation

// MARK: - Errors

enum ParakeetCoreMLError: LocalizedError {
    case modelNotLoaded
    case modelsNotFound(path: String)
    case inferenceError(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:      return "Parakeet CoreML models are not loaded."
        case .modelsNotFound(let p): return "Parakeet models not found at \(p)"
        case .inferenceError(let m): return "Parakeet inference error: \(m)"
        }
    }
}

// MARK: - Engine

/// Wraps the four Parakeet TDT CoreML models for on-device ASR.
///
/// Mirrors Python's `CoreMLTranscriber` from coreml_transcriber.py.
/// Models live at ~/Library/Application Support/Onit/Models/parakeet-tdt-0.6b-v3-coreml/
actor ParakeetCoreMLEngine {

    static let shared = ParakeetCoreMLEngine()

    // MARK: - Constants (matching Python)

    static let maxModelSamples      = 240_000   // 15s × 16kHz
    private static let blankId              = 8192       // SOS / blank token
    private static let durationBins         = [0, 1, 2, 3, 4]
    private static let maxSymbolsPerStep    = 10
    private static let maxTokensPerChunk    = 150
    private static let samplesPerEncoderFrame = 1280    // MEL_HOP_SIZE × ENCODER_SUBSAMPLING
    private static let decoderHiddenSize    = 640
    private static let encoderHiddenSize    = 1024

    // MARK: - Models

    private var preprocessorModel: MLModel?
    private var encoderModel: MLModel?
    private var decoderModel: MLModel?
    private var jointModel: MLModel?
    /// Variant exposing `top_k_logits` + `top_k_ids` for keyword boosting.
    /// Lazily loaded only when boosted transcription is requested.
    private var jointModelV3: MLModel?
    private var vocabulary: [Int: String] = [:]

    /// True only after ALL four models AND the vocabulary loaded successfully.
    /// Deliberately NOT derived from `preprocessorModel != nil` - a partial load
    /// (e.g. encoder throws after the preprocessor loaded) must read as
    /// "not loaded" so the next `ensureLoaded()` genuinely retries instead of
    /// wedging every transcribe call on `.modelNotLoaded` until app restart.
    private(set) var isLoaded = false

    /// In-flight load, if any. Concurrent `ensureLoaded()` callers (idle-reload
    /// reArm + a session's self-heal) await this single task instead of each
    /// starting their own load - the actor is reentrant at every `await`, so
    /// without this handle two loads could run interleaved.
    private var loadTask: Task<Void, Error>?

    // MARK: - Paths

    private static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models/parakeet-tdt-0.6b-v3-coreml")
    }

    private init() {}

    // MARK: - Unload

    /// Drop every loaded `MLModel` and the vocabulary. Callers (e.g. the model picker's
    /// delete action) use this to avoid the engine holding a reference to a model
    /// whose backing `.mlmodelc` files were just removed from disk.
    ///
    /// If a load is in flight, it is cancelled and awaited first so an
    /// unload-mid-load can't interleave with the `loadModel` awaits and leave
    /// a mixed nil/non-nil model state behind.
    func unload() async {
        if let task = loadTask {
            task.cancel()
            _ = try? await task.value
            loadTask = nil
        }
        clearLoadedState()
    }

    /// Nil out every model, clear the vocabulary, and mark the engine unloaded.
    /// Synchronous (no suspension points) so the reset is atomic on the actor.
    private func clearLoadedState() {
        preprocessorModel = nil
        encoderModel = nil
        decoderModel = nil
        jointModel = nil
        jointModelV3 = nil
        vocabulary = [:]
        isLoaded = false
    }

    // MARK: - Load

    /// Idempotent load. Guarantees on exit:
    ///   • success → all four models + vocabulary are loaded (`isLoaded == true`)
    ///   • failure → clean slate (`isLoaded == false`, all models nil) and the
    ///     error is rethrown, so the next call genuinely retries. A partial
    ///     bundle (interrupted first-run download) throws `.modelsNotFound`,
    ///     which upstream treats as the retryable "needs download" signal.
    /// Concurrent callers coalesce onto a single in-flight load task.
    func ensureLoaded() async throws {
        if isLoaded { return }

        // A load is already in flight (the actor is reentrant at awaits) -
        // piggyback on it instead of starting a second one.
        if let existing = loadTask {
            return try await existing.value
        }

        let task = Task { try await self.performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        let dir = Self.modelsDir

        // Validate the whole bundle up front: all four .mlmodelc directories
        // plus a vocab file must exist. A partial bundle from an interrupted
        // download throws the retryable `.modelsNotFound` instead of
        // half-loading and wedging the engine.
        try Self.validateModelBundle(at: dir)

        var step = "Preprocessor"
        do {
            // Compute units matching Python's CoreMLTranscriber:
            // Preprocessor → cpuOnly  (all ops run on CPU)
            // Encoder/Decoder/Joint → cpuAndNeuralEngine
            let preprocessor = try await loadModel("Preprocessor", dir: dir, computeUnits: .cpuOnly)
            step = "Encoder"
            let encoder = try await loadModel("Encoder", dir: dir, computeUnits: .cpuAndNeuralEngine)
            step = "Decoder"
            let decoder = try await loadModel("Decoder", dir: dir, computeUnits: .cpuAndNeuralEngine)
            step = "JointDecision"
            let joint = try await loadModel("JointDecision", dir: dir, computeUnits: .cpuAndNeuralEngine)

            // Vocabulary: parakeet_v3_vocab.json preferred over parakeet_vocab.json
            step = "vocabulary"
            let v3 = dir.appendingPathComponent("parakeet_v3_vocab.json")
            let v1 = dir.appendingPathComponent("parakeet_vocab.json")
            let vocabURL = FileManager.default.fileExists(atPath: v3.path) ? v3 : v1

            let rawVocab = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabURL))
            let vocab = Dictionary(
                uniqueKeysWithValues: rawVocab.compactMap { (k, v) -> (Int, String)? in
                    guard let id = Int(k) else { return nil }
                    return (id, v)
                }
            )

            // If unload() cancelled us while a model was loading, don't commit.
            try Task.checkCancellation()

            // Commit atomically - no suspension points between these
            // assignments, so no interleaved caller can observe partial state.
            preprocessorModel = preprocessor
            encoderModel = encoder
            decoderModel = decoder
            jointModel = joint
            vocabulary = vocab
            isLoaded = true
        } catch {
            log.warning("ParakeetCoreMLEngine: load failed at \(step) - rolling back to clean slate: \(error)")
            clearLoadedState()
            throw error
        }
    }

    /// Verify every file the load sequence needs exists before touching CoreML:
    /// the four `.mlmodelc` compiled model directories plus a vocab JSON.
    /// (`fileExists(atPath:)` matches directories too, which `.mlmodelc` is.)
    /// Throws `.modelsNotFound` naming the first missing piece - the same
    /// retryable error upstream already interprets as "needs (re)download".
    static func validateModelBundle(at dir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw ParakeetCoreMLError.modelsNotFound(path: dir.path)
        }
        for name in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
            let path = dir.appendingPathComponent("\(name).mlmodelc").path
            guard fm.fileExists(atPath: path) else {
                throw ParakeetCoreMLError.modelsNotFound(path: path)
            }
        }
        let v3 = dir.appendingPathComponent("parakeet_v3_vocab.json")
        let v1 = dir.appendingPathComponent("parakeet_vocab.json")
        guard fm.fileExists(atPath: v3.path) || fm.fileExists(atPath: v1.path) else {
            throw ParakeetCoreMLError.modelsNotFound(path: v3.path)
        }
    }

    private func loadModel(_ name: String, dir: URL, computeUnits: MLComputeUnits) async throws -> MLModel {
        let path = dir.appendingPathComponent("\(name).mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        config.allowLowPrecisionAccumulationOnGPU = true
        return try await MLModel.load(contentsOf: path, configuration: config)
    }

    // MARK: - Public API

    /// Transcribe float32 PCM samples (16 kHz mono) to text.
    /// - Parameters:
    ///   - samples: Raw 16 kHz mono float32 audio
    ///   - language: Optional ISO 639-1 code for language forcing (nil = auto)
    func transcribe(_ samples: [Float], language: String? = nil) throws -> String {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }

        let langTokenId = languageTokenId(language)

        if samples.count <= Self.maxModelSamples {
            return try transcribeSingle(samples, langTokenId: langTokenId)
        } else {
            return try transcribeChunked(samples, langTokenId: langTokenId)
        }
    }

    /// Group already-decoded (tokenId, frameIndex) pairs into per-word
    /// timestamps using the SentencePiece ▁ word-start marker. Cheap helper
    /// used by the live ASR service to attach exact word timings to a
    /// hypothesis without re-running the encoder/decoder.
    func wordTimestamps(tokenIds: [Int], frameTimestamps: [Int]) -> [WordTimestamp] {
        guard tokenIds.count == frameTimestamps.count, !tokenIds.isEmpty else { return [] }

        // v3 vocab uses leading space for word boundaries; fall back to U+2581
        // for older vocab. Sample the first few mapped pieces to decide.
        let spaceMarker: String = {
            let sample = tokenIds.prefix(5).compactMap { vocabulary[$0] }
            return sample.contains(where: { $0.hasPrefix("\u{2581}") }) ? "\u{2581}" : " "
        }()
        let spf = Float(Self.samplesPerEncoderFrame) / 16000.0

        var result: [WordTimestamp] = []
        var wordPieces: [String] = []
        var wordStartFrame = 0
        var wordEndFrame = 0

        func flush(_ pieces: [String], start: Int, end: Int) -> WordTimestamp {
            let text = pieces.joined().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{2581}", with: "")
            return WordTimestamp(
                word: text,
                startSec: Float(start) * spf,
                endSec: Float(end) * spf
            )
        }

        for i in tokenIds.indices {
            let piece = vocabulary[tokenIds[i]] ?? ""
            let frame = frameTimestamps[i]
            if piece.hasPrefix(spaceMarker) && !wordPieces.isEmpty {
                result.append(flush(wordPieces, start: wordStartFrame, end: wordEndFrame))
                wordPieces = [piece]
                wordStartFrame = frame
                wordEndFrame = frame
            } else {
                if wordPieces.isEmpty { wordStartFrame = frame }
                wordPieces.append(piece)
                wordEndFrame = frame
            }
        }
        if !wordPieces.isEmpty {
            result.append(flush(wordPieces, start: wordStartFrame, end: wordEndFrame))
        }
        return result
    }

    /// Returns word-level timestamps for a single ≤15s clip using TDT frame positions.
    /// Groups SentencePiece tokens by the ▁ word-start marker.
    func transcribeWithWordTimestamps(_ samples: [Float], language: String? = nil) throws -> [WordTimestamp] {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }
        guard samples.count <= Self.maxModelSamples else { return [] }

        let langTokenId = languageTokenId(language)
        let originalLength = samples.count
        let framesNeeded = (originalLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let frameAligned = min(framesNeeded * Self.samplesPerEncoderFrame, Self.maxModelSamples)

        var padded = [Float](repeating: 0, count: Self.maxModelSamples)
        padded.replaceSubrange(0..<min(samples.count, Self.maxModelSamples), with: samples.prefix(Self.maxModelSamples))

        let (mel, melLength) = try runPreprocessor(padded, audioLength: frameAligned)
        let (encoderOut, encoderLength) = try runEncoder(mel, melLength: melLength)
        let actualFrames = (frameAligned + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame

        let tokenFrames = try tdtDecodeWithFrames(
            encoderOut: encoderOut,
            encoderLength: encoderLength,
            actualAudioFrames: actualFrames,
            langTokenId: langTokenId)

        // v3 vocab uses leading space for word boundaries; fall back to U+2581 for older vocab
        let spaceMarker: String = {
            let sample = tokenFrames.prefix(5).compactMap { vocabulary[$0.token] }
            return sample.contains(where: { $0.hasPrefix("\u{2581}") }) ? "\u{2581}" : " "
        }()
        let spf = Float(Self.samplesPerEncoderFrame) / 16000.0

        var result: [WordTimestamp] = []
        var wordPieces: [String] = []
        var wordStartFrame = 0
        var wordEndFrame = 0

        func flush(_ pieces: [String], start: Int, end: Int) -> WordTimestamp {
            let text = pieces.joined().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{2581}", with: "")
            return WordTimestamp(word: text,
                                 startSec: Float(start) * spf,
                                 endSec:   Float(end)   * spf)
        }

        for tf in tokenFrames {
            let piece = vocabulary[tf.token] ?? ""
            if piece.hasPrefix(spaceMarker) && !wordPieces.isEmpty {
                result.append(flush(wordPieces, start: wordStartFrame, end: wordEndFrame))
                wordPieces = [piece]
                wordStartFrame = tf.frame
                wordEndFrame = tf.frame
            } else {
                if wordPieces.isEmpty { wordStartFrame = tf.frame }
                wordPieces.append(piece)
                wordEndFrame = tf.frame
            }
        }
        if !wordPieces.isEmpty {
            result.append(flush(wordPieces, start: wordStartFrame, end: wordEndFrame))
        }
        return result
    }

    // MARK: - Private: Segment handling

    private func transcribeSingle(_ samples: [Float], langTokenId: Int?) throws -> String {
        let (text, _, _) = try transcribeSingleWithTimestamps(samples, langTokenId: langTokenId)
        return text
    }

    /// Convenience overload that resolves the language string to a token ID internally.
    func transcribeSingleWithTimestamps(
        _ samples: [Float], language: String?
    ) throws -> (text: String, tokenIds: [Int], timestamps: [Int]) {
        return try transcribeSingleWithTimestamps(samples, langTokenId: languageTokenId(language))
    }

    func transcribeSingleWithTimestamps(
        _ samples: [Float], langTokenId: Int?
    ) throws -> (text: String, tokenIds: [Int], timestamps: [Int]) {
        let originalLength = samples.count

        // Frame-align to SAMPLES_PER_ENCODER_FRAME boundary (matches Python)
        let framesNeeded = (originalLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let frameAligned = min(framesNeeded * Self.samplesPerEncoderFrame, Self.maxModelSamples)
        let audioLength = frameAligned

        // Pad to maxModelSamples
        var padded = [Float](repeating: 0, count: Self.maxModelSamples)
        let copyLen = min(samples.count, Self.maxModelSamples)
        padded.replaceSubrange(0..<copyLen, with: samples[0..<copyLen])

        let (mel, melLength) = try runPreprocessor(padded, audioLength: audioLength)
        let (encoderOut, encoderLength) = try runEncoder(mel, melLength: melLength)
        let actualFrames = (audioLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame

        let (tokenIds, timestamps) = try tdtDecode(
            encoderOut: encoderOut,
            encoderLength: encoderLength,
            actualAudioFrames: actualFrames,
            langTokenId: langTokenId
        )

        return (tokensToText(tokenIds), tokenIds, timestamps)
    }

    /// Transcribe a short window (gap region) and return only the text.
    func transcribeWindowText(_ samples: [Float], language: String? = nil) throws -> String {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }
        return try transcribeSingle(samples, langTokenId: languageTokenId(language))
    }

    // MARK: - Constrained decode (salmon-class recovery)

    /// Constraint applied during a constrained TDT decode pass. The frame range
    /// is in encoder-frame units (one frame = `samplesPerEncoderFrame / 16000` ≈ 80 ms).
    struct DecodeConstraint: Sendable {
        enum Kind: Sendable {
            /// Force the listed token IDs in order at the start of `frameRange`.
            /// Each is emitted with duration=1; the joint network is bypassed
            /// for these emissions but the LSTM is still advanced normally.
            case force(tokens: [Int])
            /// Forbid these token IDs from being emitted anywhere in
            /// `frameRange`. We pick the highest-logit non-forbidden top-K
            /// candidate from the v3 joint network's `top_k_logits` instead.
            case forbid(tokens: Set<Int>)
        }
        let frameRange: Range<Int>
        let kind: Kind

        init(frameRange: Range<Int>, kind: Kind) {
            self.frameRange = frameRange
            self.kind = kind
        }
    }

    /// Decode a ≤15s clip with optional per-frame constraints applied during
    /// the TDT loop. The decoder LSTM evolves over the full audio context just
    /// like in the regular path - constraints only affect which (token,
    /// duration) pair is chosen at each emission step within their frame
    /// range. When `constraints` is empty this matches `transcribeSingleWithTimestamps`.
    ///
    /// Used by the dictionary salmon-class recovery experiment: forcing a
    /// proxy word at the keyword's audio range, optionally with a `forbid`
    /// constraint that blocks the offending ASR word from being re-emitted at
    /// nearby frames, lets us see what the decoder *would* have produced
    /// without the bad fusion.
    func transcribeWithConstraints(
        _ samples: [Float],
        language: String? = nil,
        constraints: [DecodeConstraint] = []
    ) throws -> (text: String, tokenIds: [Int], timestamps: [Int]) {
        try ensureV3JointLoaded()

        let originalLength = samples.count
        let framesNeeded = (originalLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let frameAligned = min(framesNeeded * Self.samplesPerEncoderFrame, Self.maxModelSamples)
        let audioLength = frameAligned

        var padded = [Float](repeating: 0, count: Self.maxModelSamples)
        let copyLen = min(samples.count, Self.maxModelSamples)
        padded.replaceSubrange(0..<copyLen, with: samples[0..<copyLen])

        let (mel, melLength) = try runPreprocessor(padded, audioLength: audioLength)
        let (encoderOut, encoderLength) = try runEncoder(mel, melLength: melLength)
        let actualFrames = (audioLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let langTokenId = languageTokenId(language)

        let (tokenIds, timestamps) = try tdtDecodeWithConstraints(
            encoderOut: encoderOut,
            encoderLength: encoderLength,
            actualAudioFrames: actualFrames,
            langTokenId: langTokenId,
            constraints: constraints
        )
        return (tokensToText(tokenIds), tokenIds, timestamps)
    }

    /// Constrained TDT decoder. Mirrors `tdtDecode` but evaluates `constraints`
    /// before each emission. Force constraints emit their tokens (one per
    /// `runDecoder` call, advancing the LSTM) and skip the joint network.
    /// Forbid constraints route through `runJointBoosted` with -inf boosts so
    /// the model picks the next-best non-forbidden token from its top-K.
    private func tdtDecodeWithConstraints(
        encoderOut: MLMultiArray,
        encoderLength: Int,
        actualAudioFrames: Int,
        langTokenId: Int?,
        constraints: [DecodeConstraint]
    ) throws -> (tokenIds: [Int], timestamps: [Int]) {
        guard encoderLength > 1 else { return ([], []) }

        let effectiveSeqLen = min(encoderLength, actualAudioFrames)

        var hState = try makeZeroState()
        var cState = try makeZeroState()

        var (decoderOut, h, c) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        hState = h; cState = c

        if let langId = langTokenId {
            let (_, lh, lc) = try runDecoder(token: langId, hIn: hState, cIn: cState)
            hState = lh; cState = lc
        }

        let (encoderFlat, T) = extractEncoderFlat(encoderOut)

        var tokenIds: [Int] = []
        var timestamps: [Int] = []
        var timeIdx = 0
        var lastEmissionTs = -1
        var emissionsAtTs = 0
        var tokensThisChunk = 0
        var pendingForceQueues: [Range<Int>: [Int]] = [:]
        for c in constraints {
            if case let .force(tokens) = c.kind {
                pendingForceQueues[c.frameRange] = tokens
            }
        }
        let lastTimestep = effectiveSeqLen - 1

        // Build a per-frame forbid set lookup. Frame ranges from constraints
        // are typically small, so a linear scan per frame is fine.
        func forbidSet(at frame: Int) -> Set<Int> {
            var union: Set<Int> = []
            for c in constraints {
                if case let .forbid(tokens) = c.kind, c.frameRange.contains(frame) {
                    union.formUnion(tokens)
                }
            }
            return union
        }

        // Returns the first not-yet-emitted forced token at `frame`, or nil.
        func nextForcedToken(at frame: Int) -> (range: Range<Int>, token: Int)? {
            for (range, tokens) in pendingForceQueues {
                if range.contains(frame), let next = tokens.first {
                    return (range, next)
                }
            }
            return nil
        }

        func consumeForcedToken(in range: Range<Int>) {
            if var queue = pendingForceQueues[range] {
                if !queue.isEmpty { queue.removeFirst() }
                if queue.isEmpty {
                    pendingForceQueues.removeValue(forKey: range)
                } else {
                    pendingForceQueues[range] = queue
                }
            }
        }

        while timeIdx < effectiveSeqLen {
            let safeTime = min(timeIdx, lastTimestep)

            // Force-emit path: a forced token is queued at this frame.
            if let forced = nextForcedToken(at: timeIdx) {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }

                tokenIds.append(forced.token)
                timestamps.append(safeTime)

                let (newDec, newH, newC) = try runDecoder(token: forced.token, hIn: hState, cIn: cState)
                decoderOut = newDec; hState = newH; cState = newC
                consumeForcedToken(in: forced.range)

                if safeTime == lastEmissionTs {
                    emissionsAtTs += 1
                } else {
                    lastEmissionTs = safeTime
                    emissionsAtTs = 1
                }
                // Advance one frame per forced token. If the queue is now
                // empty we'll fall through to normal greedy on the next loop.
                timeIdx += 1
                continue
            }

            var encoderStep = try makeEncoderStep(encoderFlat, frameIdx: safeTime, T: T)

            let forbid = forbidSet(at: timeIdx)
            var label: Int
            var durationBin: Int
            if forbid.isEmpty {
                (label, durationBin) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
            } else {
                // Apply -inf boost on forbidden ids → joint picks next best.
                let boosts = Dictionary(uniqueKeysWithValues:
                    forbid.map { ($0, -Float.infinity) })
                (label, durationBin) = try runJointBoosted(
                    encoderStep: encoderStep, decoderStep: decoderOut, boostByToken: boosts
                )
            }
            var duration = Self.durationBins[min(durationBin, Self.durationBins.count - 1)]
            var isBlank = (label == Self.blankId)

            if isBlank && duration == 0 { duration = 1 }
            if !isBlank && duration == 0 && timeIdx == lastEmissionTs && emissionsAtTs >= 1 {
                duration = 1
            }

            var currentLabelTime = timeIdx
            timeIdx += duration

            // Inner blank loop - same as tdtDecode, with the same forbid mask
            // applied to keep behavior consistent inside the constraint range.
            while timeIdx < effectiveSeqLen && isBlank {
                let st = min(timeIdx, lastTimestep)
                encoderStep = try makeEncoderStep(encoderFlat, frameIdx: st, T: T)
                let innerForbid = forbidSet(at: timeIdx)
                let (l2, db2): (Int, Int)
                if innerForbid.isEmpty {
                    (l2, db2) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
                } else {
                    let innerBoosts = Dictionary(uniqueKeysWithValues:
                        innerForbid.map { ($0, -Float.infinity) })
                    (l2, db2) = try runJointBoosted(
                        encoderStep: encoderStep, decoderStep: decoderOut, boostByToken: innerBoosts
                    )
                }
                var dur2 = Self.durationBins[min(db2, Self.durationBins.count - 1)]
                isBlank = (l2 == Self.blankId)
                if isBlank && dur2 == 0 { dur2 = 1 }
                label = l2
                currentLabelTime = timeIdx
                timeIdx += dur2
            }

            if timeIdx < effectiveSeqLen && label != Self.blankId {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }

                tokenIds.append(label)
                timestamps.append(currentLabelTime)

                let (newDec, newH, newC) = try runDecoder(token: label, hIn: hState, cIn: cState)
                decoderOut = newDec; hState = newH; cState = newC

                if currentLabelTime == lastEmissionTs {
                    emissionsAtTs += 1
                } else {
                    lastEmissionTs = currentLabelTime
                    emissionsAtTs = 1
                }

                if emissionsAtTs >= Self.maxSymbolsPerStep {
                    timeIdx = max(timeIdx, currentLabelTime + 1)
                }
            }
        }

        return (tokenIds, timestamps)
    }

    private func transcribeChunked(_ samples: [Float], langTokenId: Int?) throws -> String {
        var results: [String] = []
        var start = 0

        while start < samples.count {
            let end   = min(start + Self.maxModelSamples, samples.count)
            let chunk = Array(samples[start..<end])

            // Skip very short tail (< 1 second)
            guard chunk.count >= 16_000 else { break }

            let text = try transcribeSingle(chunk, langTokenId: langTokenId)
            if !text.isEmpty { results.append(text) }

            start += Self.maxModelSamples
        }

        return results.joined(separator: " ")
    }

    /// Top-level timestamped transcribe - dispatches to the single-shot path
    /// for clips that fit the encoder context, or to a chunked variant that
    /// stitches per-chunk frame indices into the original recording's
    /// timeline. Both return the same shape, so callers don't need to branch
    /// on audio length.
    func transcribeWithTimestamps(
        _ samples: [Float], language: String? = nil
    ) throws -> (text: String, tokenIds: [Int], timestamps: [Int]) {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }
        let langTokenId = languageTokenId(language)
        if samples.count <= Self.maxModelSamples {
            return try transcribeSingleWithTimestamps(samples, langTokenId: langTokenId)
        }
        return try transcribeChunkedWithTimestamps(samples, langTokenId: langTokenId)
    }

    /// Timestamped variant of `transcribeChunked`. Decodes each ≤15-s chunk
    /// with `transcribeSingleWithTimestamps` and offsets every chunk's
    /// frame indices by `chunkStartSample / samplesPerEncoderFrame` so the
    /// returned timestamps are absolute in the original recording's
    /// timeline. Letting downstream code (`wordTimestamps`,
    /// `CustomDictionaryService.alignedWordTimeRanges`) consume the result
    /// without caring whether the audio was short or long.
    ///
    /// Inherits limitations of `transcribeChunked`:
    ///   • LSTM state resets at each chunk boundary - words spanning the
    ///     boundary split into pieces; the joining space matches the
    ///     wordTimestamps grouping rules so counts stay aligned.
    ///   • Sub-1-s tails are dropped.
    ///
    /// Dictation repair is intentionally NOT applied here - chunk boundaries
    /// introduce frame-index discontinuities that the repair scanner would
    /// interpret as missing dictation commands. The ASR service keeps repair
    /// gated on "≤15-s clip" for that reason.
    ///
    /// Words straddling a chunk boundary land in `wordTimestamps` as a single
    /// "merged" span whose frame range covers both halves of the audio. That
    /// is intentional - KWS downstream pulls audio from the word's time range,
    /// so a wider boundary span gives the keyword spotter more context to work
    /// with than a strict mid-word split would.
    private func transcribeChunkedWithTimestamps(
        _ samples: [Float], langTokenId: Int?
    ) throws -> (text: String, tokenIds: [Int], timestamps: [Int]) {
        var texts: [String] = []
        var allTokenIds: [Int] = []
        var allFrames: [Int] = []
        var start = 0

        while start < samples.count {
            let end = min(start + Self.maxModelSamples, samples.count)
            let chunk = Array(samples[start..<end])
            // Match the existing chunker's short-tail policy.
            guard chunk.count >= 16_000 else { break }

            let (chunkText, chunkTokenIds, chunkFrames) =
                try transcribeSingleWithTimestamps(chunk, langTokenId: langTokenId)

            // Gate on tokens, not text - a chunk that decodes only
            // whitespace/marker pieces trims to "" but its tokens + frames
            // are still real data we need to keep aligned downstream.
            if !chunkTokenIds.isEmpty {
                if !chunkText.isEmpty { texts.append(chunkText) }
                // Ceiling-divide so the chunk's frame indices start strictly
                // after the previous chunk's last possible frame. With
                // maxModelSamples = 240_000 and samplesPerEncoderFrame = 1280
                // we get 187.5 frames per chunk; floor-divide would alias
                // chunk N+1's frame 0 onto chunk N's frame 187 and produce
                // non-monotonic timestamps at the seam.
                let chunkStartFrame =
                    (start + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
                allTokenIds.append(contentsOf: chunkTokenIds)
                allFrames.append(contentsOf: chunkFrames.map { $0 + chunkStartFrame })
            }
            start += Self.maxModelSamples
        }

        return (texts.joined(separator: " "), allTokenIds, allFrames)
    }

    // MARK: - CoreML model runners

    private func runPreprocessor(_ audio: [Float], audioLength: Int) throws -> (MLMultiArray, Int) {
        guard let model = preprocessorModel else { throw ParakeetCoreMLError.modelNotLoaded }

        let audioMLA = try MLMultiArray(shape: [1, NSNumber(value: audio.count)], dataType: .float32)
        audioMLA.dataPointer.assumingMemoryBound(to: Float.self)
            .update(from: audio, count: audio.count)

        let lengthMLA = try MLMultiArray(shape: [1], dataType: .int32)
        lengthMLA[0] = NSNumber(value: audioLength)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioMLA),
            "audio_length":  MLFeatureValue(multiArray: lengthMLA),
        ])
        let output = try model.prediction(from: input)

        guard let mel    = output.featureValue(for: "mel")?.multiArrayValue,
              let melLen = output.featureValue(for: "mel_length")?.multiArrayValue else {
            throw ParakeetCoreMLError.inferenceError("Preprocessor: missing output features")
        }
        return (mel, melLen[0].intValue)
    }

    private func runEncoder(_ mel: MLMultiArray, melLength: Int) throws -> (MLMultiArray, Int) {
        guard let model = encoderModel else { throw ParakeetCoreMLError.modelNotLoaded }

        let melLenMLA = try MLMultiArray(shape: [1], dataType: .int32)
        melLenMLA[0] = NSNumber(value: melLength)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "mel":        MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: melLenMLA),
        ])
        let output = try model.prediction(from: input)

        guard let enc    = output.featureValue(for: "encoder")?.multiArrayValue,
              let encLen = output.featureValue(for: "encoder_length")?.multiArrayValue else {
            throw ParakeetCoreMLError.inferenceError("Encoder: missing output features")
        }
        return (enc, encLen[0].intValue)
    }

    private func runDecoder(token: Int, hIn: MLMultiArray, cIn: MLMultiArray)
        throws -> (MLMultiArray, MLMultiArray, MLMultiArray)
    {
        guard let model = decoderModel else { throw ParakeetCoreMLError.modelNotLoaded }

        let targetsMLA = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targetsMLA[0] = NSNumber(value: token)

        let targetLenMLA = try MLMultiArray(shape: [1], dataType: .int32)
        targetLenMLA[0] = 1

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "targets":       MLFeatureValue(multiArray: targetsMLA),
            "target_length": MLFeatureValue(multiArray: targetLenMLA),
            "h_in":          MLFeatureValue(multiArray: hIn),
            "c_in":          MLFeatureValue(multiArray: cIn),
        ])
        let output = try model.prediction(from: input)

        guard let dec  = output.featureValue(for: "decoder")?.multiArrayValue,
              let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
              let cOut = output.featureValue(for: "c_out")?.multiArrayValue else {
            throw ParakeetCoreMLError.inferenceError("Decoder: missing output features")
        }
        return (dec, hOut, cOut)
    }

    private func runJoint(encoderStep: MLMultiArray, decoderStep: MLMultiArray) throws -> (Int, Int) {
        guard let model = jointModel else { throw ParakeetCoreMLError.modelNotLoaded }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encoderStep),
            "decoder_step": MLFeatureValue(multiArray: decoderStep),
        ])
        let output = try model.prediction(from: input)

        guard let tokenMLA    = output.featureValue(for: "token_id")?.multiArrayValue,
              let durationMLA = output.featureValue(for: "duration")?.multiArrayValue else {
            throw ParakeetCoreMLError.inferenceError("JointDecision: missing output features")
        }
        return (tokenMLA[0].intValue, durationMLA[0].intValue)
    }

    /// Run the v3 joint network and apply additive logit boosts to specific token IDs.
    /// Re-argmaxes over the (boosted) top-64 candidates the model returns.
    /// `boostByToken` maps token_id → additive boost (in logit/log-space units).
    private func runJointBoosted(
        encoderStep: MLMultiArray,
        decoderStep: MLMultiArray,
        boostByToken: [Int: Float]
    ) throws -> (Int, Int) {
        guard let model = jointModelV3 else { throw ParakeetCoreMLError.modelNotLoaded }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_step": MLFeatureValue(multiArray: encoderStep),
            "decoder_step": MLFeatureValue(multiArray: decoderStep),
        ])
        let output = try model.prediction(from: input)

        guard let tokenMLA    = output.featureValue(for: "token_id")?.multiArrayValue,
              let durationMLA = output.featureValue(for: "duration")?.multiArrayValue,
              let topIdsMLA   = output.featureValue(for: "top_k_ids")?.multiArrayValue,
              let topLogitsMLA = output.featureValue(for: "top_k_logits")?.multiArrayValue else {
            throw ParakeetCoreMLError.inferenceError("JointDecisionv3: missing output features")
        }

        // No boosts to apply → return the model's default argmax
        guard !boostByToken.isEmpty else {
            return (tokenMLA[0].intValue, durationMLA[0].intValue)
        }

        let count = min(topIdsMLA.count, topLogitsMLA.count)
        guard count > 0 else { return (tokenMLA[0].intValue, durationMLA[0].intValue) }

        var bestId = tokenMLA[0].intValue
        var bestLogit: Float = -Float.infinity
        // Find best after applying boost
        for i in 0..<count {
            let id = topIdsMLA[i].intValue
            var logit = topLogitsMLA[i].floatValue
            if let bonus = boostByToken[id] { logit += bonus }
            if logit > bestLogit { bestLogit = logit; bestId = id }
        }
        return (bestId, durationMLA[0].intValue)
    }

    /// Public boosted transcription: runs preprocessor + encoder + boosted-TDT decode.
    /// `boost` is a flat amount added to the logits of every token in `boostTokens`
    /// at every emission step. Set `boost = 0` to disable (returns the same result
    /// as the regular `transcribe()` path, modulo the v3 vs v1 joint).
    func transcribeWithBoost(
        _ samples: [Float],
        boostTokens: [Int],
        boost: Float,
        language: String? = nil
    ) throws -> String {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }
        try ensureV3JointLoaded()

        let langTokenId = languageTokenId(language)
        let originalLength = samples.count
        let framesNeeded = (originalLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let frameAligned = min(framesNeeded * Self.samplesPerEncoderFrame, Self.maxModelSamples)

        var padded = [Float](repeating: 0, count: Self.maxModelSamples)
        padded.replaceSubrange(0..<min(samples.count, Self.maxModelSamples),
                               with: samples.prefix(Self.maxModelSamples))

        let (mel, melLength) = try runPreprocessor(padded, audioLength: frameAligned)
        let (encoderOut, encoderLength) = try runEncoder(mel, melLength: melLength)
        let actualFrames = (frameAligned + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame

        let boostMap: [Int: Float] = boost == 0
            ? [:]
            : Dictionary(uniqueKeysWithValues: boostTokens.map { ($0, boost) })

        let tokenIds = try tdtDecodeBoosted(
            encoderOut: encoderOut,
            encoderLength: encoderLength,
            actualAudioFrames: actualFrames,
            langTokenId: langTokenId,
            boostByToken: boostMap)

        return tokensToText(tokenIds)
    }

    /// Variant of `tdtDecode` that uses the v3 joint with logit boosts.
    private func tdtDecodeBoosted(
        encoderOut: MLMultiArray,
        encoderLength: Int,
        actualAudioFrames: Int,
        langTokenId: Int?,
        boostByToken: [Int: Float]
    ) throws -> [Int] {
        guard encoderLength > 1 else { return [] }
        let effectiveSeqLen = min(encoderLength, actualAudioFrames)

        var hState = try makeZeroState()
        var cState = try makeZeroState()

        var (decoderOut, h, c) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        hState = h; cState = c

        if let langId = langTokenId {
            let (_, lh, lc) = try runDecoder(token: langId, hIn: hState, cIn: cState)
            hState = lh; cState = lc
        }

        let (encoderFlat, T) = extractEncoderFlat(encoderOut)

        var tokenIds: [Int] = []
        var timeIdx = 0
        var lastEmissionTs = -1
        var emissionsAtTs = 0
        var tokensThisChunk = 0
        let lastTimestep = effectiveSeqLen - 1

        while timeIdx < effectiveSeqLen {
            let safeTime = min(timeIdx, lastTimestep)
            var encoderStep = try makeEncoderStep(encoderFlat, frameIdx: safeTime, T: T)

            var (label, durationBin) = try runJointBoosted(
                encoderStep: encoderStep, decoderStep: decoderOut, boostByToken: boostByToken)
            var duration = Self.durationBins[min(durationBin, Self.durationBins.count - 1)]
            var isBlank = (label == Self.blankId)

            if isBlank && duration == 0 { duration = 1 }
            if !isBlank && duration == 0 && timeIdx == lastEmissionTs && emissionsAtTs >= 1 {
                duration = 1
            }

            var currentLabelTime = timeIdx
            timeIdx += duration

            while timeIdx < effectiveSeqLen && isBlank {
                let st = min(timeIdx, lastTimestep)
                encoderStep = try makeEncoderStep(encoderFlat, frameIdx: st, T: T)

                let (l2, db2) = try runJointBoosted(
                    encoderStep: encoderStep, decoderStep: decoderOut, boostByToken: boostByToken)
                var dur2 = Self.durationBins[min(db2, Self.durationBins.count - 1)]
                isBlank = (l2 == Self.blankId)
                if isBlank && dur2 == 0 { dur2 = 1 }

                label = l2
                currentLabelTime = timeIdx
                timeIdx += dur2
            }

            if timeIdx < effectiveSeqLen && label != Self.blankId {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }

                tokenIds.append(label)

                let (newDec, newH, newC) = try runDecoder(token: label, hIn: hState, cIn: cState)
                decoderOut = newDec; hState = newH; cState = newC

                if currentLabelTime == lastEmissionTs {
                    emissionsAtTs += 1
                } else {
                    lastEmissionTs = currentLabelTime
                    emissionsAtTs = 1
                }

                if emissionsAtTs >= Self.maxSymbolsPerStep {
                    timeIdx = max(timeIdx, currentLabelTime + 1)
                }
            }
        }

        return tokenIds
    }

    private func ensureV3JointLoaded() throws {
        guard jointModelV3 == nil else { return }
        let url = Self.modelsDir.appendingPathComponent("JointDecisionv3.mlmodelc")
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        jointModelV3 = try MLModel(contentsOf: url, configuration: cfg)
    }

    // MARK: - TDT greedy decoder (mirrors Python's _tdt_decode exactly)

    private func tdtDecode(
        encoderOut: MLMultiArray,
        encoderLength: Int,
        actualAudioFrames: Int,
        langTokenId: Int?
    ) throws -> (tokenIds: [Int], timestamps: [Int]) {
        guard encoderLength > 1 else { return ([], []) }

        let effectiveSeqLen = min(encoderLength, actualAudioFrames)

        // Initialise zero LSTM state [2, 1, 640]
        var hState = try makeZeroState()
        var cState = try makeZeroState()

        // Prime decoder with SOS/blank token
        var (decoderOut, h, c) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        hState = h; cState = c


        // Optional language priming - updates LSTM state but keeps SOS decoder output
        // (using lang token's decoder_out would truncate the first word)
        if let langId = langTokenId {
            let (_, lh, lc) = try runDecoder(token: langId, hIn: hState, cIn: cState)
            hState = lh; cState = lc
        }

        // Pre-extract encoder into a compact [hidden × T] float buffer using
        // correct strides (Neural Engine output may have ANE-aligned strides)
        let (encoderFlat, T) = extractEncoderFlat(encoderOut)

        var tokenIds: [Int] = []
        var timestamps: [Int] = []
        var timeIdx = 0
        var lastEmissionTs = -1
        var emissionsAtTs = 0
        var tokensThisChunk = 0
        let lastTimestep = effectiveSeqLen - 1

        while timeIdx < effectiveSeqLen {
            let safeTime = min(timeIdx, lastTimestep)
            var encoderStep = try makeEncoderStep(encoderFlat, frameIdx: safeTime, T: T)

            var (label, durationBin) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
            var duration = Self.durationBins[min(durationBin, Self.durationBins.count - 1)]
            var isBlank = (label == Self.blankId)

            // Guard: blank with duration=0 → force advance
            if isBlank && duration == 0 { duration = 1 }

            // Guard: repeated non-blank at same timestep with duration=0 → force advance
            if !isBlank && duration == 0 && timeIdx == lastEmissionTs && emissionsAtTs >= 1 {
                duration = 1
            }

            var currentLabelTime = timeIdx
            timeIdx += duration

            // Inner blank loop: consume consecutive blanks without touching decoder state
            while timeIdx < effectiveSeqLen && isBlank {
                let st = min(timeIdx, lastTimestep)
                encoderStep = try makeEncoderStep(encoderFlat, frameIdx: st, T: T)

                let (l2, db2) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
                var dur2 = Self.durationBins[min(db2, Self.durationBins.count - 1)]
                isBlank = (l2 == Self.blankId)
                if isBlank && dur2 == 0 { dur2 = 1 }

                label = l2
                currentLabelTime = timeIdx
                timeIdx += dur2
            }

            // Emit token if active (timeIdx < effectiveSeqLen) and non-blank
            if timeIdx < effectiveSeqLen && label != Self.blankId {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }

                tokenIds.append(label)
                timestamps.append(currentLabelTime)

                let (newDec, newH, newC) = try runDecoder(token: label, hIn: hState, cIn: cState)
                decoderOut = newDec; hState = newH; cState = newC

                if currentLabelTime == lastEmissionTs {
                    emissionsAtTs += 1
                } else {
                    lastEmissionTs = currentLabelTime
                    emissionsAtTs = 1
                }

                // Too many emissions at same timestep → force time forward
                if emissionsAtTs >= Self.maxSymbolsPerStep {
                    timeIdx = max(timeIdx, currentLabelTime + 1)
                }
            }
        }

        return (tokenIds, timestamps)
    }

    // MARK: - TDT decode with per-token frame positions

    private func tdtDecodeWithFrames(
        encoderOut: MLMultiArray,
        encoderLength: Int,
        actualAudioFrames: Int,
        langTokenId: Int?
    ) throws -> [(token: Int, frame: Int)] {
        guard encoderLength > 1 else { return [] }

        let effectiveSeqLen = min(encoderLength, actualAudioFrames)
        var hState = try makeZeroState()
        var cState = try makeZeroState()
        var (decoderOut, h, c) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        hState = h; cState = c

        if let langId = langTokenId {
            let (_, lh, lc) = try runDecoder(token: langId, hIn: hState, cIn: cState)
            hState = lh; cState = lc
        }

        let (encoderFlat, T) = extractEncoderFlat(encoderOut)
        var result: [(token: Int, frame: Int)] = []
        var timeIdx = 0
        var lastEmissionTs = -1
        var emissionsAtTs = 0
        var tokensThisChunk = 0
        let lastTimestep = effectiveSeqLen - 1

        while timeIdx < effectiveSeqLen {
            let safeTime = min(timeIdx, lastTimestep)
            var encoderStep = try makeEncoderStep(encoderFlat, frameIdx: safeTime, T: T)

            var (label, durationBin) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
            var duration = Self.durationBins[min(durationBin, Self.durationBins.count - 1)]
            var isBlank = (label == Self.blankId)
            if isBlank && duration == 0 { duration = 1 }
            if !isBlank && duration == 0 && timeIdx == lastEmissionTs && emissionsAtTs >= 1 { duration = 1 }

            var currentLabelTime = timeIdx
            timeIdx += duration

            while timeIdx < effectiveSeqLen && isBlank {
                let st = min(timeIdx, lastTimestep)
                encoderStep = try makeEncoderStep(encoderFlat, frameIdx: st, T: T)
                let (l2, db2) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
                var dur2 = Self.durationBins[min(db2, Self.durationBins.count - 1)]
                isBlank = (l2 == Self.blankId)
                if isBlank && dur2 == 0 { dur2 = 1 }
                label = l2
                currentLabelTime = timeIdx
                timeIdx += dur2
            }

            if timeIdx < effectiveSeqLen && label != Self.blankId {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }
                result.append((token: label, frame: currentLabelTime))
                let (newDec, newH, newC) = try runDecoder(token: label, hIn: hState, cIn: cState)
                decoderOut = newDec; hState = newH; cState = newC
                if currentLabelTime == lastEmissionTs {
                    emissionsAtTs += 1
                } else {
                    lastEmissionTs = currentLabelTime
                    emissionsAtTs = 1
                }
                if emissionsAtTs >= Self.maxSymbolsPerStep {
                    timeIdx = max(timeIdx, currentLabelTime + 1)
                }
            }
        }

        return result
    }

    // MARK: - MLMultiArray helpers

    /// Zero LSTM state [2, 1, DECODER_HIDDEN_SIZE] (float32).
    private func makeZeroState() throws -> MLMultiArray {
        let mla = try MLMultiArray(
            shape: [2, 1, NSNumber(value: Self.decoderHiddenSize)],
            dataType: .float32
        )
        // MLMultiArray is NOT zero-initialised - must zero explicitly
        let ptr = mla.dataPointer.assumingMemoryBound(to: Float.self)
        ptr.initialize(repeating: 0, count: 2 * 1 * Self.decoderHiddenSize)
        return mla
    }

    /// Extract encoder output as a compact [hidden × T] float array, respecting
    /// ANE-aligned strides (identical to Python's _mlarray_to_numpy + stride_tricks).
    private func extractEncoderFlat(_ enc: MLMultiArray) -> (flat: [Float], T: Int) {
        // Shape: [1, encoderHiddenSize, T]
        let H = enc.shape[1].intValue
        let T = enc.shape[2].intValue
        let s1 = enc.strides[1].intValue   // stride over hidden dimension
        let s2 = enc.strides[2].intValue   // stride over time dimension
        // batch dim stride (enc.strides[0]) not needed since batch=1

        let ptr = enc.dataPointer.assumingMemoryBound(to: Float.self)
        var flat = [Float](repeating: 0, count: H * T)

        for h in 0..<H {
            for t in 0..<T {
                flat[h * T + t] = ptr[h * s1 + t * s2]
            }
        }
        return (flat, T)
    }

    /// Build a [1, encoderHiddenSize, 1] MLMultiArray for one encoder frame.
    private func makeEncoderStep(_ flat: [Float], frameIdx: Int, T: Int) throws -> MLMultiArray {
        let H = Self.encoderHiddenSize
        // Allocate with standard row-major strides: [H, 1, 1]
        // Shape [1, H, 1] → ptr[h] maps to element [0, h, 0]
        let mla = try MLMultiArray(shape: [1, NSNumber(value: H), 1], dataType: .float32)
        let ptr = mla.dataPointer.assumingMemoryBound(to: Float.self)
        for h in 0..<H {
            ptr[h] = flat[h * T + frameIdx]
        }
        return mla
    }

    /// Convert token IDs to text via vocabulary.
    /// Replaces SentencePiece leading-space marker U+2581 with a space.
    private func tokensToText(_ tokenIds: [Int]) -> String {
        let tokens = tokenIds.compactMap { vocabulary[$0] }
        return tokens
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Rebuild text from token IDs, inserting repair strings after specified token indices.
    func rebuildText(tokenIds: [Int], repairs: [Int: String]) -> String {
        var parts: [String] = []
        for (i, id) in tokenIds.enumerated() {
            let tok = vocabulary[id]?.replacingOccurrences(of: "\u{2581}", with: " ") ?? ""
            parts.append(tok)
            if let inserted = repairs[i] {
                parts.append(" \(inserted)")
            }
        }
        return parts.joined()
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Rebuild a `[WordTimestamp]` array from the same (tokenIds, frameTimestamps)
    /// pair used by `rebuildText`, splicing each repair's word timings in at the
    /// position immediately following the repair's `afterTokenIdx`. The repair's
    /// timings must already be in original-audio frame coordinates - the caller
    /// is responsible for offsetting gap-local frames before passing them in.
    ///
    /// Used so that dictionary KWS span alignment can stay valid through a
    /// dictation-repair turn: without this, the post-repair text has N+M words
    /// but the pre-repair `wordTimestamps` array only has N entries → count
    /// mismatch → time-prune disabled → "every 'it' got replaced" failure mode
    /// returns. With this splice, counts match and the prune stays active.
    func rebuildWordTimestamps(
        tokenIds: [Int],
        frameTimestamps: [Int],
        repairs: [Int: [WordTimestamp]]
    ) -> [WordTimestamp] {
        guard tokenIds.count == frameTimestamps.count, !tokenIds.isEmpty else { return [] }

        let spaceMarker: String = {
            let sample = tokenIds.prefix(5).compactMap { vocabulary[$0] }
            return sample.contains(where: { $0.hasPrefix("\u{2581}") }) ? "\u{2581}" : " "
        }()
        let spf = Float(Self.samplesPerEncoderFrame) / 16000.0

        var result: [WordTimestamp] = []
        var wordPieces: [String] = []
        var wordStartFrame = 0
        var wordEndFrame = 0

        func flush() {
            guard !wordPieces.isEmpty else { return }
            let text = wordPieces.joined().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{2581}", with: "")
            result.append(WordTimestamp(
                word: text,
                startSec: Float(wordStartFrame) * spf,
                endSec: Float(wordEndFrame) * spf
            ))
            wordPieces.removeAll(keepingCapacity: true)
        }

        for i in tokenIds.indices {
            let piece = vocabulary[tokenIds[i]] ?? ""
            let frame = frameTimestamps[i]
            if piece.hasPrefix(spaceMarker) && !wordPieces.isEmpty {
                flush()
                wordPieces = [piece]
                wordStartFrame = frame
                wordEndFrame = frame
            } else {
                if wordPieces.isEmpty { wordStartFrame = frame }
                wordPieces.append(piece)
                wordEndFrame = frame
            }
            // Splice any repair anchored at this token. Gaps land between
            // words in practice (≥960 ms of silence inside one word would be
            // pathological), so flushing the current word first puts the
            // repair cleanly between two original words.
            if let inserted = repairs[i], !inserted.isEmpty {
                flush()
                result.append(contentsOf: inserted)
            }
        }
        flush()
        return result
    }

    /// Look up vocabulary token ID for language forcing (e.g. "en" → id of "<|en|>").
    private func languageTokenId(_ lang: String?) -> Int? {
        guard let lang = lang, lang != "auto", !lang.isEmpty else { return nil }
        let target = "<|\(lang)|>"
        return vocabulary.first(where: { $0.value == target })?.key
    }

    // MARK: - TDT Biasing experiment hooks (internal - used by the TDT biasing experiments)

    /// Greedy longest-prefix tokenize `text` against the Parakeet vocab. Mirrors the
    /// approach from the aborted LSTM-priming branch (~5–10% mismatch vs true SP Unigram,
    /// fine for biasing the LSTM). Returns the Parakeet token ids (no SOS, no language).
    /// Special tokens of the form "<...>" are excluded - they're inserted only by the
    /// pipeline, never tokenized from text.
    func tokenizeForPriming(_ text: String) -> [Int] {
        // Build piece→id map once; for one-shot biasing experiments we don't cache.
        var pieceToId: [String: Int] = [:]
        var maxPieceLen = 0
        for (id, piece) in vocabulary {
            if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
            pieceToId[piece] = id
            maxPieceLen = max(maxPieceLen, piece.count)
        }

        // Normalize spaces → U+2581, prepend marker if needed (SP convention).
        var normalized = text.replacingOccurrences(of: " ", with: "\u{2581}")
        if !normalized.hasPrefix("\u{2581}") { normalized = "\u{2581}" + normalized }

        var tokens: [Int] = []
        var idx = normalized.startIndex
        while idx < normalized.endIndex {
            let remaining = normalized.distance(from: idx, to: normalized.endIndex)
            let tryMax = min(maxPieceLen, remaining)
            var matched = false
            var L = tryMax
            while L >= 1 {
                let end = normalized.index(idx, offsetBy: L)
                let candidate = String(normalized[idx..<end])
                if let id = pieceToId[candidate] {
                    tokens.append(id)
                    idx = end
                    matched = true
                    break
                }
                L -= 1
            }
            if !matched {
                idx = normalized.index(after: idx)  // skip unrepresentable char
            }
        }
        return tokens
    }

    /// Decode token ids back to text - exposed for the bias tests so they can show
    /// exactly which Parakeet pieces were chosen for priming.
    func decodeTokensForDebug(_ tokenIds: [Int]) -> String {
        tokensToText(tokenIds)
    }

    /// Transcribe with the decoder LSTM state pre-primed by feeding `primeTokenIds`
    /// through the decoder before the SOS-only init. The intent is to bias the TDT
    /// decoder toward emitting tokens consistent with the priming text (e.g. feeding
    /// "Leonardo" tokens before reading audio biases the decoder toward emitting
    /// "Leonardo" when ambiguous).
    ///
    /// CAVEAT: A previous experiment found that priming with greedy-matched SP tokens
    /// can corrupt the LSTM state and collapse the decode (see
    /// `feat/aborted/lm-priming-sentencepiece` for failure analysis). This hook is for
    /// experimentation only; it intentionally mirrors that approach so we can confirm
    /// or refute the same failure mode in the Fernardo-detection setting.
    func transcribeWithLSTMPrime(
        _ samples: [Float],
        primeTokenIds: [Int],
        language: String? = nil
    ) throws -> String {
        guard preprocessorModel != nil else { throw ParakeetCoreMLError.modelNotLoaded }
        guard samples.count <= Self.maxModelSamples else {
            throw ParakeetCoreMLError.inferenceError("Bias test only supports ≤15s clips")
        }

        let langTokenId = languageTokenId(language)
        let originalLength = samples.count
        let framesNeeded = (originalLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let frameAligned = min(framesNeeded * Self.samplesPerEncoderFrame, Self.maxModelSamples)
        let audioLength = frameAligned

        var padded = [Float](repeating: 0, count: Self.maxModelSamples)
        let copyLen = min(samples.count, Self.maxModelSamples)
        padded.replaceSubrange(0..<copyLen, with: samples[0..<copyLen])

        let (mel, melLength) = try runPreprocessor(padded, audioLength: audioLength)
        let (encoderOut, encoderLength) = try runEncoder(mel, melLength: melLength)
        let actualFrames = (audioLength + Self.samplesPerEncoderFrame - 1) / Self.samplesPerEncoderFrame
        let effectiveSeqLen = min(encoderLength, actualFrames)
        guard effectiveSeqLen > 1 else { return "" }

        // ── Init LSTM state, prime with SOS+lang+primeTokenIds, then resume normal TDT decode ──
        var hState = try makeZeroState()
        var cState = try makeZeroState()
        var (decoderOut, h, c) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        hState = h; cState = c

        if let langId = langTokenId {
            let (_, lh, lc) = try runDecoder(token: langId, hIn: hState, cIn: cState)
            hState = lh; cState = lc
        }

        // Prime with arbitrary tokens, advancing decoder state but NOT consuming audio frames.
        // We do NOT update `decoderOut` from the last priming token - we keep the SOS
        // decoder_out for the first joint call, since using the priming token's
        // decoder_out can truncate the first emitted word (same reason language priming
        // doesn't update decoder_out in the production path).
        for tid in primeTokenIds {
            let (_, ph, pc) = try runDecoder(token: tid, hIn: hState, cIn: cState)
            hState = ph; cState = pc
        }
        // Re-run SOS through the now-primed h/c so decoder_out matches the LSTM state.
        // This produces a decoder_out conditioned on (SOS+lang+prime+SOS) - closest analog
        // to "biased SOS" that Parakeet was trained to consume.
        let (newDec, h2, c2) = try runDecoder(token: Self.blankId, hIn: hState, cIn: cState)
        decoderOut = newDec; hState = h2; cState = c2

        let (encoderFlat, T) = extractEncoderFlat(encoderOut)

        // Greedy TDT decode (mirror of `tdtDecode` body, but with our pre-primed state)
        var tokenIds: [Int] = []
        var timeIdx = 0
        var lastEmissionTs = -1
        var emissionsAtTs = 0
        var tokensThisChunk = 0
        let lastTimestep = effectiveSeqLen - 1

        while timeIdx < effectiveSeqLen {
            let safeTime = min(timeIdx, lastTimestep)
            var encoderStep = try makeEncoderStep(encoderFlat, frameIdx: safeTime, T: T)

            var (label, durationBin) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
            var duration = Self.durationBins[min(durationBin, Self.durationBins.count - 1)]
            var isBlank = (label == Self.blankId)
            if isBlank && duration == 0 { duration = 1 }
            if !isBlank && duration == 0 && timeIdx == lastEmissionTs && emissionsAtTs >= 1 {
                duration = 1
            }
            var currentLabelTime = timeIdx
            timeIdx += duration

            while timeIdx < effectiveSeqLen && isBlank {
                let st = min(timeIdx, lastTimestep)
                encoderStep = try makeEncoderStep(encoderFlat, frameIdx: st, T: T)
                let (l2, db2) = try runJoint(encoderStep: encoderStep, decoderStep: decoderOut)
                var dur2 = Self.durationBins[min(db2, Self.durationBins.count - 1)]
                isBlank = (l2 == Self.blankId)
                if isBlank && dur2 == 0 { dur2 = 1 }
                label = l2
                currentLabelTime = timeIdx
                timeIdx += dur2
            }

            if timeIdx < effectiveSeqLen && label != Self.blankId {
                tokensThisChunk += 1
                guard tokensThisChunk <= Self.maxTokensPerChunk else { break }
                tokenIds.append(label)
                let (nd, nh, nc) = try runDecoder(token: label, hIn: hState, cIn: cState)
                decoderOut = nd; hState = nh; cState = nc
                if currentLabelTime == lastEmissionTs { emissionsAtTs += 1 }
                else { lastEmissionTs = currentLabelTime; emissionsAtTs = 1 }
                if emissionsAtTs >= Self.maxSymbolsPerStep {
                    timeIdx = max(timeIdx, currentLabelTime + 1)
                }
            }
        }

        return tokensToText(tokenIds)
    }
}

// MARK: - StreamingASRCapable

extension ParakeetCoreMLEngine: StreamingASRCapable {

    /// Chunked-streaming seam: transcribe one recording segment via the existing
    /// timestamped decode, then group the decoder's (tokenIds, frameTimestamps)
    /// into `[WordTimestamp]`. Reuses `transcribeWithTimestamps` +
    /// `wordTimestamps(tokenIds:frameTimestamps:)`; no decoding logic is
    /// duplicated. The returned word timings are SEGMENT-RELATIVE (frame 0 ==
    /// first sample handed in) - the stitcher re-offsets to absolute coords.
    ///
    /// Keep `samples` ≤ `maxModelSamples` (15 s @ 16 kHz) per the seam contract:
    /// beyond that `transcribeWithTimestamps` falls back to the engine's own
    /// chunker.
    func transcribeSegment(
        samples: [Float],
        sampleRate: Int,
        language: String?
    ) async throws -> StreamingSegmentResult {
        // Defensive: an idle-unload can strike in the post-stop window between
        // the last keep-alive ping and this segment call.
        try await ensureLoaded()
        let (text, tokenIds, frames) = try transcribeWithTimestamps(samples, language: language)
        let words = wordTimestamps(tokenIds: tokenIds, frameTimestamps: frames)
        return StreamingSegmentResult(text: text, wordTimestamps: words)
    }
}
