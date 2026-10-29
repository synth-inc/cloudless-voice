// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryStoreTests.swift
//  OnitTests
//
//  Store behavior on an in-memory database: Petrov evidence updates, the
//  passive-sighting dedup window, the evidence admission gate (≥2 distinct
//  days OR dictated/corrected), tombstoning, and the version counter that
//  keys the trie cache.
//

import XCTest
@testable import Onit

final class TermMemoryStoreTests: XCTestCase {

    private let day = 86_400.0
    private let base = 1_754_000_000.0  // fixed epoch so day boundaries are stable

    /// Admission that accepts everything scoreable (trained on the test terms).
    private func admission() -> TermAdmission {
        let words = ["kalender", "lukwise", "posthog", "verity", "memory", "store"]
        return TermAdmission(
            trigrams: TermAdmission.TrigramModel(words: words),
            knownWords: Set(words))
    }

    private func makeStore() throws -> TermMemoryStore {
        try XCTUnwrap(TermMemoryStore(inMemory: ()))
    }

    private func sight(_ term: String, source: TermMemoryStore.Source,
                       app: String? = "com.test.app", at ts: Double) -> TermMemoryStore.Sighting {
        .init(term: term, source: source, appBundle: app, ts: ts)
    }

    func testSingleOCRSightingIsStoredButNotEligible() throws {
        let store = try makeStore()
        store.recordSightings([sight("Kalender", source: .ocr, at: base)], admission: admission())
        XCTAssertEqual(store.termCount, 1)
        // One passive sighting on one day: fails the evidence gate.
        XCTAssertTrue(store.biasList(now: base + 3600, limit: 50).isEmpty)
    }

    func testTwoDistinctDaysMakeEligible() throws {
        let store = try makeStore()
        store.recordSightings([sight("Kalender", source: .ocr, at: base)], admission: admission())
        store.recordSightings([sight("Kalender", source: .ocr, at: base + 2 * day)], admission: admission())
        let list = store.biasList(now: base + 2 * day + 3600, limit: 50)
        XCTAssertEqual(list.map(\.display), ["Kalender"])
        XCTAssertEqual(list[0].evidence.n, 2)
    }

    func testDictatedTermIsImmediatelyEligible() throws {
        let store = try makeStore()
        store.recordSightings([sight("Lukwise", source: .dictated, at: base)], admission: admission())
        XCTAssertEqual(store.biasList(now: base + 60, limit: 50).map(\.display), ["Lukwise"])
    }

    func testPassiveDedupWithinAnHourPerApp() throws {
        let store = try makeStore()
        let recorded1 = store.recordSightings(
            [sight("Kalender", source: .ocr, at: base)], admission: admission())
        // Same app 10 minutes later: dropped.
        let recorded2 = store.recordSightings(
            [sight("Kalender", source: .ocr, at: base + 600)], admission: admission())
        // Different app inside the hour: counts (per-app window).
        let recorded3 = store.recordSightings(
            [sight("Kalender", source: .ocr, app: "com.other.app", at: base + 700)],
            admission: admission())
        // Same app past the hour: counts.
        let recorded4 = store.recordSightings(
            [sight("Kalender", source: .ocr, at: base + 3700)], admission: admission())
        XCTAssertEqual([recorded1, recorded2, recorded3, recorded4], [1, 0, 1, 1])
        // Deliberate usage is never deduped.
        let recorded5 = store.recordSightings(
            [sight("Kalender", source: .dictated, at: base + 3710)], admission: admission())
        XCTAssertEqual(recorded5, 1)
    }

    func testCorrectionPinsAndOutranks() throws {
        let store = try makeStore()
        store.recordSightings([
            sight("Posthog", source: .dictated, at: base),
            sight("Lukwise", source: .correction, at: base),
        ], admission: admission())
        let list = store.biasList(now: base + 3600, limit: 50)
        XCTAssertEqual(list.first?.display, "Lukwise")  // w=10 beats w=3
        XCTAssertTrue(list.first?.pinned ?? false)
    }

    func testUndictatableTermNeverEligible() throws {
        let store = try makeStore()
        store.recordSightings(
            [sight("deadbeef01", source: .correction, at: base)], admission: admission())
        XCTAssertTrue(store.biasList(now: base + 60, limit: 50).isEmpty)
    }

