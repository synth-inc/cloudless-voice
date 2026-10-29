// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SileroVADService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-13.
//
//  Silero VAD CoreML inference for short-recording silence detection.
//
//  Targets accidental trigger clicks: when a user briefly presses the dictation
//  shortcut without speaking, the resulting <2s buffer often produces hallucinated
//  text from the ASR. This service runs a lightweight CoreML LSTM over the buffer
//  and reports whether any 256ms chunk contains speech (probability > 0.5).
//
//  Audio is RMS-normalised to TARGET_RMS=0.1 before inference so the threshold
//  stays meaningful across mic sensitivity levels. Long recordings (≥2s) are
//  skipped - by then the user clearly intended to dictate.
//
//  Fails open on any error: never silences audio if the model can't load or
//  inference throws.
//

import CoreML
import Foundation

actor SileroVADService {

    // MARK: - Singleton

    static let shared = SileroVADService()

    // MARK: - Constants (matching Python)

    private static let chunkSize = 4096        // 256ms at 16kHz
    private static let contextSize = 64
    private static let hiddenStateSize = 128
    private static let speechThreshold: Float = 0.5
    private static let durationGateSec: Double = 2.0
    private static let targetRMS: Float = 0.1
    private static let sampleRate: Double = 16_000

    // MARK: - State

    private var model: MLModel?

    var isLoaded: Bool { model != nil }

    private init() {}

    // MARK: - Public

    /// Load the Silero VAD CoreML model from the local model directory. The model
    /// must be downloaded first via `HuggingFaceModelDownloader.downloadVADIfNeeded()`.
    func ensureLoaded() async throws {
        guard model == nil else { return }

        let (vadDir, modelName) = await MainActor.run {
            (HuggingFaceModelDownloader.vadDirectory, HuggingFaceModelDownloader.vadModelName)
        }
        let modelDir = vadDir.appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw VADError.modelNotFound(path: modelDir.path)
        }

        // Compile .mlpackage → .mlmodelc (cached so we only compile once).
        let compiledPath = vadDir.appendingPathComponent(modelName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"))
        let compiledURL: URL
        if FileManager.default.fileExists(atPath: compiledPath.path) {
            compiledURL = compiledPath
        } else {
            let tempCompiled = try await MLModel.compileModel(at: modelDir)
            try? FileManager.default.removeItem(at: compiledPath)
            try FileManager.default.moveItem(at: tempCompiled, to: compiledPath)
            compiledURL = compiledPath
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly  // matches Python; LSTM doesn't benefit from ANE here.

        model = try MLModel(contentsOf: compiledURL, configuration: config)
        log.info("SileroVADService: model loaded from \(compiledURL.path)")
    }

    /// Returns `true` if the audio is detected as silent (no speech in any chunk).
    /// Returns `false` for any audio ≥2s, on engine errors, or when speech is detected.
    /// Never silences audio defensively - fails open.
    func isAudioSilent(_ audio: [Float]) async -> Bool {
        let durationSec = Double(audio.count) / Self.sampleRate
        if durationSec >= Self.durationGateSec {
            log.debug("SileroVADService: skipping (\(String(format: "%.2f", durationSec))s ≥ \(Self.durationGateSec)s gate)")
            return false
        }

        guard let model else {
            log.warning("SileroVADService: model not loaded - passing through")
            return false
        }

        do {
            let normalized = rmsNormalize(audio)
            return try runInference(normalized, model: model)
        } catch {
            log.warning("SileroVADService: inference error: \(error.localizedDescription) - passing through")
            return false
        }
    }

    // MARK: - Private

    private func rmsNormalize(_ audio: [Float]) -> [Float] {
        var sumSq: Float = 0
        for v in audio { sumSq += v * v }
        let rms = (sumSq / Float(audio.count)).squareRoot()
        guard rms > 1e-9 else { return audio }
        let scale = Self.targetRMS / rms
        return audio.map { max(-1.0, min(1.0, $0 * scale)) }
    }

    /// Stream chunks through the LSTM. Returns `true` if NO chunk had speech_prob > threshold.
    private func runInference(_ audio: [Float], model: MLModel) throws -> Bool {
        var hiddenState = [Float](repeating: 0, count: Self.hiddenStateSize)
        var cellState = [Float](repeating: 0, count: Self.hiddenStateSize)
        var context = [Float](repeating: 0, count: Self.contextSize)

        let totalSamples = audio.count
        let numChunks = (totalSamples + Self.chunkSize - 1) / Self.chunkSize

        for i in 0..<numChunks {
            let start = i * Self.chunkSize
            let end = min(start + Self.chunkSize, totalSamples)
            var chunk = Array(audio[start..<end])
            if chunk.count < Self.chunkSize {
                chunk.append(contentsOf: [Float](repeating: 0, count: Self.chunkSize - chunk.count))
            }

            // audio_input shape [1, contextSize + chunkSize] = [1, 4160]
            var audioInput = context
            audioInput.append(contentsOf: chunk)

            let audioMLA = try makeMultiArray(audioInput, shape: [1, Self.contextSize + Self.chunkSize])
            let hiddenMLA = try makeMultiArray(hiddenState, shape: [1, Self.hiddenStateSize])
            let cellMLA = try makeMultiArray(cellState, shape: [1, Self.hiddenStateSize])

            let inputs: [String: MLFeatureValue] = [
                "audio_input": MLFeatureValue(multiArray: audioMLA),
                "hidden_state": MLFeatureValue(multiArray: hiddenMLA),
                "cell_state": MLFeatureValue(multiArray: cellMLA),
            ]
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let result = try model.prediction(from: provider)

            guard let vadOut = result.featureValue(for: "vad_output")?.multiArrayValue,
                  let newHidden = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                  let newCell = result.featureValue(for: "new_cell_state")?.multiArrayValue else {
                log.warning("SileroVADService: missing output features - passing through")
                return false
            }

            let speechProb = vadOut[0].floatValue
            if speechProb > Self.speechThreshold {
                log.debug("SileroVADService: speech detected (chunk \(i + 1)/\(numChunks), prob=\(String(format: "%.2f", speechProb)))")
                return false
            }

            hiddenState = readMultiArray(newHidden, count: Self.hiddenStateSize)
            cellState = readMultiArray(newCell, count: Self.hiddenStateSize)
            // Context = last contextSize samples of audio_input.
            context = Array(audioInput.suffix(Self.contextSize))
        }

        log.info("SileroVADService: no speech detected in \(numChunks) chunk(s) - suppressing")
        return true
    }

    private func makeMultiArray(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let mla = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let ptr = mla.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        for i in 0..<values.count { ptr[i] = values[i] }
        return mla
    }

    private func readMultiArray(_ mla: MLMultiArray, count: Int) -> [Float] {
        let ptr = mla.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}

// MARK: - Errors

enum VADError: LocalizedError {
    case modelNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Silero VAD model not found at \(path)"
        }
    }
}
