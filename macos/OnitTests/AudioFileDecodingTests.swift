// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AudioFileDecodingTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-09-15.
//

import AVFoundation
import Foundation
import Testing
@testable import Onit

struct AudioFileDecodingTests {

    @Test("Stereo 44.1 kHz WAV keeps its duration and mixes both channels down")
    func stereoWavIsDownmixedWithoutLosingTheTail() throws {
        // Speech only on the RIGHT channel: a decoder that keeps the first channel
        // returns silence.
        let url = try writeTone(
            seconds: 2.5,
            sampleRate: 44_100,
            channels: 2,
            toneChannel: 1,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            fileExtension: "wav"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioResampling.decodeFile(at: url)

        #expect(abs(samples.count - 40_000) <= 40, "decoded \(samples.count) samples, expected 40000")
        #expect(rms(samples) > 0.1, "right channel was dropped (rms \(rms(samples)))")
        // The converter holds a few frames back until it is told the input ended.
        #expect(rms(samples.suffix(1_600)) > 0.1, "last 100 ms are silent")
    }

    @Test("AAC m4a decodes to 16 kHz with its duration")
    func compressedFileDecodes() throws {
        let url = try writeTone(
            seconds: 3,
            sampleRate: 48_000,
            channels: 1,
            toneChannel: 0,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: 64_000,
            ],
            fileExtension: "m4a"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioResampling.decodeFile(at: url)

        #expect(abs(samples.count - 48_000) <= 960, "decoded \(samples.count) samples, expected ~48000")
        #expect(rms(samples) > 0.1)
    }

    @Test("A truncated file decodes what it holds")
    func truncatedFileDecodesWhatItHolds() throws {
        let url = try writeTone(
            seconds: 2.5,
            sampleRate: 44_100,
            channels: 2,
            toneChannel: 0,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            fileExtension: "wav"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        // An interrupted download: the header still announces 2.5 s. AVAudioFile reads up to
        // the real end without throwing (checked 2026-09-15), so no partial-read fallback.
        let data = try Data(contentsOf: url)
        try data.prefix(data.count * 6 / 10).write(to: url)

        let samples = try AudioResampling.decodeFile(at: url)

        #expect(samples.count > 20_000, "decoded \(samples.count) samples of a ~24000 sample file")
    }

    @Test("A file that is not audio throws")
    func nonAudioFileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        try Data("definitely not a RIFF header".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try AudioResampling.decodeFile(at: url)
        }
    }

    // MARK: - Helpers

    private func writeTone(
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        toneChannel: Int,
        settings: [String: Any],
        fileExtension: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-\(UUID().uuidString).\(fileExtension)")
        var fileSettings = settings
        fileSettings[AVSampleRateKey] = sampleRate
        fileSettings[AVNumberOfChannelsKey] = channels

        let frames = AVAudioFrameCount(seconds * sampleRate)
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let tone = try #require(buffer.floatChannelData?[toneChannel])
        for i in 0..<Int(frames) {
            tone[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }

        // The file is finalized when it is released, so it must not outlive this scope.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }
        return url
    }

    private func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}