    func testRemoveTermTombstones() throws {
        let store = try makeStore()
        store.recordSightings([sight("Kalender", source: .dictated, at: base)], admission: admission())
        store.removeTerm("kalender")
        XCTAssertTrue(store.biasList(now: base + 60, limit: 50).isEmpty)
        // Re-sighting a removed term must not resurrect it.
        store.recordSightings([sight("Kalender", source: .dictated, at: base + day)], admission: admission())
        XCTAssertTrue(store.biasList(now: base + day + 60, limit: 50).isEmpty)
    }

    func testVersionBumpsOnWrites() throws {
        let store = try makeStore()
        let v0 = store.version
        store.recordSightings([sight("Kalender", source: .ocr, at: base)], admission: admission())
        let v1 = store.version
        XCTAssertGreaterThan(v1, v0)
        // A fully-deduped batch must NOT bump (trie cache stays warm).
        store.recordSightings([sight("Kalender", source: .ocr, at: base + 60)], admission: admission())
        XCTAssertEqual(store.version, v1)
    }

    func testDisplayCasingUpgrades() throws {
        let store = try makeStore()
        store.recordSightings([sight("kalender", source: .dictated, at: base)], admission: admission())
        store.recordSightings([sight("Kalender", source: .dictated, at: base + 2 * day)], admission: admission())
        XCTAssertEqual(store.biasList(now: base + 2 * day + 60, limit: 50).first?.display, "Kalender")
    }

    func testAliasStorageRoundTrip() throws {
        let store = try makeStore()
        store.recordSightings([sight("Lukwise", source: .dictated, at: base)], admission: admission())
        store.storePrediction(
            term: "Lukwise",
            prediction: .init(phones: ["W", "ER", "K", "W", "AY", "Z"],
                              unconditional: ["luckwise"], gated: ["luck wise"]))
        XCTAssertEqual(
            store.aliases(forTerms: ["lukwise"], tier: .unconditional), ["lukwise": ["luckwise"]])
        XCTAssertEqual(
            store.aliases(forTerms: ["lukwise"], tier: .gated), ["lukwise": ["luck wise"]])
        let record = store.biasList(now: base + 60, limit: 50).first
        XCTAssertEqual(record?.phones, ["W", "ER", "K", "W", "AY", "Z"])
        XCTAssertTrue(record?.aliasesDone ?? false)
        // Predicted terms leave the needs-aliases backlog.
        XCTAssertTrue(store.termsNeedingAliases(limit: 10).isEmpty)
    }

    func testRetentionPruneForgetsStaleTerms() throws {
        let store = try makeStore()
        store.recordSightings([
            sight("Posthog", source: .dictated, at: base - 400 * day),  // stale
            sight("Kalender", source: .dictated, at: base),               // fresh
        ], admission: admission())
        store.storePrediction(
            term: "Posthog",
            prediction: .init(phones: ["P"], unconditional: ["posthawg"], gated: []))
        let versionBefore = store.version

        let deleted = store.pruneTermsUnseen(since: base - 365 * day)
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(store.termCount, 1)
        XCTAssertEqual(store.biasList(now: base + 60, limit: 50).map(\.display), ["Kalender"])
        // The forgotten term's aliases go with it, and the version bumps so
        // the bias snapshot + trie cache refresh.
        XCTAssertTrue(store.aliases(forTerms: ["posthog"], tier: .unconditional).isEmpty)
        XCTAssertGreaterThan(store.version, versionBefore)
        // Nothing stale left → prune is a no-op and must NOT bump the version.
        XCTAssertEqual(store.pruneTermsUnseen(since: base - 365 * day), 0)
        XCTAssertEqual(store.version, versionBefore + 1)
    }

    func testTopKLimitAndActivationOrder() throws {
        let store = try makeStore()
        store.recordSightings([
            sight("Posthog", source: .dictated, at: base - 30 * day),   // old
            sight("Lukwise", source: .dictated, at: base),             // fresh
            sight("Kalender", source: .correction, at: base),             // fresh + heavy
        ], admission: admission())
        let list = store.biasList(now: base + 3600, limit: 2)
        XCTAssertEqual(list.map(\.display), ["Kalender", "Lukwise"])
    }
}
