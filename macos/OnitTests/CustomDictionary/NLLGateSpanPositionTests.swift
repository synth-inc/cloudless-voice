// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NLLGateSpanPositionTests.swift
//  OnitTests
//
//  Locks in the fix for the "gate substring-searches for the span instead of
//  using the rescorer's exact word index" bug. Before the fix, a transcript
//  containing the span text multiple times (e.g. "it" appearing 5x) would
//  always be scored against the *first* occurrence - regardless of which
//  one the rescorer intended to replace.
//
//  See `feedback_no_linear_timestamp_interpolation.md` for the underlying
//  principle: never approximate a span's identity downstream when the
//  upstream already produced the exact value.
//

import XCTest
@testable import Onit

final class NLLGateSpanPositionTests: XCTestCase {

    // MARK: - charOffsets(forWordRange:in:)

    func testCharOffsetsForSingleWordAtStart() {
        let s = Array("hello world there")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 0, width: 1), in: s
        )
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 5)
        XCTAssertEqual(String(s[r!.start..<r!.end]), "hello")
    }

    func testCharOffsetsForSingleWordInMiddle() {
        let s = Array("hello world there")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 1, width: 1), in: s
        )
        XCTAssertEqual(String(s[r!.start..<r!.end]), "world")
    }

    func testCharOffsetsForSingleWordAtEnd() {
        let s = Array("hello world there")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 2, width: 1), in: s
        )
        XCTAssertEqual(String(s[r!.start..<r!.end]), "there")
    }

    func testCharOffsetsForMultiWordSpan() {
        let s = Array("alpha beta gamma delta")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 1, width: 2), in: s
        )
        XCTAssertEqual(String(s[r!.start..<r!.end]), "beta gamma")
    }

    /// The motivating case: span text "it" appears 5 times in the transcript
    /// but the rescorer intends position 14 (the "it" before "will basically
    /// activate"). The helper must return offsets covering THAT occurrence,
    /// not the first one.
    func testCharOffsetsDisambiguatesRepeatedWord() {
        let asr = "It will be like uh Siri, so anytime you have a podcast active you can say quote heyq quote and uh it will basically activate and you can ask it a question and it'll answer."
        let chars = Array(asr)
        let words = asr.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        // Find the second pure "it" (index 19 in the word array based on hand-count below).
        let itIndices = words.enumerated().compactMap { $0.element == "it" ? $0.offset : nil }
        XCTAssertGreaterThanOrEqual(itIndices.count, 2, "test fixture should have >= 2 'it'")
        let targetWordIndex = itIndices[1]  // the "it" before "will basically"
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: targetWordIndex, width: 1), in: chars
        )
        XCTAssertNotNil(r)
        XCTAssertEqual(String(chars[r!.start..<r!.end]), "it")
        // And critically: the located offsets must NOT be at the start of the
        // string (which is where "It" lives).
        XCTAssertGreaterThan(r!.start, 0)
    }

    func testCharOffsetsHandlesLeadingWhitespace() {
        let s = Array("  hello world")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 0, width: 1), in: s
        )
        XCTAssertEqual(String(s[r!.start..<r!.end]), "hello")
    }

    func testCharOffsetsHandlesMultipleSpaces() {
        let s = Array("hello   world")
        let r = CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 1, width: 1), in: s
        )
        XCTAssertEqual(String(s[r!.start..<r!.end]), "world")
    }

    func testCharOffsetsReturnsNilForOutOfRange() {
        let s = Array("hello world")
        XCTAssertNil(CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 5, width: 1), in: s
        ))
        XCTAssertNil(CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: 0, width: 0), in: s
        ))
        XCTAssertNil(CustomDictionaryNLLGate.charOffsets(
            forWordRange: (startWord: -1, width: 1), in: s
        ))
    }
}
