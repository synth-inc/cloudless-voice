// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmojiSemanticMatcherValidationTests.swift
//  OnitTests
//
//  Acceptance test for the on-device MiniLM emoji embedder port. Loads the REAL
//  bundled CoreML model + 2,056-emoji anchor table + WordPiece tokenizer and
//  checks the Swift pipeline reproduces emoji_assets/VALIDATION.md. If the Swift
//  numbers diverge materially from VALIDATION.md, the tokenizer is almost
//  certainly the culprit - debug it against TOKENIZER_NOTES.md.
//

import XCTest
@testable import Onit

final class EmojiSemanticMatcherValidationTests: XCTestCase {

    private let embedder = MiniLMEmojiEmbedder.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(embedder.ensureLoaded(),
                          "MiniLMEmoji model / anchors not bundled - skipping")
    }

    private func topMatch(_ query: String) -> MiniLMEmojiEmbedder.AnchorMatch? {
        guard let vec = embedder.embed(query) else { return nil }
        return embedder.bestAnchor(vec)
    }

    /// Logs each result. Set `EMOJI_VALIDATION_OUT` to also tee lines to a file
    /// (the test host app's stdout isn't captured by xcodebuild).
    private func dump(_ line: String) {
        print(line)
        NSLog("%@", line)
        guard let path = ProcessInfo.processInfo.environment["EMOJI_VALIDATION_OUT"] else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); handle.closeFile()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func testValidationParity() throws {
        // (query, acceptable top-1 glyphs, expectPass)
        let positives: [(String, Set<String>)] = [
            ("sobbing", ["😭", "😢"]),
            ("upward chart", ["📈"]),
            ("mind blown", ["🤯"]),
        ]

        for (query, expected) in positives {
            let match = try XCTUnwrap(topMatch(query), "no embedding for \(query)")
            dump("SemanticEmojiValidation: \"\(query)\" → \(match.glyph) (\(match.name)) "
                  + "cos \(String(format: "%.3f", match.cosine)) "
                  + "margin \(String(format: "%.3f", match.cosine - match.secondCosine))")
            XCTAssertTrue(expected.contains(match.glyph),
                          "\(query): expected one of \(expected), got \(match.glyph)")
            XCTAssertGreaterThanOrEqual(match.cosine, 0.43,
                                        "\(query): cosine \(match.cosine) below gate")
        }

        // Negative: full phrase must fall below the 0.43 confidence gate.
        let negQuery = "how do I add an emoji"
        let neg = try XCTUnwrap(topMatch(negQuery), "no embedding for \(negQuery)")
        dump("SemanticEmojiValidation: \"\(negQuery)\" (NEG) → \(neg.glyph) (\(neg.name)) "
              + "cos \(String(format: "%.3f", neg.cosine))")
        XCTAssertLessThan(neg.cosine, 0.43,
                          "negative \(negQuery): cosine \(neg.cosine) should be below gate")
    }
}
