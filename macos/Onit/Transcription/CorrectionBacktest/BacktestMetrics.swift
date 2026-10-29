// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktestMetrics.swift
//  Onit
//
//  Word-error-rate and word-level diff for the correction backtest. Mirrors
//  the normalization in OnitTests/TranscriptionBenchmark/TranscriptionMetrics
//  (lowercase + whitespace tokenization, punctuation kept) so in-app numbers
//  stay comparable with the offline benchmarks.
//

import Foundation

enum BacktestMetrics {

    /// Word error rate: word-level Levenshtein distance over the reference
    /// length. Can exceed 1.0 when the hypothesis is longer than the reference.
    static func wer(reference: String, hypothesis: String) -> Double {
        let refWords = tokenize(reference)
        let hypWords = tokenize(hypothesis)
        guard !refWords.isEmpty else { return hypWords.isEmpty ? 0.0 : 1.0 }
        return Double(levenshtein(refWords, hypWords)) / Double(refWords.count)
    }

    /// Splits `actual` into display tokens and marks the ones that don't
    /// participate in the longest common subsequence with `expected`
    /// (case-insensitive) - the same highlighting rule as the benchmark
    /// comparison viewer.
    static func wordDiff(expected: String, actual: String) -> [(token: String, isError: Bool)] {
        let exp = tokenize(expected)
        let act = actual.split(whereSeparator: \.isWhitespace).map(String.init)
        let actLower = act.map { $0.lowercased() }

        let m = exp.count
        let n = actLower.count
        guard m > 0, n > 0 else {
            return act.map { ($0, true) }
        }

        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = exp[i - 1] == actLower[j - 1]
                    ? dp[i - 1][j - 1] + 1
                    : max(dp[i - 1][j], dp[i][j - 1])
            }
        }

        var matched = Set<Int>()
        var i = m, j = n
        while i > 0 && j > 0 {
            if exp[i - 1] == actLower[j - 1] {
                matched.insert(j - 1)
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return act.enumerated().map { idx, token in
            (token, !matched.contains(idx))
        }
    }

    // MARK: - Private

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
