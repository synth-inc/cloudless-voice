// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryNLLGate.swift
//  Onit
//
//  Validates CTC-detected substitutions with a Llama NLL gate.
//
//  After CTC fires for a term, this gate computes:
//    Δ_norm = (NLL_orig − NLL_proxy) / NLL_orig
//  where NLL_orig = avg per-token NLL of the ASR sentence,
//        NLL_proxy = avg per-token NLL with the confusion span replaced by a
//                    semantically adjacent known word (the proxy).
//
//  If Δ_norm > threshold → keep the substitution.
//  If Δ_norm ≤ threshold → reject (the confusion span fits the sentence better).
//
//  The default threshold is **0.0** - "accept the substitution only if the
//  proxy is at least as plausible to Llama as the original ASR." This is a
//  static, non-calibrated boundary chosen from the production case set in
//  `OnitTests/CustomDictionary/NLLGateProxyThresholdEvalTests.swift` (cases
//  prefixed `prod_`, mined from the local transcript history DB). 15 cases
//  across two dictionary terms: real positives cluster Δ ≥ +0.033, real negatives
//  (including earlier false positives) cluster Δ ≤ −0.005.
//  The sign of Δ separates them - 100% accuracy at 0.0. We picked 0.0 over
//  the −0.005 empirical sweep optimum because the gap is on the right side
//  of zero either way and a static boundary keeps per-term calibration out
//  of the enrollment flow. Re-derive any time the model or test set changes:
//    xcodebuild test -scheme Onit -only-testing \
//      OnitTests/NLLGateProxyThresholdEvalTests/testEmpiricalDefaultThreshold
//
//  Earlier values in this slot and why they were wrong:
//    • −0.126 - unsourced DTW margin from an unrelated KWS-embedding run,
//      pasted in as if it were an NLL Δ_norm. Scored 60% on the production set.
//    • −0.243 - empirical optimum on a 50-case synthetic set written in this
//      file, but the synthetic sentences were 5–13 words while real dictations
//      are 30–60+ words. Avg-per-token NLL washes out the single-word swap in
//      long sentences, dragging the synthetic threshold far below the value
//      that separates real-world positives from real-world negatives.
//      Scored 33% on the production set (let earlier false positives through).
//

import Foundation

/// One proxy-substitution variant evaluated by the gate. The gate tries
/// several variants (preserve preceding punct, consume preceding ", ", etc.)
/// and picks the lowest-NLL one as the winner.
struct NLLGateVariant: Sendable {
    /// Short label for the debug view (e.g. "keep", "consume preceding ', '").
    let label: String
    /// The proxy-substituted sentence after applying this variant.
    let text: String
    /// Average per-token NLL of `text`.
    let nll: Double
    /// Δ_norm = (originalNLL − nll) / originalNLL.
    let deltaNorm: Double
}

/// How a winning replacement should be applied to the corrected output.
/// `consumePreceding` and `consumeTrailing` strip any consumable punctuation
/// (`,.;:!?-–-`) plus any surrounding whitespace immediately before / after
/// the replaced span.
enum NLLGateApplyStyle: Sendable {
    case keep
    case consumePreceding
    case consumeTrailing
    case consumeBoth

    var consumePreceding: Bool {
        switch self {
        case .consumePreceding, .consumeBoth: return true
        case .keep, .consumeTrailing: return false
        }
    }

    var consumeTrailing: Bool {
        switch self {
        case .consumeTrailing, .consumeBoth: return true
        case .keep, .consumePreceding: return false
        }
    }
}

/// Snapshot of the exact strings + NLLs the gate evaluated. Surfaced into the
/// debug view so we can see whether punctuation contaminates the input.
struct NLLGateTrace: Sendable {
    let originalText: String
    let originalNLL: Double
    /// Winning variant - these mirror the legacy fields the debug view reads.
    let proxyText: String
    let proxyNLL: Double
    let proxyWord: String
    let deltaNorm: Double
    let threshold: Double
    let accepted: Bool
    /// Label of the winning variant (e.g. "keep", "consume preceding ', '").
    let winningVariantLabel: String
    /// Every variant the gate evaluated, in evaluation order. Includes the winner.
    let variants: [NLLGateVariant]
}

/// Result of a gate evaluation: the boolean decision, the apply-style for
/// the winning variant, and an optional trace.
struct NLLGateDecision: Sendable {
    let accept: Bool
    let applyStyle: NLLGateApplyStyle
    let trace: NLLGateTrace?

    static let reject = NLLGateDecision(accept: false, applyStyle: .keep, trace: nil)
    static let acceptNoTrace = NLLGateDecision(accept: true, applyStyle: .keep, trace: nil)
}

