// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryRescorer.swift
//  Onit
//
//  CTC-based keyword spotting and transcript correction for custom dictionary.
//

import Foundation

/// Metadata about a single substitution applied by the rescorer.
struct DictionaryReplacement: Sendable {
    /// The dictionary term that was substituted in.
    let term: CustomDictionaryTerm
    /// The original ASR span that was replaced (e.g. "on it" for "Onit").
    let originalSpan: String
    /// Word index in the original transcript where the span starts.
    let startWordIndex: Int
    /// Number of words in the original span.
    let spanWidth: Int
    /// What to substitute in. Defaults to `term.text` for normal matches.
    /// Possessive matches set this to `<term.text>'s` so "nodding's" → "Raudin's".
    let replacementText: String
    /// Override for the proxy word the NLL gate uses. Defaults to
    /// `term.proxyWord`. Possessive matches set this to `<proxyWord>'s` so the
    /// gate scores grammatically valid sentences.
    let proxyOverride: String?

    init(
        term: CustomDictionaryTerm,
        originalSpan: String,
        startWordIndex: Int,
        spanWidth: Int,
        replacementText: String? = nil,
        proxyOverride: String? = nil
    ) {
        self.term = term
        self.originalSpan = originalSpan
        self.startWordIndex = startWordIndex
        self.spanWidth = spanWidth
        self.replacementText = replacementText ?? term.text
        self.proxyOverride = proxyOverride
    }

    /// Effective proxy word for NLL evaluation. Possessive matches override
    /// the term-level proxy so the gate compares grammatically valid strings.
    var effectiveProxy: String? {
        proxyOverride ?? term.proxyWord
    }
}

/// Performs keyword spotting via CTC DP and corrects TDT transcript words.
///
/// Conservative by design: prefers not replacing if uncertain.
///
/// ## Span-based matching
///
/// Terms are matched against N-gram spans of 1–`maxSpanWidth` words so that
/// single-word terms tokenized into multiple BPE subwords (e.g. "Onit" → ["▁on","it"])
/// still find the right span ("on it") in the transcript instead of the
/// wrong single word ("on").  Spans are normalized by removing spaces before
/// Levenshtein comparison so "on it" ≡ "onit".
struct CustomDictionaryRescorer: Sendable {

    /// Maximum number of consecutive transcript words to try as a matching span.
    private static let maxSpanWidth = 3

    /// Half-width (in seconds) of the time window around a CTC detection used
    /// to prune transcript word spans. A detection centred at `t` is allowed
    /// to replace any span whose estimated time range overlaps
    /// `[detectionStart - tolerance, detectionEnd + tolerance]`. Generous by
    /// design because the per-word time estimate is a character-proportional
    /// heuristic, not a true forced alignment.
    private static let alignmentToleranceSeconds: Double = 2.0

    // MARK: - Main Entry Point

    func rescore(
        transcript: String,
        logProbs: [[Float]],
        embeddings: [[Float]]?,
        frameDuration: Double,
        vocabulary: CustomDictionaryContext,
        termEmbeddings: [UUID: [[[Float]]]]
    ) -> (corrected: String, replacements: [DictionaryReplacement]) {
        guard !logProbs.isEmpty, !vocabulary.terms.isEmpty, !transcript.isEmpty else {
            return (transcript, [])
        }

        let words = transcript.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return (transcript, []) }

        // Pre-normalise every transcript word once - the inner loop used to
        // recompute this per `(term × spanWidth × startIdx)` combination which
        // produced an O(|terms| × |words|²) similarity scan.
        let normalizedWords = words.map { normalizeKey($0) }

        // Memoise span keys so every `(startIdx, spanWidth)` pair is joined
        // exactly once across all terms.
        let maxSpan = min(Self.maxSpanWidth, words.count)
        var spanKeyCache: [[String]] = Array(
            repeating: [String](repeating: "", count: words.count),
            count: maxSpan + 1
        )
        for spanWidth in 1...maxSpan {
            let upper = words.count - spanWidth
            if upper < 0 { continue }
            for startIdx in 0...upper {
                spanKeyCache[spanWidth][startIdx] = normalizedWords[startIdx..<(startIdx + spanWidth)].joined()
            }
        }

