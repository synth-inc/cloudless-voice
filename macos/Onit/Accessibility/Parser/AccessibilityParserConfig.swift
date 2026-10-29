// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityParserConfig.swift
//  Onit
//
//  Created by Kévin Naudin on 28/04/2025.
//

struct AccessibilityParserConfig {

    static let recursiveDepthMax = 1000

    /// Total budget for text accumulated across one window walk. A terminal
    /// running a long agent session can expose hundreds of thousands of words;
    /// downstream consumers (term mining, history snapshots) need a window's
    /// worth of text, not the whole scrollback. Parsers stop accumulating once
    /// past this, so the final string can overshoot by at most one element value.
    static let maxCapturedTextLength = 30_000

    /// Budget for a single element's value. Huge single values (terminal
    /// scrollback, editor buffers) are usually one AXTextArea - keep the TAIL,
    /// since the bottom of the buffer is what's on screen and most recent.
    static let maxElementValueLength = 8_000

    /// Tail-biased truncation for oversized element values. The cut is advanced
    /// to the next word boundary so the leading fragment of a split word can't
    /// be mined as a (garbage) glossary term.
    static func truncatedValue(_ text: String) -> String {
        guard text.count > maxElementValueLength else { return text }
        var tail = String(text.suffix(maxElementValueLength))
        if let firstSpace = tail.firstIndex(where: { $0.isWhitespace }) {
            tail = String(tail[tail.index(after: firstSpace)...])
        }
        return "…" + tail
    }
}
