// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASREngineGate.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-09-16.
//

import Foundation

/// One inference at a time on a shared model.
///
/// Every path drives the same process-wide objects: a live dictation, the segments of a
/// file transcription, a re-transcription, the keep-alive ping, the correction backtest,
/// and the Smart Formatting scorer behind all of them. Actor isolation is not enough to
/// serialize them: an engine whose call awaits inside its actor (`WhisperCoreMLEngine`
/// awaiting WhisperKit, `MLXScoringEngine.tokenScores` awaiting its model container) lets
/// a second call in at that suspension point, and the two then share one model.
///
/// Two gates, so a file transcription's cleanup pass never delays a dictation's ASR:
/// - ``asr`` around every ASR inference,
/// - ``cleanup`` around every Smart Formatting pass.
///
/// FIFO, except that a live dictation jumps the queue (`jumpQueue`): it waits for the
/// work in flight, never behind a file job's remaining segments. Isolated to the main
/// actor, which is where every caller already runs, so the queue needs no lock of its own.
@MainActor
final class ASREngineGate {

    /// The ASR engines (Parakeet, Whisper, Moonshine, MLX).
    static let asr = ASREngineGate()
    /// The Smart Formatting scorer.
    static let cleanup = ASREngineGate()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Runs `inference` with exclusive use of the model. Errors (and cancellation) still
    /// release the gate.
    /// - Parameter jumpQueue: a live dictation goes to the head of the queue.
    func withEngine<T>(jumpQueue: Bool = false, _ inference: () async throws -> T) async rethrows -> T {
        await acquire(jumpQueue: jumpQueue)
        do {
            let value = try await inference()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    /// Take the gate by hand. Only for callers that cannot pass a closure across
    /// isolation (`StreamingDictationSession` runs on its own actor); everywhere else
    /// use `withEngine`, which cannot forget the release.
    func acquire(jumpQueue: Bool = false) async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            if jumpQueue {
                waiters.insert(continuation, at: 0)
            } else {
                waiters.append(continuation)
            }
        }
    }

    /// Pair of `acquire()`.
    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
