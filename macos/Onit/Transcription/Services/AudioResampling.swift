// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AudioResampling.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import AVFoundation
import Foundation

/// Linear-interpolated resampling shared between the ASR services. Cheap and
/// good-enough for 16 kHz speech - Whisper/Parakeet downstream models are
/// trained on similar approximations, so the resampling fidelity is not the
/// bottleneck. Centralised here so we don't keep three copies of the same
/// implementation around.
enum AudioResampling {

    /// Resample `samples` from `sourceSampleRate` to `targetSampleRate` using linear
    /// interpolation. Returns the input unchanged when the rates already match.
    static func linear(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        guard sourceSampleRate != targetSampleRate else { return samples }

        let ratio = sourceSampleRate / targetSampleRate
        let targetCount = Int(Double(samples.count) / ratio)
        guard targetCount > 0 else { return [] }

        var result = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let sourceIndex = Double(i) * ratio
            let index0 = Int(sourceIndex)
            let index1 = min(index0 + 1, samples.count - 1)
            let frac = Float(sourceIndex - Double(index0))
            result[i] = samples[index0] * (1 - frac) + samples[index1] * frac
        }
        return result
    }

    /// Decodes any file `AVAudioFile` reads (wav, aiff, caf, m4a, mp3, flac) to 16 kHz mono
    /// float32, the ASR contract. Reads in chunks, mixes every channel down, and drains the
    /// converter's tail so the last few milliseconds are not lost. Blocking: call it off the
    /// main actor.
    static func decodeFile(at url: URL, targetSampleRate: Double = 16_000) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 65_536
        let ratio = targetSampleRate / sourceFormat.sampleRate

        guard let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: targetSampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let output = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up)) + 1_024
              )
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Without it the converter keeps the first channel only.
        converter.downmix = true

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio))
        var readError: Error?

        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: chunkFrames)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }

            if let readError { throw readError }
            if status == .error { throw conversionError ?? CocoaError(.fileReadCorruptFile) }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream { break }
            // No output and nothing left to read: done, whatever status says.
            if output.frameLength == 0, file.framePosition >= file.length { break }
        }
        return samples
    }
}
