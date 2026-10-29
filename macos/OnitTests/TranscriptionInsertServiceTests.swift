// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionInsertServiceTests.swift
//  OnitTests
//
//  Unit tests for the strict Spotlight-only Accessibility insertion gate.
//

import Foundation
import ApplicationServices
import Testing
@testable import Onit

@MainActor
struct TranscriptionInsertServiceTests {

    private let textFieldRole = kAXTextFieldRole as String

    // MARK: - True case

    @Test func trueForSpotlightTextFieldSettable() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight",
            axRole: textFieldRole,
            selectedTextSettable: true
        ) == true)
    }

    // MARK: - Non-Spotlight bundle ids

    @Test func falseForNonSpotlightBundleIds() {
        let others = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.apple.Terminal",
            "com.microsoft.VSCode",       // Electron
            "com.tinyspeck.slackmacgap",  // Electron
            "com.apple.finder",
        ]
        for bundleId in others {
            #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
                bundleId: bundleId,
                axRole: textFieldRole,
                selectedTextSettable: true
            ) == false, "expected false for \(bundleId)")
        }
    }

    // MARK: - Guard rails

    @Test func falseWhenNotSettable() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight",
            axRole: textFieldRole,
            selectedTextSettable: false
        ) == false)
    }

    @Test func falseForNilBundleId() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: nil,
            axRole: textFieldRole,
            selectedTextSettable: true
        ) == false)
    }

    @Test func falseForNilRole() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight",
            axRole: nil,
            selectedTextSettable: true
        ) == false)
    }

    @Test func falseForWrongRole() {
        // Spotlight bundle id but a non-text-field role must not trigger the workaround.
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight",
            axRole: kAXStaticTextRole as String,
            selectedTextSettable: true
        ) == false)
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight",
            axRole: kAXTextAreaRole as String,
            selectedTextSettable: true
        ) == false)
    }

    @Test func falseWhenAllInputsFalsey() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: nil,
            axRole: nil,
            selectedTextSettable: false
        ) == false)
    }

    // MARK: - Exact-equality (not prefix / category) matching

    @Test func falseForBundleIdPrefixOrSuffix() {
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.Spotlight.helper",
            axRole: textFieldRole,
            selectedTextSettable: true
        ) == false)
        #expect(TranscriptionInsertService.shouldUseSpotlightAXInsert(
            bundleId: "com.apple.SpotlightX",
            axRole: textFieldRole,
            selectedTextSettable: true
        ) == false)
    }
}
