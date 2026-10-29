// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptStitcher.swift
//  Onit
//
//  Created by Kévin Naudin on 20/07/2026.
//

import Foundation

/// Assembles the segment transcripts of a chunked-streaming dictation into
/// one transcript, deduplicating the words doubled by each segment's lead-in
/// overlap. Port of the validated stream-merge rule (2026-07 streaming
/// bench): the longest suffix(assembled)/prefix(next) match over
/// *normalized* words (lowercased, punctuation stripped - the ASR re-decodes
/// the overlap and may change casing/punctuation), capped at
/// ``maxOverlapWords``.
///
/// Not thread-safe - the streaming worker owns one instance per dictation.
final class TranscriptStitcher {

    /// Longest join overlap considered. 12 words comfortably covers the
    /// ~0.5 s audio overlap (2-4 spoken words) plus re-decode drift, while
    /// keeping accidental long-range matches impossible in practice.
    static let maxOverlapWords = 12

    private var words: [String] = []

    /// Whether a segment-final period is dropped when the next segment goes on in
    /// lowercase (see `append`). Only the file path sets it: its cuts land on 0.2 s
    /// pauses, often mid-sentence, while a live cut waits for a 0.6 s inter-phrase
    /// pause where that period is usually a real sentence end.
    private let repairsSegmentFinalPeriod: Bool

    init(repairsSegmentFinalPeriod: Bool = false) {
        self.repairsSegmentFinalPeriod = repairsSegmentFinalPeriod
    }

    /// Number of words assembled so far.
    var wordCount: Int { words.count }

    /// The assembled transcript (single-space joined).
    var text: String { words.joined(separator: " ") }

    /// Append a segment transcript. When `hasSpeechOverlap` is `true` (a fixed
    /// mid-speech cut re-sent the boundary speech), drop the leading words that
    /// duplicate the current tail (overlap re-decode). When `false` (a pause cut
    /// with a silence-only lead-in, or the first segment), no spoken word was
    /// re-decoded, so nothing is dropped - otherwise a word genuinely repeated
    /// across the pause would be lost. Empty/whitespace input no-ops.
    func append(_ segmentText: String?, hasSpeechOverlap: Bool) {
        guard let segmentText else { return }
        let incoming = segmentText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !incoming.isEmpty else { return }

        let overlap = hasSpeechOverlap
            ? Self.findOverlap(assembled: words, incoming: incoming, cap: Self.maxOverlapWords)
            : 0
        let kept = incoming[overlap...]
        // With `repairsSegmentFinalPeriod`, the period the model puts at the end of every
        // segment, sentence over or not ("Everyone. preferred", then "Everyone. Preferred"
        // once Smart Formatting capitalizes it). The next segment going on in lowercase
        // says the sentence continues: on a 7 min French phone call cut on 0.2 s pauses,
        // 20 of 46 joins had it, and the 9 real sentence ends were followed by a capital. Left alone: words with an inner period ("U.S."),
        // abbreviations ("etc. and more"), and a next word that is not all lowercase
        // ("it works. iPhone users", "macOS").
        if repairsSegmentFinalPeriod,
           let next = kept.first, next.first?.isLowercase == true, next == next.lowercased(),
           let last = words.last, last.count > 1, last.hasSuffix("."),
           last.dropLast().allSatisfy({ $0.isLetter || $0.isNumber }),
           !Self.abbreviations.contains(last.dropLast().lowercased()) {
            words[words.count - 1] = String(last.dropLast())
        }
        words.append(contentsOf: kept)
    }

    /// Words whose period belongs to the word, English and French.
    private static let abbreviations: Set<String> = [
        "etc", "inc", "ltd", "co", "corp", "vs", "approx", "dept", "jr", "sr",
        "dr", "mr", "mrs", "ms", "st", "cf", "env", "mme", "mlle",
    ]

    /// Longest `k` ≤ `cap` such that the last `k` normalized words of
    /// `assembled` equal the first `k` normalized words of `incoming`. 0 when
    /// nothing matches.
    static func findOverlap(assembled: [String], incoming: [String], cap: Int) -> Int {
        let maxK = min(cap, min(assembled.count, incoming.count))
        for k in stride(from: maxK, through: 1, by: -1) {
            var match = true
            for i in 0..<k {
                if normalize(assembled[assembled.count - k + i]) != normalize(incoming[i]) {
                    match = false
                    break
                }
            }
            if match { return k }
        }
        return 0
    }

    /// Join-comparison normalization: keep letters/digits (Unicode-aware, so
    /// accented words survive), drop everything else, lowercase. A word that
    /// normalizes to empty (pure punctuation, e.g. an em-dash token) compares
    /// equal to another empty-normalized word - same as the validated merge.
    static func normalize(_ word: String) -> String {
        word.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
}
