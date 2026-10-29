// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SemanticEmojiMatcher.swift
//  Onit
//
//  Semantic emoji replacement for spoken names that don't exactly match a known
//  trigger. Runs AFTER the framework's exact `<name> <trigger>` pass, so it only
//  sees leftover "<words> <trigger>" spans (e.g. "crying emoji", "tears
//  streaming down face emoji").
//
//  Trigger words come from the locale the pipeline ran with
//  (`SmartFormattingDefaults.emojiTriggerWords(locale:)`), so a FR-locked user
//  saying "émoji" reaches this pass too. Only the suffix order is handled here:
//  the framework also matches `<trigger> <name>`, but widening a fuzzy matcher
//  to a second word order multiplies its false-fire surface, and false fires on
//  ordinary speech are already what keeps this feature off by default.
//
//  Boundary handling (the "how many words" problem): we don't hardcode a span
//  length. Starting from the word adjacent to the trigger, we extend the span
//  one word to the LEFT at a time and track the best cosine similarity to any
//  emoji anchor. We keep the longest span within a tolerance band of the peak
//  cosine - the descriptor. The peak glyph must clear `threshold`, otherwise the
//  text is left untouched.
//
//  Backend: a bundled on-device MiniLM (all-MiniLM-L6-v2) CoreML embedder plus a
//  precomputed 2,056-emoji anchor table (MiniLMEmojiEmbedder). This covers ALL
//  emojis independently of the 129-entry exact-trigger map - the anchors come
//  from the bundled table, not from EmojiTriggers. `bestAnchor(query)` = argmax
//  dot over the 2,056 unit-norm anchor rows.
//
//  Gated behind the `emojiSemanticMatchingEnabled` debug flag while we tune it.
//

#if canImport(TranscriptionCleanup)

import Defaults
import Foundation
import TranscriptionCleanup

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// `@unchecked Sendable`: the embedder it delegates to is itself lock-guarded.
final class SemanticEmojiMatcher: @unchecked Sendable {

    static let shared = SemanticEmojiMatcher()

    private init() {}

    // MARK: - Tunables

    /// Minimum peak cosine to the best anchor before we replace anything.
    /// 0.43 splits the observed negative ("how do I add an emoji" → 0.402) from
    /// the weakest legit positive ("in love" → 0.439) per emoji_assets/VALIDATION.md.
    /// Hard gate for now. The #1→#2 margin (AnchorMatch.secondCosine) is available
    /// as a future soft signal for surfacing alternatives in the gray zone.
    private let threshold: Float = 0.43
    /// Max words to the left of "emoji" we'll consider for the descriptor.
    /// Bounds the spans analyzed per "emoji" occurrence to at most this many.
    private let maxLeftWords = 5
    /// Total embeddings we'll compute for one dictation, across all "emoji"
    /// occurrences. Guards a pathological transcript with many "emoji" words from
    /// running unbounded work (each embed is a ~4ms CoreML call). Repeated spans
    /// are memoized, so this is a ceiling on *distinct* span embeds per pass.
    private let maxEmbedsPerText = 60
    /// A longer span is preferred over a shorter one as long as its best-anchor
    /// cosine is within this much of the overall peak. This makes "blowing a kiss"
    /// (→😘) win over the generic sub-span "kiss" (→👄, which scores marginally
    /// higher in isolation), while still rejecting words that clearly dilute the
    /// match (e.g. a leading "talking" that drops the cosine well below the band).
    private let spanTolerance: Float = 0.06

    private let embedder = MiniLMEmojiEmbedder.shared

    // MARK: - Public

    var isEnabled: Bool {
        Defaults[ConfigKeys.emojiSemanticMatchingEnabled] && Defaults[ConfigKeys.sfEmojiEnabled]
    }

    /// No-op unless enabled; otherwise runs the semantic pass.
    ///
    /// `locale` must be the one the cleanup pipeline just ran with, so this
    /// pass looks for the same trigger words the exact pass did.
    func applyIfEnabled(
        to text: String,
        locale: TranscriptionCleanup.SupportedLocale
    ) -> String {
        guard isEnabled else { return text }
        return apply(to: text, locale: locale)
    }

