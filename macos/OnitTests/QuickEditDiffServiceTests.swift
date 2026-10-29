// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  QuickEditDiffServiceTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 01/07/2026.
//

import XCTest
@testable import Onit

/// Tests for QuickEditDiffService diff computation and undo functionality
@MainActor
final class QuickEditDiffServiceTests: XCTestCase {

    var diffService: QuickEditDiffService!

    override func setUp() {
        super.setUp()
        diffService = QuickEditDiffService.shared
        diffService.reset()
    }

    override func tearDown() {
        diffService.reset()
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Helper to print segment details for debugging
    private func printSegments(_ segments: [DiffSegment], label: String = "") {
        print("\n--- Segments \(label) ---")
        for (i, seg) in segments.enumerated() {
            let paired = seg.pairedSegmentId != nil ? "paired" : "standalone"
            print("[\(i)] \(seg.type) range(\(seg.range.location),\(seg.range.length)) original=\"\(seg.originalText)\" new=\"\(seg.newText)\" (\(paired))")
        }
        print("displayText: \"\(diffService.displayText)\"")
        print("responseText: \"\(diffService.responseText)\"")
    }

    /// Verify undo on an insert segment restores the original text
    private func verifyUndoInsert(segmentIndex: Int, expectedResponse: String, file: StaticString = #file, line: UInt = #line) {
        let segments = diffService.diffSegments
        guard segmentIndex < segments.count else {
            XCTFail("Segment index \(segmentIndex) out of bounds", file: file, line: line)
            return
        }

        let segment = segments[segmentIndex]
        XCTAssertEqual(segment.type, .insert, "Expected insert segment at index \(segmentIndex)", file: file, line: line)

        let result = diffService.undoSegment(segmentId: segment.id)
        XCTAssertNotNil(result, "Undo should return a result", file: file, line: line)
        XCTAssertEqual(result, expectedResponse, "Undo result mismatch", file: file, line: line)
    }

    /// Verify undo on a standalone delete segment restores the deleted text
    private func verifyUndoDelete(segmentIndex: Int, expectedResponse: String, file: StaticString = #file, line: UInt = #line) {
        let segments = diffService.diffSegments
        guard segmentIndex < segments.count else {
            XCTFail("Segment index \(segmentIndex) out of bounds", file: file, line: line)
            return
        }

        let segment = segments[segmentIndex]
        XCTAssertEqual(segment.type, .delete, "Expected delete segment at index \(segmentIndex)", file: file, line: line)
        XCTAssertNil(segment.pairedSegmentId, "Expected standalone delete (no pairedSegmentId)", file: file, line: line)

        let result = diffService.undoSegment(segmentId: segment.id)
        XCTAssertNotNil(result, "Undo should return a result", file: file, line: line)
        XCTAssertEqual(result, expectedResponse, "Undo result mismatch", file: file, line: line)
    }

    // MARK: - Basic Tests

    func testIdenticalTexts() {
        let text = "Hello world"
        diffService.computeDiff(original: text, response: text)

        XCTAssertFalse(diffService.hasChanges)
        XCTAssertEqual(diffService.displayText, text)
        XCTAssertTrue(diffService.diffSegments.allSatisfy { $0.type == .equal })
    }

    func testEmptyOriginal() {
        diffService.computeDiff(original: "", response: "Hello world")

        XCTAssertTrue(diffService.hasChanges)
        XCTAssertEqual(diffService.displayText, "Hello world")

        // Should be pure inserts
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertFalse(inserts.isEmpty)
        XCTAssertTrue(inserts.allSatisfy { $0.originalText.isEmpty })
    }

    func testEmptyResponse() {
        diffService.computeDiff(original: "Hello world", response: "")

        XCTAssertTrue(diffService.hasChanges)
        XCTAssertEqual(diffService.displayText, "Hello world")

        // Should be standalone deletes
        let deletes = diffService.diffSegments.filter { $0.type == .delete }
        XCTAssertFalse(deletes.isEmpty)
        XCTAssertTrue(deletes.allSatisfy { $0.pairedSegmentId == nil })
    }

    // MARK: - SWAP Tests (delete + insert)

    func testSimpleSwap() {
        // "Hello" replaced by "Hi"
        diffService.computeDiff(original: "Hello world", response: "Hi world")

        printSegments(diffService.diffSegments, label: "Simple Swap")

        XCTAssertTrue(diffService.hasChanges)

        // Find the insert segment
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertEqual(inserts.count, 1)

        let insert = inserts[0]
        XCTAssertEqual(insert.newText, "Hi")
        XCTAssertEqual(insert.originalText, "Hello") // Should have the deleted text
        XCTAssertNotNil(insert.pairedSegmentId) // Should be paired

        // Verify undo restores original
        let insertIndex = diffService.diffSegments.firstIndex { $0.id == insert.id }!
        verifyUndoInsert(segmentIndex: insertIndex, expectedResponse: "Hello world")
    }

    func testMultiWordSwap() {
        // "Hello beautiful" replaced by "Hi"
        diffService.computeDiff(original: "Hello beautiful world", response: "Hi world")

        printSegments(diffService.diffSegments, label: "Multi-word Swap")

        XCTAssertTrue(diffService.hasChanges)

        // Find the insert for "Hi"
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 0, "Should have at least one insert")

        // The insert "Hi" should have the deleted text as originalText
        if let hiInsert = inserts.first(where: { $0.newText == "Hi" }) {
            XCTAssertFalse(hiInsert.originalText.isEmpty, "Swap insert should have non-empty originalText")
            XCTAssertNotNil(hiInsert.pairedSegmentId, "Swap insert should be paired")

            // Verify undo restores the deleted text
            let result = diffService.undoSegment(segmentId: hiInsert.id)
            XCTAssertNotNil(result)
            XCTAssertTrue(result!.contains("Hello") || result!.contains("beautiful"), "Undo should restore deleted text")
        }
    }

