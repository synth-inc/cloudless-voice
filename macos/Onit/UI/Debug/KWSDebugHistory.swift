// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  KWSDebugHistory.swift
//  Onit
//
//  In-memory ring buffer of KWS detection results for the Perplexity Debug window.
//  Entries are appended by CustomDictionaryService after every rescore() call.
//

import Foundation

// MARK: - Gate evaluation types
//
// Referenced by `CustomDictionaryService.applyReplacementsWithGate` in both
// release and DEBUG builds, so these must live outside the `#if DEBUG` block
// below. The release path collects them but doesn't read them - only the
// DEBUG ring-buffer below surfaces them in the UI.

/// Source path that produced a `DictionaryReplacement` and therefore the gate
/// evaluation we recorded for it.
enum GateEvaluationSource: String, Sendable {
    case kws
    case commonMistake
}

/// One NLL gate evaluation, recorded per `DictionaryReplacement`. This is the
/// truth-of-record for what the gate actually evaluated - every replacement
/// the rescorer produced gets exactly one entry here. The earlier
/// `[String: NLLGateTrace]` map keyed by term text collapsed multiple
/// evaluations of the same term onto one entry, so detections / mistakes that
/// the gate scored against different spans rendered with the wrong trace.
struct GateEvaluation: Sendable, Identifiable {
    let id = UUID()
    /// Dictionary term that triggered this evaluation (e.g. "Raudin").
    let termText: String
    /// The exact ASR span the gate ran against (e.g. "And", "join").
    let originalSpan: String
    /// Which path produced the replacement candidate.
    let source: GateEvaluationSource
    /// Full gate trace - proxy, Δ_norm, threshold, all variants, ACCEPT/REJECT.
    let trace: NLLGateTrace
}

#if DEBUG

// MARK: - Per-detection result

struct KWSDetectionResult: Sendable {
    /// Raw keyword string returned by the spotter (matches the term text for Whisper KWS).
    let keyword: String
    let startSec: Double
    let endSec: Double
    /// Dictionary term this keyword maps to, if any.
    let matchedTerm: String?
    /// The original ASR span the rescorer aligned this detection to, if any.
    /// Nil when the detection didn't make it to a replacement candidate
    /// (e.g. no transcript span match).
    let originalSpan: String?
}

/// A common-mistake substring match - emitted independently of the audio-based
/// KWS path whenever a term's `commonMistakes` list matches the transcript.
struct CommonMistakeMatch: Sendable {
    /// The exact transcript span that matched (e.g. "Leonardo").
    let span: String
    /// The term this mistake routes to (e.g. "Fernardo").
    let matchedTerm: String
    /// Whether the gate accepted the replacement this match produced. Nil when
    /// the term had no proxy word (uncalibrated → no evaluation possible).
    let accepted: Bool?
}

// MARK: - Entry

struct KWSDebugEntry: Identifiable {
    let id = UUID()
    let date = Date()

    let transcript: String
    let output: String

    /// All detections returned by the spotter (before term-mapping filter).
    let rawDetections: [KWSDetectionResult]
    /// Detections that mapped to a known dictionary term.
    let relevantDetections: [KWSDetectionResult]

    /// Substring-match candidates fired by each term's `commonMistakes` list.
    /// Independent of the KWS audio path - these can fire even when the
    /// spotter produces nothing.
    let commonMistakeMatches: [CommonMistakeMatch]

    /// Every NLL gate evaluation the rescorer ran during this rescore. The
    /// debug view renders this list directly - render this, not synthesised
    /// traces attached to detections or mistakes, when you want to know what
    /// the gate actually decided.
    let gateEvaluations: [GateEvaluation]

    /// All keywords the spotter was loaded with.
    let activeKeywords: [String]
    /// Active dictionary term texts.
    let activeTerms: [String]

    /// Non-nil when rescore() threw an error.
    let error: String?

    var didDetectAny: Bool { !rawDetections.isEmpty }
    var didDetectRelevant: Bool { !relevantDetections.isEmpty }
    var didReplace: Bool { transcript != output }
    var didFireCommonMistake: Bool { !commonMistakeMatches.isEmpty }
}

// MARK: - Singleton

@MainActor
final class KWSDebugHistory: ObservableObject {
    static let shared = KWSDebugHistory()
    @Published private(set) var entries: [KWSDebugEntry] = []
    private let maxEntries = 50
    private init() {}

    func record(_ entry: KWSDebugEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
    }
}

#endif
