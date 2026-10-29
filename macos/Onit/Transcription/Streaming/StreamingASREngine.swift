// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StreamingASREngine.swift
//  Onit
//
//  Created by Kévin Naudin on 20/07/2026.
//

import Foundation

/// Result of transcribing one segment of an in-progress dictation through the
/// chunked-streaming seam.
///
/// `wordTimestamps` are **segment-relative**: `startSec`/`endSec` are measured
/// from the first sample handed to `transcribeSegment` (frame 0 == segment
/// start), not from the start of the recording. The streaming stitcher re-offsets
/// them to absolute recording coordinates once it knows where the segment sits.
/// `nil` when the underlying engine exposes no per-word timing (MLX); the
/// session then degrades the whole run's timeline to `nil` (the dictionary
/// rescore falls back to its non-timed path).
struct StreamingSegmentResult: Sendable {
    let text: String
    let wordTimestamps: [WordTimestamp]?
}

/// Capability surface for ASR engines that can transcribe a dictation as a
/// sequence of disjoint (small-overlap) audio segments *during* recording - the
/// chunked-streaming scheme ported from the Windows `IStreamingAsrEngine` seam.
///
/// Ported deliberately WITHOUT the Windows `priorText` decoder-context parameter:
/// no macOS engine consumes a rolling transcript, so cross-segment overlap dedup
/// is entirely the stitcher's job. Do not add a prior-text parameter here.
///
/// Engines that can't or shouldn't be driven segment-by-segment simply don't
/// conform; the streaming pipeline gates on the registry's
/// `ASRBackendDescriptor.supportsChunkedStreaming` and otherwise stays on the
/// single-shot path.
///
/// Declared `AnyObject` (not `@MainActor`) so the ASR engine `actor`s can conform:
/// `transcribeSegment` is `async`, satisfied by an actor-isolated method.
///
/// Refined `Sendable` so the session may hold and drive an erased
/// `any StreamingASRCapable` across its worker isolation - every conformer is an
/// `actor`, so the requirement is already satisfied.
protocol StreamingASRCapable: AnyObject, Sendable {

    /// Transcribe one segment of an in-progress dictation.
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM in [-1, 1], 16 kHz mono (segment incl. any
    ///     lead-in overlap the caller prepended).
    ///   - sampleRate: Must be 16000; the engines assume 16 kHz internally.
    ///   - language: Optional language hint (ISO 639-1); `nil` = auto.
    /// - Returns: The segment text plus optional segment-relative word timings.
    ///
    /// - Important: Callers must keep each segment **≤ 15 s** on the Parakeet
    ///   engine. Beyond that its own timestamped path re-triggers nested
    ///   chunking (`maxModelSamples`), which is not what the streaming stitcher
    ///   wants. This is a contract on the seam, not enforced here.
    func transcribeSegment(
        samples: [Float],
        sampleRate: Int,
        language: String?
    ) async throws -> StreamingSegmentResult
}