    func testMultipleSwaps() {
        // Multiple words replaced
        diffService.computeDiff(original: "The quick brown fox", response: "A slow red dog")

        printSegments(diffService.diffSegments, label: "Multiple Swaps")

        XCTAssertTrue(diffService.hasChanges)

        // Each swap should be independent
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 0)

        // Undo first insert only
        if let firstInsert = inserts.first {
            let originalResponse = diffService.responseText
            let result = diffService.undoSegment(segmentId: firstInsert.id)
            XCTAssertNotNil(result)
            XCTAssertNotEqual(result, originalResponse) // Should have changed
        }
    }

    // MARK: - Standalone DELETE Tests

    func testStandaloneDeleteAtEnd() {
        // Text removed from end
        diffService.computeDiff(original: "Hello world today", response: "Hello world")

        printSegments(diffService.diffSegments, label: "Standalone Delete at End")

        // Should have standalone delete for " today"
        let deletes = diffService.diffSegments.filter { $0.type == .delete }
        XCTAssertEqual(deletes.count, 1)

        let delete = deletes[0]
        XCTAssertNil(delete.pairedSegmentId) // Standalone
        XCTAssertEqual(delete.originalText, " today")

        // Verify undo restores the deleted text
        let deleteIndex = diffService.diffSegments.firstIndex { $0.id == delete.id }!
        verifyUndoDelete(segmentIndex: deleteIndex, expectedResponse: "Hello world today")
    }

    func testStandaloneDeleteAtStart() {
        // Text removed from start
        diffService.computeDiff(original: "Hello world", response: "world")

        printSegments(diffService.diffSegments, label: "Standalone Delete at Start")

        let deletes = diffService.diffSegments.filter { $0.type == .delete }
        XCTAssertEqual(deletes.count, 1)

        let delete = deletes[0]
        XCTAssertNil(delete.pairedSegmentId)
        XCTAssertEqual(delete.originalText, "Hello ")

        // Verify undo
        let deleteIndex = diffService.diffSegments.firstIndex { $0.id == delete.id }!
        verifyUndoDelete(segmentIndex: deleteIndex, expectedResponse: "Hello world")
    }

    /// Tests standalone deletes in the middle of text (word removed without replacement).
    /// Verifies that undoing the delete restores the removed text.
    func testStandaloneDeleteInMiddle_UndoRestoresDeletedText() {
        // Text removed from middle (separated by equal)
        diffService.computeDiff(original: "Hello beautiful world", response: "Hello world")

        printSegments(diffService.diffSegments, label: "Standalone Delete in Middle")

        // Should have standalone deletes (text removed without replacement)
        let standaloneDeletes = diffService.diffSegments.filter { $0.type == .delete && $0.pairedSegmentId == nil }
        XCTAssertGreaterThan(standaloneDeletes.count, 0, "Should have at least one standalone delete")

        // The deleted text should contain "beautiful"
        let allDeletedText = standaloneDeletes.map { $0.originalText }.joined()
        XCTAssertTrue(allDeletedText.contains("beautiful"), "Deleted text should contain 'beautiful'")

        // Verify undo restores the deleted text
        var currentResponse = diffService.responseText
        for delete in standaloneDeletes {
            diffService.computeDiff(original: "Hello beautiful world", response: currentResponse)
            if let deleteSegment = diffService.diffSegments.first(where: { $0.id == delete.id || ($0.type == .delete && $0.pairedSegmentId == nil) }) {
                if let result = diffService.undoSegment(segmentId: deleteSegment.id) {
                    currentResponse = result
                }
            }
        }
        XCTAssertTrue(currentResponse.contains("beautiful"), "After undo, response should contain 'beautiful'")
    }

    // MARK: - Pure INSERT Tests

    /// Tests pure inserts (no preceding delete) at the end of text.
    /// Verifies that undoing all inserts sequentially restores the original text.
    func testPureInsertAtEnd_UndoAllRestoresOriginal() {
        diffService.computeDiff(original: "Hello", response: "Hello world")

        printSegments(diffService.diffSegments, label: "Pure Insert at End")

        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 0, "Should have at least one insert")

        // All inserts should be pure (no paired delete)
        for insert in inserts {
            XCTAssertTrue(insert.originalText.isEmpty, "Pure insert should have empty originalText")
        }

        // Verify undo of all inserts eventually restores original
        var currentResponse = diffService.responseText
        for insert in inserts.reversed() {
            diffService.computeDiff(original: "Hello", response: currentResponse)
            if let insertSegment = diffService.diffSegments.first(where: { $0.type == .insert && $0.newText == insert.newText }) {
                if let result = diffService.undoSegment(segmentId: insertSegment.id) {
                    currentResponse = result
                }
            }
        }
        XCTAssertEqual(currentResponse, "Hello", "After undoing all inserts, should restore original")
    }

    /// Tests pure inserts at the start of text.
    /// Verifies basic undo functionality works and shortens the response.
    func testPureInsertAtStart_BasicUndoWorks() {
        diffService.computeDiff(original: "world", response: "Hello world")

        printSegments(diffService.diffSegments, label: "Pure Insert at Start")

        XCTAssertTrue(diffService.hasChanges)

        // There should be inserts for "Hello " or similar
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 0, "Should have at least one insert")

        // At least one insert should contain "Hello"
        let hasHelloInsert = inserts.contains { $0.newText.contains("Hello") }
        XCTAssertTrue(hasHelloInsert, "Should have insert containing 'Hello'")

        // Verify undo works - undo first insert
        if let firstInsert = inserts.first {
            let result = diffService.undoSegment(segmentId: firstInsert.id)
            XCTAssertNotNil(result, "Undo should succeed")
            // Result should be shorter than "Hello world"
            XCTAssertLessThan(result!.count, "Hello world".count, "After undo, response should be shorter")
        }
    }

    // MARK: - Complex Sentence Tests

    func testGrammarCorrection() {
        let original = "I goes to the store yesterday"
        let response = "I went to the store yesterday"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Grammar Correction")

        XCTAssertTrue(diffService.hasChanges)

        // "goes" should be swapped with "went"
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 0)

        // Find the swap for "goes" -> "went"
        if let wentInsert = inserts.first(where: { $0.newText == "went" }) {
            XCTAssertEqual(wentInsert.originalText, "goes")
            XCTAssertNotNil(wentInsert.pairedSegmentId)
        }
    }

    func testSentenceRewrite() {
        let original = "The cat sat on the mat."
        let response = "A dog lay on the rug."

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Sentence Rewrite")

        XCTAssertTrue(diffService.hasChanges)

        // Multiple swaps expected
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertGreaterThan(inserts.count, 1)
    }

    func testPunctuationChanges() {
        let original = "Hello, world!"
        let response = "Hello world."

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Punctuation Changes")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testAddingPunctuation() {
        let original = "Hello world"
        let response = "Hello, world!"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Adding Punctuation")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testLongParagraph() {
        let original = """
        The quick brown fox jumps over the lazy dog. This sentence contains every letter of the alphabet. It is often used for typing practice.
        """
        let response = """
        A fast red fox leaps over a sleepy dog. This sentence includes all letters of the alphabet. It is commonly used for typing exercises.
        """

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Long Paragraph")

        XCTAssertTrue(diffService.hasChanges)

        // Should have multiple changes
        let nonEqualSegments = diffService.diffSegments.filter { $0.type != .equal }
        XCTAssertGreaterThan(nonEqualSegments.count, 5)
    }

    func testEmailImprovement() {
        let original = "hi john, can u send me the report asap? thx"
        let response = "Hi John, could you please send me the report as soon as possible? Thank you."

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Email Improvement")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testCodeComment() {
        let original = "// this function does stuff"
        let response = "// This function calculates the sum of two integers"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Code Comment")

        XCTAssertTrue(diffService.hasChanges)
    }

    // MARK: - Edge Cases

    func testWhitespaceOnly() {
        diffService.computeDiff(original: "Hello  world", response: "Hello world")

        printSegments(diffService.diffSegments, label: "Whitespace Only")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testNewlines() {
        let original = "Hello\nworld"
        let response = "Hello\n\nworld"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Newlines")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testSpecialCharacters() {
        let original = "Price: $100"
        let response = "Price: €85"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Special Characters")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testEmoji() {
        let original = "Hello world"
        let response = "Hello world 👋"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Emoji")

        XCTAssertTrue(diffService.hasChanges)
    }

    func testUnicode() {
        let original = "Café résumé"
        let response = "Cafe resume"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Unicode")

        XCTAssertTrue(diffService.hasChanges)
    }

    // MARK: - Undo Chain Tests

    func testUndoMultipleSwapsSequentially() {
        diffService.computeDiff(original: "Hello world today", response: "Hi universe now")

        printSegments(diffService.diffSegments, label: "Before Undo Chain")

        // Get initial inserts
        var inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertEqual(inserts.count, 3) // Hi, universe, now

        // Undo first swap (Hi -> Hello)
        if let firstInsert = inserts.first {
            let result = diffService.undoSegment(segmentId: firstInsert.id)
            XCTAssertNotNil(result)
            print("After first undo: \(result!)")
        }

        printSegments(diffService.diffSegments, label: "After First Undo")

        // Undo second swap (universe -> world)
        inserts = diffService.diffSegments.filter { $0.type == .insert }
        if let secondInsert = inserts.first(where: { $0.newText == "universe" }) {
            let result = diffService.undoSegment(segmentId: secondInsert.id)
            XCTAssertNotNil(result)
            print("After second undo: \(result!)")
        }

        printSegments(diffService.diffSegments, label: "After Second Undo")

        // Undo third swap (now -> today)
        inserts = diffService.diffSegments.filter { $0.type == .insert }
        if let thirdInsert = inserts.first(where: { $0.newText == "now" }) {
            let result = diffService.undoSegment(segmentId: thirdInsert.id)
            XCTAssertNotNil(result)
            print("After third undo: \(result!)")
            XCTAssertEqual(result, "Hello world today") // Fully restored
        }

        XCTAssertFalse(diffService.hasChanges) // Should be identical now
    }

    /// Tests undoing a paired delete (part of a swap) redirects to the paired insert.
    /// Clicking undo on the delete "Hello" should restore it via the paired insert "Hi".
    func testUndoPairedDeleteRedirectsToInsert() {
        // "Hello" is replaced by "Hi" - they are paired
        diffService.computeDiff(original: "Hello world", response: "Hi world")

        printSegments(diffService.diffSegments, label: "Paired Delete Test")

        // Find the paired delete segment
        let pairedDeletes = diffService.diffSegments.filter { $0.type == .delete && $0.pairedSegmentId != nil }
        XCTAssertEqual(pairedDeletes.count, 1, "Should have one paired delete")

        let delete = pairedDeletes[0]
        XCTAssertEqual(delete.originalText, "Hello")
        XCTAssertNotNil(delete.pairedSegmentId)

        // Undo via the delete segment - should redirect to the paired insert
        let result = diffService.undoSegment(segmentId: delete.id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "Hello world", "Undo on paired delete should restore original via insert")

        // After undo, there should be no changes
        XCTAssertFalse(diffService.hasChanges)
    }

    /// Tests undoing a standalone delete at the start AND a pure insert at the end sequentially.
    /// Scenario: "Hello world" → "world!" (delete "Hello " + insert "!")
    func testUndoStandaloneDeleteAndPureInsertSequentially() {
        // Scenario: delete at start + insert at end
        diffService.computeDiff(original: "Hello world", response: "world!")

        printSegments(diffService.diffSegments, label: "Delete + Insert Separate")

        // Should have: delete "Hello ", equal "world", insert "!"
        let deletes = diffService.diffSegments.filter { $0.type == .delete && $0.pairedSegmentId == nil }
        let inserts = diffService.diffSegments.filter { $0.type == .insert && $0.pairedSegmentId == nil }

        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(inserts.count, 1)

        // Undo the delete first
        if let delete = deletes.first {
            let result = diffService.undoSegment(segmentId: delete.id)
            XCTAssertEqual(result, "Hello world!")
        }

        // Now undo the insert
        let newInserts = diffService.diffSegments.filter { $0.type == .insert }
        if let insert = newInserts.first(where: { $0.newText == "!" }) {
            let result = diffService.undoSegment(segmentId: insert.id)
            XCTAssertEqual(result, "Hello world")
        }
    }

    // MARK: - Real-World Sentence Transformation Tests

    /// Tests various real-world sentence transformations (grammar, tone, style).
    /// Verifies that diff computation works and undo doesn't crash.
    func testRealWorldSentenceTransformations() {
        let testCases: [(original: String, response: String, description: String)] = [
            // Professional email rewrites
            ("pls fix the bug asap", "Please fix the bug as soon as possible.", "Informal to formal"),
            ("the meeting is at 3pm tmrw", "The meeting is scheduled for 3:00 PM tomorrow.", "Abbreviation expansion"),

            // Grammar corrections
            ("She don't like apples", "She doesn't like apples", "Subject-verb agreement"),
            ("He goed to school", "He went to school", "Irregular verb correction"),
            ("Their going to the park", "They're going to the park", "Homophone correction"),

            // Sentence improvements
            ("The thing is very good", "The product is excellent", "Vague to specific"),
            ("I think maybe we should probably consider", "We should consider", "Conciseness"),

            // Technical writing
            ("click the button", "Click the Submit button", "UI instruction clarity"),
            ("it doesnt work", "The feature is not functioning correctly", "Bug report improvement"),

            // Creative writing
            ("The man walked slowly", "The elderly gentleman ambled leisurely", "Descriptive enhancement"),
            ("It was a dark night", "The moonless night shrouded the city in darkness", "Show don't tell"),

            // Mixed changes
            ("hello world how r u", "Hello World! How are you?", "Multiple fixes"),
            ("STOP YELLING AT ME", "Please lower your voice", "Tone adjustment"),
        ]

        for (index, testCase) in testCases.enumerated() {
            diffService.reset()
            diffService.computeDiff(original: testCase.original, response: testCase.response)

            print("\n========== Test \(index + 1): \(testCase.description) ==========")
            print("Original: \"\(testCase.original)\"")
            print("Response: \"\(testCase.response)\"")
            printSegments(diffService.diffSegments)

            // Skip if identical (edge case)
            if testCase.original == testCase.response {
                continue
            }

            XCTAssertTrue(diffService.hasChanges, "Test \(index + 1) should have changes: \(testCase.description)")

            // Verify display text is not empty
            XCTAssertFalse(diffService.displayText.isEmpty, "Test \(index + 1) should have displayText")

            // Verify at least one non-equal segment exists
            let nonEqualSegments = diffService.diffSegments.filter { $0.type != .equal }
            XCTAssertGreaterThan(nonEqualSegments.count, 0, "Test \(index + 1) should have non-equal segments")

            // Test that undo operations don't crash (basic stability test)
            let inserts = diffService.diffSegments.filter { $0.type == .insert }
            if let firstInsert = inserts.first {
                let result = diffService.undoSegment(segmentId: firstInsert.id)
                XCTAssertNotNil(result, "Undo should succeed for first insert in test \(index + 1): \(testCase.description)")
            }
        }
    }

    // MARK: - Stress Tests

    func testVeryLongText() {
        let words = ["The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]
        let original = (0..<100).map { _ in words.randomElement()! }.joined(separator: " ")
        let response = (0..<100).map { _ in words.randomElement()! }.joined(separator: " ")

        diffService.computeDiff(original: original, response: response)

        print("\n========== Stress Test: Long Text ==========")
        print("Original length: \(original.count)")
        print("Response length: \(response.count)")
        print("Segment count: \(diffService.diffSegments.count)")

        // Just verify it doesn't crash and produces valid output
        XCTAssertFalse(diffService.displayText.isEmpty)
    }

    func testManySmallChanges() {
        // Every word is different
        let original = "one two three four five six seven eight nine ten"
        let response = "1 2 3 4 5 6 7 8 9 10"

        diffService.computeDiff(original: original, response: response)
        printSegments(diffService.diffSegments, label: "Many Small Changes")

        XCTAssertTrue(diffService.hasChanges)

        // Should have many swaps
        let inserts = diffService.diffSegments.filter { $0.type == .insert }
        XCTAssertEqual(inserts.count, 10) // Each number is a swap
    }
}
