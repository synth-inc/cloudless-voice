// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperBPETokenizerTests.swift
//  OnitTests
//
//  Tests for the byte-level GPT-2 BPE tokenizer used by Whisper.
//  Expected token IDs were generated against HuggingFace's
//  `WhisperTokenizer.from_pretrained("openai/whisper-base")`.
//

import XCTest
@testable import Onit

final class WhisperBPETokenizerTests: XCTestCase {

    // MARK: - Helpers

    /// Encode body-only (no decoder prefix). Awaits the actor for ergonomic XCT use.
    private func encodeBody(_ text: String) async throws -> [Int] {
        try await WhisperBPETokenizer.shared.encode(text, withDecoderPrefix: false)
    }

    private func encodeWithPrefix(_ text: String) async throws -> [Int] {
        try await WhisperBPETokenizer.shared.encode(text, withDecoderPrefix: true)
    }

    // MARK: - Core fixtures (spec'd in the issue)

    func testOnitBodyOnly() async throws {
        let ids = try await encodeBody("Onit")
        XCTAssertEqual(ids, [1282, 270])
    }

    func testOnitWithDecoderPrefix() async throws {
        let ids = try await encodeWithPrefix("Onit")
        XCTAssertEqual(ids,
                       [50258, 50259, 50359, 50363, 1282, 270],
                       "Decoder prefix must be SOT + en + transcribe + notimestamps.")
    }

    func testHelloWorldMatchesHuggingFace() async throws {
        // From `WhisperTokenizer.from_pretrained("openai/whisper-base")`
        // .encode(" hello world", add_special_tokens=False) → [7751, 1002]
        let ids = try await encodeBody("hello world")
        XCTAssertEqual(ids, [7751, 1002])
    }

    // MARK: - Diverse inputs (matches HF whisper-base)

    func testNumbers() async throws {
        // ' 123' → [34466]
        let ids = try await encodeBody("123")
        XCTAssertEqual(ids, [34466])
    }

    func testUnicodeAccent() async throws {
        // ' café' → [25118]
        let ids = try await encodeBody("café")
        XCTAssertEqual(ids, [25118])
    }

    func testPunctuation() async throws {
        // ' Hello, world!' → [2425, 11, 1002, 0]
        let ids = try await encodeBody("Hello, world!")
        XCTAssertEqual(ids, [2425, 11, 1002, 0])
    }

    func testMultiWord() async throws {
        // ' foo bar baz' → [726, 78, 2159, 27147]
        let ids = try await encodeBody("foo bar baz")
        XCTAssertEqual(ids, [726, 78, 2159, 27147])
    }

    func testUnicodeMultiCharacter() async throws {
        // ' Sjögren' → [318, 73, 973, 45968]
        let ids = try await encodeBody("Sjögren")
        XCTAssertEqual(ids, [318, 73, 973, 45968])
    }

    // MARK: - Empty / edge cases

    func testEmptyStringReturnsEmpty() async throws {
        let ids = try await encodeBody("")
        XCTAssertEqual(ids, [])
    }

    func testEmptyWithPrefixReturnsPrefixOnly() async throws {
        let ids = try await encodeWithPrefix("")
        XCTAssertEqual(ids, [50258, 50259, 50359, 50363])
    }
}
