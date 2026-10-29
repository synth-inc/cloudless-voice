// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryGateLatencyTests.swift
//  OnitTests
//
//  Measures the per-call cost of `CustomDictionaryNLLGate.evaluate()` so we
//  can project the latency impact of emitting per-occurrence KWS detections
//  (each occurrence becomes one gate call). Skips if Llama isn't loaded.
//

import XCTest
@testable import Onit

final class CustomDictionaryGateLatencyTests: XCTestCase {

    private let warmupSentence = "I work with Raudin every Tuesday at the office."
    private let warmupSpan = "Raudin"
    private let warmupProxy = "Thompson"

    /// Time `gate.evaluate(...)` per call across N synthetic replacements.
    /// Mirrors what `applyReplacementsWithGate` does today: each replacement
    /// is one gate call, no caching of `nllOrig` across calls.
    func testPerCallGateLatency() async throws {
        try await ensurePerplexityEngineLoaded()
        let gate = CustomDictionaryNLLGate.shared

        // Warm up - first call usually pays one-time graph compile costs.
        _ = await gate.evaluate(
            asrSentence: warmupSentence,
            confusionSpan: warmupSpan,
            proxyWord: warmupProxy
        )

        // Test set: short, medium, long sentences with one match each.
        // Each call is independent so this stands in for "N detections in
        // one rescore" - the gate does not cache `nllOrig` between calls.
        let sentences: [(label: String, text: String, span: String)] = [
            ("short",  "I called Raudin yesterday.",                                 "Raudin"),
            ("medium", "I work with Raudin at the office and call him every day.",   "Raudin"),
            ("long",   "I work with Raudin every Tuesday at the office and check in with him before lunch and again before close.", "Raudin"),
        ]

        var parts: [String] = []
        for (label, text, span) in sentences {
            // Run 4 calls back-to-back to amortize warm-cache effects and
            // get a stable average. Each call emits up to 4 NLL evals
            // (original + 0..3 applicable variants depending on the span's
            // surrounding punctuation).
            let n = 4
            let t0 = Date()
            for _ in 0..<n {
                _ = await gate.evaluate(
                    asrSentence: text, confusionSpan: span, proxyWord: warmupProxy
                )
            }
            let elapsed = Date().timeIntervalSince(t0)
            let avgMs = (elapsed / Double(n)) * 1000
            parts.append("[\(label) \(text.count)ch=\(String(format: "%.1f", avgMs))ms]")
        }

        // No assertion on absolute time - different machines vary widely.
        // The summary lands in the test log so we can read the numbers.
        // Marked as XCTSkip so the suite doesn't fail when used as a probe.
        throw XCTSkip("Per-call gate latency: \(parts.joined(separator: " "))")
    }

    /// Worst-case: span sandwiched between punctuation so all 4 variants are
    /// applicable (keep + consume preceding + consume trailing + consume
    /// both). Compares to a clean sentence (1 variant only).
    func testFullVariantSetLatency() async throws {
        try await ensurePerplexityEngineLoaded()
        let gate = CustomDictionaryNLLGate.shared

        // Warm.
        _ = await gate.evaluate(
            asrSentence: warmupSentence, confusionSpan: warmupSpan, proxyWord: warmupProxy
        )

        let cleanSentence = "I called Raudin yesterday morning"
        let sandwichedSentence = "Hello, Raudin, please join us"

        let n = 5
        let tClean = Date()
        for _ in 0..<n {
            _ = await gate.evaluate(
                asrSentence: cleanSentence, confusionSpan: "Raudin", proxyWord: warmupProxy
            )
        }
        let cleanMs = Date().timeIntervalSince(tClean) / Double(n) * 1000

        let tSandwich = Date()
        for _ in 0..<n {
            _ = await gate.evaluate(
                asrSentence: sandwichedSentence, confusionSpan: "Raudin", proxyWord: warmupProxy
            )
        }
        let sandwichMs = Date().timeIntervalSince(tSandwich) / Double(n) * 1000

        throw XCTSkip(String(
            format: "Variant cost: clean=%.1fms (1 variant) sandwiched=%.1fms (4 variants) delta=+%.1fms",
            cleanMs, sandwichMs, sandwichMs - cleanMs
        ))
    }

    /// Project end-to-end rescore cost when the same keyword appears N times
    /// in the same dictation. Each extra occurrence becomes one extra gate
    /// call (today we max-pool to one call regardless).
    func testRepeatedOccurrenceProjection() async throws {
        try await ensurePerplexityEngineLoaded()
        let gate = CustomDictionaryNLLGate.shared

        // Sentence with the keyword repeated 3×. Per-occurrence detection
        // would emit 3 detections → 3 gate calls.
        let sentence = "I told Raudin that Raudin should call Raudin tomorrow."
        let span = "Raudin"

        // Warm up.
        _ = await gate.evaluate(
            asrSentence: sentence, confusionSpan: span, proxyWord: warmupProxy
        )

        // Today: 1 call (max-per-keyword KWS path).
        let t1 = Date()
        _ = await gate.evaluate(
            asrSentence: sentence, confusionSpan: span, proxyWord: warmupProxy
        )
        let oneCall = Date().timeIntervalSince(t1) * 1000

        // Per-occurrence: 3 calls.
        let t3 = Date()
        for _ in 0..<3 {
            _ = await gate.evaluate(
                asrSentence: sentence, confusionSpan: span, proxyWord: warmupProxy
            )
        }
        let threeCalls = Date().timeIntervalSince(t3) * 1000

        let extra = threeCalls - oneCall
        let pct = (extra / oneCall) * 100
        let summary = String(
            format: "1× call=%.1fms  3× calls=%.1fms  delta=+%.1fms (+%.0f%%)",
            oneCall, threeCalls, extra, pct
        )
        throw XCTSkip("Repeated-occurrence projection - \(summary)")
    }

    // MARK: - Setup

    private func ensurePerplexityEngineLoaded() async throws {
        guard await !MLXScoringEngine.shared.isLoaded else { return }
        do {
            try await MLXScoringEngine.shared.ensureLoaded()
        } catch {
            throw XCTSkip("MLXScoringEngine not loaded: \(error.localizedDescription)")
        }
        // After ensureLoaded resolves, give the engine one warmup token call.
        _ = try? await MLXScoringEngine.shared.tokenScores("warmup")
    }
}
