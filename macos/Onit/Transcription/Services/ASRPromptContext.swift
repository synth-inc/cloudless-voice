// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRPromptContext.swift
//  Onit
//
//  Model-agnostic side-channel for injecting prompt context into the MLX ASR
//  models that support it (Qwen3 `context:`, Granite `userPrompt:`).
//
//  The `MLXTranscriber` protocol is `transcribe(samples:language:)` with no
//  context parameter, and is shared by every MLX model - so rather than thread
//  a `context:` arg through the whole engine/service chain, `TranscriptionManager`
//  stages the payload here once per transcription and the Qwen3/Granite
//  transcribers read it. Non-MLX backends never touch it.
//
//  Carries the custom-dictionary glossary today; the preceding-text "run-up"
//  feature will add a `precedingText` field to the same payload.
//

import Foundation

/// Thread-safe holder + per-model prompt formatters. Not an actor: the
/// transcribers run on the `MLXASREngine` actor and need a synchronous read
/// from inside `transcribe(samples:language:)`.
final class ASRPromptContext: @unchecked Sendable {
    static let shared = ASRPromptContext()

    /// What `TranscriptionManager` stages before each transcription.
    struct Payload: Sendable, Equatable {
        var dictionaryTerms: [String] = []
        // var precedingText: String? = nil   // (added by the run-up feature)

        var isEmpty: Bool { dictionaryTerms.isEmpty }
    }

    /// Cap the glossary so the prompt doesn't crowd the model's token budget.
    /// Raised to 100: a sweep showed Qwen3 (64K ctx) handles ≥50 terms with no WER
    /// or latency cost; 100 is a conservative step. Granite (4K ctx) is tighter -
    /// pending its own sweep - but 100 terms (~few-hundred tokens) still fits.
    private static let maxTerms = 100

    private let lock = NSLock()
    private var payload = Payload()

    private init() {}

    /// Called once per transcription (empty payload when the feature is off).
    func set(_ payload: Payload) {
        lock.lock(); defer { lock.unlock() }
        self.payload = payload
        #if DEBUG || ONIT_BETA
        // New utterance, new capture: backends that never resolve a prompt
        // (Parakeet/Whisper/Moonshine…) must not inherit the previous MLX
        // dictation's prompt - history rows would pair it with the wrong model.
        _lastResolvedPrompt = nil
        #endif
    }

    /// The staged payload, so a path that stages its own can put the previous one back.
    func snapshot() -> Payload {
        lock.lock(); defer { lock.unlock() }
        return payload
    }

    // MARK: - Decode-time trie boost (experimental)

    /// Settings for token-trie shallow-fusion boosting in the Qwen3 decoder
    /// (`Qwen3DecodingOptions.boostTerms`). Off by default; evals and the
    /// debug UI toggle it. Terms come from the same staged payload as the
    /// prompt glossary, so both layers always see the same dictionary.
    struct TrieBoost: Sendable, Equatable {
        var enabled = false
        var strength: Float = 4.0
        var maxBacktracks = 16
        /// Canonical term → known mishearings, rewritten to the canonical on
        /// completion (the term's commonMistakes list is the natural source).
        var aliases: [String: [String]] = [:]
    }

    private var _trieBoost = TrieBoost()
    var trieBoost: TrieBoost {
        lock.lock(); defer { lock.unlock() }
        return _trieBoost
    }
    func setTrieBoost(_ settings: TrieBoost) {
        lock.lock(); _trieBoost = settings; lock.unlock()
    }