        // Rough per-word timestamps from character-proportional distribution
        // of the total audio duration across the transcript text. This is a
        // heuristic - real forced alignment is not plumbed through the TDT
        // pipeline - so we use it only as a *pruning window*, never as a
        // correctness signal. See `alignmentToleranceSeconds`.
        let wordTimeRanges = Self.estimateWordTimeRanges(
            words: words,
            totalDuration: Double(logProbs.count) * frameDuration
        )

        // (startIdx, spanWidth, term, replacement, ctcScore, similarity, effectiveMinSim)
        var candidates: [(startIdx: Int, spanWidth: Int, term: CustomDictionaryTerm, replacement: String, ctcScore: Float, similarity: Float, effectiveMinSim: Float)] = []

        for term in vocabulary.terms {
            guard normalizeKey(term.text).count >= vocabulary.minTermLength else { continue }
            let termKey = normalizeKey(term.text)

            // Levenshtein pre-scan: skip this term entirely if no N-gram in the
            // transcript is even loosely similar to it. highConfidenceSimilarity
            // (0.30) is intentionally permissive so that heavy ASR mishears like
            // "audit" ↔ "Onit" (sim≈0.40) still pass through.
            let hasCandidateSpan = (1...maxSpan).contains { sw in
                let upper = words.count - sw
                guard upper >= 0 else { return false }
                return (0...upper).contains { si in
                    Self.similarity(spanKeyCache[sw][si], termKey)
                        >= ContextBiasingConstants.highConfidenceSimilarity
                }
            }
            guard hasCandidateSpan else { continue }

            // ── Contrastive DTW path ────────────────────────────────────────
            // Used when the user has enrolled the term via the calibration flow.
            // Sliding window over raw encoder embeddings for detection - no
            // word-time alignment needed. After detection, Levenshtein selects
            // which transcript span to replace, same as the CTC path below.
            if let embs = embeddings, !embs.isEmpty, frameDuration > 0,
               let templates = termEmbeddings[term.id], !templates.isEmpty {

                let meanLen = max(2, templates.reduce(0) { $0 + $1.count } / templates.count)
                let minLen = max(2, meanLen - 2)
                let maxLen = meanLen + 3
                var bestDTWScore: Float = 0
                var bestFrameStart = 0
                var bestFrameLen = meanLen

                for len in minLen...min(maxLen, embs.count) {
                    guard len <= embs.count else { break }
                    let maxStart = embs.count - len
                    let negStep = max(1, embs.count / 6)
                    for start in 0...maxStart {
                        let query = Array(embs[start..<(start + len)])
                        // Negatives: evenly-sampled windows from outside the candidate
                        // window. Alignment-free - no word-time estimates needed.
                        let negatives: [[[Float]]] = stride(from: 0, through: maxStart, by: negStep)
                            .filter { s in s + len <= start || s >= start + len }
                            .map { s in Array(embs[s..<(s + len)]) }
                        let score = ContrastiveDTWScorer.score(
                            query: query, templates: templates, negatives: negatives)
                        if score > bestDTWScore {
                            bestDTWScore = score; bestFrameStart = start; bestFrameLen = len
                        }
                    }
                }

                guard bestDTWScore >= ContrastiveDTWScorer.detectionThreshold else { continue }

                // DTW confirmed presence - now find the best Levenshtein span to
                // replace. Use the detected frame window (±alignmentToleranceSeconds)
                // as a pruning hint, same as the CTC path.
                let detectionStart = Double(bestFrameStart) * frameDuration - Self.alignmentToleranceSeconds
                let detectionEnd = Double(bestFrameStart + bestFrameLen) * frameDuration + Self.alignmentToleranceSeconds

                var bestStartIdx = -1
                var bestSpanWidth = 1
                var bestSimilarity: Float = 0.0

                for spanWidth in 1...maxSpan {
                    let upper = words.count - spanWidth
                    if upper < 0 { continue }
                    for startIdx in 0...upper {
                        let spanStart = wordTimeRanges[startIdx].start
                        let spanEnd = wordTimeRanges[startIdx + spanWidth - 1].end
                        if spanEnd < detectionStart || spanStart > detectionEnd { continue }
                        let sim = Self.similarity(spanKeyCache[spanWidth][startIdx], termKey)
                        if sim > bestSimilarity {
                            bestSimilarity = sim; bestStartIdx = startIdx; bestSpanWidth = spanWidth
                        }
                    }
                }

                guard bestStartIdx >= 0,
                      bestSimilarity >= ContextBiasingConstants.highConfidenceSimilarity else { continue }

                candidates.append((
                    startIdx: bestStartIdx,
                    spanWidth: bestSpanWidth,
                    term: term,
                    replacement: term.text,
                    ctcScore: 0,
                    similarity: bestDTWScore,
                    effectiveMinSim: ContextBiasingConstants.highConfidenceSimilarity
                ))
                log.debug("CustomDictionaryRescorer: DTW candidate score=\(String(format: "%.2f", bestDTWScore)) spanWords=\(bestSpanWidth)")
                continue
            }

            // ── CTC DP path ─────────────────────────────────────────────────
            guard let tokenIds = term.ctcTokenIds, !tokenIds.isEmpty else { continue }

            let extraTokens = max(0, tokenIds.count - ContextBiasingConstants.baselineTokenCountForThreshold)
            let relaxation = min(
                Float(extraTokens) * ContextBiasingConstants.thresholdRelaxationPerToken,
                ContextBiasingConstants.maxThresholdRelaxation
            )
            let adjustedMinScore = vocabulary.minCtcScore - relaxation

            let detections = CtcDPAlgorithm.ctcWordSpotMultiple(
                logProbs: logProbs,
                keywordTokens: tokenIds,
                minScore: adjustedMinScore,
                mergeOverlap: true
            )

            guard let bestDetection = detections.max(by: { $0.score < $1.score }),
                  bestDetection.score >= adjustedMinScore else { continue }

            // Convert the detection frame window to a time window, widened by
            // the alignment tolerance. Any span whose estimated time range is
            // entirely outside this window is pruned without running
            // Levenshtein. On short utterances this is a no-op (every span
            // overlaps); on long dictations with repeated phonemes it
            // concentrates the search on the region where the CTC actually
            // fired.
            let detectionStart = Double(bestDetection.startFrame) * frameDuration - Self.alignmentToleranceSeconds
            let detectionEnd = Double(bestDetection.endFrame) * frameDuration + Self.alignmentToleranceSeconds

            // When the CTC score is very confident (well above the gate threshold),
            // lower the similarity floor so that phonetically close ASR confusions
            // are still corrected (e.g. TDT transcribes "Onit" as "audit", sim≈0.40).
            // At low confidence (borderline threshold clearance) the stricter floor
            // guards against over-eager replacements.
            let isHighConfidence = bestDetection.score > adjustedMinScore + ContextBiasingConstants.highConfidenceMargin
            let effectiveMinSim = isHighConfidence
                ? ContextBiasingConstants.highConfidenceSimilarity
                : vocabulary.minSimilarity

            let termLen = termKey.count
            // Length-bucketing: sim = 1 - dist / max(|a|, |b|) ≥ effectiveMinSim
            //               ⇒ dist ≤ max(|a|, |b|) × (1 - effectiveMinSim)
            //               ⇒ |span| differing from |term| by more than that
            //                 cannot meet the threshold - skip.
            let slack = 1 - effectiveMinSim

            var bestStartIdx = -1
            var bestSpanWidth = 1
            var bestSimilarity: Float = 0.0

            for spanWidth in 1...maxSpan {
                let upper = words.count - spanWidth
                if upper < 0 { continue }
                for startIdx in 0...upper {
                    // Time-window prune
                    let spanStart = wordTimeRanges[startIdx].start
                    let spanEnd = wordTimeRanges[startIdx + spanWidth - 1].end
                    if spanEnd < detectionStart || spanStart > detectionEnd {
                        continue
                    }

                    let spanKey = spanKeyCache[spanWidth][startIdx]
                    let spanLen = spanKey.count

                    // Length-bucket prune
                    let maxLen = max(spanLen, termLen)
                    if maxLen == 0 { continue }
                    let lenDelta = abs(spanLen - termLen)
                    if Float(lenDelta) > Float(maxLen) * slack { continue }

                    let sim = Self.similarity(spanKey, termKey)
                    if sim > bestSimilarity {
                        bestSimilarity = sim
                        bestStartIdx = startIdx
                        bestSpanWidth = spanWidth
                    }
                }
            }

            guard bestStartIdx >= 0, bestSimilarity >= effectiveMinSim else { continue }

            candidates.append((
                startIdx: bestStartIdx,
                spanWidth: bestSpanWidth,
                term: term,
                replacement: term.text,
                ctcScore: bestDetection.score,
                similarity: bestSimilarity,
                effectiveMinSim: effectiveMinSim
            ))
        }

