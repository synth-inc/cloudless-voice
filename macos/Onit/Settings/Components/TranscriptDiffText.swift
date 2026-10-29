// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptDiffText.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import SwiftUI

/// Renders an inline word-level diff of a transcription, distinguishing two
/// origins of change:
///   - **Smart cleanup** (raw → cleaned): blue text on a tinted background.
///   - **User correction** (cleaned → corrected): green text.
///
/// When `showEdits` is `false`, or no actual change exists, the text is rendered
/// plain. Deletions are strikethrough in `Color.T_2` regardless of origin - the
/// strikethrough is enough to convey removal, color reads better when reserved
/// for additions.
struct TranscriptDiffText: View {
    /// The raw ASR output.
    let rawText: String

    /// The text after the smart-cleanup pipeline ran.
    let cleanedText: String

    /// The user's manual correction, if any. When nil, only smart-cleanup edits
    /// are shown.
    let correctedText: String?

    /// When `true`, compute and render the diff. When `false`, render the
    /// final text plain.
    let showEdits: Bool

    /// When non-nil, restricts the displayed text to this many lines (Figma
    /// uses 8). When nil, the text expands fully.
    var lineLimit: Int? = nil

    /// Type size and colour of the unchanged text. A row that was rewritten shows
    /// this text smaller and in the secondary colour, under the rewrite.
    var size: CGFloat = 14
    var color: Color = Color.S_0

    var body: some View {
        Text(attributedString)
            .styleText(size: size, weight: .regular, color: color)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    /// The text the row currently displays - the user's correction wins when present.
    private var displayText: String {
        correctedText ?? cleanedText
    }

    private var attributedString: AttributedString {
        guard showEdits, rawText != displayText else {
            return AttributedString(displayText)
        }

        // Full diff vs raw catches everything that changed (cleanup + user).
        // Each insert/delete is then classified by its origin.
        let fullResult = TranscriptionDiffService.computeSegments(
            original: rawText,
            response: displayText,
            useWordLevel: true,
            showDeletedTextInline: true
        )

        // When the user has not edited the cleaned text, every change is from
        // smart cleanup - skip the second diff entirely.
        let userInsertTexts: Set<String>
        let userDeleteTexts: Set<String>
        if let correctedText, correctedText != cleanedText {
            let userResult = TranscriptionDiffService.computeSegments(
                original: cleanedText,
                response: correctedText,
                useWordLevel: true,
                showDeletedTextInline: true
            )
            userInsertTexts = Set(userResult.segments.compactMap { $0.type == .insert ? $0.newText : nil })
            userDeleteTexts = Set(userResult.segments.compactMap { $0.type == .delete ? $0.originalText : nil })
        } else {
            userInsertTexts = []
            userDeleteTexts = []
        }

        var output = AttributedString()
        for segment in fullResult.segments {
            switch segment.type {
            case .equal:
                output += AttributedString(segment.newText)

            case .insert:
                var part = AttributedString(segment.newText)
                if userInsertTexts.contains(segment.newText) {
                    // User-driven insertion (post-cleanup): green text on tinted bg.
                    part.foregroundColor = Color.lime500
                    part.backgroundColor = Color.lime500.opacity(0.15)
                } else {
                    // Smart-cleanup insertion (kept by the user): blue text on tinted bg.
                    part.foregroundColor = Color.info500
                    part.backgroundColor = Color.info500.opacity(0.15)
                }
                output += part

            case .delete:
                var part = AttributedString(segment.originalText)
                part.strikethroughStyle = .single
                part.foregroundColor = Color.T_2
                part.backgroundColor = Color.T_8
                output += part
            }
        }
        return output
    }
}