    func apply(to text: String, locale: TranscriptionCleanup.SupportedLocale) -> String {
        // Trigger words come from the locale, not a hardcoded "emoji": a
        // FR-locked user says "émoji", which the exact pass already matches.
        // Spelling them in here would leave this pass silently English-only.
        let triggers = TranscriptionCleanup.SmartFormattingDefaults
            .emojiTriggerWords(locale: locale)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !triggers.isEmpty else { return text }
        guard triggers.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil })
        else { return text }
        guard embedder.ensureLoaded() else { return text }

        // Longest first so a trigger that prefixes another can't shadow it, and
        // escaped so a word from the framework's list is never read as syntax.
        let triggerAlternation = triggers
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) + "s?" }
            .joined(separator: "|")

        // "<up to N words> <trigger>(s)" - capture the preceding words in group 1.
        let pattern = #"((?:[\p{L}\p{N}][\p{L}\p{N}'’\-]*\s+){1,\#(maxLeftWords)})(?:\#(triggerAlternation))\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let ns = NSMutableString(string: text)
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))

        // Shared across all matches in this dictation: an embed budget (caps total
        // work) and a span→vector memo (repeated spans cost nothing).
        var embedBudget = maxEmbedsPerText
        var cache: [String: [Float]?] = [:]
        // This pass runs inline in the dictation path, so its cost lands on
        // perceived latency. Logged per dictation to make the budget tunable
        // from a real transcript rather than from the per-embed estimate.
        let started = Date()
        var replacements = 0

        // Apply right-to-left so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let g1Range = match.range(at: 1)
            guard g1Range.location != NSNotFound else { continue }
            let group1 = ns.substring(with: g1Range)
            let words = group1.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { continue }

            guard let peak = bestSpan(words: words, budget: &embedBudget, cache: &cache) else { continue }

            // Replace from the start of the chosen suffix span through "emoji".
            let drop = words.count - peak.length
            let spanStartUTF16 = g1Range.location + utf16OffsetSkippingWords(drop, in: group1)
            let end = match.range.location + match.range.length
            let replaceRange = NSRange(location: spanStartUTF16, length: end - spanStartUTF16)
            let replaced = ns.substring(with: replaceRange)
            ns.replaceCharacters(in: replaceRange, with: peak.glyph)
            replacements += 1
            log.info("SemanticEmoji: span (\(LogPrivacy.summary(replaced))) -> glyph (cos \(String(format: "%.2f", peak.cosine)))")
        }

        let elapsedMs = Date().timeIntervalSince(started) * 1000
        if replacements > 0 || !matches.isEmpty {
            log.info(
                "[semantic-emoji] \(matches.count) span(s), \(replacements) replaced, "
                    + "\(maxEmbedsPerText - embedBudget) embed(s) in "
                    + "\(String(format: "%.0f", elapsedMs))ms"
            )
        }

        return ns as String
    }

    // MARK: - Greedy span search

    private struct Peak { let glyph: String; let cosine: Float; let length: Int }

    /// Score every span length, then choose the LONGEST span whose match is
    /// within `spanTolerance` of the peak (and clears `threshold`). We do NOT
    /// stop at the first cosine dip: a mid-span stopword ("blowing A kiss")
    /// causes a local dip even though the longer, more specific span
    /// ("blowing a kiss" → 😘) is the intended descriptor and outranks the
    /// generic sub-span ("kiss" → 👄) once you look at the full phrase.
    private func bestSpan(words: [String], budget: inout Int, cache: inout [String: [Float]?]) -> Peak? {
        var candidates: [Peak] = []
        for length in 1...words.count {
            let span = words.suffix(length).joined(separator: " ").lowercased()
            let vec: [Float]?
            if let cached = cache[span] {
                vec = cached // memoized (may be nil if the embed previously failed)
            } else {
                guard budget > 0 else { break } // out of embed budget for this dictation
                budget -= 1
                vec = embedder.embed(span)
                cache[span] = vec
            }
            guard let vec, let best = embedder.bestAnchor(vec) else { continue }
            candidates.append(Peak(glyph: best.glyph, cosine: best.cosine, length: length))
        }
        guard let maxCos = candidates.map(\.cosine).max(), maxCos >= threshold else { return nil }
        let band = max(threshold, maxCos - spanTolerance)
        // Longest span still within the band - consume the whole descriptor.
        return candidates.filter { $0.cosine >= band }.max { $0.length < $1.length }
    }

    // MARK: - Offset helper

    /// UTF-16 offset within `group1` after skipping `count` leading words
    /// (each word plus its trailing whitespace).
    private func utf16OffsetSkippingWords(_ count: Int, in group1: String) -> Int {
        guard count > 0 else { return 0 }
        var idx = group1.startIndex
        var skipped = 0
        while skipped < count && idx < group1.endIndex {
            while idx < group1.endIndex && !group1[idx].isWhitespace { idx = group1.index(after: idx) }
            while idx < group1.endIndex && group1[idx].isWhitespace { idx = group1.index(after: idx) }
            skipped += 1
        }
        return group1[..<idx].utf16.count
    }
}

#endif // canImport(TranscriptionCleanup)
