// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmojiTriggers.swift
//  Onit
//
//  Read-only view onto the cleanup framework's spoken-emoji dictionary.
//
//  The map itself lives in TranscriptionCleanup (`EmojiConstants`) and is
//  exposed per locale by `SmartFormattingDefaults.emojiGlyphs(locale:)`. This
//  type only picks the locale, so Settings can list exactly the names the
//  generator will match. User additions and overrides are layered on top by
//  `EmojiTriggersManager` and handed back to the pipeline through
//  `CategoryConfig.customGlyphs`.
//

import Foundation
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

enum EmojiTriggers {

    /// Built-in spoken name -> glyph map for the locale the cleanup pipeline
    /// will actually run with.
    ///
    /// Reads through to the framework instead of holding a copy: an app-side
    /// duplicate drifts the first time the framework gains a name, and the
    /// drift only surfaces as a name that shows in Settings but never fires.
    ///
    /// Empty without the TranscriptionCleanup library (a fully open build), which
    /// has no spoken-emoji pass to describe.
    static func defaults(for locale: CleanupLocale) -> [String: String] {
        #if canImport(TranscriptionCleanup)
        TranscriptionCleanup.SmartFormattingDefaults.emojiGlyphs(locale: locale.library)
        #else
        [:]
        #endif
    }
}
