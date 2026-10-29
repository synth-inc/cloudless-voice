// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailLayoutEitherOrTests.swift
//  OnitTests
//
//  Verifies the intended behavior: email layout should be eligible when the dictation has a
//  salutation OR a sign-off - not require BOTH. Users often dictate an email in pieces (just the
//  opener, or just the closing), so requiring both would leave those unformatted.
//
//  Runs the real engine's email-layout post-process directly (emailFormattingEnabled set on the
//  config, bypassing the app-side composer gate), with a flat-score stub engine so no MLX model is
//  needed for the deterministic email pass.
//

#if canImport(TranscriptionCleanup)

import Foundation
import Testing
import TranscriptionCleanup
@testable import Onit

/// Flat-score engine - mirrors `MLXScoringEngineAdapter`'s no-model path. `outlierThreshold`,
/// `capThreshold`, and `currentLocale` come from the `ScoringEngine` protocol-extension defaults.
private actor FlatScoreEngine: ScoringEngine {
    func tokenScores(_ text: String) async throws -> (tokenIDs: [Int], scores: [Float]) {
        let n = text.split(separator: " ").count
        return (tokenIDs: Array(0..<max(n, 1)), scores: Array(repeating: 2.0, count: max(n - 1, 0)))
    }
    func scoreTrailingPunctuation(_ text: String, punctuation: [String]) async throws
        -> (avgScore: Float, punctScores: [String: Float]) {
        (avgScore: 2.0, punctScores: Dictionary(uniqueKeysWithValues: punctuation.map { ($0, 2.0) }))
    }
}

@Suite(.serialized, .disabled("Smart Cleanup enforcement cannot be disabled in the shipped framework"))
struct EmailLayoutEitherOrTests {

    private func emailFormat(_ text: String) async throws -> String {
        let pipeline = TranscriptionCleanup.CleanupPipeline(engine: FlatScoreEngine(), llmCleanup: nil)
        // Email layout on, everything else off - isolate the email post-process.
        let cfg = TranscriptionCleanup.PipelineConfig(emailFormattingEnabled: true)
        return try await pipeline.processChunked(text, config: cfg).outputText
    }

    // Email layout reflows onto multiple lines; the inputs are single-paragraph, so a newline in
    // the output means the email pass engaged.
    private func wasEmailFormatted(_ output: String) -> Bool { output.contains("\n") }

    @Test("Salutation-only is eligible (no sign-off required)")
    func salutationOnly() async throws {
        let out = try await emailFormat(
            "Hey Josh, nice talking to you earlier today. I'd love to find some time to connect next week.")
        #expect(wasEmailFormatted(out), "salutation-only should email-format; got: \(out.debugDescription)")
    }

    @Test("Sign-off-only is eligible (no salutation required)")
    func signOffOnly() async throws {
        let out = try await emailFormat(
            "Let's circle back next week to nail down the details. Thanks, Tim.")
        #expect(wasEmailFormatted(out), "sign-off-only should email-format; got: \(out.debugDescription)")
    }

    @Test("Salutation + sign-off is eligible (baseline)")
    func both() async throws {
        let out = try await emailFormat("Hey Josh, nice talking to you. Thanks, Tim.")
        #expect(wasEmailFormatted(out), "salutation+sign-off should email-format; got: \(out.debugDescription)")
    }

    @Test("Neither salutation nor sign-off is NOT email-formatted")
    func neither() async throws {
        let out = try await emailFormat(
            "The quarterly numbers look strong across every region this month.")
        #expect(!wasEmailFormatted(out), "plain text should not email-format; got: \(out.debugDescription)")
    }
}

#endif // canImport(TranscriptionCleanup)
