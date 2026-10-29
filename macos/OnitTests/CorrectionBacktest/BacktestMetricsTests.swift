// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktestMetricsTests.swift
//  OnitTests
//
//  WER + word-diff for the correction backtest. Mirrors the normalization
//  used by the offline benchmark suite (lowercase, whitespace tokens,
//  punctuation kept) so in-app numbers stay comparable.
//

import Foundation
import Testing
@testable import Onit

@Suite("BacktestMetrics.wer")
struct BacktestMetricsWERTests {

    @Test("identical strings score 0")
    func identicalIsZero() {
        #expect(BacktestMetrics.wer(reference: "hello world", hypothesis: "hello world") == 0.0)
    }

    @Test("case differences are normalized away")
    func caseInsensitive() {
        #expect(BacktestMetrics.wer(reference: "Hello World", hypothesis: "hello world") == 0.0)
    }

    @Test("one substitution in four words is 0.25")
    func oneSubstitution() {
        let wer = BacktestMetrics.wer(
            reference: "the quick brown fox",
            hypothesis: "the quick green fox"
        )
        #expect(abs(wer - 0.25) < 0.0001)
    }

    @Test("one deletion in four words is 0.25")
    func oneDeletion() {
        let wer = BacktestMetrics.wer(
            reference: "the quick brown fox",
            hypothesis: "the quick fox"
        )
        #expect(abs(wer - 0.25) < 0.0001)
    }

    @Test("empty reference with empty hypothesis is 0")
    func bothEmpty() {
        #expect(BacktestMetrics.wer(reference: "", hypothesis: "") == 0.0)
    }

    @Test("empty reference with non-empty hypothesis is 1.0")
    func emptyReferenceOnly() {
        #expect(BacktestMetrics.wer(reference: "", hypothesis: "spurious words") == 1.0)
    }

    @Test("empty hypothesis against full reference is 1.0")
    func emptyHypothesis() {
        #expect(BacktestMetrics.wer(reference: "one two three", hypothesis: "") == 1.0)
    }

    @Test("hypothesis longer than reference can exceed 1.0")
    func insertionsExceedOne() {
        // ref has 1 word; hypothesis has 3 → 2 insertions / 1 ref word = 2.0
        let wer = BacktestMetrics.wer(reference: "yes", hypothesis: "yes and also no")
        #expect(wer > 1.0)
    }

    @Test("extra whitespace does not create phantom tokens")
    func whitespaceCollapsed() {
        #expect(BacktestMetrics.wer(reference: "a b", hypothesis: "a   b") == 0.0)
    }
}

@Suite("BacktestMetrics.wordDiff")
struct BacktestMetricsDiffTests {

    @Test("all-correct output marks no errors")
    func noErrors() {
        let diff = BacktestMetrics.wordDiff(expected: "the quick fox", actual: "the quick fox")
        #expect(diff.allSatisfy { !$0.isError })
        #expect(diff.map(\.token) == ["the", "quick", "fox"])
    }

    @Test("a substituted word is flagged, matches are not")
    func flagsSubstitution() {
        let diff = BacktestMetrics.wordDiff(expected: "the quick brown fox", actual: "the quick green fox")
        let errors = diff.filter(\.isError).map(\.token)
        #expect(errors == ["green"])
    }

    @Test("original casing is preserved in returned tokens")
    func preservesCasing() {
        let diff = BacktestMetrics.wordDiff(expected: "hello world", actual: "Hello World")
        #expect(diff.map(\.token) == ["Hello", "World"])
        #expect(diff.allSatisfy { !$0.isError })
    }

    @Test("empty expected marks every actual token as an error")
    func emptyExpected() {
        let diff = BacktestMetrics.wordDiff(expected: "", actual: "two words")
        #expect(diff.count == 2)
        #expect(diff.allSatisfy { $0.isError })
    }

    @Test("empty actual yields no tokens")
    func emptyActual() {
        let diff = BacktestMetrics.wordDiff(expected: "anything", actual: "")
        #expect(diff.isEmpty)
    }
}
