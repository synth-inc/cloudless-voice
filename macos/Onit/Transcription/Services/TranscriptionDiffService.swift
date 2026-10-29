// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionDiffService.swift
//  Onit
//
//  Created by Kévin Naudin on 12/17/2025.
//

import Foundation
import AppKit
import Combine

// MARK: - Diff Types

/// Type of diff operation
enum DiffType: Equatable {
    case equal
    case insert
    case delete
}

/// A segment of diff with its type and text content
struct DiffSegment: Identifiable, Equatable {
    let id: UUID
    let type: DiffType
    let range: NSRange          // Range in the displayed text (response)
    let originalText: String    // Text from original (for swaps, contains deleted text)
    let newText: String         // Text in response (for insert/equal)
    let pairedSegmentId: UUID?  // ID of the paired segment (delete paired with insert in swaps)

    init(id: UUID = UUID(), type: DiffType, range: NSRange, originalText: String, newText: String, pairedSegmentId: UUID? = nil) {
        self.id = id
        self.type = type
        self.range = range
        self.originalText = originalText
        self.newText = newText
        self.pairedSegmentId = pairedSegmentId
    }
}

// MARK: - TranscriptionDiffService

@MainActor
class TranscriptionDiffService: ObservableObject {

    static let shared = TranscriptionDiffService()

    // MARK: - Configuration

    /// When true, uses word-level diff (better for understanding semantic changes).
    /// When false, uses character-level diff (more granular but can be confusing).
    var useWordLevelDiff: Bool = true

    /// When true, shows deleted text inline with red strikethrough.
    /// When false, deleted text is hidden (zero-width segments).
    var showDeletedTextInDiff: Bool = true

    // MARK: - Published State

    @Published private(set) var originalText: String = ""
    @Published private(set) var responseText: String = ""
    @Published private(set) var diffSegments: [DiffSegment] = []
    @Published private(set) var hasChanges: Bool = false

    /// The text to display in the UI. When showDeletedTextInDiff is true,
    /// this includes deleted text inline. Otherwise, it equals responseText.
    @Published private(set) var displayText: String = ""

    private init() {}

    // MARK: - Public Methods

    /// Compute diff between original selected text and AI response
    /// Uses word-level or character-level diff based on `useWordLevelDiff` flag
    /// - Parameters:
    ///   - original: The original text selected by the user
    ///   - response: The AI-generated response
    func computeDiff(original: String, response: String) {
        originalText = original
        responseText = response

        let result = Self.computeSegments(
            original: original,
            response: response,
            useWordLevel: useWordLevelDiff,
            showDeletedTextInline: showDeletedTextInDiff
        )

        diffSegments = result.segments
        displayText = result.displayText
        hasChanges = result.segments.contains { $0.type != .equal }
    }

    /// Pure helper: compute diff segments without touching shared state.
    /// Safe to call off the main actor and from non-overlay contexts (e.g., transcript history list).
    /// - Parameters:
    ///   - original: The original text
    ///   - response: The new text to compare against
    ///   - useWordLevel: When true, tokenize by word; otherwise diff per character
    ///   - showDeletedTextInline: When true, displayText includes deleted segments inline (delete segments returned alongside inserts)
    /// - Returns: Tuple of segments and the displayText string to render
    nonisolated static func computeSegments(
        original: String,
        response: String,
        useWordLevel: Bool = true,
        showDeletedTextInline: Bool = true
    ) -> (segments: [DiffSegment], displayText: String) {
        if useWordLevel {
            let wordDiffs = diffWords(original: original, response: response)
            if showDeletedTextInline {
                let result = buildDiffSegmentsWithInlineDeletions(wordDiffs: wordDiffs)
                return (result.segments, result.displayText)
            } else {
                let segments = buildDiffSegmentsFromWords(wordDiffs: wordDiffs, response: response)
                return (segments, response)
            }
        } else {
            let charDiffs = diffCharacters(original: original, response: response)
            if showDeletedTextInline {
                let result = buildCharDiffSegmentsWithInlineDeletions(charDiffs: charDiffs)
                return (result.segments, result.displayText)
            } else {
                let segments = buildDiffSegments(charDiffs: charDiffs, response: response)
                return (segments, response)
            }
        }
    }

