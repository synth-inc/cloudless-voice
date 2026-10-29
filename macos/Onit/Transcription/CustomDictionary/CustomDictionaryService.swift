// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryService.swift
//  Onit
//
//  Singleton service managing the custom dictionary CTC biasing feature.
//

import Combine
import Defaults
import Foundation
import SwiftUI

/// Manages custom vocabulary terms and applies CTC biasing to TDT transcripts.
@MainActor
final class CustomDictionaryService: ObservableObject {

    // MARK: - Singleton

    static let shared = CustomDictionaryService()

    // MARK: - Published State

    @Published private(set) var isEnabled = false
    @Published var terms: [CustomDictionaryTerm] = []
    @Published private(set) var isModelReady = false
    @Published private(set) var isLoading = false
    /// Terms detected from user corrections, awaiting the user's accept/dismiss decision.
    @Published private(set) var pendingSuggestions: [String] = []
    /// True while a history scan is in progress.
    @Published private(set) var isScanning = false

    // MARK: - Private

    /// Holds the in-flight warmup/enable task so it is never fire-and-forget.
    /// Reassigned (and the previous one cancelled) whenever a new warmup is
    /// scheduled - e.g. auto-warmup on app launch followed by an auto-enable
    /// from `addTerm`. Both paths ultimately call `loadModelIfNeeded`, so a
    /// single slot is sufficient.
    private var warmupTask: Task<Void, Never>?

    /// Fingerprint of the `terms` array at the time the KWS model was last loaded.
    /// When it diverges from `currentTermsKey()`, `persistTerms()` schedules
    /// a reload so new / renamed / removed terms are always reflected.
    private var kwsLoadedKey: [Int]?

    // MARK: - Initialization

    private init() {
        isEnabled = Defaults[.customDictionaryEnabled]
        terms = Defaults[.customDictionaryTermsV2]
        pendingSuggestions = Defaults[.customDictionaryPendingSuggestions]
        cleanupLegacyStorage()

        // Warm up the CTC model on startup when the feature was left enabled.
        // `isModelReady` is in-memory only (not persisted), so it resets to
        // false on every launch - without this task nothing would reload the
        // model, and `rescore()` would silently short-circuit on its
        // `isModelReady` guard until the user manually toggled the feature
        // off/on or added a new term.
        if isEnabled {
            warmupTask = Task { [weak self] in
                await self?.loadModelIfNeeded()
            }
        }
    }

    /// Drops the legacy `customDictionaryTerms: [String]` UserDefaults key from BETA
    /// builds. The schema change to `[CustomDictionaryTerm]` (with `id` + `createdAt`)
    /// intentionally resets BETA testers' terms - this method just clears the orphan
    /// key and emits a warning so support can correlate "my terms disappeared" reports
    /// with the migration instead of treating them as a bug.
    ///
    /// Short-circuits via `customDictionaryLegacyCleared` so subsequent launches don't
    /// probe UserDefaults again.
    private func cleanupLegacyStorage() {
        guard !Defaults[.customDictionaryLegacyCleared] else { return }
        let legacyKey = "customDictionaryTerms"
        let storage = UserDefaults.standard
        if let legacy = storage.array(forKey: legacyKey) as? [String], !legacy.isEmpty {
            log.warning(
                "CustomDictionaryService: discarding \(legacy.count) legacy term(s) from BETA storage (V1 → V2 migration; reset by design)"
            )
            storage.removeObject(forKey: legacyKey)
        }
        Defaults[.customDictionaryLegacyCleared] = true
    }

    /// All term texts (manual + pending) used as the de-dup baseline by the
    /// suggestion detector. Centralised so the two call sites stay in sync.
    private var allKnownTermTexts: [String] {
        terms.map(\.text) + pendingSuggestions
    }

    // MARK: - Enable / Disable

    func enable() async {
        guard !isEnabled else { return }
        isEnabled = true
        Defaults[.customDictionaryEnabled] = true
        // Perplexity (MLXScoringEngine) is a hard dependency for `NLLGate`,
        // `ProxySelector`, `CalibrationManager`. Tell the warmup coordinator so it
        // loads Llama 3.2 1B if no other consumer (smart formatting / LM conditioning)
        // has already brought it in - otherwise the dictionary silently rejects every
        // candidate from `loadModelIfNeeded()` onward.
        await MainActor.run { WarmupCoordinator.shared.featureStateChanged() }
        await loadModelIfNeeded()
    }

    func disable() {
        isEnabled = false
        Defaults[.customDictionaryEnabled] = false
        // Symmetric with `enable()` - drop Llama 3.2 1B if no other consumer keeps
        // it alive. Without this, ~1.25 GB of MLX/Metal memory stays resident even
        // after the user has explicitly turned off every dictionary-driven feature.
        Task { @MainActor in WarmupCoordinator.shared.featureStateChanged() }
    }

