// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktrackingMarkerMatchingTests.swift
//  OnitTests
//
//  Regression coverage for the backtracking-marker gate. ASR routinely commas-off
//  interjections ("no, sorry", "wait,", "actually,"), and the marker regex used to require a
//  literal space between words - so "No, sorry" never matched "no sorry" and the backtracking
//  pass was skipped in exactly the natural-speech cases it exists for (and the onboarding demo's
//  backtracking step silently failed). The separator is now punctuation-tolerant (`\W+`).
//

import Foundation
import Testing
@testable import Onit

@Suite
struct BacktrackingMarkerMatchingTests {

    private func matches(_ marker: String, in text: String) -> Bool {
        let regexes = BacktrackingMarkersManager.compileRegexes(for: [marker])
        let range = NSRange(text.startIndex..., in: text)
        return regexes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    // MARK: - The bug: ASR punctuation between marker words

    @Test("A multi-word marker matches across an ASR-inserted comma")
    func matchesAcrossComma() {
        #expect(matches("no sorry", in: "at 8 AM, No, sorry, 9 AM."))   // the reported case
        #expect(matches("no sorry", in: "at 8 AM, no sorry, 9 AM"))     // plain space still works
        #expect(matches("wait no", in: "let's meet \u{2014} wait, no, tomorrow"))
        #expect(matches("no sorry", in: "no. Sorry, 9 AM"))             // period + space
    }

    // MARK: - Must not over-match

    @Test("The separator only bridges punctuation/whitespace, never an intervening word")
    func doesNotBridgeAWord() {
        #expect(!matches("no sorry", in: "no I'm not sorry"))           // "I'm not" between → no match
        #expect(!matches("no sorry", in: "nosorry"))                    // needs a real separator
    }

    @Test("Unrelated text with no marker does not match")
    func noFalsePositiveOnPlainText() {
        #expect(!matches("no sorry", in: "Let's meet at 9 AM tomorrow."))
    }

    @Test("Single-word markers are unaffected")
    func singleWordUnaffected() {
        #expect(matches("actually", in: "Actually, let's do 9 AM."))
        #expect(!matches("actually", in: "The factual answer is 9 AM."))  // \b guards against substrings
    }
}