    /// Undo a specific diff segment - replaces the new text with the original text
    /// - Parameter segmentId: The ID of the segment to undo
    /// - Returns: The new response text after undo, or nil if segment not found
    func undoSegment(segmentId: UUID) -> String? {
        guard let segmentIndex = diffSegments.firstIndex(where: { $0.id == segmentId }) else {
            return nil
        }

        let segment = diffSegments[segmentIndex]

        // Handle based on segment type
        switch segment.type {
        case .insert:
            // For insert: replace newText with originalText in response
            // When showDeletedTextInDiff is true, we need to find the position in responseText
            let newResponse: String
            if showDeletedTextInDiff {
                // Calculate the position in responseText by counting non-delete content before this segment
                let responsePosition = calculateResponsePosition(for: segmentIndex)
                let nsString = responseText as NSString
                let responseRange = NSRange(location: responsePosition, length: segment.newText.utf16.count)
                newResponse = nsString.replacingCharacters(in: responseRange, with: segment.originalText)
            } else {
                let nsString = responseText as NSString
                newResponse = nsString.replacingCharacters(in: segment.range, with: segment.originalText)
            }

            // Recompute diff with updated response
            computeDiff(original: originalText, response: newResponse)
            return newResponse

        case .delete:
            guard showDeletedTextInDiff else { return nil }

            // If this delete is paired with an insert (part of a swap), redirect undo to the insert
            if let pairedInsertId = segment.pairedSegmentId,
               let pairedInsertIndex = diffSegments.firstIndex(where: { $0.id == pairedInsertId }),
               diffSegments[pairedInsertIndex].type == .insert {
                // Undo via the paired insert - this will replace newText with originalText (the deleted text)
                let pairedInsert = diffSegments[pairedInsertIndex]
                let responsePosition = calculateResponsePosition(for: pairedInsertIndex)
                let nsString = responseText as NSString
                let responseRange = NSRange(location: responsePosition, length: pairedInsert.newText.utf16.count)
                let newResponse = nsString.replacingCharacters(in: responseRange, with: pairedInsert.originalText)

                // Recompute diff with updated response
                computeDiff(original: originalText, response: newResponse)
                return newResponse
            }

            // Standalone delete: restore the deleted text by inserting it into response
            let responsePosition = calculateResponsePosition(for: segmentIndex)
            let nsString = responseText as NSString
            let newResponse = nsString.replacingCharacters(
                in: NSRange(location: responsePosition, length: 0),
                with: segment.originalText
            )

            // Recompute diff with updated response
            computeDiff(original: originalText, response: newResponse)
            return newResponse

        case .equal:
            return nil
        }
    }

    /// Calculate the position in responseText that corresponds to a segment index
    /// This is needed when showDeletedTextInDiff is true because displayText != responseText
    private func calculateResponsePosition(for segmentIndex: Int) -> Int {
        var responsePosition = 0
        for i in 0..<segmentIndex {
            let seg = diffSegments[i]
            switch seg.type {
            case .equal, .insert:
                // Equal and insert text exists in responseText
                responsePosition += seg.newText.utf16.count
            case .delete:
                // Delete text doesn't exist in responseText, skip it
                break
            }
        }
        return responsePosition
    }

    /// Reset the diff service
    func reset() {
        originalText = ""
        responseText = ""
        displayText = ""
        diffSegments = []
        hasChanges = false
    }

    // MARK: - Character Diff Algorithm

    /// Character-level diff operation
    private enum CharDiffOp: Equatable {
        case equal(Character)
        case delete(Character)
        case insert(Character)
    }