    /// Force a model reload on the next rescore. Called after calibration scans
    /// that temporarily replace the keyword set with a single term's keywords.
    func invalidateModel() {
        guard isEnabled else { return }
        isModelReady = false
        kwsLoadedKey = nil
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in await self?.loadModelIfNeeded() }
    }

    /// Load (or reload) the KWS model with keyword variants derived from `terms`.
    ///
    /// Safe to call repeatedly - no-ops when the model is already loaded with the
    /// current term set. Re-entrant calls while a load is in progress are dropped.
    func loadModelIfNeeded() async {
        guard isEnabled else { return }
        guard !isLoading else { return }
        let newKey = currentTermsKey()
        guard !isModelReady || kwsLoadedKey != newKey else { return }

        isLoading = true
        defer { isLoading = false }

        // Whisper KWS only helps backends that expose per-word timestamps for
        // span alignment - currently Parakeet. Other backends (Qwen3/Granite/…)
        // recover dictionary terms via the prompt (Qwen/Granite, Layer B) and the
        // universal text common-mistakes + Llama-NLL-gate path (Layer A), neither
        // of which needs the KWS model. Skip the ~Whisper load on those (saves
        // RAM) and mark ready so the text path proceeds.
        guard Defaults[Defaults.Keys.TranscriptionConfigKeys.backend] == .parakeetCoreML else {
            isModelReady = true
            kwsLoadedKey = newKey
            log.info("CustomDictionaryService: non-Parakeet backend - text + NLL-gate path only (no Whisper KWS load)")
            return
        }

        let whisperKeywords = terms.map(\.text)
        guard !whisperKeywords.isEmpty else {
            isModelReady = true
            kwsLoadedKey = newKey
            return
        }

        do {
            try await WhisperKwsService.shared.loadIfNeeded(keywords: whisperKeywords)
            isModelReady = true
            kwsLoadedKey = newKey
            log.info("CustomDictionaryService: Whisper KWS ready - \(whisperKeywords.count) term(s)")
        } catch {
            log.error("CustomDictionaryService: Whisper KWS load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Terms Management

    /// Add a new term to the dictionary. Auto-enables the feature on first add.
    /// Duplicate detection is case-insensitive. Returns the new term so the
    /// caller can trigger calibration.
    @discardableResult
    func addTerm(_ text: String) -> CustomDictionaryTerm? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let needle = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.textLowercased == needle })
        else { return nil }
        let newTerm = CustomDictionaryTerm(text: trimmed)
        terms.append(newTerm)
        persistTerms()

        if !isEnabled {
            warmupTask?.cancel()
            warmupTask = Task { [weak self] in
                await self?.enable()
            }
        }
        return newTerm
    }

    /// Update a term's NLL calibration metadata (proxy word, threshold, state).
    /// Used by `CustomDictionaryCalibrationManager` to persist calibration results.
    func updateTerm(_ updated: CustomDictionaryTerm) {
        guard let idx = terms.firstIndex(where: { $0.id == updated.id }) else { return }
        terms[idx] = updated
        persistTerms()
    }

    func removeTerm(at offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        persistTerms()
    }

    /// Remove the first term matching `text` (case-insensitive).
    func removeTerm(_ text: String) {
        let needle = text.lowercased()
        terms.removeAll { $0.textLowercased == needle }
        persistTerms()
    }

    /// Remove a term by its stable identifier (preferred for UI lists).
    func removeTerm(id: UUID) {
        terms.removeAll { $0.id == id }
        persistTerms()
    }

    /// Rename a term in place. Preserves `id` and `createdAt`. No-op if the new
    /// text is empty or would clash with another existing term (case-insensitive).
    func renameTerm(id: UUID, to newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = terms.firstIndex(where: { $0.id == id })
        else { return }
        let needle = trimmed.lowercased()
        let conflict = terms.contains { $0.id != id && $0.textLowercased == needle }
        guard !conflict else { return }
        terms[index].text = trimmed
        persistTerms()
    }

    private func persistTerms() {
        Defaults[.customDictionaryTermsV2] = terms
        // Invalidate the KWS model whenever the term set changes so the
        // next rescore() uses keywords that reflect the new term list.
        if isEnabled, isModelReady, kwsLoadedKey != currentTermsKey() {
            isModelReady = false
            warmupTask?.cancel()
            warmupTask = Task { [weak self] in await self?.loadModelIfNeeded() }
        }
    }

    /// Add `span` as a common-mistake on the term with id `termID`. Used by
    /// the calibration flow - when the user confirms "yes, this sentence is
    /// about <term>", the matched span (e.g. "on it") becomes a deterministic
    /// substring trigger for future dictations.
    ///
    /// No-op when:
    ///   - the term doesn't exist
    ///   - the span is empty after trimming
    ///   - the span equals the term text itself (case-insensitive - adding
    ///     "Onit" as a mistake of "Onit" creates a self-replacement loop)
    ///   - the span already exists in `commonMistakes` (case-insensitive dedup)
    func addCommonMistake(termID: UUID, span: String) {
        let trimmed = span.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = terms.firstIndex(where: { $0.id == termID })
        else { return }
        let normalizedSpan = trimmed.lowercased()
        guard normalizedSpan != terms[idx].textLowercased else { return }
        let alreadyHas = terms[idx].commonMistakes.contains { $0.lowercased() == normalizedSpan }
        guard !alreadyHas else { return }
        terms[idx].commonMistakes.append(trimmed)
        log.info("CustomDictionaryService: learned a common-mistake spelling (\(LogPrivacy.summary(trimmed)))")
        persistTerms()
    }

    // MARK: - Suggestions

    /// Detect candidate terms from a single correction and queue any new suggestions.
    ///
    /// Safe to call from any context - detection is synchronous and cheap.
    /// Dedup is checked **twice**: once against the dictionary/pending
    /// snapshot taken when the Task is scheduled, and a second time at
    /// append-time against the then-current state. The re-check closes a
    /// TOCTOU window where two concurrent corrections (or a correction
    /// racing a manual `addTerm`) could otherwise both propose the same
    /// candidate and leave a duplicate in `pendingSuggestions`.
    nonisolated func detectAndQueueSuggestions(raw: String, corrected: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let detector = CustomDictionaryTermDetector(
                language: LocalizationManager.shared.currentLanguage
            )
            let candidates = detector.detect(
                raw: raw,
                corrected: corrected,
                existingTerms: self.allKnownTermTexts
            )
            guard !candidates.isEmpty else { return }

            // Re-read the current state on the main actor at append time;
            // `self.allKnownTermTexts` above was computed when the Task
            // started, but another correction or manual add may have
            // landed in between.
            let knownNow = Set(self.allKnownTermTexts.map { $0.lowercased() })
            var appended = false
            for candidate in candidates {
                let key = candidate.term.lowercased()
                guard !knownNow.contains(key) else { continue }
                guard !self.pendingSuggestions.contains(where: { $0.lowercased() == key }) else { continue }
                self.pendingSuggestions.append(candidate.term)
                appended = true
            }
            if appended {
                Defaults[.customDictionaryPendingSuggestions] = self.pendingSuggestions
            }
        }
    }

    /// Accept a suggestion: add it to the dictionary and remove from pending.
    func acceptSuggestion(_ term: String) {
        addTerm(term)
        dismissSuggestion(term)
    }

    /// Dismiss a suggestion without adding it.
    func dismissSuggestion(_ term: String) {
        pendingSuggestions.removeAll { $0 == term }
        Defaults[.customDictionaryPendingSuggestions] = pendingSuggestions
    }

    /// Scan all stored correction pairs from history and queue detected candidates.
    ///
    /// The actual LCS-based `detectAll` pass is dispatched to a detached
    /// background task so the Settings UI doesn't freeze on databases with
    /// hundreds of corrections (LCS is O(n·m) per pair). Only the final
    /// append back into `pendingSuggestions` runs on the main actor.
    func scanHistoryForSuggestions() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let pairs = await TranscriptionHistoryManager.shared.fetchAllCorrectionPairs()
        guard !pairs.isEmpty else { return }

        // Snapshot the existing term list (Sendable [String]) and current
        // language so the detached task can dedup + pick the right denylist
        // without capturing the service or hopping back to MainActor.
        let existingTermsSnapshot = allKnownTermTexts
        let language = LocalizationManager.shared.currentLanguage

        let candidates = await Task.detached(priority: .utility) {
            let detector = CustomDictionaryTermDetector(language: language)
            return detector.detectAll(pairs: pairs, existingTerms: existingTermsSnapshot)
        }.value

        guard !candidates.isEmpty else {
            log.info("CustomDictionaryService: History scan found 0 candidate(s) across \(pairs.count) correction(s)")
            return
        }

        // Re-check against the *current* known terms + pending list (which may
        // have grown since the snapshot was taken) before appending. Includes
        // `terms` so a manual add during the scan doesn't create a duplicate suggestion.
        let pendingNow = Set(allKnownTermTexts.map { $0.lowercased() })
        var appended = 0
        for candidate in candidates {
            let key = candidate.term.lowercased()
            guard !pendingNow.contains(key) else { continue }
            pendingSuggestions.append(candidate.term)
            appended += 1
        }
        if appended > 0 {
            Defaults[.customDictionaryPendingSuggestions] = pendingSuggestions
        }
        log.info("CustomDictionaryService: History scan found \(appended) new candidate(s) across \(pairs.count) correction(s)")
    }

    // MARK: - Rescoring

    func rescore(
        transcript: String,
        audioSamples: [Float],
        wordTimestamps: [WordTimestamp]? = nil
    ) async -> String {
        // Record an early-return entry on guard failures so the debug view
        // tells us *why* nothing happened - silent short-circuits made bugs
        // un-debuggable. Inline here so it runs before the guards.
#if DEBUG
        let activeKeywords = terms.map(\.text)
        let activeTerms = terms.map(\.text)
        func recordKWS(
            output: String,
            raw: [KWSDetection] = [],
            relevant: [KWSDetection] = [],
            termMap: [String: CustomDictionaryTerm] = [:],
            evaluations: [GateEvaluation] = [],
            cmReplacements: [DictionaryReplacement] = [],
            error: String? = nil
        ) {
            // Audio-level detection info only - gate decisions live in the
            // `evaluations` list (one entry per replacement). Earlier code
            // tried to attach traces to detections by term-text lookup, which
            // collapsed multiple evaluations of the same term onto one trace.
            let toResult = { (d: KWSDetection) -> KWSDetectionResult in
                let termText = termMap[d.keyword]?.text
                // Surface *an* aligned span for the detection's row, if any
                // evaluation matched this term. Multiple evaluations may have
                // produced different spans for the same term - the gate
                // evaluations section is the place to see them all. Here we
                // pick the first matching span as a hint, not as gate state.
                let span = evaluations.first(where: { $0.termText == termText })?.originalSpan
                return KWSDetectionResult(
                    keyword: d.keyword, startSec: d.startSec, endSec: d.endSec,
                    matchedTerm: termText, originalSpan: span
                )
            }
            let cmMatches = cmReplacements.map { r in
                // Find the evaluation produced from this specific common-mistake
                // replacement so the REPLACED / REJECTED badge reflects this
                // match's own decision, not some other evaluation's.
                let eval = evaluations.first(where: {
                    $0.source == .commonMistake &&
                    $0.termText == r.term.text &&
                    $0.originalSpan == r.originalSpan
                })
                return CommonMistakeMatch(
                    span: r.originalSpan,
                    matchedTerm: r.term.text,
                    accepted: eval?.trace.accepted
                )
            }
            let entry = KWSDebugEntry(
                transcript: transcript, output: output,
                rawDetections: raw.map(toResult),
                relevantDetections: relevant.map(toResult),
                commonMistakeMatches: cmMatches,
                gateEvaluations: evaluations,
                activeKeywords: activeKeywords, activeTerms: activeTerms, error: error
            )
            Task { @MainActor in KWSDebugHistory.shared.record(entry) }
        }
        if !isEnabled {
            recordKWS(output: transcript, error: "skipped: customDictionary disabled")
            return transcript
        }
        // Do NOT gate on `isModelReady` (= Whisper KWS loaded): the text
        // common-mistakes + Llama-NLL-gate path is universal and backend-agnostic
        // (Layer A). The KWS *audio* path below self-gates on readiness + word
        // timestamps, so it stays Parakeet-only. (Matches the release guard, which
        // omits isModelReady.)
        if terms.isEmpty {
            recordKWS(output: transcript, error: "skipped: no terms in dictionary")
            return transcript
        }
        if transcript.isEmpty {
            recordKWS(output: transcript, error: "skipped: empty transcript")
            return transcript
        }
#else
        guard isEnabled, !terms.isEmpty, !transcript.isEmpty else { return transcript }
#endif

        // Layer A (post-decode confusions + proxy + NLL-gate substitution) is OFF
        // by default - the dictionary ships via Layer B prompt biasing on
        // Qwen3/Granite. The proxy/gate is the historical weak link (unreliable
        // proxy selection), so it's behind an opt-in flag rather than deleted.
        // The flag gates ONLY this text path: Whisper-KWS rescoring on Parakeet
        // is the pre-existing audio path and stays active by default.
        let layerAEnabled = Defaults[.customDictionaryRescoreEnabled]

        let words = transcript.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return transcript }

        // Deterministic substring match against each term's `commonMistakes`.
        // Independent of audio + KWS - so a calibrated term has a fallback path
        // through perplexity even when KWS doesn't fire. Layer A opt-in.
        let cmReplacements = layerAEnabled ? buildCommonMistakeReplacements(words: words) : []

        // KWS path - audio-dependent, may be skipped or fail without aborting
        // the rescore (the common-mistakes path can still produce output).
        var kwsDetections: [KWSDetection] = []
        var kwsRelevant: [KWSDetection] = []
        var kwsTermMap: [String: CustomDictionaryTerm] = [:]
        var kwsReplacements: [DictionaryReplacement] = []
        var kwsError: String? = nil

