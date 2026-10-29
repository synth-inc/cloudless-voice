// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionTermMiner.swift
//  Onit
//
//  Mines candidate dictionary terms from a user's live transcript correction,
//  using the same orthographic criteria as on-screen term mining (CapsTermSelector:
//  structured identifiers - camelCase / ALLCAPS / underscore - or out-of-vocabulary
//  words). This replaces the older diff-based detector's hand-tuned heuristics
//  (uppercase requirement + per-locale function-word denylist) with the shared,
//  data-driven selector.
//
//  A candidate is a term the user actually introduced in the correction: it
//  passes the caps/OOV criteria and does not appear verbatim (as a whole token,
//  case-sensitively) in the raw transcript - so casing fixes ("onit" → "Onit")
//  and respellings ("caps selective" → "capsSelected") qualify, while words the
//  ASR already got right do not. Terms already in the dictionary ARE returned -
//  the bar renders them as already-enabled chips (clear "it's in your
//  dictionary" state) rather than silently hiding them.
//

import Foundation

enum CorrectionTermMiner {

    /// Candidate terms the user introduced in `correction` relative to `raw`.
    /// Order follows the selector's OOV-first ranking. Pure and synchronous -
    /// cheap enough to run per keystroke (the caller debounces).
    static func newTerms(correction: String, raw: String) -> [String] {
        let trimmed = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rawTokens = Set(tokenize(raw))

        return CapsTermSelector.shared.selectCapsTerms(trimmed)
            .filter { !rawTokens.contains($0) }          // case-sensitive: casing fixes count
    }

    /// Whole alphanumeric-ish tokens (keeps `_`, `-`, `'` like the selector's
    /// tokenizer) - used for the "already in the raw transcript" check.
    private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "'" })
            .map(String.init)
    }
}
