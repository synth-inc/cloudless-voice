// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptStitcherTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 20/07/2026.
//

import Foundation
import Testing
@testable import Onit

struct TranscriptStitcherTests {

    @Test("First segment is taken verbatim")
    func firstSegmentIsTakenVerbatim() {
        let st = TranscriptStitcher()
        st.append("Hello there, this is a test.", hasSpeechOverlap: false)

        #expect(st.text == "Hello there, this is a test.")
    }

    @Test("Fixed-cut overlap words are deduplicated")
    func overlapWordsAreDeduplicated() {
        let st = TranscriptStitcher()
        st.append("the quick brown fox", hasSpeechOverlap: false)
        st.append("brown fox jumps over the lazy dog", hasSpeechOverlap: true)

        #expect(st.text == "the quick brown fox jumps over the lazy dog")
    }

    @Test("Dedupe tolerates casing variance")
    func dedupeToleratesCasingVariance() {
        // The re-decoded overlap often drifts in casing ("Smart Cleanup" vs
        // "smart cleanup") - normalization must still match the join.
        let st = TranscriptStitcher()
        st.append("we should enable Smart Cleanup", hasSpeechOverlap: false)
        st.append("smart cleanup and then ship it", hasSpeechOverlap: true)

        #expect(st.text == "we should enable Smart Cleanup and then ship it")
    }

    @Test("Dedupe tolerates punctuation variance")
    func dedupeToleratesPunctuationVariance() {
        let st = TranscriptStitcher()
        st.append("validated pairs. JSONL,", hasSpeechOverlap: false)
        st.append("pairs JSONL is the file we use", hasSpeechOverlap: true)

        #expect(st.text == "validated pairs. JSONL, is the file we use")
    }

    @Test("Pause-cut segment keeps a word repeated across the pause")
    func pauseCutKeepsRepeatedBoundaryWord() {
        // A silence-aligned cut re-sends no speech, so a boundary word the user
        // genuinely repeated across the pause ("Paris. [pause] Paris is…") must
        // NOT be deduped - that was the pre-fix silent data-loss bug.
        let st = TranscriptStitcher()
        st.append("I really love visiting Paris", hasSpeechOverlap: false)
        st.append("Paris is beautiful", hasSpeechOverlap: false)

        #expect(st.text == "I really love visiting Paris Paris is beautiful")
    }

    @Test("Fixed cut drops the period the model closed its segment with")
    func fixedCutDropsSegmentFinalPeriodBeforeLowercase() {
        // Measured on Qwen3 1.7B, 12 s fixed cut inside "Everyone preferred".
        let st = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        st.append("three options for the settings screen. Everyone.", hasSpeechOverlap: false)
        st.append("everyone preferred the second option", hasSpeechOverlap: true)

        #expect(st.text == "three options for the settings screen. Everyone preferred the second option")
    }

    @Test("Pause cut drops the period when the sentence goes on")
    func pauseCutDropsSegmentFinalPeriodBeforeLowercase() {
        // A pause inside a sentence gets the same segment-final period.
        let st = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        st.append("C'est bien ça.", hasSpeechOverlap: false)
        st.append("zéro six", hasSpeechOverlap: false)

        #expect(st.text == "C'est bien ça zéro six")
    }

    @Test("A real sentence end survives any cut")
    func sentenceEndSurvivesCuts() {
        let fixed = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        fixed.append("we shipped it.", hasSpeechOverlap: false)
        fixed.append("Then we rested", hasSpeechOverlap: true)
        #expect(fixed.text == "we shipped it. Then we rested")

        let pause = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        pause.append("see you tomorrow.", hasSpeechOverlap: false)
        pause.append("And then we left", hasSpeechOverlap: false)
        #expect(pause.text == "see you tomorrow. And then we left")

        let etc = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        etc.append("apples, pears, etc.", hasSpeechOverlap: false)
        etc.append("and more", hasSpeechOverlap: false)
        #expect(etc.text == "apples, pears, etc. and more")

        let brand = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        brand.append("it works.", hasSpeechOverlap: false)
        brand.append("iPhone users loved it", hasSpeechOverlap: false)
        #expect(brand.text == "it works. iPhone users loved it")

        let abbreviation = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        abbreviation.append("based in the U.S.", hasSpeechOverlap: false)
        abbreviation.append("and in Canada", hasSpeechOverlap: true)
        #expect(abbreviation.text == "based in the U.S. and in Canada")
    }

    @Test("A live stitcher leaves the segment-final period alone")
    func liveStitcherKeepsSegmentFinalPeriod() {
        // Live cuts wait for a 0.6 s inter-phrase pause, where that period is usually a
        // real sentence end: the repair is for the file path's 0.2 s cuts only.
        let live = TranscriptStitcher()
        live.append("C'est bien ça.", hasSpeechOverlap: false)
        live.append("zéro six", hasSpeechOverlap: false)

        #expect(live.text == "C'est bien ça. zéro six")
    }

    @Test("No overlap appends everything")
    func noOverlapAppendsEverything() {
        let st = TranscriptStitcher()
        st.append("first phrase here", hasSpeechOverlap: false)
        st.append("completely different words", hasSpeechOverlap: true)

        #expect(st.text == "first phrase here completely different words")
    }

    @Test("Longest overlap wins up to the cap")
    func longestOverlapWinsUpToTheCap() {
        let prev = (1...15).map { "w\($0)" }
        // Incoming repeats the last 12 words then adds one new one.
        let incoming = Array(prev.dropFirst(3)) + ["new"]

        let st = TranscriptStitcher()
        st.append(prev.joined(separator: " "), hasSpeechOverlap: false)
        st.append(incoming.joined(separator: " "), hasSpeechOverlap: true)

        #expect(st.text == (prev + ["new"]).joined(separator: " "))
        #expect(st.wordCount == 16)
    }

    @Test("Empty or whitespace segments are ignored")
    func emptyOrWhitespaceSegmentsAreIgnored() {
        let st = TranscriptStitcher()
        st.append("hello world", hasSpeechOverlap: false)
        st.append(nil, hasSpeechOverlap: true)
        st.append("", hasSpeechOverlap: true)
        st.append("   ", hasSpeechOverlap: true)

        #expect(st.text == "hello world")
    }

    @Test("Empty-normalized words compare equal in findOverlap")
    func findOverlapEmptyNormalizedWordsCompareEqual() {
        // Pure-punctuation tokens ("-" vs "-") normalize to empty and match,
        // same as the validated merge rule.
        let overlap = TranscriptStitcher.findOverlap(
            assembled: ["pause", "\u{2014}"],
            incoming: ["-", "then", "continue"],
            cap: TranscriptStitcher.maxOverlapWords)

        #expect(overlap == 1)
    }
}