#if DEBUG
        let kwsDisabled = Defaults[.customDictionaryDisableKWS]
        if kwsDisabled {
            kwsError = "DEBUG: KWS disabled via debug toggle"
        }
#else
        let kwsDisabled = false
#endif

        // KWS replacement requires aligned per-word audio timings. When the
        // ASR backend can't supply them (FluidAudio, chunked >15s Parakeet) or
        // when post-decode rewrites changed the word count we couldn't reconcile,
        // we skip KWS entirely. A position-blind whole-transcript Levenshtein
        // scan would silently revert to the "every 'it' got replaced" failure
        // mode this PR fixes - the deterministic commonMistakes substring path
        // still runs.
        let exactRanges = alignedWordTimeRanges(words: words, asrTimings: wordTimestamps)

        if isModelReady && !audioSamples.isEmpty && !kwsDisabled, let exactRanges {
            do {
                kwsDetections = try await WhisperKwsService.shared.detectKeywords(in: audioSamples)
                kwsTermMap = buildTermKeywordMap()
                kwsRelevant = kwsDetections.filter { kwsTermMap[$0.keyword] != nil }

                if !kwsRelevant.isEmpty {
                    kwsReplacements = buildReplacements(
                        detections: kwsRelevant,
                        termByKeyword: kwsTermMap,
                        words: words,
                        wordTimeRanges: exactRanges
                    )
                }
            } catch {
                log.error("CustomDictionaryService: KWS error: \(error.localizedDescription)")
                kwsError = error.localizedDescription
            }
        } else if isModelReady && !audioSamples.isEmpty && !kwsDisabled {
            // Audio present but no aligned timings → record the skip in the
            // debug history so the dictionary debug view shows *why* KWS was
            // bypassed instead of silently producing zero detections.
            kwsError = "skipped: no aligned ASR word timings (audio path bypassed)"
        }

        let allReplacements = cmReplacements + kwsReplacements
        guard !allReplacements.isEmpty else {
#if DEBUG
            recordKWS(
                output: transcript,
                raw: kwsDetections, relevant: kwsRelevant, termMap: kwsTermMap,
                cmReplacements: cmReplacements,
                error: kwsError
            )
#endif
            return transcript
        }

        let sourcedReplacements: [(DictionaryReplacement, GateEvaluationSource)] =
            cmReplacements.map { ($0, .commonMistake) }
            + kwsReplacements.map { ($0, .kws) }

        let (corrected, evaluations) = await applyReplacementsWithGate(
            transcript: transcript,
            sourcedReplacements: sourcedReplacements
        )

        if corrected != transcript {
            log.info("CustomDictionaryService: transcript \(LogPrivacy.summary(transcript)) -> \(LogPrivacy.summary(corrected))")
        }