actor CustomDictionaryNLLGate {

    static let shared = CustomDictionaryNLLGate()
    private init() {}

    // MARK: - Constants

    /// Default Δ_norm threshold: > 0.0 → replace. Static (not per-term).
    /// Validated on the production-derived test set in
    /// `OnitTests/CustomDictionary/NLLGateProxyThresholdEvalTests.swift`
    /// (cases prefixed `prod_`) - 15 real-dictation cases across two
    /// dictionary terms, 100% accuracy. See the file header for the lineage of earlier
    /// values (−0.126 unsourced, −0.243 synthetic-bias, −0.005 sweep optimum).
    static let defaultThreshold: Double = 0.0

    /// Lower clamp for per-term calibration. A threshold below this would accept
    /// almost every replacement - pathological when negative examples don't
    /// separate cleanly from positives.
    static let calibrationMinThreshold: Double = -0.20

    /// Upper clamp for per-term calibration. A threshold above 0 means the proxy
    /// must produce a *better* sentence than the original to accept - strictly
    /// stricter than the default operating point we have evidence for.
    static let calibrationMaxThreshold: Double = 0.0

    /// Minimum labelled-sample accuracy required to trust a calibrated threshold.
    /// If the best sweep value can't beat this, positives and negatives don't
    /// separate well enough - fall back to the global default.
    static let calibrationMinAccuracy: Double = 0.80

    /// Per-token NLL cap to handle infinite-NLL tokens (OOV characters).
    private let nllCap: Float = 18.0

    // MARK: - Public API

    /// Decide whether to apply a dictionary replacement and return a trace of
    /// the exact strings + NLLs evaluated.
    ///
    /// - Parameters:
    ///   - asrSentence: Full ASR output before replacement.
    ///   - confusionSpan: The span text (e.g. "it"). Used for the trace +
    ///                    fallback substring search; not load-bearing when
    ///                    `spanWordRange` is supplied.
    ///   - proxyWord: Proxy word for NLL comparison (e.g. "Echo").
    ///                When `nil` the gate rejects with no trace.
    ///   - threshold: Per-term threshold; falls back to `defaultThreshold`.
    ///   - spanWordRange: Exact word-index position of the span in the
    ///                    whitespace-tokenized transcript. **Required for
    ///                    production callers** - the rescorer knows precisely
    ///                    which occurrence of the span it intends to replace,
    ///                    so the gate must score *that* occurrence rather
    ///                    than substring-searching for the first match.
    ///                    Substring search is left as a fallback when this is
    ///                    nil (e.g. from older callers / tests).
    func evaluate(
        asrSentence: String,
        confusionSpan: String,
        proxyWord: String?,
        threshold: Double? = nil,
        spanWordRange: (startWord: Int, width: Int)? = nil
    ) async -> NLLGateDecision {
        guard let proxy = proxyWord, !proxy.isEmpty else {
            return .reject
        }
        guard await MLXScoringEngine.shared.isLoaded else {
            log.info("CustomDictionaryNLLGate: Llama not loaded - rejecting replacement conservatively")
            return .reject
        }

        let effectiveThreshold = threshold ?? Self.defaultThreshold

        do {
            let nllOrig = try await avgScore(asrSentence)
            guard nllOrig > 0, nllOrig.isFinite else {
                return .acceptNoTrace
            }

            let asrChars = Array(asrSentence)
            let spanStart: Int
            let spanEnd: Int
            if let r = spanWordRange,
               let offsets = Self.charOffsets(forWordRange: r, in: asrChars) {
                spanStart = offsets.start
                spanEnd = offsets.end
            } else {
                // Fallback: locate by substring. Picks the FIRST occurrence -
                // wrong for common-word spans like "it", "and", "the" when the
                // rescorer intended a later position. Production callers must
                // pass `spanWordRange`.
                guard let range = asrSentence.range(of: confusionSpan, options: .caseInsensitive) else {
                    return .acceptNoTrace
                }
                spanStart = asrSentence.distance(from: asrSentence.startIndex, to: range.lowerBound)
                spanEnd = asrSentence.distance(from: asrSentence.startIndex, to: range.upperBound)
            }
            let proxyChars = Array(proxy)

            let prRange = consumePrecedingPunctOffsets(in: asrChars, spanStart: spanStart)
            let trRange = consumeTrailingPunctOffsets(in: asrChars, spanEnd: spanEnd)

            // Build the four variants. `consume*` variants are skipped when no
            // adjacent punctuation exists, so on a clean sentence we only do
            // one extra NLL call.
            struct Spec { let label: String; let pre: Bool; let trl: Bool; let style: NLLGateApplyStyle }
            let specs: [Spec] = [
                Spec(label: "keep",              pre: false, trl: false, style: .keep),
                Spec(label: "consume preceding", pre: true,  trl: false, style: .consumePreceding),
                Spec(label: "consume trailing",  pre: false, trl: true,  style: .consumeTrailing),
                Spec(label: "consume both",      pre: true,  trl: true,  style: .consumeBoth),
            ]

            var variants: [NLLGateVariant] = []
            var winnerNLL = Double.infinity
            var winnerIdx = 0
            var winnerStyle: NLLGateApplyStyle = .keep
            var winnerLabel = "keep"

            for spec in specs {
                if spec.pre && prRange == nil { continue }
                if spec.trl && trRange == nil { continue }
                guard let text = applyVariant(
                    chars: asrChars,
                    spanStart: spanStart,
                    spanEnd: spanEnd,
                    proxyChars: proxyChars,
                    precedingRange: spec.pre ? prRange : nil,
                    trailingRange: spec.trl ? trRange : nil
                ) else { continue }
                let nll = Double(try await avgScore(text))
                let delta = (Double(nllOrig) - nll) / Double(nllOrig)
                variants.append(NLLGateVariant(
                    label: spec.label, text: text, nll: nll, deltaNorm: delta
                ))
                if nll < winnerNLL {
                    winnerNLL = nll
                    winnerIdx = variants.count - 1
                    winnerStyle = spec.style
                    winnerLabel = spec.label
                }
            }

            guard !variants.isEmpty else {
                // Fell through every spec - shouldn't happen since "keep" has
                // no preconditions, but be defensive.
                return .acceptNoTrace
            }

            let winner = variants[winnerIdx]
            let accept = winner.deltaNorm > effectiveThreshold

            log.debug(
                "CustomDictionaryNLLGate: span=\(LogPrivacy.summary(confusionSpan)) proxy=\(LogPrivacy.summary(proxy)) "
                + "winner=\(winnerLabel) Δ_norm=\(String(format: "%.4f", winner.deltaNorm)) "
                + "thresh=\(effectiveThreshold) → \(accept ? "ACCEPT" : "REJECT")"
            )
            let trace = NLLGateTrace(
                originalText: asrSentence,
                originalNLL: Double(nllOrig),
                proxyText: winner.text,
                proxyNLL: winner.nll,
                proxyWord: proxy,
                deltaNorm: winner.deltaNorm,
                threshold: effectiveThreshold,
                accepted: accept,
                winningVariantLabel: winner.label,
                variants: variants
            )
            return NLLGateDecision(accept: accept, applyStyle: winnerStyle, trace: trace)
        } catch {
            log.warning("CustomDictionaryNLLGate: NLL error (\(error)) - accepting replacement")
            return .acceptNoTrace
        }
    }

    /// Convert a word-index range (as emitted by the rescorer) into character
    /// offsets in the original transcript. Uses the same whitespace tokenization
    /// as `transcript.components(separatedBy: .whitespaces).filter { !$0.isEmpty }`
    /// so a `DictionaryReplacement(startWordIndex: i, spanWidth: w)` maps to
    /// the exact characters of the `i`-th word through the `(i+w-1)`-th word.
    /// This is the load-bearing fix for the "gate evaluates the wrong 'it'"
    /// bug - substring search picks the first occurrence; word indices pick
    /// the intended one.
    static func charOffsets(
        forWordRange r: (startWord: Int, width: Int),
        in chars: [Character]
    ) -> (start: Int, end: Int)? {
        guard r.width > 0, r.startWord >= 0 else { return nil }
        let endWord = r.startWord + r.width - 1
        var currentWord = -1
        var inWord = false
        var spanStart: Int? = nil
        var spanEnd: Int? = nil
        for (i, c) in chars.enumerated() {
            if c.isWhitespace {
                if inWord {
                    inWord = false
                    if currentWord == endWord {
                        spanEnd = i
                        break
                    }
                }
            } else {
                if !inWord {
                    currentWord += 1
                    inWord = true
                    if currentWord == r.startWord {
                        spanStart = i
                    }
                }
            }
        }
        // Last word reaches end of string with no trailing whitespace.
        if inWord && spanEnd == nil && currentWord == endWord {
            spanEnd = chars.count
        }
        guard let s = spanStart, let e = spanEnd, s < e else { return nil }
        return (s, e)
    }

    /// Punctuation characters the gate is willing to consume. Excludes parens,
    /// quotes, and brackets (those typically bracket content correctly).
    private static let consumablePunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\u{2014}", "\u{2013}", "-"
    ]

    /// Walk backward from `spanStart` over any combination of whitespace and
    /// consumable punctuation. Returns `(start, end)` integer offsets covering
    /// that run, or nil if no consumable punctuation precedes the span.
    private func consumePrecedingPunctOffsets(in chars: [Character], spanStart: Int) -> (Int, Int)? {
        var idx = spanStart
        var sawPunct = false
        while idx > 0 {
            let c = chars[idx - 1]
            if c.isWhitespace {
                idx -= 1
                continue
            }
            if Self.consumablePunctuation.contains(c) {
                sawPunct = true
                idx -= 1
                continue
            }
            break
        }
        return sawPunct ? (idx, spanStart) : nil
    }

    /// Walk forward from `spanEnd` over any combination of whitespace and
    /// consumable punctuation. Returns `(start, end)` integer offsets covering
    /// that run, or nil if no consumable punctuation follows the span.
    private func consumeTrailingPunctOffsets(in chars: [Character], spanEnd: Int) -> (Int, Int)? {
        var idx = spanEnd
        var sawPunct = false
        while idx < chars.count {
            let c = chars[idx]
            if c.isWhitespace {
                idx += 1
                continue
            }
            if Self.consumablePunctuation.contains(c) {
                sawPunct = true
                idx += 1
                continue
            }
            break
        }
        return sawPunct ? (spanEnd, idx) : nil
    }

    /// Build a variant text from the original characters, optionally splicing
    /// out the preceding and/or trailing punct ranges, with the span replaced
    /// by `proxyChars`. Right-to-left order keeps earlier offsets valid.
    private func applyVariant(
        chars: [Character],
        spanStart: Int,
        spanEnd: Int,
        proxyChars: [Character],
        precedingRange: (Int, Int)?,
        trailingRange: (Int, Int)?
    ) -> String? {
        var out = chars
        if let (s, e) = trailingRange {
            out.replaceSubrange(s..<e, with: " ")
        }
        out.replaceSubrange(spanStart..<spanEnd, with: proxyChars)
        if let (s, e) = precedingRange {
            out.replaceSubrange(s..<e, with: " ")
        }
        return String(out)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Convenience wrapper for callers that don't need the trace.
    func shouldReplace(
        asrSentence: String,
        confusionSpan: String,
        proxyWord: String?,
        threshold: Double? = nil
    ) async -> Bool {
        let d = await evaluate(
            asrSentence: asrSentence,
            confusionSpan: confusionSpan,
            proxyWord: proxyWord,
            threshold: threshold
        )
        return d.accept
    }

    // MARK: - Calibration Helper

    /// Compute the best threshold for a term given labelled delta-norm samples.
    ///
    /// Scans [lo, hi] in 1 ‰ steps; returns the threshold that maximises accuracy.
    /// Falls back to `defaultThreshold` when either sample set is empty.
    func calibrateThreshold(
        positiveSentences: [(sentence: String, span: String)],
        negativeSentences: [(sentence: String, span: String)],
        proxyWord: String
    ) async throws -> Double {
        guard !positiveSentences.isEmpty, !negativeSentences.isEmpty else {
            return Self.defaultThreshold
        }

        var positiveDeltas: [Double] = []
        var negativeDeltas: [Double] = []

        for (sentence, span) in positiveSentences {
            if let d = try await deltaNorm(sentence: sentence, span: span, proxy: proxyWord) {
                positiveDeltas.append(d)
            }
        }
        for (sentence, span) in negativeSentences {
            if let d = try await deltaNorm(sentence: sentence, span: span, proxy: proxyWord) {
                negativeDeltas.append(d)
            }
        }

        guard !positiveDeltas.isEmpty, !negativeDeltas.isEmpty else {
            return Self.defaultThreshold
        }

        let all: [(Double, Bool)] = positiveDeltas.map { ($0, true) } + negativeDeltas.map { ($0, false) }
        let lo = all.map(\.0).min()! - 0.001
        let hi = all.map(\.0).max()! + 0.001

        var bestT = lo, bestAcc = 0
        var t = lo
        while t <= hi {
            let acc = all.filter { (d, isPos) in (d > t) == isPos }.count
            if acc > bestAcc { bestAcc = acc; bestT = t }
            t += 0.001
        }

        let accuracy = Double(bestAcc) / Double(all.count)
        guard accuracy >= Self.calibrationMinAccuracy else {
            return Self.defaultThreshold
        }
        return min(Self.calibrationMaxThreshold, max(Self.calibrationMinThreshold, bestT))
    }

    // MARK: - Private

    private func avgScore(_ text: String) async throws -> Float {
        let (_, nlls) = try await MLXScoringEngine.shared.tokenScores(text)
        guard !nlls.isEmpty else { return .infinity }
        let capped = nlls.map { min($0, nllCap) }
        return capped.reduce(0, +) / Float(capped.count)
    }

    private func deltaNorm(sentence: String, span: String, proxy: String) async throws -> Double? {
        let nllOrig = try await avgScore(sentence)
        guard nllOrig > 0, nllOrig.isFinite else { return nil }
        guard let range = sentence.range(of: span, options: .caseInsensitive) else { return nil }
        let proxySentence = sentence.replacingCharacters(in: range, with: proxy)
        let nllProxy = try await avgScore(proxySentence)
        return Double((nllOrig - nllProxy) / nllOrig)
    }
}
