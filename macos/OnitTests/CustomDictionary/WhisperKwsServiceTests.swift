// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperKwsServiceTests.swift
//  OnitTests
//
//  Smoke test for `WhisperKwsService`. Loads the bundled CoreML resources and
//  runs detection on 5 seconds of digital silence - silence must produce zero
//  detections, regardless of which keywords are in the dictionary.
//
//  Skipped when the bundled `.mlmodelc` / tokenizer assets are missing (e.g.
//  fresh checkouts without the WhisperKWS download), so the suite stays green
//  on machines that haven't fetched the large model resources yet.
//

import AVFoundation
import XCTest
@testable import Onit

final class WhisperKwsServiceTests: XCTestCase {

    /// Smoke test - load the service with two real keywords (Fernardo, Onit)
    /// and call `detectKeywords` on 5 seconds of zeros. Silence should never
    /// fire any keyword.
    func testSilenceProducesNoDetections() async throws {
        do {
            try await WhisperKwsService.shared.loadIfNeeded(
                keywords: ["Fernardo", "Onit"],
                keywordThresholds: ["Fernardo": -5.96, "Onit": -7.00]
            )
        } catch {
            // The CoreML resources or BPE tokenizer assets are not bundled in
            // this build - skip the test rather than failing the suite.
            throw XCTSkip("WhisperKwsService.loadIfNeeded threw: \(error.localizedDescription)")
        }

        let silence = [Float](repeating: 0, count: 5 * 16_000)
        let detections = try await WhisperKwsService.shared.detectKeywords(
            in: silence, sampleRate: 16_000
        )
        XCTAssertEqual(
            detections.count, 0,
            "5 s of digital silence produced \(detections.count) detection(s); "
            + "expected 0. First: \(String(describing: detections.first))"
        )
    }

    /// Throughput guard for the parallel decoder path: 50 keywords over a 5 s
    /// clip should score in under 500 ms on M-series Apple Silicon.
    func testFiftyKeywordLatencyBudget() async throws {
        let keywords = [
            "Onit", "Fernardo", "Alice", "Bob", "Carol", "Dave", "Eve", "Frank",
            "Grace", "Heidi", "Ivan", "Judy", "Mallory", "Oscar", "Peggy", "Trent",
            "Victor", "Walter", "Romeo", "Sierra", "Tango", "Delta", "Echo", "Foxtrot",
            "Juliet", "Kilo", "Lima", "Mike", "Nina", "Olive", "Panda", "Quest",
            "River", "Sunny", "Tiger", "Unity", "Violet", "Wendy", "Xray", "Yankee",
            "Zebra", "Amber", "Baker", "Cedar", "Daisy", "Eagle", "Flame", "Giant",
            "Hazel", "Iris",
        ]

        do {
            try await WhisperKwsService.shared.loadIfNeeded(keywords: keywords)
        } catch {
            throw XCTSkip("WhisperKwsService.loadIfNeeded threw: \(error.localizedDescription)")
        }

        let silence = [Float](repeating: 0, count: 5 * 16_000)
        _ = try await WhisperKwsService.shared.computeMaxScores(
            in: Array(silence.prefix(Int(WhisperKwsService.windowSec * 16_000))),
            sampleRate: 16_000
        )

        let t0 = Date()
        _ = try await WhisperKwsService.shared.computeMaxScores(in: silence, sampleRate: 16_000)
        let elapsed = Date().timeIntervalSince(t0)
        let stages = await WhisperKwsService.shared.lastStageTimings

        let breakdown = String(
            format: "windows=%d mel=%.0fms enc=%.0fms dec=%.0fms score=%.0fms",
            stages.windowCount,
            stages.melSec * 1000,
            stages.encoderSec * 1000,
            stages.decoderSec * 1000,
            stages.scoringSec * 1000
        )
        // Persist the breakdown to a temp file so external tooling can read
        // timings on passing runs (XCTest suppresses stdout/NSLog from
        // xcodebuild output, but the file is reliable and append-only).
        let line = "[KWS-LATENCY] elapsed=\(String(format: "%.3f", elapsed))s \(breakdown)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/kws_latency.log"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        XCTAssertLessThan(
            elapsed,
            0.5,
            "50-keyword Whisper KWS scoring took \(String(format: "%.3f", elapsed))s; "
            + "expected <0.500s. Stages: \(breakdown)"
        )
    }

    /// Helper: load a WAV file as 16 kHz mono Float32 samples.
    private func loadWavAsMonoFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "WhisperKwsTests", code: 1)
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "WhisperKwsTests", code: 2)
        }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        // Mix down to mono.
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            for i in 0..<frameCount { mono[i] += channelData[c][i] }
        }
        let scale = 1.0 / Float(channels)
        for i in 0..<frameCount { mono[i] *= scale }
        return mono
    }
}