    /// Compute diff at character level using Myers algorithm
    nonisolated private static func diffCharacters(original: String, response: String) -> [CharDiffOp] {
        let originalChars = Array(original)
        let responseChars = Array(response)

        let n = originalChars.count
        let m = responseChars.count

        if n == 0 && m == 0 {
            return []
        }

        if n == 0 {
            return responseChars.map { .insert($0) }
        }

        if m == 0 {
            return originalChars.map { .delete($0) }
        }

        // Myers diff algorithm on characters
        let max = n + m
        var v = Array(repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []

        for d in 0...max {
            trace.append(v)

            for k in stride(from: -d, through: d, by: 2) {
                let kIndex = k + max

                var x: Int
                if k == -d || (k != d && v[kIndex - 1] < v[kIndex + 1]) {
                    x = v[kIndex + 1]
                } else {
                    x = v[kIndex - 1] + 1
                }

                var y = x - k

                // Compare characters
                while x < n && y < m && originalChars[x] == responseChars[y] {
                    x += 1
                    y += 1
                }

                v[kIndex] = x

                if x >= n && y >= m {
                    return backtrackCharacters(original: originalChars, response: responseChars, trace: trace, d: d)
                }
            }
        }

        // Fallback
        return originalChars.map { .delete($0) } + responseChars.map { .insert($0) }
    }

    /// Backtrack to build the character diff result
    nonisolated private static func backtrackCharacters(original: [Character], response: [Character], trace: [[Int]], d: Int) -> [CharDiffOp] {
        var result: [CharDiffOp] = []
        var x = original.count
        var y = response.count

        for step in stride(from: d, through: 0, by: -1) {
            let v = trace[step]
            let max = original.count + response.count
            let k = x - y
            let kIndex = k + max

            let prevK: Int
            if k == -step || (k != step && v[kIndex - 1] < v[kIndex + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = v[prevK + max]
            let prevY = prevX - prevK

            // Add equal operations
            while x > prevX && y > prevY {
                result.insert(.equal(response[y - 1]), at: 0)
                x -= 1
                y -= 1
            }

            if step > 0 {
                if x > prevX {
                    result.insert(.delete(original[x - 1]), at: 0)
                    x -= 1
                } else {
                    result.insert(.insert(response[y - 1]), at: 0)
                    y -= 1
                }
            }
        }

        return result
    }

    // MARK: - Word-Level Diff Algorithm

    /// A token representing a word, whitespace, or punctuation
    private struct Token: Equatable {
        let text: String
        let utf16Length: Int

        init(_ text: String) {
            self.text = text
            self.utf16Length = text.utf16.count
        }
    }

    /// Word-level diff operation
    private enum WordDiffOp: Equatable {
        case equal(Token)
        case delete(Token)
        case insert(Token)
    }

    /// Punctuation characters that should be split as separate tokens
    /// Note: Hyphen (-) is NOT included so compound words like "cost-effective" stay together
    nonisolated private static let punctuationSet: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: ".,;:!?\"'()[]{}…–\u{2014}/\\@#$%^&*+=<>|`~")
        return set
    }()

    /// Tokenize text into words, whitespace, and punctuation tokens
    /// - Parameter text: The text to tokenize
    /// - Returns: Array of tokens preserving the original text when joined
    nonisolated private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var currentToken = ""

        let punctuationSet = Self.punctuationSet

        for char in text {
            let scalar = char.unicodeScalars.first!

            if char.isWhitespace {
                // Flush current token if any
                if !currentToken.isEmpty {
                    tokens.append(Token(currentToken))
                    currentToken = ""
                }
                // Each whitespace character is its own token (preserves spaces, newlines, tabs)
                tokens.append(Token(String(char)))
            } else if punctuationSet.contains(scalar) {
                // Flush current token if any
                if !currentToken.isEmpty {
                    tokens.append(Token(currentToken))
                    currentToken = ""
                }
                // Each punctuation character is its own token
                tokens.append(Token(String(char)))
            } else {
                // Regular character (including hyphens) - accumulate into current word
                currentToken.append(char)
            }
        }

        // Flush final token
        if !currentToken.isEmpty {
            tokens.append(Token(currentToken))
        }

        return tokens
    }

