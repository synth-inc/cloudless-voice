// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
// Portions derived from FluidAudio (https://github.com/FluidInference/FluidAudio),
// Copyright (c) FluidInference, licensed under the Apache License, Version 2.0.
// Modified by Synthetic Exploration, Inc. See THIRD_PARTY_NOTICES.md at the repository root.
//
//  CanaryCoreMLEngine.swift
//  Onit
//
//  On-device NVIDIA Canary-1B-v2 ASR (attention encoder-decoder) via CoreML.
//  Isolated engine - deliberately does NOT depend on FluidAudio, so bumping that
//  package (which powers the shipped Parakeet backend) can never affect this path.
//
//  Pipeline: waveform → [Preprocessor fp32/CPU] mel → [Encoder int4/GPU (Metal)] →
//  transpose to [1,T,D] → greedy autoregressive loop ([Decoder int4/GPU] → last
//  hidden → [Projection int4/GPU] → argmax until EOS) → SentencePiece detokenize.
//  Encoder/decoder/projection run on `.cpuAndGPU`, NOT the ANE - loading int4 on
//  the ANE deadlocks the program compile (see ensureLoaded below). int4 payloads
//  require macOS 15+ (gated in ASRModel.isAvailableForCurrentOS).
//
//  The decode algorithm + exact CoreML I/O feature names are ported from
//  FluidAudio's `feat/canary-asr` reference implementation (CanaryManager /
//  CanaryModels / CanaryConfig), which is the intended runner for the
//  `FluidInference/canary-1b-v2-coreml` model bundle.
//

@preconcurrency import CoreML
import Foundation

/// Fixed-shape contract for the canary-1b-v2 CoreML pipeline (15 s window).
enum CanaryConfig {
    static let sampleRate = 16_000
    static let maxSamples = 240_000            // 15 s window (preprocessor input is fixed)
    static let chunkOverlapSamples = 48_000    // 3 s overlap between adjacent >15 s windows
    static let encoderHidden = 1024
    static let encoderFrames = 188
    static let maxDecoderSteps = 128           // fallback; real length read from the model
    static let eosId = 3                        // <|endoftext|>

    /// Canary's decoder prompt is what selects the transcription language:
    /// <|startofcontext|> <|startoftranscript|> <|emo:undefined|> <SRC_LANG>
    /// <TGT_LANG> <|pnc|> <|noitn|> <|notimestamp|> <|nodiarize|>. For transcription
    /// (not translation) the source and target slots hold the SAME spoken-language
    /// token - filled by `prompt(langTokenId:)`. `<|en|>` = 64.
    static let englishLangTokenId: Int32 = 64

    /// Build the decoder prompt forcing `langTokenId` as both source and target.
    static func prompt(langTokenId: Int32) -> [Int32] {
        [7, 4, 16, langTokenId, langTokenId, 5, 9, 11, 13]
    }

    /// The 25 languages NVIDIA Canary-1B-v2 is trained on (ISO 639-1). A selection
    /// outside this set is mapped to English rather than forcing a language token
    /// the model can't actually transcribe - matches the Parakeet language picker.
    static let supportedLanguageCodes: Set<String> = [
        "en", "de", "es", "fr", "it", "pt", "nl", "pl", "ru", "uk", "cs", "sk",
        "sl", "hr", "bg", "ro", "hu", "el", "da", "sv", "fi", "et", "lv", "lt", "mt",
    ]

    // int4 bundle (the default in FluidInference/canary-1b-v2-coreml).
    static let preprocessorName = "Preprocessor"
    static let encoderName = "EncoderInt4"
    static let decoderName = "DecoderInt4"
    static let projectionName = "Projection"
    static let vocabFile = "vocab.json"
}

enum CanaryEngineError: LocalizedError {
    case modelNotLoaded
    case modelMissing(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Canary engine is not loaded."
        case .modelMissing(let n): return "Canary model not found: \(n)"
        case .processingFailed(let m): return "Canary transcription failed: \(m)"
        }
    }
}

