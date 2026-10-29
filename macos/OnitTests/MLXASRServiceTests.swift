// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXASRServiceTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-19.
//

import Foundation
import Testing
@testable import Onit

@MainActor
struct MLXASRServiceTests {

    @Test("A fresh service has an empty audio buffer")
    func freshServiceHasEmptyBuffer() {
        let service = MLXASRService.shared
        service.reset()
        #expect(service.accumulatedSamples.isEmpty)
        #expect(service.accumulatedDuration == 0)
    }

    @Test("Transcribing an empty buffer short-circuits to no hypotheses")
    func transcribingEmptyBufferReturnsNoHypotheses() async throws {
        let service = MLXASRService.shared
        service.reset()
        let (hypotheses, language, vadSuppressed) = try await service.transcribe()
        #expect(hypotheses.isEmpty)
        #expect(language == nil)
        #expect(vadSuppressed == false)
    }

    @Test("markAsReady flips isModelReady true")
    func markAsReadyFlipsFlag() {
        let service = MLXASRService.shared
        service.markAsReady()
        #expect(service.isModelReady == true)
    }
}