    /// Compute diff at word level using Myers algorithm
    nonisolated private static func diffWords(original: String, response: String) -> [WordDiffOp] {
        let originalTokens = tokenize(original)
        let responseTokens = tokenize(response)

        let n = originalTokens.count
        let m = responseTokens.count

        if n == 0 && m == 0 {
            return []
        }

        if n == 0 {
            return responseTokens.map { .insert($0) }
        }

        if m == 0 {
            return originalTokens.map { .delete($0) }
        }

        // Myers diff algorithm on tokens
        let max = n + m
        var v = Array(repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []

        for d in 0...max {
            trace.append(v)

            for k in stride(from: -d, through: d, by: 2) {
                let kIndex = k + max

                var x: Int
                if k == -d || (k != d && v[kIndex - 1] < v[kIndex + 1]) {
                    x = v[kIndex + 1]
                } else {
                    x = v[kIndex - 1] + 1
                }

                var y = x - k

                // Compare tokens
                while x < n && y < m && originalTokens[x] == responseTokens[y] {
                    x += 1
                    y += 1
                }

                v[kIndex] = x

                if x >= n && y >= m {
                    return backtrackWords(original: originalTokens, response: responseTokens, trace: trace, d: d)
                }
            }
        }

        // Fallback
        return originalTokens.map { .delete($0) } + responseTokens.map { .insert($0) }
    }

    /// Backtrack to build the word diff result
    nonisolated private static func backtrackWords(original: [Token], response: [Token], trace: [[Int]], d: Int) -> [WordDiffOp] {
        var result: [WordDiffOp] = []
        var x = original.count
        var y = response.count

        for step in stride(from: d, through: 0, by: -1) {
            let v = trace[step]
            let max = original.count + response.count
            let k = x - y
            let kIndex = k + max

            let prevK: Int
            if k == -step || (k != step && v[kIndex - 1] < v[kIndex + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = v[prevK + max]
            let prevY = prevX - prevK

            // Add equal operations
            while x > prevX && y > prevY {
                result.insert(.equal(response[y - 1]), at: 0)
                x -= 1
                y -= 1
            }

            if step > 0 {
                if x > prevX {
                    result.insert(.delete(original[x - 1]), at: 0)
                    x -= 1
                } else {
                    result.insert(.insert(response[y - 1]), at: 0)
                    y -= 1
                }
            }
        }

        return result
    }

    /// Convert word diff operations to display segments with ranges in the response text
    /// Merges consecutive delete+insert into a single insert (swap) with originalText preserved
    nonisolated private static func buildDiffSegmentsFromWords(wordDiffs: [WordDiffOp], response: String) -> [DiffSegment] {
        var segments: [DiffSegment] = []

        // State tracking for merging consecutive operations
        var pendingDeleteTokens: [Token] = []  // Tokens from consecutive deletes
        var currentInsertTokens: [Token] = []
        var currentInsertOriginalTokens: [Token] = []
        var currentInsertStartIndex: Int = 0

        var currentEqualTokens: [Token] = []
        var currentEqualStartIndex: Int = 0

        var responseIndex = 0  // Current position in response text (utf16)

        func flushEqual() {
            guard !currentEqualTokens.isEmpty else { return }
            let text = currentEqualTokens.map { $0.text }.joined()
            let length = currentEqualTokens.reduce(0) { $0 + $1.utf16Length }
            let range = NSRange(location: currentEqualStartIndex, length: length)
            segments.append(DiffSegment(
                type: .equal,
                range: range,
                originalText: text,
                newText: text
            ))
            currentEqualTokens = []
        }

        func flushInsert() {
            guard !currentInsertTokens.isEmpty else { return }
            let newText = currentInsertTokens.map { $0.text }.joined()
            let originalText = currentInsertOriginalTokens.map { $0.text }.joined()
            let length = currentInsertTokens.reduce(0) { $0 + $1.utf16Length }
            let range = NSRange(location: currentInsertStartIndex, length: length)
            segments.append(DiffSegment(
                type: .insert,
                range: range,
                originalText: originalText,
                newText: newText
            ))
            currentInsertTokens = []
            currentInsertOriginalTokens = []
        }

        /// Flush standalone deletes as a zero-width insert segment
        /// This allows "undoing" pure deletions by inserting the original text back
        func flushStandaloneDeletes() {
            guard !pendingDeleteTokens.isEmpty else { return }
            let originalText = pendingDeleteTokens.map { $0.text }.joined()
            // Zero-width range at current position - undoing will insert text here
            let range = NSRange(location: responseIndex, length: 0)
            segments.append(DiffSegment(
                type: .insert,
                range: range,
                originalText: originalText,
                newText: ""
            ))
            pendingDeleteTokens = []
        }

        for op in wordDiffs {
            switch op {
            case .equal(let token):
                // Flush any pending insert
                flushInsert()
                // Flush standalone deletes as zero-width insert (so they can be undone)
                flushStandaloneDeletes()

                // Start new equal sequence if needed
                if currentEqualTokens.isEmpty {
                    currentEqualStartIndex = responseIndex
                }
                currentEqualTokens.append(token)
                responseIndex += token.utf16Length

            case .delete(let token):
                // Flush any current equal segment
                flushEqual()
                // Flush any current insert segment
                flushInsert()
                // Accumulate deleted tokens - they will be merged into the next insert (swap)
                pendingDeleteTokens.append(token)

            case .insert(let token):
                // Flush any current equal segment
                flushEqual()

                // If this is the start of an insert sequence, transfer pending deletes
                if currentInsertTokens.isEmpty {
                    currentInsertStartIndex = responseIndex
                    // Transfer pending deletes as originalText (this makes it a swap)
                    currentInsertOriginalTokens = pendingDeleteTokens
                    pendingDeleteTokens = []
                }
                currentInsertTokens.append(token)
                responseIndex += token.utf16Length
            }
        }

        // Flush remaining segments
        flushEqual()
        flushInsert()
        // Flush any trailing standalone deletes (text removed from end of original)
        flushStandaloneDeletes()

        return segments
    }

    // MARK: - Build Diff Segments with Inline Deletions (Word-level)

    /// Result type for building segments with inline deletions
    private struct InlineDeletionResult {
        let segments: [DiffSegment]
        let displayText: String
    }

    /// Build diff segments with deleted text shown inline
    /// Links consecutive delete+insert pairs (swaps) via pairedSegmentId for proper undo behavior
    /// Merges consecutive standalone deletes into a single segment for better undo UX
    nonisolated private static func buildDiffSegmentsWithInlineDeletions(wordDiffs: [WordDiffOp]) -> InlineDeletionResult {
        var segments: [DiffSegment] = []
        var displayTextBuilder = ""
        var displayIndex = 0  // Current position in displayText

        // Track pending delete info that might be paired with a following insert
        var pendingDeleteStartIndex: Int = 0
        var pendingDeleteText = ""
        var hasPendingDeletes = false

        func flushPendingDeletesAsStandalone() {
            // Merge all pending deletes into a single standalone segment
            guard hasPendingDeletes else { return }

            let range = NSRange(location: pendingDeleteStartIndex, length: pendingDeleteText.utf16.count)
            segments.append(DiffSegment(
                type: .delete,
                range: range,
                originalText: pendingDeleteText,
                newText: ""
                // No pairedSegmentId - this is standalone
            ))

            pendingDeleteText = ""
            hasPendingDeletes = false
        }

        for op in wordDiffs {
            switch op {
            case .equal(let token):
                // Flush any pending deletes as standalone before equal
                flushPendingDeletesAsStandalone()

                let text = token.text
                let range = NSRange(location: displayIndex, length: token.utf16Length)
                segments.append(DiffSegment(
                    type: .equal,
                    range: range,
                    originalText: text,
                    newText: text
                ))
                displayTextBuilder += text
                displayIndex += token.utf16Length

            case .delete(let token):
                // Accumulate delete - it might be paired with a following insert
                let text = token.text

                if !hasPendingDeletes {
                    // Start of a new delete sequence
                    pendingDeleteStartIndex = displayIndex
                    hasPendingDeletes = true
                }

                pendingDeleteText += text
                displayTextBuilder += text
                displayIndex += token.utf16Length

            case .insert(let token):
                let text = token.text
                let range = NSRange(location: displayIndex, length: token.utf16Length)

                if hasPendingDeletes {
                    // This insert is paired with preceding delete(s) - create a swap pair
                    let pairId = UUID()
                    let deleteId = UUID()

                    // Create a single merged delete segment with pairedSegmentId
                    let deleteRange = NSRange(location: pendingDeleteStartIndex, length: pendingDeleteText.utf16.count)
                    let pairedDelete = DiffSegment(
                        id: deleteId,
                        type: .delete,
                        range: deleteRange,
                        originalText: pendingDeleteText,
                        newText: "",
                        pairedSegmentId: pairId
                    )
                    segments.append(pairedDelete)

                    // Create insert with pairedSegmentId and originalText from deletes
                    segments.append(DiffSegment(
                        id: pairId,
                        type: .insert,
                        range: range,
                        originalText: pendingDeleteText,  // Store deleted text for undo
                        newText: text,
                        pairedSegmentId: deleteId  // Link back to delete
                    ))

                    pendingDeleteText = ""
                    hasPendingDeletes = false
                } else {
                    // Pure insert (no preceding delete)
                    segments.append(DiffSegment(
                        type: .insert,
                        range: range,
                        originalText: "",
                        newText: text
                    ))
                }

                displayTextBuilder += text
                displayIndex += token.utf16Length
            }
        }

        // Flush any remaining pending deletes as standalone (deletions at the end with no following insert)
        flushPendingDeletesAsStandalone()

        return InlineDeletionResult(segments: segments, displayText: displayTextBuilder)
    }

    // MARK: - Build Diff Segments with Inline Deletions (Character-level)

    /// Build character-level diff segments with deleted text shown inline
    /// Links consecutive delete+insert pairs (swaps) via pairedSegmentId for proper undo behavior
    /// Merges consecutive standalone deletes into a single segment for better undo UX
    nonisolated private static func buildCharDiffSegmentsWithInlineDeletions(charDiffs: [CharDiffOp]) -> InlineDeletionResult {
        var segments: [DiffSegment] = []
        var displayTextBuilder = ""
        var displayIndex = 0

        // Accumulate consecutive operations of the same type for cleaner segments
        var currentType: DiffType?
        var currentChars: [Character] = []
        var currentStartIndex = 0

        // Track pending delete info that might be paired with a following insert
        var pendingDeleteStartIndex: Int = 0
        var pendingDeleteText = ""
        var hasPendingDelete = false

        func flushPendingDeleteAsStandalone() {
            guard hasPendingDelete else { return }
            let range = NSRange(location: pendingDeleteStartIndex, length: pendingDeleteText.utf16.count)
            segments.append(DiffSegment(
                type: .delete,
                range: range,
                originalText: pendingDeleteText,
                newText: ""
                // No pairedSegmentId - this is standalone
            ))
            pendingDeleteText = ""
            hasPendingDelete = false
        }

        func flushCurrent() {
            guard !currentChars.isEmpty, let type = currentType else { return }
            let text = String(currentChars)
            let range = NSRange(location: currentStartIndex, length: text.utf16.count)

            switch type {
            case .equal:
                flushPendingDeleteAsStandalone()
                segments.append(DiffSegment(type: .equal, range: range, originalText: text, newText: text))

            case .delete:
                // Accumulate delete - might be paired with following insert
                if !hasPendingDelete {
                    pendingDeleteStartIndex = currentStartIndex
                    hasPendingDelete = true
                }
                pendingDeleteText += text

            case .insert:
                if hasPendingDelete {
                    // This insert is paired with preceding delete - create a swap pair
                    let pairId = UUID()
                    let deleteId = UUID()

                    // Create merged delete segment with pairedSegmentId
                    let deleteRange = NSRange(location: pendingDeleteStartIndex, length: pendingDeleteText.utf16.count)
                    let pairedDelete = DiffSegment(
                        id: deleteId,
                        type: .delete,
                        range: deleteRange,
                        originalText: pendingDeleteText,
                        newText: "",
                        pairedSegmentId: pairId
                    )
                    segments.append(pairedDelete)

                    // Create insert with pairedSegmentId and originalText from delete
                    segments.append(DiffSegment(
                        id: pairId,
                        type: .insert,
                        range: range,
                        originalText: pendingDeleteText,  // Store deleted text for undo
                        newText: text,
                        pairedSegmentId: deleteId
                    ))

                    pendingDeleteText = ""
                    hasPendingDelete = false
                } else {
                    // Pure insert (no preceding delete)
                    segments.append(DiffSegment(type: .insert, range: range, originalText: "", newText: text))
                }
            }

            currentChars = []
            currentType = nil
        }

        for op in charDiffs {
            let (type, char): (DiffType, Character) = {
                switch op {
                case .equal(let c): return (.equal, c)
                case .delete(let c): return (.delete, c)
                case .insert(let c): return (.insert, c)
                }
            }()

            // If type changed, flush the current accumulator
            if type != currentType {
                flushCurrent()
                currentType = type
                currentStartIndex = displayIndex
            }

            currentChars.append(char)
            displayTextBuilder.append(char)
            displayIndex += String(char).utf16.count
        }

        // Flush remaining
        flushCurrent()
        flushPendingDeleteAsStandalone()

        return InlineDeletionResult(segments: segments, displayText: displayTextBuilder)
    }

    // MARK: - Build Diff Segments (Character-level)

    /// Convert character diff operations to display segments with ranges in the response text
    /// Merges consecutive delete+insert into a single insert (swap) with originalText preserved
    nonisolated private static func buildDiffSegments(charDiffs: [CharDiffOp], response: String) -> [DiffSegment] {
        var segments: [DiffSegment] = []

        // State tracking
        var pendingDeleteChars: [Character] = []  // Characters from consecutive deletes
        var currentInsertChars: [Character] = []
        var currentInsertOriginalChars: [Character] = []
        var currentInsertStartIndex: Int = 0

        var currentEqualChars: [Character] = []
        var currentEqualStartIndex: Int = 0

        var responseIndex = 0  // Current position in response text

        func flushEqual() {
            guard !currentEqualChars.isEmpty else { return }
            let text = String(currentEqualChars)
            let range = NSRange(location: currentEqualStartIndex, length: text.utf16.count)
            segments.append(DiffSegment(
                type: .equal,
                range: range,
                originalText: text,
                newText: text
            ))
            currentEqualChars = []
        }

        func flushInsert() {
            guard !currentInsertChars.isEmpty else { return }
            let newText = String(currentInsertChars)
            let originalText = String(currentInsertOriginalChars)
            let range = NSRange(location: currentInsertStartIndex, length: newText.utf16.count)
            segments.append(DiffSegment(
                type: .insert,
                range: range,
                originalText: originalText,
                newText: newText
            ))
            currentInsertChars = []
            currentInsertOriginalChars = []
        }

        /// Flush standalone deletes as a zero-width insert segment
        /// This allows "undoing" pure deletions by inserting the original text back
        func flushStandaloneDeletes() {
            guard !pendingDeleteChars.isEmpty else { return }
            let originalText = String(pendingDeleteChars)
            // Zero-width range at current position - undoing will insert text here
            let range = NSRange(location: responseIndex, length: 0)
            segments.append(DiffSegment(
                type: .insert,
                range: range,
                originalText: originalText,
                newText: ""
            ))
            pendingDeleteChars = []
        }

        for op in charDiffs {
            switch op {
            case .equal(let char):
                // Flush any pending insert
                flushInsert()
                // Flush standalone deletes as zero-width insert (so they can be undone)
                flushStandaloneDeletes()

                // Start new equal sequence if needed
                if currentEqualChars.isEmpty {
                    currentEqualStartIndex = responseIndex
                }
                currentEqualChars.append(char)
                responseIndex += String(char).utf16.count

            case .delete(let char):
                // Flush any current equal segment
                flushEqual()
                // Flush any current insert segment
                flushInsert()
                // Accumulate deleted characters - they will be merged into the next insert (swap)
                pendingDeleteChars.append(char)

            case .insert(let char):
                // Flush any current equal segment
                flushEqual()

                // If this is the start of an insert sequence, transfer pending deletes
                if currentInsertChars.isEmpty {
                    currentInsertStartIndex = responseIndex
                    // Transfer pending deletes as originalText (this makes it a swap)
                    currentInsertOriginalChars = pendingDeleteChars
                    pendingDeleteChars = []
                }
                currentInsertChars.append(char)
                responseIndex += String(char).utf16.count
            }
        }

        // Flush remaining segments
        flushEqual()
        flushInsert()
        // Flush any trailing standalone deletes (text removed from end of original)
        flushStandaloneDeletes()

        return segments
    }
}
