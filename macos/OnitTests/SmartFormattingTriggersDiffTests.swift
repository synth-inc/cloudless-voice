// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartFormattingTriggersDiffTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-09-04.
//
//  The Settings UI stores the WHOLE trigger map once the user edits anything,
//  while the pipeline wants a delta ("trigger:replacement" adds, plain removes).
//  Asserting the delta alone would only prove the app agrees with itself, so
//  every case here feeds the diff into the real `PipelineConfig` merge helpers.
//
//  Scope, so these greens aren't read as more than they are: they prove the app
//  hands the framework the right delta, nothing about what the framework then does
//  with it. The reach of a removal across every generator is covered framework-side
//  (`RemovedTriggerReachTests`), on internals no app-side test can touch.
//

#if canImport(TranscriptionCleanup)

import TranscriptionCleanup
import XCTest
@testable import Onit

@MainActor
final class SmartFormattingTriggersDiffTests: XCTestCase {

    // MARK: - Helpers

    private func punctuationMap(custom: [String: [String]]?) -> [String: String] {
        let diff = SmartFormattingTriggersManager.diff(
            custom: custom,
            defaults: SmartFormattingDefaults.punctuation
        )
        let config = PipelineConfig(categories: [
            .punctuation: CategoryConfig(
                enabled: true,
                addTriggers: diff.add,
                removeTriggers: diff.remove
            )
        ])
        return config.getPunctuationTriggers(defaults: punctuationDefaults)
    }

    /// `verbal -> symbol`, the shape the pipeline defaults come in.
    private var punctuationDefaults: [String: String] {
        var result: [String: String] = [:]
        for (symbol, verbals) in SmartFormattingDefaults.punctuation {
            for verbal in verbals { result[verbal] = symbol }
        }
        return result
    }

    // MARK: - Tests

    func testNoCustomizationLeavesDefaultsUntouched() {
        let merged = punctuationMap(custom: nil)
        XCTAssertEqual(merged, punctuationDefaults)
    }

    /// The reported bug: "at" added next to the built-in "at sign".
    func testAddedTriggerReachesThePipeline() {
        var custom = SmartFormattingDefaults.punctuation
        custom["@", default: []].append("at")

        let merged = punctuationMap(custom: custom)

        XCTAssertEqual(merged["at"], "@")
        XCTAssertEqual(merged["at sign"], "@", "Adding a trigger must not drop the defaults")
    }

    func testRemovedDefaultStopsFiring() {
        var custom = SmartFormattingDefaults.punctuation
        custom["@"] = custom["@"]?.filter { $0 != "at sign" }

        let merged = punctuationMap(custom: custom)

        XCTAssertNil(merged["at sign"])
        XCTAssertEqual(merged["at symbol"], "@", "Only the removed trigger goes away")
    }

    /// A verbal moved to another symbol is an add, not a remove + add: removals
    /// are applied first, so treating it as both would delete the new mapping.
    func testTriggerReassignedToAnotherSymbol() {
        var custom = SmartFormattingDefaults.punctuation
        custom["@"] = custom["@"]?.filter { $0 != "at symbol" }
        custom["&", default: []].append("at symbol")

        let merged = punctuationMap(custom: custom)

        XCTAssertEqual(merged["at symbol"], "&")
    }

    /// The map is stored lowercased by the manager, but the merge helpers
    /// compare case-insensitively - a stray capital must not read as a removal.
    func testCaseOnlyDifferenceIsNotARemoval() {
        var custom = SmartFormattingDefaults.punctuation
        custom["@"] = ["At Sign", "at symbol"]

        let diff = SmartFormattingTriggersManager.diff(
            custom: custom,
            defaults: SmartFormattingDefaults.punctuation
        )

        XCTAssertFalse(diff.remove.contains("at sign"))
    }

    /// Deleting every trigger of a category is a deliberate "off", not an absence
    /// of customization: `SmartFormattingTriggers.isEmpty` must not collapse it
    /// back to `nil` and hand the user back the defaults they just deleted.
    func testEmptiedCategoryIsStillACustomization() {
        var triggers = SmartFormattingTriggers()
        triggers.fillers = []

        XCTAssertFalse(triggers.isEmpty)

        let diff = SmartFormattingTriggersManager.diff(
            custom: triggers.fillers,
            defaults: SmartFormattingDefaults.fillers
        )
        XCTAssertTrue(diff.add.isEmpty)
        XCTAssertEqual(diff.remove.count, SmartFormattingDefaults.fillers.count)
    }

    func testCustomFillerReachesThePipeline() {
        var custom = SmartFormattingDefaults.fillers
        custom.append("basically")
        custom.removeAll { $0.lowercased() == "um" }

        let diff = SmartFormattingTriggersManager.diff(
            custom: custom,
            defaults: SmartFormattingDefaults.fillers
        )
        let config = PipelineConfig(categories: [
            .fillers: CategoryConfig(enabled: true, addTriggers: diff.add, removeTriggers: diff.remove)
        ])
        let merged = config.getFillerWords(defaults: SmartFormattingDefaults.fillers)
            .map { $0.lowercased() }

        XCTAssertTrue(merged.contains("basically"))
        XCTAssertFalse(merged.contains("um"))
    }

    func testFormattingTriggerReachesThePipeline() {
        var custom = SmartFormattingDefaults.formatting
        custom["\n", default: []].append("line break")

        let diff = SmartFormattingTriggersManager.diff(
            custom: custom,
            defaults: SmartFormattingDefaults.formatting
        )
        let config = PipelineConfig(categories: [
            .formatting: CategoryConfig(enabled: true, addTriggers: diff.add, removeTriggers: diff.remove)
        ])
        let defaults = SmartFormattingDefaults.formatting.flatMap { replacement, spokens in
            spokens.map { ["spoken": $0, "replacement": replacement] }
        }
        let merged = config.getFormattingTriggers(defaults: defaults)

        XCTAssertTrue(
            merged.contains { $0["spoken"] == "line break" && $0["replacement"] == "\n" }
        )
        XCTAssertTrue(merged.contains { $0["spoken"] == "new line" })
    }
}

#endif // canImport(TranscriptionCleanup)