#if DEBUG
        recordKWS(
            output: corrected,
            raw: kwsDetections, relevant: kwsRelevant, termMap: kwsTermMap,
            evaluations: evaluations,
            cmReplacements: cmReplacements,
            error: kwsError
        )
#endif
        return corrected
    }

    // MARK: - NLL Gate

    /// Per-replacement: ask the gate for a decision against the *original*
    /// transcript. For each accepted decision, compute the precise character
    /// range to replace (using the replacement's word index) and stage a
    /// positioned splice. Splices are applied right-to-left so earlier word
    /// positions stay valid. This makes each gate decision affect ONLY the
    /// occurrence it scored - repeated keywords in the transcript stay
    /// unaffected unless a separate detection / common-mistake match fires
    /// for them.
    ///
    /// Uncalibrated terms (no proxy word) are skipped - a false positive on a
    /// common phrase like "working on it" is worse than a false negative.
    private func applyReplacementsWithGate(
        transcript: String,
        sourcedReplacements: [(DictionaryReplacement, GateEvaluationSource)]
    ) async -> (String, [GateEvaluation]) {
        let gated = sourcedReplacements.filter { $0.0.effectiveProxy != nil }
        guard !gated.isEmpty else {
            let uncalibrated = sourcedReplacements.map { $0.0.term.text }.joined(separator: ", ")
            log.info("CustomDictionaryService: NLL gate skipped all replacements - no proxy word for \(uncalibrated.count) term(s)")
            return (transcript, [])
        }

        // Truth-of-record list. One entry per replacement the gate scored -
        // never collapsed by term text, so the debug view can render each
        // distinct evaluation (different span / different source) on its own.
        var evaluations: [GateEvaluation] = []

        // Phase 1: gate evaluation per replacement (against the unmodified
        // transcript). Stage positioned splices for each accepted decision.
        struct Splice { let charRange: Range<Int>; let output: String }
        var splices: [Splice] = []

        let words = transcript.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for (replacement, source) in gated {
            let decision = await CustomDictionaryNLLGate.shared.evaluate(
                asrSentence: transcript,
                confusionSpan: replacement.originalSpan,
                proxyWord: replacement.effectiveProxy,
                threshold: replacement.term.nllThreshold,
                // Plumb the exact rescorer-emitted word position so the gate
                // scores *this* occurrence of the span, not whichever one
                // substring-search finds first. See feedback memory
                // `feedback_no_linear_timestamp_interpolation.md`.
                spanWordRange: (
                    startWord: replacement.startWordIndex,
                    width: replacement.spanWidth
                )
            )
            if let trace = decision.trace {
                evaluations.append(GateEvaluation(
                    termText: replacement.term.text,
                    originalSpan: replacement.originalSpan,
                    source: source,
                    trace: trace
                ))
            }
            guard decision.accept else {
                log.info(
                    "CustomDictionaryService: NLL gate rejected a replacement (\(LogPrivacy.summary(replacement.originalSpan)) -> \(LogPrivacy.summary(replacement.replacementText)))"
                )
                continue
            }
            guard let positioned = positionedReplacement(
                transcript: transcript, words: words,
                replacement: replacement, applyStyle: decision.applyStyle
            ) else {
                log.warning(
                    "CustomDictionaryService: could not locate a span (\(LogPrivacy.summary(replacement.originalSpan))) in transcript; skipping apply"
                )
                continue
            }
            splices.append(Splice(charRange: positioned.range, output: positioned.output))
            log.info(
                "CustomDictionaryService: NLL gate accepted a replacement (\(LogPrivacy.summary(replacement.originalSpan)) -> \(LogPrivacy.summary(replacement.replacementText))) [\(decision.applyStyle)]"
            )
        }

        guard !splices.isEmpty else { return (transcript, evaluations) }

        // Phase 2a: drop splices whose char ranges overlap an already-staged
        // splice. Two paths (common-mistakes + KWS) can independently propose
        // the same span when both fire on the same audio event; without this
        // filter the right-to-left apply loop would double-replace and corrupt
        // indices. Process in original order so the first proposal wins.
        var staged: [Splice] = []
        for splice in splices {
            let overlapsExisting = staged.contains { existing in
                splice.charRange.overlaps(existing.charRange)
            }
            if !overlapsExisting { staged.append(splice) }
        }

        // Phase 2b: apply right-to-left so earlier indices stay valid through
        // length changes from later splices.
        var chars = Array(transcript)
        for splice in staged.sorted(by: { $0.charRange.lowerBound > $1.charRange.lowerBound }) {
            chars.replaceSubrange(splice.charRange, with: Array(splice.output))
        }
        let result = String(chars)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (result, evaluations)
    }

    /// Compute the precise character range to splice and the replacement text
    /// for a single accepted gate decision. Locates `originalSpan` inside the
    /// word range `[startWordIndex, startWordIndex + spanWidth)` so repeated
    /// keywords in the transcript don't all collapse to the first match.
    /// Extends the range to consume preceding/trailing punctuation per
    /// `applyStyle`, and fences the output with single spaces so the splice
    /// joins cleanly with neighboring text.
    private func positionedReplacement(
        transcript: String,
        words: [String],
        replacement r: DictionaryReplacement,
        applyStyle: NLLGateApplyStyle
    ) -> (range: Range<Int>, output: String)? {
        guard let wordCharStart = charPosition(of: r.startWordIndex, in: transcript) else {
            return nil
        }
        let wordEndIdx = r.startWordIndex + r.spanWidth
        let wordCharEnd: Int
        if wordEndIdx < words.count {
            wordCharEnd = charPosition(of: wordEndIdx, in: transcript) ?? transcript.count
        } else {
            wordCharEnd = transcript.count
        }

        let chars = Array(transcript)
        guard wordCharStart <= wordCharEnd, wordCharEnd <= chars.count else { return nil }
        let wordRangeText = String(chars[wordCharStart..<wordCharEnd])
        guard let spanInRange = wordRangeText.range(of: r.originalSpan, options: .caseInsensitive) else {
            return nil
        }
        let spanStartOffset = wordRangeText.distance(from: wordRangeText.startIndex, to: spanInRange.lowerBound)
        let spanEndOffset = wordRangeText.distance(from: wordRangeText.startIndex, to: spanInRange.upperBound)
        var startIdx = wordCharStart + spanStartOffset
        var endIdx = wordCharStart + spanEndOffset

        var prefix = ""
        var suffix = ""

        if applyStyle.consumePreceding {
            var idx = startIdx
            var sawPunct = false
            while idx > 0 {
                let c = chars[idx - 1]
                if c.isWhitespace { idx -= 1; continue }
                if Self.consumablePunctuation.contains(c) { sawPunct = true; idx -= 1; continue }
                break
            }
            if sawPunct {
                startIdx = idx
                prefix = " "
            }
        }
        if applyStyle.consumeTrailing {
            var idx = endIdx
            var sawPunct = false
            while idx < chars.count {
                let c = chars[idx]
                if c.isWhitespace { idx += 1; continue }
                if Self.consumablePunctuation.contains(c) { sawPunct = true; idx += 1; continue }
                break
            }
            if sawPunct {
                endIdx = idx
                suffix = " "
            }
        }

        return (startIdx..<endIdx, prefix + r.replacementText + suffix)
    }

    /// Returns the character offset where the `n`th non-whitespace word
    /// begins in `text`. Robust to multi-space runs and other whitespace
    /// inconsistencies between the words array and the original transcript.
    private func charPosition(of wordIndex: Int, in text: String) -> Int? {
        var pos = 0
        var wordCount = 0
        var inWord = false
        for c in text {
            if c.isWhitespace {
                inWord = false
            } else {
                if !inWord {
                    if wordCount == wordIndex { return pos }
                    wordCount += 1
                    inWord = true
                }
            }
            pos += 1
        }
        return wordCount == wordIndex ? pos : nil
    }

    /// Punctuation the apply step is willing to consume - must match the
    /// gate's set in `CustomDictionaryNLLGate.consumablePunctuation`.
    private static let consumablePunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\u{2014}", "\u{2013}", "-"
    ]

    // MARK: - KWS Helpers

    /// Map keyword strings emitted by the spotter back to their dictionary term.
    /// Whisper emits the literal term text as `keyword`, so a single direct
    /// entry per term is sufficient.
    private func buildTermKeywordMap() -> [String: CustomDictionaryTerm] {
        var map: [String: CustomDictionaryTerm] = [:]
        for term in terms {
            map[term.text] = term
        }
        return map
    }

    /// Align ASR-reported word timings 1:1 with the transcript's whitespace-
    /// split `words` array. Returns nil when the counts don't match - i.e.
    /// LM conditioning rewrote the word structure or the ASR backend didn't
    /// supply timings - and the caller must skip the audio-time pruning rather
    /// than fall back to interpolation.
    private func alignedWordTimeRanges(
        words: [String],
        asrTimings: [WordTimestamp]?
    ) -> [(start: Double, end: Double)]? {
        guard let asrTimings else {
            log.info("CustomDictionaryService: alignedWordTimeRanges - no ASR timings; skipping time prune")
            return nil
        }
        guard asrTimings.count == words.count else {
            log.info("CustomDictionaryService: alignedWordTimeRanges - count mismatch (transcript=\(words.count), asr=\(asrTimings.count)); skipping time prune")
            return nil
        }
        return asrTimings.map { (Double($0.startSec), Double($0.endSec)) }
    }

    /// For each KWS detection, find the best matching N-gram in the transcript
    /// (using exact ASR-reported time windows + Levenshtein similarity) and
    /// return the corresponding `DictionaryReplacement` candidates.
    ///
    /// `wordTimeRanges` must be ASR-decoder-derived timings aligned 1:1 with
    /// `words`. Callers are responsible for skipping the audio path when
    /// timings aren't available - see the gate in `rescore`.
    ///
    /// Each detection picks its best span independently; if two detections
    /// converge on the same word range (the same audio event spotted twice),
    /// we keep the higher-similarity proposal and drop the duplicate so the
    /// gate doesn't evaluate identical splices.
    private func buildReplacements(
        detections: [KWSDetection],
        termByKeyword: [String: CustomDictionaryTerm],
        words: [String],
        wordTimeRanges: [(start: Double, end: Double)]
    ) -> [DictionaryReplacement] {
        let maxSpanWidth = 3
        // KWS encoder stride is 0.2s (`WhisperKwsService.strideSec`); a single
        // stride of slack on each side is enough to absorb peak-detection
        // jitter without the ±2s drag-in that produced the "every 'it' →
        // Onit" failure mode on the reported clip.
        let alignmentTolerance = 0.20

        struct Candidate {
            let detection: KWSDetection
            let term: CustomDictionaryTerm
            let startWordIndex: Int
            let spanWidth: Int
            let sim: Float
        }
        var candidates: [Candidate] = []

        for detection in detections {
            guard let term = termByKeyword[detection.keyword] else { continue }
            let termKey = normalizeKey(term.text)
            let windowStart = detection.startSec - alignmentTolerance
            let windowEnd   = detection.endSec   + alignmentTolerance

            var bestStart = -1
            var bestWidth = 1
            var bestSim: Float = 0

            for spanWidth in 1...min(maxSpanWidth, words.count) {
                let upper = words.count - spanWidth
                if upper < 0 { continue }
                for startIdx in 0...upper {
                    let spanIndices = startIdx..<(startIdx + spanWidth)
                    let spanStart = wordTimeRanges[startIdx].start
                    let spanEnd   = wordTimeRanges[startIdx + spanWidth - 1].end
                    if spanEnd < windowStart || spanStart > windowEnd { continue }
                    let spanKey = words[spanIndices].map { normalizeKey($0) }.joined()
                    let sim = CustomDictionaryRescorer.similarity(spanKey, termKey)
                    if sim > bestSim { bestSim = sim; bestStart = startIdx; bestWidth = spanWidth }
                }
            }

            // KWS spotter precision is high enough to accept a lower similarity
            // floor than the older CTC-only path (where false detections were
            // more common).
            guard bestStart >= 0, bestSim >= 0.3 else { continue }

            candidates.append(Candidate(
                detection: detection, term: term,
                startWordIndex: bestStart, spanWidth: bestWidth, sim: bestSim
            ))
        }

        // Dedup: when multiple detections produced an identical (start, width,
        // term) span, keep the highest-similarity one. We dedup by exact span
        // identity rather than overlap because partial-overlap proposals
        // describe genuinely different replacements that the NLL gate should
        // see independently.
        var bestByKey: [String: Candidate] = [:]
        for c in candidates {
            let key = "\(c.term.id)|\(c.startWordIndex)|\(c.spanWidth)"
            if let prior = bestByKey[key], prior.sim >= c.sim { continue }
            bestByKey[key] = c
        }

        // Deterministic ordering. Swift `Dictionary.values` has no ordering
        // contract, and the downstream splice-overlap dedup in
        // `applyReplacementsWithGate` resolves overlapping char ranges by
        // "first proposal wins" - so an unordered iteration here can make the
        // same audio produce different output across runs. Sort by start
        // position first, then span width, then term id, so the winner is
        // pinned to a deterministic rule.
        let ordered = bestByKey.values.sorted { lhs, rhs in
            if lhs.startWordIndex != rhs.startWordIndex {
                return lhs.startWordIndex < rhs.startWordIndex
            }
            if lhs.spanWidth != rhs.spanWidth {
                return lhs.spanWidth < rhs.spanWidth
            }
            return lhs.term.id.uuidString < rhs.term.id.uuidString
        }
        return ordered.map { c in
            let span = words[c.startWordIndex..<(c.startWordIndex + c.spanWidth)].joined(separator: " ")
            return DictionaryReplacement(
                term: c.term,
                originalSpan: span,
                startWordIndex: c.startWordIndex,
                spanWidth: c.spanWidth
            )
        }
    }

    /// Deterministic substring match against each term's `commonMistakes`.
    /// Independent of audio + KWS - gives calibrated terms an always-on
    /// fallback that still routes through the perplexity gate (so the gate
    /// rejects when the original phrasing fits the sentence better).
    ///
    /// Match rules:
    ///   - case-insensitive, all occurrences emitted (not just the first)
    ///   - boundary punctuation on transcript words is ignored when comparing
    ///     but the actual matched text becomes `originalSpan` (with apostrophe
    ///     preserved for possessive matches)
    ///   - possessive: if the last word in a window is `<mistake>'s`, emit a
    ///     possessive replacement with `replacementText = "<term>'s"` and
    ///     `proxyOverride = "<proxyWord>'s"` so the gate scores valid grammar
    private func buildCommonMistakeReplacements(words: [String]) -> [DictionaryReplacement] {
        var result: [DictionaryReplacement] = []
        var usedIndices = Set<Int>()

        // Precompute normalized form for every transcript word so we don't
        // redo the work for each (term, mistake) pair.
        let normalizedWords = words.map { stripBoundaryPunctuation($0).lowercased() }

        for term in terms where !term.commonMistakes.isEmpty {
            for mistake in term.commonMistakes {
                let mistakeWords = mistake
                    .lowercased()
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard !mistakeWords.isEmpty,
                      mistakeWords.count <= words.count else { continue }
                let windowSize = mistakeWords.count
                let possessiveLast = mistakeWords.last! + "'s"

                var startIdx = 0
                while startIdx <= words.count - windowSize {
                    let endIdx = startIdx + windowSize
                    let range = startIdx..<endIdx
                    if !range.allSatisfy({ !usedIndices.contains($0) }) {
                        startIdx += 1
                        continue
                    }

                    let slice = Array(normalizedWords[range])

                    // Exact match.
                    if slice == mistakeWords {
                        let span = extractCoreSpan(words: words, range: range)
                        result.append(DictionaryReplacement(
                            term: term,
                            originalSpan: span,
                            startWordIndex: startIdx,
                            spanWidth: windowSize
                        ))
                        usedIndices.formUnion(range)
                        log.info("CustomDictionaryService: common-mistake match (\(LogPrivacy.summary(span)) -> \(LogPrivacy.summary(term.text)))")
                        startIdx = endIdx
                        continue
                    }

                    // Possessive match - every word except the last matches
                    // exactly, and the last word is `<mistake>'s`.
                    let lastIdx = endIdx - 1
                    let prefixMatches = (0..<windowSize - 1).allSatisfy {
                        normalizedWords[startIdx + $0] == mistakeWords[$0]
                    }
                    if prefixMatches, normalizedWords[lastIdx] == possessiveLast {
                        let span = extractCoreSpan(words: words, range: range)
                        let possessiveReplacement = term.text + "'s"
                        let possessiveProxy = term.proxyWord.map { $0 + "'s" }
                        result.append(DictionaryReplacement(
                            term: term,
                            originalSpan: span,
                            startWordIndex: startIdx,
                            spanWidth: windowSize,
                            replacementText: possessiveReplacement,
                            proxyOverride: possessiveProxy
                        ))
                        usedIndices.formUnion(range)
                        log.info("CustomDictionaryService: common-mistake possessive (\(LogPrivacy.summary(span)) -> \(LogPrivacy.summary(possessiveReplacement)))")
                        startIdx = endIdx
                        continue
                    }

                    startIdx += 1
                }
            }
        }
        return result
    }

    /// Strip boundary punctuation (preserves apostrophes inside the word so
    /// contractions like "don't" and possessives like "nodding's" stay
    /// matchable as `nodding's`).
    private func stripBoundaryPunctuation(_ word: String) -> String {
        let trimSet = CharacterSet.punctuationCharacters
            .union(CharacterSet.symbols)
            .subtracting(CharacterSet(charactersIn: "'"))
        return word.trimmingCharacters(in: trimSet)
    }

    /// Returns the substring of the transcript covered by `words[range]` with
    /// boundary punctuation stripped from the first/last word. Apostrophes
    /// inside words are preserved.
    private func extractCoreSpan(words: [String], range: Range<Int>) -> String {
        var parts: [String] = []
        for i in range {
            var word = words[i]
            if i == range.lowerBound {
                while let f = word.first,
                      f.isPunctuation || f.isSymbol,
                      f != "'" {
                    word.removeFirst()
                }
            }
            if i == range.upperBound - 1 {
                while let l = word.last,
                      l.isPunctuation || l.isSymbol,
                      l != "'" {
                    word.removeLast()
                }
            }
            parts.append(word)
        }
        return parts.joined(separator: " ")
    }

    /// Lowercase + strip non-alphanumeric characters (matches `CustomDictionaryRescorer`).
    private func normalizeKey(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    /// `(backend, id, text)` fingerprint used to detect when the terms - or the
    /// active ASR backend - change between loads. The backend is part of the
    /// key because the non-Parakeet branch of `loadModelIfNeeded` marks ready
    /// WITHOUT loading Whisper KWS: a key blind to the backend would keep that
    /// stale "ready" state when the user switches back to Parakeet.
    private func currentTermsKey() -> [Int] {
        var backendHasher = Hasher()
        backendHasher.combine(Defaults[Defaults.Keys.TranscriptionConfigKeys.backend].rawValue)
        return [backendHasher.finalize()] + terms.map { t in
            var h = Hasher(); h.combine(t.id); h.combine(t.text); return h.finalize()
        }
    }
}
