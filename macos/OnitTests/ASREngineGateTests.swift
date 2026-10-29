// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASREngineGateTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-09-16.
//

import Foundation
import Testing
@testable import Onit

@MainActor
struct ASREngineGateTests {

    /// Counts how many bodies run at the same time. An actor, so the count itself is
    /// not the thing under test.
    private actor Concurrency {
        private var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    @Test("Only one inference runs at a time")
    func onlyOneInferenceRunsAtATime() async {
        let counter = Concurrency()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { @MainActor in
                    await ASREngineGate.asr.withEngine {
                        await counter.enter()
                        // Long enough that overlapping bodies would be caught: an engine
                        // that awaits inside its actor suspends exactly like this.
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await counter.leave()
                    }
                }
            }
        }

        #expect(await counter.peak == 1)
    }

    @Test("A body that throws still releases the gate")
    func throwingBodyReleasesTheGate() async {
        struct Boom: Error {}

        await #expect(throws: Boom.self) {
            try await ASREngineGate.asr.withEngine { throw Boom() }
        }

        // Would hang forever if the gate stayed taken.
        let ran = await ASREngineGate.asr.withEngine { true }
        #expect(ran)
    }
}
