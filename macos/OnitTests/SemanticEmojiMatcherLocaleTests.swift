// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SemanticEmojiMatcherLocaleTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-07-30.
//
//  The semantic pass takes its trigger words from the locale the cleanup
//  pipeline ran with, not from a hardcoded "emoji". A FR-locked user says
//  "émoji", which the exact pass already matches (FrenchRules appends the
//  accented spelling), so a pass that only knew the English word would be
//  silently dead for them.
//
//  Uses the real bundled model: "sobbing" -> 😭 is asserted by
//  EmojiSemanticMatcherValidationTests, so the glyph here is a fixed point and
//  only the trigger detection is under test.
//

#if canImport(TranscriptionCleanup)

import TranscriptionCleanup
import XCTest
@testable import Onit

final class SemanticEmojiMatcherLocaleTests: XCTestCase {

    private let matcher = SemanticEmojiMatcher.shared

    override func setUpWithError() throws {
        try XCTSkipUnless(MiniLMEmojiEmbedder.shared.ensureLoaded(),
                          "MiniLMEmoji model / anchors not bundled - skipping")
    }

    func testFrenchAccentedTriggerFires() {
        let result = matcher.apply(to: "envoie un sobbing émoji", locale: .french)
        XCTAssertTrue(
            result.contains("😭"),
            "The accented FR trigger must fire under the French locale, got: \(result)"
        )
        XCTAssertFalse(result.contains("émoji"), "The trigger word is consumed with the span")
    }

    func testAccentedTriggerIsInertUnderEnglishLocale() {
        // "émoji" is not an English trigger word, and inventing one here would
        // diverge from what the exact pass matched a moment earlier.
        let text = "envoie un sobbing émoji"
        XCTAssertEqual(
            matcher.apply(to: text, locale: .english), text,
            "An out-of-locale trigger must leave the text untouched"
        )
    }

    func testSharedTriggerStillFiresUnderFrenchLocale() {
        // French appends its spelling rather than replacing the shared list, so
        // a FR-locked user saying the plain "emoji" is still served.
        let result = matcher.apply(to: "envoie un sobbing emoji", locale: .french)
        XCTAssertTrue(
            result.contains("😭"),
            "Shared trigger words must survive the French merge, got: \(result)"
        )
    }

    func testTextWithoutAnyTriggerIsUntouched() {
        let text = "just a plain sentence with no marker at all"
        XCTAssertEqual(matcher.apply(to: text, locale: .english), text)
    }
}

#endif // canImport(TranscriptionCleanup)
