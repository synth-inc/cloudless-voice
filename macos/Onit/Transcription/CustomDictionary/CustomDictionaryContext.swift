// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryContext.swift
//  Onit
//
//  Collection of vocabulary terms for a transcription session.
//

import Foundation

/// Collection of custom vocabulary terms used to bias CTC transcription.
struct CustomDictionaryContext: Sendable {
    let terms: [CustomDictionaryTerm]
    /// CTC biasing weight (default 3.0)
    let alpha: Float
    /// Min normalized CTC score to trigger replacement
    let minCtcScore: Float
    /// Min string similarity floor
    let minSimilarity: Float
    /// Min chars to avoid false positives
    let minTermLength: Int

    static let defaultAlpha: Float = 3.0
    static let defaultMinCtcScore: Float = ContextBiasingConstants.defaultMinSpotterScore
    static let defaultMinSimilarity: Float = ContextBiasingConstants.defaultMinSimilarity
    static let defaultMinTermLength: Int = 3

    init(
        terms: [CustomDictionaryTerm],
        alpha: Float = defaultAlpha,
        minCtcScore: Float = defaultMinCtcScore,
        minSimilarity: Float = defaultMinSimilarity,
        minTermLength: Int = defaultMinTermLength
    ) {
        self.terms = terms
        self.alpha = alpha
        self.minCtcScore = minCtcScore
        self.minSimilarity = minSimilarity
        self.minTermLength = minTermLength
    }

    /// Create from plain text lines (one word/phrase per line, # comments, blank lines ignored).
    static func fromLines(_ lines: [String]) -> CustomDictionaryContext {
        let terms = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { CustomDictionaryTerm(text: $0) }
        return CustomDictionaryContext(terms: terms)
    }
}
