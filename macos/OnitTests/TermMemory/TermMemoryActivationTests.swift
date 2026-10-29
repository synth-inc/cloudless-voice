// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryActivationTests.swift
//  OnitTests
//
//  The activation math must stay IDENTICAL to the offline term-memory replay
//  simulator's - the replay eval's coverage numbers only transfer if it does.
//  Golden values below were computed with the simulator's formula directly.
//

import XCTest
@testable import Onit

final class TermMemoryActivationTests: XCTestCase {

    private let day = 86_400.0
    private let now = 1_000_000_000.0

    func testSingleEventUsesOptimizedLearningForm() {
        // One OCR sighting (w=1) 10 days ago: ln(1·10^-0.5 / 0.5)
        let e = TermMemoryActivation.Evidence(
            W: 1, n: 1, tFirst: now - 10 * day, t1: now - 10 * day, w1: 1, t2: nil, w2: nil)
        XCTAssertEqual(TermMemoryActivation.baseLevel(e, now: now), -0.4581453659, accuracy: 1e-8)
    }

    func testTwoEvents() {
        // OCR (w=1) 30 days ago + dictated-kept (w=3) 2 days ago.
        let e = TermMemoryActivation.Evidence(
            W: 4, n: 2, tFirst: now - 30 * day,
            t1: now - 2 * day, w1: 3, t2: now - 30 * day, w2: 1)
        XCTAssertEqual(TermMemoryActivation.baseLevel(e, now: now), 0.8346009646, accuracy: 1e-8)
    }

    func testTailApproximation() {
        // 5 events over 60 days, W=16, recent correction (w=10) 1 day ago,
        // dictation (w=3) 5 days ago - the Petrov closed-form tail kicks in.
        let e = TermMemoryActivation.Evidence(
            W: 16, n: 5, tFirst: now - 60 * day,
            t1: now - 1 * day, w1: 10, t2: now - 5 * day, w2: 3)
        XCTAssertEqual(TermMemoryActivation.baseLevel(e, now: now), 2.4801219418, accuracy: 1e-8)
    }

    func testAgeFloorPreventsBlowup() {
        // A term seen this instant must not return +inf (age floored at 0.001d).
        let e = TermMemoryActivation.Evidence(
            W: 1, n: 1, tFirst: now, t1: now, w1: 1, t2: nil, w2: nil)
        let b = TermMemoryActivation.baseLevel(e, now: now)
        XCTAssertTrue(b.isFinite)
        XCTAssertEqual(b, Darwin.log(1 * pow(0.001, -0.5) / 0.5), accuracy: 1e-9)
    }

    func testFreshTermOutranksStaleHeavyTermEventually() {
        // The power-law tail: a heavily-seen term from last month stays
        // retrievable but a fresh correction outranks it.
        let stale = TermMemoryActivation.Evidence(
            W: 20, n: 20, tFirst: now - 90 * day,
            t1: now - 30 * day, w1: 1, t2: now - 31 * day, w2: 1)
        let fresh = TermMemoryActivation.Evidence(
            W: 10, n: 1, tFirst: now - 1 * day, t1: now - 1 * day, w1: 10, t2: nil, w2: nil)
        XCTAssertGreaterThan(
            TermMemoryActivation.baseLevel(fresh, now: now),
            TermMemoryActivation.baseLevel(stale, now: now))
        // …but the stale term is still bias-eligible (above τ).
        XCTAssertGreaterThan(
            TermMemoryActivation.baseLevel(stale, now: now),
            TermMemoryActivation.biasThreshold)
    }

    func testAddingShiftsPetrovWindow() {
        var e = TermMemoryActivation.adding(nil, ts: now - 10 * day, weight: 1)
        XCTAssertEqual(e.n, 1)
        XCTAssertNil(e.t2)
        e = TermMemoryActivation.adding(e, ts: now - 5 * day, weight: 3)
        XCTAssertEqual(e.n, 2)
        XCTAssertEqual(e.t1, now - 5 * day)
        XCTAssertEqual(e.w1, 3)
        XCTAssertEqual(e.t2, now - 10 * day)
        XCTAssertEqual(e.w2, 1)
        e = TermMemoryActivation.adding(e, ts: now - 1 * day, weight: 10)
        XCTAssertEqual(e.n, 3)
        XCTAssertEqual(e.W, 14)
        XCTAssertEqual(e.t1, now - 1 * day)
        XCTAssertEqual(e.t2, now - 5 * day)
        XCTAssertEqual(e.tFirst, now - 10 * day)  // first-seen never moves
    }
}