        guard !candidates.isEmpty else { return (transcript, []) }

        // Sort: higher similarity first, then higher CTC score
        let sorted = candidates.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.ctcScore > $1.ctcScore
        }

        // Apply greedily - skip overlapping spans
        var usedIndices = Set<Int>()
        // Represent transcript as tokens; nil = deleted (part of a replaced span)
        var result: [String?] = words.map { Optional($0) }
        var appliedReplacements: [DictionaryReplacement] = []

        for c in sorted {
            let indices = c.startIdx..<(c.startIdx + c.spanWidth)
            guard !indices.contains(where: { usedIndices.contains($0) }) else { continue }

            // Re-check similarity against current words (in case an earlier replacement changed something).
            // Use the same effective floor that was used to admit this candidate.
            let currentSpanWords = indices.compactMap { result[$0] }
            let currentKey = currentSpanWords.map { normalizeKey($0) }.joined()
            let sim = Self.similarity(currentKey, normalizeKey(c.replacement))
            guard sim >= c.effectiveMinSim else { continue }

            let originalSpan = currentSpanWords.joined(separator: " ")

            // Replace first word of span with the term, nil-out the rest
            result[c.startIdx] = c.replacement
            for idx in (c.startIdx + 1)..<(c.startIdx + c.spanWidth) {
                result[idx] = nil
            }
            indices.forEach { usedIndices.insert($0) }

            appliedReplacements.append(DictionaryReplacement(
                term: c.term,
                originalSpan: originalSpan,
                startWordIndex: c.startIdx,
                spanWidth: c.spanWidth
            ))

            log.debug("CustomDictionaryRescorer: Replaced a span (span=\(c.spanWidth), sim=\(String(format: "%.2f", sim)), ctc=\(String(format: "%.1f", c.ctcScore)))")
        }

        return (result.compactMap { $0 }.joined(separator: " "), appliedReplacements)
    }

    // MARK: - Time Window Estimation

    /// Estimate per-word time ranges by distributing `totalDuration` across
    /// the transcript proportional to each word's character count (whitespace
    /// counted as a separator, not owned by any word). This is NOT a forced
    /// alignment - utterances with pauses, fillers, or non-uniform pacing
    /// will drift - which is why the caller only uses the output as a
    /// *pruning window* with a generous tolerance, never as a correctness
    /// signal. Returns an array aligned 1:1 with `words`.
    static func estimateWordTimeRanges(
        words: [String],
        totalDuration: Double
    ) -> [(start: Double, end: Double)] {
        guard !words.isEmpty else { return [] }
        guard totalDuration > 0 else {
            return Array(repeating: (start: 0, end: 0), count: words.count)
        }
        let totalChars = words.reduce(0) { $0 + max($1.count, 1) }
        guard totalChars > 0 else {
            return Array(repeating: (start: 0, end: 0), count: words.count)
        }
        let secondsPerChar = totalDuration / Double(totalChars)
        var ranges: [(start: Double, end: Double)] = []
        ranges.reserveCapacity(words.count)
        var cursor: Double = 0
        for word in words {
            let span = Double(max(word.count, 1)) * secondsPerChar
            ranges.append((start: cursor, end: cursor + span))
            cursor += span
        }
        return ranges
    }

    // MARK: - String Helpers

    /// Normalize for key comparison: lowercase, keep letters AND digits, drop
    /// everything else (punctuation, spaces). "on it" → "onit";  "Onit" → "onit";
    /// "iOS 17" → "ios17";  "GPT-4" → "gpt4". Digits are preserved so that
    /// terms like "iOS17", "GPT4", "Llama3" survive normalisation - stripping
    /// them collapsed such terms to their letter-only form and broke
    /// similarity scoring against the transcript.
    private func normalizeKey(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    /// Levenshtein-based similarity in [0, 1].
    static func similarity(_ a: String, _ b: String) -> Float {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        let dist = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        return 1.0 - Float(dist) / Float(maxLen)
    }

    /// Normalize for display comparison: lowercase, strip punctuation, keep
    /// spaces *and digits* so alphanumeric term variants ("iOS 17") survive.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.whitespaces).contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Levenshtein

    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }
}