    /// Terms to boost at decode time: the staged dictionary terms when the
    /// feature is on, empty otherwise (callers treat empty as "off").
    func trieBoostTerms() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _trieBoost.enabled ? payload.dictionaryTerms : []
    }

    /// Atomic snapshot of the boost staging: terms + settings under ONE lock,
    /// so a concurrent re-stage can never pair one dictation's terms with
    /// another's aliases/strength (review finding: torn read).
    func trieBoostStaging() -> (terms: [String], settings: TrieBoost) {
        lock.lock(); defer { lock.unlock() }
        return (_trieBoost.enabled ? payload.dictionaryTerms : [], _trieBoost)
    }

    // MARK: - Debug capture

    #if DEBUG || ONIT_BETA
    private var _lastResolvedPrompt: String?
    /// The most recent prompt actually returned to a transcriber, for the
    /// Perplexity Debug window. nil when prompt-biasing produced no prompt.
    var lastResolvedPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastResolvedPrompt
    }
    private func recordResolved(_ prompt: String?) {
        lock.lock(); _lastResolvedPrompt = prompt; lock.unlock()
    }

    /// Benchmark/test override: when non-nil, `qwenSystemPrompt()` returns this
    /// verbatim (bypassing the glossary builder), so the prompt-iteration bench
    /// can A/B instruction wordings against real audio. Set nil to clear.
    private var _promptOverride: String?
    var promptOverride: String? { lock.lock(); defer { lock.unlock() }; return _promptOverride }
    func setPromptOverride(_ prompt: String?) { lock.lock(); _promptOverride = prompt; lock.unlock() }

    private var _lastOnScreenTerms: [String] = []
    private var _lastOnScreenOCRText: String?
    private var _lastOnScreenSource: String?
    private var _lastOnScreenDecisions: [CapsTermSelector.Decision] = []
    private var _lastOnScreenScreenshot: String?
    private var _lastOnScreenHasCommonList = true
    /// Layer C: the mined terms, raw OCR blob, per-token decision trace, saved
    /// screenshot filename, and whether the OOV word-list loaded - all surfaced in
    /// the Perplexity Debug window so term selection can be diagnosed.
    var lastOnScreenTerms: [String] { lock.lock(); defer { lock.unlock() }; return _lastOnScreenTerms }
    var lastOnScreenOCRText: String? { lock.lock(); defer { lock.unlock() }; return _lastOnScreenOCRText }
    /// Human-readable capture source ("OCR" / "Accessibility …") for the debug UI.
    var lastOnScreenSource: String? { lock.lock(); defer { lock.unlock() }; return _lastOnScreenSource }
    var lastOnScreenDecisions: [CapsTermSelector.Decision] { lock.lock(); defer { lock.unlock() }; return _lastOnScreenDecisions }
    var lastOnScreenScreenshot: String? { lock.lock(); defer { lock.unlock() }; return _lastOnScreenScreenshot }
    var lastOnScreenHasCommonList: Bool { lock.lock(); defer { lock.unlock() }; return _lastOnScreenHasCommonList }
    func recordOnScreenMining(terms: [String], ocrText: String?,
                              decisions: [CapsTermSelector.Decision] = [],
                              screenshot: String? = nil, hasCommonList: Bool = true,
                              source: String? = nil) {
        lock.lock()
        _lastOnScreenTerms = terms
        _lastOnScreenOCRText = ocrText
        _lastOnScreenDecisions = decisions
        _lastOnScreenScreenshot = screenshot
        _lastOnScreenHasCommonList = hasCommonList
        _lastOnScreenSource = source
        lock.unlock()
    }

    private var _lastFormatBefore: String?
    private var _lastFormatAfter: String?
    private var _lastFormatEnabled = false
    private var _lastFormatTermCount = 0
    private var _lastFormatReplacements: [(spoken: String, term: String)] = []
    private var _lastFormatVetoed: [(spoken: String, term: String)] = []
    /// Layer-B format matcher: the ASR text before/after dictionary-format restore,
    /// plus enough status (enabled? how many terms? which replacements, from which
    /// term?) for the debug view to explain every change - or the absence of one.
    var lastFormatBefore: String? { lock.lock(); defer { lock.unlock() }; return _lastFormatBefore }
    var lastFormatAfter: String? { lock.lock(); defer { lock.unlock() }; return _lastFormatAfter }
    var lastFormatEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _lastFormatEnabled }
    var lastFormatTermCount: Int { lock.lock(); defer { lock.unlock() }; return _lastFormatTermCount }
    var lastFormatReplacements: [(spoken: String, term: String)] {
        lock.lock(); defer { lock.unlock() }; return _lastFormatReplacements
    }
    /// Merges the perplexity gate refused (ambiguous span read better as a phrase).
    var lastFormatVetoed: [(spoken: String, term: String)] {
        lock.lock(); defer { lock.unlock() }; return _lastFormatVetoed
    }
    func recordFormatMatch(before: String, after: String, enabled: Bool, termCount: Int,
                           replacements: [(spoken: String, term: String)] = [],
                           vetoed: [(spoken: String, term: String)] = []) {
        lock.lock()
        _lastFormatBefore = before
        _lastFormatAfter = after
        _lastFormatEnabled = enabled
        _lastFormatTermCount = termCount
        _lastFormatReplacements = replacements
        _lastFormatVetoed = vetoed
        lock.unlock()
    }
    #endif

    // MARK: - Glossary

    /// First words of the glossary clause - the prompt-echo sentinel. On silent
    /// or near-empty audio, Qwen3 occasionally ECHOES the glossary prompt back
    /// as its "transcription". Any transcript starting with these words is
    /// prompt echo, never real speech. `glossaryClause` builds from this same
    /// constant so the prompt text and the detector can't drift apart.
    static let glossaryEchoPrefix = "The audio may mention these names"

    /// True when `transcript` is the model echoing our glossary prompt.
    static func isPromptEcho(_ transcript: String) -> Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix(glossaryEchoPrefix.lowercased())
    }

    /// "…use these exact spellings: A, B, C." - the natural-language format that
    /// beat bare CSV in the dictionary eval. Returns nil when there are no terms.
    /// Internal (not private) so the prompt eval bench measures THIS string
    /// instead of a drifting copy.
    func glossaryClause(_ terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        // One cap for all modes. An earlier revision capped harder (25) while
        // trie boosting to guard against glossary echo, but field data showed
        // echo occurs below any useful cap (24-term echo, history row 8740 -
        // silence reaching the ASR, a VAD gap) while the tight cap silently
        // starved screen-mined terms out of the prompt (the Lukwise miss).
        let capped = Array(cleaned.prefix(Self.maxTerms))
        // The no-spaces reinforcement is scoped to "terms written without
        // spaces": stated unconditionally it pushed the model to glue
        // legitimate multi-word terms together ("Synth Inc" → "SynthInc").
        return Self.glossaryEchoPrefix + " and technical terms. Write each "
            + "one EXACTLY as spelled here - keep its capitalization and formatting "
            + "(camelCase, PascalCase, snake_case, kebab-case). Terms written "
            + "without spaces are single words: never insert spaces into them, "
            + "even when they sound like several separate words: "
            + capped.joined(separator: ", ") + "."
    }

    // MARK: - Per-model formatters

    /// Qwen3 `context:` - injected as a system message, so the transcription
    /// task is implicit; we pass only the glossary. Nil = no biasing.
    func qwenSystemPrompt() -> String? {
        #if DEBUG || ONIT_BETA
        if let override = promptOverride {
            recordResolved(override)
            return override
        }
        #endif
        let prompt = glossaryClause(snapshot().dictionaryTerms)
        #if DEBUG || ONIT_BETA
        recordResolved(prompt)
        #endif
        return prompt
    }

    /// Granite `userPrompt:` - REPLACES the model's default transcription
    /// instruction (GraniteSpeech `Model.buildPrompt`: `userPrompt ?? defaultPrompt`),
    /// so the glossary must be paired with an explicit instruction. Nil = no
    /// biasing (Granite then falls back to its own default prompt).
    func granitePrompt() -> String? {
        #if DEBUG || ONIT_BETA
        if let override = promptOverride {
            recordResolved(override)
            return override
        }
        #endif
        let prompt = glossaryClause(snapshot().dictionaryTerms).map {
            "can you transcribe the speech into a written format? " + $0
        }
        #if DEBUG || ONIT_BETA
        recordResolved(prompt)
        #endif
        return prompt
    }
}