actor CanaryCoreMLEngine {

    static let shared = CanaryCoreMLEngine()

    static let maxModelSamples = CanaryConfig.maxSamples

    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var projection: MLModel?
    private var tokenizer: CanaryTokenizer?

    /// True only after ALL FIVE components (preprocessor + encoder + decoder +
    /// projection + tokenizer) loaded successfully. Deliberately NOT derived from
    /// `preprocessor != nil` - a partial load (e.g. the encoder throws after the
    /// preprocessor loaded) must read as "not loaded" so the next `ensureLoaded()`
    /// genuinely retries instead of wedging every `transcribe()` on
    /// `.modelNotLoaded` until app restart.
    private(set) var isLoaded = false

    /// In-flight load, if any. Concurrent `ensureLoaded()` callers (warmup/reArm +
    /// the backtest runner) await this single task instead of each starting their
    /// own five-model load - the actor is reentrant at every `await`, so without
    /// this handle two loads could run interleaved.
    private var loadTask: Task<Void, Error>?

    /// ~/Library/Application Support/Onit/Models/canary-1b-v2-coreml - matches
    /// `HuggingFaceModelDownloader.canaryDirectory` (kept in sync so the download
    /// target and the load path never disagree). Computed locally so the actor
    /// doesn't touch the @MainActor downloader.
    private static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onit/Models/canary-1b-v2-coreml")
    }

    private init() {}

    // MARK: - Load / unload

    /// Idempotent load. Guarantees on exit:
    ///   • success → all four models + tokenizer are loaded (`isLoaded == true`)
    ///   • failure → clean slate (`isLoaded == false`, every model + tokenizer
    ///     nil) and the error is rethrown, so the next call genuinely retries.
    /// Concurrent callers coalesce onto a single in-flight load task.
    func ensureLoaded() async throws {
        if isLoaded { return }

        // A load is already in flight (the actor is reentrant at awaits) -
        // piggyback on it instead of starting a second five-model load.
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

        // Validate the whole bundle up front: the four .mlmodelc directories plus
        // the vocab file must exist. A partial bundle from an interrupted download
        // throws `.modelMissing` here instead of half-loading and wedging.
        try Self.validateBundle(at: dir)

        // Preprocessor runs fp32 on CPU (power-spectrum / log exceed fp16 range).
        // Encoder/decoder/projection run on the GPU, NOT the ANE: loading the int4
        // models with `.cpuAndNeuralEngine` deadlocks the ANE program compile on
        // macOS 26 (verified - the encoder load blocks at 0% CPU indefinitely,
        // timing out warmup). `.cpuAndGPU` loads the same int4 bundle in ~1.7s and
        // runs on Metal. (FluidAudio's identical `.cpuAndNeuralEngine` config
        // presumably works on shipping macOS 15; this is our host-ANE workaround.)
        let cpu = MLModelConfiguration(); cpu.computeUnits = .cpuOnly
        let gpu = MLModelConfiguration(); gpu.computeUnits = .cpuAndGPU

        var step = CanaryConfig.preprocessorName
        do {
            let pre = try Self.loadModel(CanaryConfig.preprocessorName, from: dir, config: cpu)
            step = CanaryConfig.encoderName
            let enc = try Self.loadModel(CanaryConfig.encoderName, from: dir, config: gpu)
            step = CanaryConfig.decoderName
            let dec = try Self.loadModel(CanaryConfig.decoderName, from: dir, config: gpu)
            step = CanaryConfig.projectionName
            let proj = try Self.loadModel(CanaryConfig.projectionName, from: dir, config: gpu)
            step = "tokenizer"
            let tok = try CanaryTokenizer(vocabURL: dir.appendingPathComponent(CanaryConfig.vocabFile))

            // If unload() cancelled us while a component was loading, don't commit.
            try Task.checkCancellation()

            // Commit atomically - no suspension points between these assignments,
            // so no interleaved caller can observe partial state.
            preprocessor = pre
            encoder = enc
            decoder = dec
            projection = proj
            tokenizer = tok
            isLoaded = true
            log.info("CanaryCoreMLEngine: loaded from \(dir.path)")
        } catch {
            log.warning("CanaryCoreMLEngine: load failed at \(step) - rolling back to clean slate: \(error)")
            clearLoadedState()
            throw error
        }
    }

    /// Drop every loaded model + the tokenizer. If a load is in flight, it is
    /// cancelled and awaited first so an unload-mid-load can't interleave with the
    /// component loads and leave a mixed nil/non-nil state behind.
    func unload() async {
        if let task = loadTask {
            task.cancel()
            _ = try? await task.value
            loadTask = nil
        }
        clearLoadedState()
    }

    /// Nil out every model + tokenizer and mark the engine unloaded. Synchronous
    /// (no suspension points) so the reset is atomic on the actor.
    private func clearLoadedState() {
        preprocessor = nil
        encoder = nil
        decoder = nil
        projection = nil
        tokenizer = nil
        isLoaded = false
    }

    /// Verify every file the load sequence needs exists before touching CoreML:
    /// the four `.mlmodelc` compiled model directories plus the vocab JSON.
    /// (`fileExists(atPath:)` matches directories too, which `.mlmodelc` is.)
    /// Throws `.modelMissing` naming the first missing piece.
    private static func validateBundle(at dir: URL) throws {
        let fm = FileManager.default
        for name in [CanaryConfig.preprocessorName, CanaryConfig.encoderName,
                     CanaryConfig.decoderName, CanaryConfig.projectionName] {
            let path = dir.appendingPathComponent("\(name).mlmodelc").path
            guard fm.fileExists(atPath: path) else {
                throw CanaryEngineError.modelMissing(name)
            }
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent(CanaryConfig.vocabFile).path) else {
            throw CanaryEngineError.modelMissing(CanaryConfig.vocabFile)
        }
    }

    private static func loadModel(_ name: String, from dir: URL, config: MLModelConfiguration) throws -> MLModel {
        let compiled = dir.appendingPathComponent("\(name).mlmodelc")
        guard FileManager.default.fileExists(atPath: compiled.path) else {
            throw CanaryEngineError.modelMissing(name)
        }
        return try MLModel(contentsOf: compiled, configuration: config)
    }

    // MARK: - Transcribe

    /// Transcribe 16 kHz mono float samples (in [-1, 1]). Audio within the 15 s
    /// window is decoded in one pass; longer audio is split into overlapping 15 s
    /// windows and stitched via token-level longest-common-substring.
    ///
    /// `language` is an ISO 639-1 code (e.g. "fr"); nil, empty, or a language
    /// Canary doesn't support falls back to English. The resolved language is
    /// baked into the decoder prompt (see `resolvePrompt`).
    func transcribe(_ samples: [Float], language: String? = nil) throws -> String {
        guard let tokenizer else { throw CanaryEngineError.modelNotLoaded }
        guard !samples.isEmpty else { return "" }

        let prompt = Self.resolvePrompt(language: language, tokenizer: tokenizer)

        let maxN = CanaryConfig.maxSamples
        if samples.count <= maxN {
            return detokenize(try transcribeWindow(samples, prompt: prompt), tokenizer: tokenizer)
        }

        let hop = maxN - CanaryConfig.chunkOverlapSamples
        var merged: [Int] = []
        var start = 0
        var chunkIndex = 0
        while start < samples.count {
            let end = min(start + maxN, samples.count)
            if chunkIndex > 0, (end - start) <= (maxN - hop) { break }
            let tokens = try transcribeWindow(Array(samples[start..<end]), prompt: prompt)
            merged = Self.mergeTokenStreams(prefix: merged, suffix: tokens)
            chunkIndex += 1
            if end >= samples.count { break }
            start += hop
        }
        return detokenize(merged, tokenizer: tokenizer)
    }

    /// Map an ISO 639-1 `language` code to the Canary decoder prompt that forces
    /// it as the transcription language. nil / empty / unsupported → English, so an
    /// unexpected value degrades to the model's best-supported language instead of
    /// failing. "en-US"/"pt_BR"-style region tags are normalized to the base code.
    private static func resolvePrompt(language: String?, tokenizer: CanaryTokenizer) -> [Int32] {
        guard let raw = language?.lowercased(), !raw.isEmpty else {
            return CanaryConfig.prompt(langTokenId: CanaryConfig.englishLangTokenId)
        }
        let code = String(raw.prefix { $0 != "-" && $0 != "_" })
        guard CanaryConfig.supportedLanguageCodes.contains(code),
              let tokenId = tokenizer.languageTokenId(forCode: code) else {
            log.warning("CanaryCoreMLEngine: language \"\(raw)\" not supported by Canary-1B-v2 - using English")
            return CanaryConfig.prompt(langTokenId: CanaryConfig.englishLangTokenId)
        }
        log.info("CanaryCoreMLEngine: forcing transcription language '\(code)' (token \(tokenId))")
        return CanaryConfig.prompt(langTokenId: tokenId)
    }

    /// 4-stage pipeline over a single ≤15 s window; returns generated token ids.
    private func transcribeWindow(_ audio: [Float], prompt: [Int32]) throws -> [Int] {
        let (mel, melLength) = try runPreprocessor(audio: audio)
        let (enc, encLength) = try runEncoder(mel: mel, melLength: melLength)
        let (embeddings, encoderMask) = try makeDecoderContext(encoder: enc, encoderLength: encLength)
        return try greedyDecode(embeddings: embeddings, encoderMask: encoderMask, prompt: prompt)
    }

    /// waveform → mel [1,128,1501]. Audio is padded/truncated to the 15 s window.
    private func runPreprocessor(audio: [Float]) throws -> (MLMultiArray, MLMultiArray) {
        guard let preprocessor else { throw CanaryEngineError.modelNotLoaded }
        let maxN = CanaryConfig.maxSamples
        let validN = min(audio.count, maxN)

        let signal = try MLMultiArray(shape: [1, maxN as NSNumber], dataType: .float32)
        let sptr = signal.dataPointer.assumingMemoryBound(to: Float32.self)
        memset(sptr, 0, maxN * MemoryLayout<Float32>.size)
        audio.prefix(validN).withUnsafeBufferPointer { src in
            if let base = src.baseAddress { sptr.update(from: base, count: validN) }
        }

        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: validN)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: signal),
            "audio_length": MLFeatureValue(multiArray: length),
        ])
        let out = try preprocessor.prediction(from: input)
        guard let mel = out.featureValue(for: "processed")?.multiArrayValue,
              let melLen = out.featureValue(for: "processed_length")?.multiArrayValue
        else { throw CanaryEngineError.processingFailed("preprocessor produced no `processed`") }
        return (mel, melLen)
    }

    /// mel → encoder [1,1024,188].
    private func runEncoder(mel: MLMultiArray, melLength: MLMultiArray) throws -> (MLMultiArray, Int) {
        guard let encoder else { throw CanaryEngineError.modelNotLoaded }
        let featLen = try MLMultiArray(shape: [1], dataType: .int32)
        featLen[0] = NSNumber(value: melLength[0].intValue)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: mel),
            "features_length": MLFeatureValue(multiArray: featLen),
        ])
        let out = try encoder.prediction(from: input)
        guard let enc = out.featureValue(for: "encoder")?.multiArrayValue else {
            throw CanaryEngineError.processingFailed("encoder produced no `encoder`")
        }
        let encLen = out.featureValue(for: "encoder_length")?.multiArrayValue?[0].intValue
            ?? CanaryConfig.encoderFrames
        return (enc, encLen)
    }

    /// encoder [1,D,T] → encoder_embeddings [1,T,D] + encoder_mask [1,T].
    /// CoreML pads the encoder's last dim to a 64-element boundary, so the
    /// transpose must use the array's real strides, not a dense linear read.
    private func makeDecoderContext(encoder: MLMultiArray, encoderLength: Int) throws -> (MLMultiArray, MLMultiArray) {
        let d = CanaryConfig.encoderHidden
        let t = CanaryConfig.encoderFrames
        let emb = try MLMultiArray(shape: [1, t as NSNumber, d as NSNumber], dataType: .float32)
        let eptr = emb.dataPointer.assumingMemoryBound(to: Float32.self)
        let strides = encoder.strides.map { $0.intValue }
        let sD = strides[1]
        let sT = strides[2]
        let read = floatReader(encoder)
        for ti in 0..<t {
            let dst = ti * d
            let tBase = ti * sT
            for di in 0..<d { eptr[dst + di] = read(di * sD + tBase) }
        }

        let mask = try MLMultiArray(shape: [1, t as NSNumber], dataType: .float32)
        let mptr = mask.dataPointer.assumingMemoryBound(to: Float32.self)
        let valid = min(max(encoderLength, 1), t)
        for i in 0..<t { mptr[i] = i < valid ? 1.0 : 0.0 }
        return (emb, mask)
    }

    /// Greedy autoregressive decode: returns generated token ids (prompt stripped).
    /// The decoder carries no KV cache - each step re-runs the full [1,S] sequence.
    private func greedyDecode(embeddings: MLMultiArray, encoderMask: MLMultiArray, prompt: [Int32]) throws -> [Int] {
        guard let decoder, let projection else { throw CanaryEngineError.modelNotLoaded }
        let s = decoder.modelDescription.inputDescriptionsByName["input_ids"]?
            .multiArrayConstraint?.shape.last?.intValue ?? CanaryConfig.maxDecoderSteps

        let inputIds = try MLMultiArray(shape: [1, s as NSNumber], dataType: .int32)
        let decoderMask = try MLMultiArray(shape: [1, s as NSNumber], dataType: .float32)
        let idptr = inputIds.dataPointer.assumingMemoryBound(to: Int32.self)
        let mkptr = decoderMask.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<s { idptr[i] = 0; mkptr[i] = 0 }
        let promptLen = min(prompt.count, s)
        for i in 0..<promptLen { idptr[i] = prompt[i]; mkptr[i] = 1 }
        var pos = promptLen

        let d = CanaryConfig.encoderHidden
        let hidden = try MLMultiArray(shape: [1, d as NSNumber], dataType: .float32)
        let hptr = hidden.dataPointer.assumingMemoryBound(to: Float32.self)

        var generated: [Int] = []
        while pos < s {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIds),
                "decoder_mask": MLFeatureValue(multiArray: decoderMask),
                "encoder_embeddings": MLFeatureValue(multiArray: embeddings),
                "encoder_mask": MLFeatureValue(multiArray: encoderMask),
            ])
            let out = try decoder.prediction(from: input)
            guard let dec = out.featureValue(for: "decoder")?.multiArrayValue else {
                throw CanaryEngineError.processingFailed("decoder produced no `decoder`")
            }

            // Hidden state at the last valid position (decoder output may be stride-padded).
            let decStrides = dec.strides.map { $0.intValue }
            let rowBase = (pos - 1) * decStrides[1]
            let elemStride = decStrides[2]
            let readDec = floatReader(dec)
            for h in 0..<d { hptr[h] = readDec(rowBase + h * elemStride) }

            let projOut = try projection.prediction(
                from: try MLDictionaryFeatureProvider(dictionary: [
                    "hidden": MLFeatureValue(multiArray: hidden)
                ]))
            guard let logits = projOut.featureValue(for: "logits")?.multiArrayValue else {
                throw CanaryEngineError.processingFailed("projection produced no `logits`")
            }

            let next = argmax(logits)
            if next == CanaryConfig.eosId { break }
            generated.append(next)
            idptr[pos] = Int32(next)
            mkptr[pos] = 1
            pos += 1
        }
        return generated
    }

    private func detokenize(_ tokens: [Int], tokenizer: CanaryTokenizer) -> String {
        tokenizer.decode(ids: tokens)
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Chunk merge

    /// Merge two adjacent window token streams using longest-common-substring on a
    /// bounded boundary window. Both windows transcribe `chunkOverlap` of identical
    /// audio at their seam, so their tokens share a common substring near the
    /// prefix's tail / suffix's head. On a hit, drop the suffix's matched head; on a
    /// miss, concatenate plainly (better to duplicate a few tokens than lose content).
    static func mergeTokenStreams(prefix: [Int], suffix: [Int], windowTokens: Int = 32, minMatch: Int = 4) -> [Int] {
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        let pTail = Array(prefix.suffix(windowTokens))
        let sHead = Array(suffix.prefix(windowTokens))
        let m = pTail.count, n = sHead.count
        if m == 0 || n == 0 { return prefix + suffix }

        var dp = [Int](repeating: 0, count: n + 1)
        var bestLen = 0, bestSEnd = 0
        for i in 1...m {
            var prev = 0
            for j in 1...n {
                let temp = dp[j]
                if pTail[i - 1] == sHead[j - 1] {
                    dp[j] = prev + 1
                    if dp[j] > bestLen { bestLen = dp[j]; bestSEnd = j }
                } else { dp[j] = 0 }
                prev = temp
            }
        }
        guard bestLen >= minMatch else { return prefix + suffix }
        return prefix + Array(suffix.dropFirst(bestSEnd))
    }

    // MARK: - MLMultiArray helpers

    private func floatReader(_ arr: MLMultiArray) -> (Int) -> Float {
        switch arr.dataType {
        case .float32:
            let p = arr.dataPointer.assumingMemoryBound(to: Float32.self)
            return { p[$0] }
        case .float16:
            let p = arr.dataPointer.assumingMemoryBound(to: UInt16.self)
            return { Self.float16BitsToFloat(p[$0]) }
        default:
            return { arr[$0].floatValue }
        }
    }

    private func argmax(_ logits: MLMultiArray) -> Int {
        let n = logits.count
        var best = 0
        var bestVal = -Float.greatestFiniteMagnitude
        switch logits.dataType {
        case .float32:
            let p = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<n where p[i] > bestVal { bestVal = p[i]; best = i }
        case .float16:
            let p = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for i in 0..<n {
                let v = Self.float16BitsToFloat(p[i])
                if v > bestVal { bestVal = v; best = i }
            }
        default:
            for i in 0..<n {
                let v = logits[i].floatValue
                if v > bestVal { bestVal = v; best = i }
            }
        }
        return best
    }

    /// Decode an IEEE-754 half-precision bit pattern to Float (no hard Float16 dep).
    ///
    /// Routed to the shared `Float16Bits` helper: the copy that used to live
    /// here trapped on a `UInt32` underflow (`exp - 15 + 127`) for every half
    /// below 1.0, which is most of a logit row.
    @inline(__always)
    private static func float16BitsToFloat(_ h: UInt16) -> Float {
        Float16Bits.toFloat(h)
    }
}
