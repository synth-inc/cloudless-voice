// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionTermMinerTests.swift
//  OnitTests
//
//  Mining "add to dictionary" candidates from a live correction: CapsTermSelector
//  criteria (structured identifiers / OOV), minus terms already in the dictionary,
//  minus tokens the ASR already produced verbatim in the raw transcript.
//

import Foundation
import Testing
@testable import Onit

@Suite("CorrectionTermMiner")
struct CorrectionTermMinerTests {

    @Test("a corrected-in camelCase term is offered")
    func correctedTermOffered() {
        let terms = CorrectionTermMiner.newTerms(
            correction: "how does the CapsTermSelector work",
            raw: "how does the caps term selector work")
        #expect(terms.contains("CapsTermSelector"))
    }

    @Test("in-dictionary terms ARE returned - the bar classifies them as already-enabled")
    func inDictionaryStillReturned() {
        // The miner deliberately does NOT filter against the dictionary: hiding
        // an already-added term read as "the bar is broken" (the xcodeproj bug).
        let terms = CorrectionTermMiner.newTerms(
            correction: "how does the CapsTermSelector work",
            raw: "how does the caps term selector work")
        #expect(terms.contains("CapsTermSelector"))
    }

    @Test("words the ASR already got right are not offered")
    func unchangedFiltered() {
        let terms = CorrectionTermMiner.newTerms(
            correction: "the TurboBias gate works",
            raw: "the TurboBias gate works")
        #expect(!terms.contains("TurboBias"))
    }

    @Test("a casing fix counts as new (raw check is case-sensitive)")
    func casingFixOffered() {
        let terms = CorrectionTermMiner.newTerms(
            correction: "open the makeSandwich function",
            raw: "open the makesandwich function")
        #expect(terms.contains("makeSandwich"))
    }

    @Test("plain sentence words are never offered")
    func plainWordsRejected() {
        let terms = CorrectionTermMiner.newTerms(
            correction: "Only the links matter here",
            raw: "only the links matter here")
        #expect(terms.isEmpty)
    }

    @Test("code identifiers with underscores are offered whole")
    func underscoreIdentifier() {
        let terms = CorrectionTermMiner.newTerms(
            correction: "call _initializeOnDeviceTranscriber here",
            raw: "call initialize on device transcriber here")
        #expect(terms.contains("_initializeOnDeviceTranscriber"))
    }

    @Test("empty correction yields nothing")
    func emptyCorrection() {
        #expect(CorrectionTermMiner.newTerms(correction: "  ", raw: "anything").isEmpty)
    }
}

@Suite("ASRPromptContext echo guard")
struct PromptEchoGuardTests {

    /// On silent audio Qwen3 sometimes echoes the glossary prompt back as its
    /// "transcription" - the detector must catch it (and the sentinel must
    /// still match the actual prompt the clause builder produces).
    @Test("glossary echo is detected; real speech is not")
    func echoDetection() {
        let clause = ASRPromptContext.shared.glossaryClause(["Onit", "QuickEdit"]) ?? ""
        #expect(ASRPromptContext.isPromptEcho(clause))
        #expect(ASRPromptContext.isPromptEcho("  " + clause))           // leading whitespace
        #expect(ASRPromptContext.isPromptEcho(clause.lowercased()))     // case drift

        #expect(!ASRPromptContext.isPromptEcho("Can you explain the start recording function"))
        #expect(!ASRPromptContext.isPromptEcho("The audio was great today"))
        #expect(!ASRPromptContext.isPromptEcho(""))
    }
}
