// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmojiReplacementEval.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-07-23.
//

#if DEBUG
#if canImport(TranscriptionCleanup)

import Foundation
import TranscriptionCleanup

/// Debug-only evaluation harness for the "emoji replacement by voice" feature.
///
/// It drives the REAL cleanup bridge (`CleanupPipelineBridge`, wrapping the
/// on-device MLX scorer) over a labeled dataset and reports precision / recall
/// per class, so we can verify the perplexity gate makes good choices:
///
/// - POSITIVES: utterances like "ship it fire emoji" where the glyph SHOULD be
///   inserted (the generator proposes it, the scorer should accept it).
/// - HARD NEGATIVES: utterances like "the fire emoji feature" or "she has a
///   heart of gold" where NO glyph should appear (either no candidate is
///   generated, or the scorer should keep the literal words).
///
/// ## Requirements
///
/// The scoring model (Qwen 2.5 1.5B multilingual, or whichever is selected)
/// must be downloaded and warmed. Open the app, go to
/// Settings > Smart Cleanup, and wait for the Cleanup Model status to read
/// "Ready" before running. Without a loaded model the scorer cannot gate the
/// candidates and every case will report an error.
///
/// ## How to run
///
/// This is not wired to any UI (it is a throwaway diagnostic). Run it one of
/// two ways in a DEBUG build:
///
/// 1. From the LLDB console while the app is running and the model is Ready:
///
///        (lldb) e -l Swift -- EmojiReplacementEval.runDetached()
///
///    Results print to the Xcode console.
///
/// 2. Temporarily, from an app entry point (e.g. `AppDelegate` after launch):
///
///        Task { await EmojiReplacementEval.run() }
///
///    Remove the call before committing.
enum EmojiReplacementEval {

    // MARK: - Dataset

    struct Sample {
        /// The raw utterance fed to the cleanup pipeline.
        let text: String
        /// Whether an emoji glyph is expected in the final output.
        let expectsEmoji: Bool
        /// Short human note about what the case exercises.
        let note: String
    }

    /// ~52 labeled utterances. POSITIVES expect a glyph, HARD NEGATIVES expect
    /// none. The "meta" negatives (a valid name immediately before the word
    /// "emoji", but the sentence is ABOUT the emoji) are the ones the scorer
    /// must actively reject; they are the reason this harness exists.
    static let dataset: [Sample] = [
        // ---- POSITIVES (expect a glyph) ----
        Sample(text: "ship it fire emoji", expectsEmoji: true, note: "canonical"),
        Sample(text: "great work thumbs up emoji", expectsEmoji: true, note: "multi-word name"),
        Sample(text: "i love this heart emoji", expectsEmoji: true, note: "heart"),
        Sample(text: "we are launching tomorrow rocket emoji", expectsEmoji: true, note: "rocket"),
        Sample(text: "we finally did it party emoji", expectsEmoji: true, note: "party"),
        Sample(text: "let me see that eyes emoji", expectsEmoji: true, note: "eyes"),
        Sample(text: "that take is 100 emoji", expectsEmoji: true, note: "numeric name"),
        Sample(text: "this is hilarious joy emoji", expectsEmoji: true, note: "joy"),
        Sample(text: "that news made me so sad cry emoji", expectsEmoji: true, note: "cry"),
        Sample(text: "i am dead skull emoji", expectsEmoji: true, note: "skull"),
        Sample(text: "amazing job everyone clap emoji", expectsEmoji: true, note: "clap"),
        Sample(text: "thank you so much pray emoji", expectsEmoji: true, note: "pray"),
        Sample(text: "sounds good to me ok emoji", expectsEmoji: true, note: "ok"),
        Sample(text: "all the tests pass check emoji", expectsEmoji: true, note: "check"),
        Sample(text: "you are a rockstar star emoji", expectsEmoji: true, note: "star"),
        Sample(text: "the release looks brand new sparkles emoji", expectsEmoji: true, note: "sparkles"),
        Sample(text: "let me think about it thinking emoji", expectsEmoji: true, note: "thinking"),
        Sample(text: "hey there team wave emoji", expectsEmoji: true, note: "wave"),
        Sample(text: "we absolutely crushed it raised hands emoji", expectsEmoji: true, note: "raised hands"),
        Sample(text: "you got this muscle emoji", expectsEmoji: true, note: "muscle"),
        Sample(text: "that reply gave me heart eyes emoji", expectsEmoji: true, note: "heart eyes multi-word"),
        Sample(text: "i can not stop laughing sob emoji", expectsEmoji: true, note: "sob"),
        Sample(text: "that outfit is so cool sunglasses emoji", expectsEmoji: true, note: "sunglasses"),
        Sample(text: "finally found the bug emoji", expectsEmoji: true, note: "bug (dev)"),
        Sample(text: "huge win for the team trophy emoji", expectsEmoji: true, note: "trophy"),
        Sample(text: "grab a coffee emoji before the standup", expectsEmoji: true, note: "coffee mid-sentence"),

        // ---- HARD NEGATIVES (expect no glyph) ----
        // "meta" cases: a valid name sits right before "emoji", but the sentence
        // is about the emoji itself. The scorer must keep the literal words.
        Sample(text: "the fire emoji feature shipped last week", expectsEmoji: false, note: "meta: about the emoji"),
        Sample(text: "how do you type the fire emoji on a mac", expectsEmoji: false, note: "meta: about the emoji"),
        Sample(text: "the heart emoji is the most used emoji", expectsEmoji: false, note: "meta: about the emoji"),
        Sample(text: "which thumbs up emoji should we use in the docs", expectsEmoji: false, note: "meta: about the emoji"),
        Sample(text: "our designer is updating the rocket emoji", expectsEmoji: false, note: "meta: about the emoji"),
        Sample(text: "the check emoji got a new look in the update", expectsEmoji: false, note: "meta: about the emoji"),
        // no "emoji" word: generator must produce nothing.
        Sample(text: "the fire spread quickly through the forest", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "she has a heart of gold", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "the rocket launched at dawn", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "let us throw a party this weekend", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "keep your eyes on the road", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "i scored one hundred on the exam", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "please do not cry over spilled milk", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "we pray every sunday morning", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "everything looks ok to me", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "double check the numbers before sending", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "there was no warning before the storm", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "the north star guided the sailors home", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "the muscle in his shoulder was sore", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "he had a sudden change of heart", expectsEmoji: false, note: "no trigger word"),
        // word-boundary trap: "fire" inside "firefighter".
        Sample(text: "the firefighter emoji request came in today", expectsEmoji: false, note: "boundary: firefighter"),
        // "emoji" present but preceded by a non-name word.
        Sample(text: "our team will discuss the emoji picker design", expectsEmoji: false, note: "no valid name before emoji"),
        Sample(text: "please add an emoji reaction to the message", expectsEmoji: false, note: "no valid name before emoji"),
        Sample(text: "the star of the show arrived late", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "we found a bug in the payment flow", expectsEmoji: false, note: "no trigger word"),
        Sample(text: "the party emoji and the fire emoji are trending", expectsEmoji: false, note: "meta: two names, about emojis"),
    ]

