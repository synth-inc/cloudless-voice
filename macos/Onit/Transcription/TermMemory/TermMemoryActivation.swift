// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryActivation.swift
//  Onit
//
//  ACT-R base-level activation for the persistent term-memory store.
//  Strength of a term is B = ln(Σ_j w_j · t_j^(−d)) over its sighting events,
//  computed O(1) via the Petrov (2006) hybrid approximation: exact terms for
//  the 2 most recent events + a closed-form integral for the older tail.
//  Mirrors the offline term-memory replay simulator's activation exactly -
//  the replay eval's numbers are only transferable if this math stays
//  identical.
//

import Foundation

enum TermMemoryActivation {

    /// ACT-R decay exponent d. 0.5 is the ACT-R default; the replay sweep
    /// showed d barely matters on a 2-month window (0.3 ≈ 0.5 > 0.7).
    static let decay = 0.5

    /// Event weights by evidence source. OCR/AX passive sightings are weak;
    /// dictating a term and keeping it is stronger; a correction that
    /// introduced the term is the strongest signal we have. The literature has
    /// no passive-exposure numbers - these are the proposal's initial guesses,
    /// to be re-fit from logs.
    static let weightOCR = 1.0
    static let weightNearCursor = 2.0
    static let weightDictatedKept = 3.0
    static let weightCorrection = 10.0

    /// Bias-eligibility threshold τ: terms with B below it stay STORED but
    /// leave the bias list (≈30-day eligibility for a single OCR sighting,
    /// ≈9 months for one dictation, years for a correction).
    static let biasThreshold = -1.7

    private static let secondsPerDay = 86_400.0

    /// The per-term evidence summary the store persists (Petrov k=2): total
    /// weighted evidence + the two most recent events + the first-seen time.
    struct Evidence: Sendable, Equatable {
        var W: Double          // Σ w_j
        var n: Int             // raw event count
        var tFirst: Double     // unix seconds of first event
        var t1: Double         // most recent event
        var w1: Double
        var t2: Double?        // second most recent (nil when n == 1)
        var w2: Double?
    }

    /// Base-level activation at `now` (unix seconds). Ages are in days,
    /// floored at 0.001 so a just-seen term doesn't blow up the power law.
    static func baseLevel(_ e: Evidence, now: Double, decay d: Double = decay) -> Double {
        func age(_ t: Double) -> Double { max((now - t) / secondsPerDay, 0.001) }
        // Darwin.log: the app-wide `log` symbol is the SwiftyBeaver logger.
        if e.n == 1 || e.t2 == nil {
            return Darwin.log(max(e.W * pow(age(e.tFirst), -d) / (1 - d), 1e-12))
        }
        guard let t2 = e.t2, let w2 = e.w2 else { return -Double.infinity }
        var s = e.w1 * pow(age(e.t1), -d) + w2 * pow(age(t2), -d)
        let tailW = e.W - e.w1 - w2
        let aF = age(e.tFirst)
        let a2 = age(t2)
        if tailW > 0 && aF > a2 {
            s += tailW * (pow(aF, 1 - d) - pow(a2, 1 - d)) / ((1 - d) * (aF - a2))
        }
        return Darwin.log(max(s, 1e-12))
    }

    /// O(1) evidence update for a new event: shift (t1,w1)→(t2,w2), record the
    /// new event as most recent, bump the totals.
    static func adding(_ e: Evidence?, ts: Double, weight: Double) -> Evidence {
        guard var updated = e else {
            return Evidence(W: weight, n: 1, tFirst: ts, t1: ts, w1: weight, t2: nil, w2: nil)
        }
        updated.t2 = updated.t1
        updated.w2 = updated.w1
        updated.t1 = ts
        updated.w1 = weight
        updated.W += weight
        updated.n += 1
        return updated
    }
}
