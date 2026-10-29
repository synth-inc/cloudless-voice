// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKReplyExtractor.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-21.
//
//  The script asks the model to put its result between two markers
//  (`<output>` and `</output>` by default), and only what is between them is
//  inserted. That one rule replaces guessing at preambles, quotes, code fences
//  and reasoning blocks: whatever the model says around the markers is ignored.
//  Both markers blank means the whole reply is used.
//

import Foundation

enum BYOKReplyExtractor {
    enum Rejection: Error, Equatable {
        /// Nothing between the markers (or an all-whitespace reply).
        case empty
        /// The reply never contained the start marker.
        case missingMarker(String)
        /// More than twice the transcript's length: the model answered or expanded
        /// instead of rewriting.
        case tooLong
        /// Under 40% of a long transcript (200+ characters): the model summarised, or
        /// the server cut the transcript to fit its context window (Ollama does this
        /// silently), so most of what was dictated would be lost.
        case tooShort
    }

    /// Transcripts at least this long are checked for a reply that's too short.
    /// Shorter ones can legitimately shrink a lot ("um uh yes" becomes "Yes.").
    static let shortReplyCheckMinimumLength = 200
    static let shortReplyMinimumRatio = 0.4

    /// `text` if its length is plausible for a rewrite of `transcript`, else why not.
    /// Runs after the markers are extracted, so the model's chatter around them
    /// doesn't count.
    static func checkLength(_ text: String, transcript: String) -> Result<String, Rejection> {
        guard text.count <= transcript.count * 2 else { return .failure(.tooLong) }
        if transcript.count >= shortReplyCheckMinimumLength,
           Double(text.count) < Double(transcript.count) * shortReplyMinimumRatio {
            return .failure(.tooShort)
        }
        return .success(text)
    }

    /// `text` with the leading whitespace of `input` put back, and its trailing
    /// whitespace too when that contains a line break ("Hi Kevin,\n" in an email
    /// composer). The extraction trims both ends, which would otherwise drop the
    /// line break the first stage deliberately produced. A trailing run without a
    /// line break is left to the caller's trailing-space heuristic.
    static func restoringEdges(of text: String, from input: String) -> String {
        let leading = input.prefix(while: \.isWhitespace)
        let trailing = String(input.reversed().prefix(while: \.isWhitespace).reversed())
        let keepTrailing = trailing.contains(where: \.isNewline)
        return String(leading) + text + (keepTrailing ? trailing : "")
    }

    static let defaultStart = "<output>"
    static let defaultEnd = "</output>"

    /// The text to insert from `reply`.
    ///
    /// The *last* start marker wins: a reasoning model may mention the marker while
    /// thinking before it writes the real one. The end marker is the first one after
    /// it; a reply that forgot to close runs to the end. With only an end marker,
    /// everything before its first occurrence is used.
    static func extract(_ reply: String, start: String, end: String) -> Result<String, Rejection> {
        let start = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = end.trimmingCharacters(in: .whitespacesAndNewlines)

        var text = Substring(reply)
        if !start.isEmpty {
            guard let range = text.range(of: start, options: .backwards) else {
                return .failure(.missingMarker(start))
            }
            text = text[range.upperBound...]
        }
        if !end.isEmpty, let range = text.range(of: end) {
            text = text[..<range.lowerBound]
        }

        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? .failure(.empty) : .success(result)
    }
}