    // MARK: - Runner

    /// Fire-and-forget entry point convenient from the LLDB console.
    static func runDetached() {
        Task { await run() }
    }

    /// Run the full eval and print a per-case log plus a precision / recall
    /// summary for the positive (glyph-expected) class.
    @MainActor
    static func run() async {
        let bridge = CleanupPipelineBridge()

        // Production-like config: all categories on (incl. emoji), English
        // locale, capitalization + trailing scoring enabled.
        var config = TranscriptionCleanup.PipelineConfig.default()
        config.capitalizationEnabled = true
        config.trailingPunctScoringEnabled = true
        config.trailingSpaceScoringEnabled = true

        print("========== Emoji Replacement Eval ==========")
        print("cases: \(dataset.count)")
        print("--------------------------------------------")

        var truePositive = 0
        var falseNegative = 0
        var falsePositive = 0
        var trueNegative = 0
        var errors = 0
        var misclassified: [String] = []

        for sample in dataset {
            let output: String
            do {
                output = try await bridge.process(sample.text, config: config)
            } catch {
                errors += 1
                print("ERROR  \"\(sample.text)\" -> \(error)")
                continue
            }

            let predicted = containsEmoji(output)
            let correct = predicted == sample.expectsEmoji
            let expectedTag = sample.expectsEmoji ? "POS" : "NEG"
            let mark = correct ? "ok  " : "MISS"

            print("\(mark) [\(expectedTag)] \"\(sample.text)\"")
            print("        -> \"\(output)\"  (\(sample.note))")

            switch (sample.expectsEmoji, predicted) {
            case (true, true): truePositive += 1
            case (true, false):
                falseNegative += 1
                misclassified.append("FN (missed glyph): \"\(sample.text)\" -> \"\(output)\"")
            case (false, true):
                falsePositive += 1
                misclassified.append("FP (spurious glyph): \"\(sample.text)\" -> \"\(output)\"")
            case (false, false): trueNegative += 1
            }
        }

        let precisionDen = truePositive + falsePositive
        let recallDen = truePositive + falseNegative
        let precision = precisionDen > 0 ? Double(truePositive) / Double(precisionDen) : 0
        let recall = recallDen > 0 ? Double(truePositive) / Double(recallDen) : 0
        let f1 = (precision + recall) > 0 ? 2 * precision * recall / (precision + recall) : 0

        print("--------------------------------------------")
        print("positives: \(truePositive + falseNegative)  negatives: \(falsePositive + trueNegative)  errors: \(errors)")
        print(String(format: "TP=%d  FN=%d  FP=%d  TN=%d", truePositive, falseNegative, falsePositive, trueNegative))
        print(String(format: "precision=%.3f  recall=%.3f  f1=%.3f", precision, recall, f1))
        if !misclassified.isEmpty {
            print("---- misclassified ----")
            for line in misclassified { print(line) }
        }
        print("============================================")
    }

    // MARK: - Emoji Detection

    /// Whether `text` contains at least one emoji pictograph. Covers the ranges
    /// used by the curated emoji set: the supplementary emoji planes plus the
    /// Miscellaneous Symbols / Dingbats / Misc-Symbols-and-Arrows blocks that
    /// hold star, warning, heart, sparkles, coffee, sun, and friends.
    static func containsEmoji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmojiPresentation { return true }
            if scalar.value >= 0x1F000 && scalar.properties.isEmoji { return true }
            if (0x2600...0x27BF).contains(scalar.value) { return true }
            if (0x2B00...0x2BFF).contains(scalar.value) { return true }
        }
        return false
    }
}
#endif

#endif // canImport(TranscriptionCleanup)
