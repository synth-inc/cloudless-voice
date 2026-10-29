// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermMemoryService.swift
//  Onit
//
//  Glue layer for the persistent term memory: owns the store, the admission
//  chain, and the alias predictor; ingests sighting events from the capture
//  passes the app already runs; and maintains a cached bias snapshot that
//  `buildASRPromptPayload` reads synchronously at dictation start (no SQLite
//  on the transcribe hot path - the snapshot refreshes on a utility queue
//  after every write batch).
//
//  Everything is inert unless `asrTermMemoryEnabled` is on (dev flag).
//

import Defaults
import Foundation

final class TermMemoryService: @unchecked Sendable {
    static let shared = TermMemoryService()

    /// What selection needs, precomputed: eligible terms by activation rank,
    /// their unconditional (trie-safe) aliases, and the tier-2 candidates.
    struct BiasSnapshot: Sendable {
        var terms: [String] = []                                  // display forms, best first
        var unconditionalAliases: [String: [String]] = [:]        // display term → aliases
        var tier2Candidates: [TermMemoryFuzzyMatcher.Candidate] = []
        var version = -1
    }

    private let queue = DispatchQueue(label: "inc.onit.term-memory", qos: .utility)
    private let lock = NSLock()
    private var _snapshot = BiasSnapshot()

    // Built lazily on `queue` (trigram model + lexicon load take ~1s combined
    // - never on the main thread, never unless the feature is on).
    private var store: TermMemoryStore?
    private var admission: TermAdmission?
    private var predictor: TermAliasPredictor?
    private var started = false

    /// Cap on terms whose full predicted-surface sets feed the tier-2 matcher
    /// (bounds per-dictation matching cost independently of top-K).
    private static let tier2TermCap = 200
    /// Alias predictions computed per refresh cycle (backlog drains across
    /// dictations; each prediction is ms-scale).
    private static let aliasBacklogPerCycle = 25

    static var isEnabled: Bool {
        Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTermMemoryEnabled]
    }

    static var topK: Int {
        max(25, min(2_000, Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTermMemoryTopK]))
    }

    /// User retention window in days; 0 = keep forever.
    static var retentionDays: Int {
        max(0, Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTermMemoryRetentionDays])
    }

    private init() {}

    /// On-disk location of the store. `createDirectory` is false for the
    /// callers that must never bring a store into existence (retention sweep,
    /// erase) - they only act on a file that is already there.
    private static func storePath(createDirectory: Bool = false) -> String? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("Onit")
        if createDirectory {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("term_memory.sqlite").path
    }

    // MARK: - Lifecycle

    /// Kick the background init (idempotent). Called at dictation start so
    /// first-dictation reads see a populated snapshot ASAP.
    func warmUp() {
        guard Self.isEnabled else { return }
        queue.async { self.ensureStarted() }
    }

    /// Must run on `queue`.
    private func ensureStarted() {
        guard !started else { return }
        started = true

        guard let path = Self.storePath(createDirectory: true) else { return }

        let lexicon = PhoneticLexicon.shared
        let newsWords = CapsTermSelector.shared.knownEnglishWordSet
        let splitWords = newsWords.union(lexicon.knownWords)

        store = TermMemoryStore(path: path)
        admission = TermAdmission(
            trigrams: TermAdmission.TrigramModel(words: newsWords),
            knownWords: splitWords)
        predictor = TermAliasPredictor(
            lexicon: lexicon,
            newsWords: newsWords,
            splitWords: splitWords,
            isKnownEnglishWord: { CapsTermSelector.shared.isKnownEnglishWord($0) },
            hasWordList: CapsTermSelector.shared.hasCommonWordList)

        store?.pruneSightingLog()
        pruneRetentionIfDue()
        refreshSnapshot()
        log.info("[TermMemory] started (\(store?.termCount ?? 0) stored terms)")
    }

    /// Retention outlives the feature switch: turning term memory off stops
    /// every `record()`, so the in-session prune would never run again and a
    /// store the user asked to expire would sit on disk forever. Called once
    /// at launch; opens nothing when the feature is on (the ingestion path
    /// already prunes), when no window is configured, or when no file exists.
    func pruneRetentionAtLaunch() {
        guard !Self.isEnabled, Self.retentionDays > 0 else { return }
        queue.async {
            let days = Self.retentionDays
            guard let path = Self.storePath(),
                  FileManager.default.fileExists(atPath: path),
                  let store = TermMemoryStore(path: path) else { return }
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
            let deleted = store.pruneTermsUnseen(since: cutoff)
            if deleted > 0 {
                log.info("[TermMemory] retention (feature off): forgot \(deleted) term(s) "
                    + "unseen for \(days)+ days")
            }
        }
    }

    // MARK: - Ingestion (called from TranscriptionManager)

    /// Screen-mined terms from the OCR or AX pass at dictation start - the
    /// evidence that today is discarded after the utterance.
    func recordScreenSightings(terms: [String], viaAccessibility: Bool, appBundle: String?) {
        record(terms: terms, source: viaAccessibility ? .nearCursor : .ocr, appBundle: appBundle)
    }

    /// Background focus-change capture (AmbientTermCaptureService) - weight 1
    /// regardless of mechanism (AX walk or OCR); logged as its own source so
    /// parameter fitting can weigh ambient exposure separately later.
    func recordAmbientSightings(terms: [String], appBundle: String?) {
        record(terms: terms, source: .ambient, appBundle: appBundle)
    }

    /// Mineable terms the final (kept) dictation text contained.
    func recordDictatedKept(finalText: String, appBundle: String?) {
        guard Self.isEnabled, !finalText.isEmpty else { return }
        let terms = CapsTermSelector.shared.selectCapsTerms(finalText)
        record(terms: terms, source: .dictated, appBundle: appBundle)
    }

    /// Terms a user correction introduced (strongest evidence; pins the term).
    func recordCorrection(raw: String, corrected: String, appBundle: String?) {
        guard Self.isEnabled else { return }
        let terms = CorrectionTermMiner.newTerms(correction: corrected, raw: raw)
        record(terms: terms, source: .correction, appBundle: appBundle)
    }

    private func record(terms: [String], source: TermMemoryStore.Source, appBundle: String?) {
        guard Self.isEnabled, !terms.isEmpty else { return }
        let ts = Date().timeIntervalSince1970
        queue.async {
            self.ensureStarted()
            guard let store = self.store, let admission = self.admission else { return }
            let sightings = terms.map {
                TermMemoryStore.Sighting(term: $0, source: source, appBundle: appBundle, ts: ts)
            }
            let recorded = store.recordSightings(sightings, admission: admission)
            self.drainAliasBacklog()
            self.pruneRetentionIfDue()
            if recorded > 0 || store.version != self.snapshot().version {
                self.refreshSnapshot()
            }
        }
    }

    /// Must run on `queue`. Applies the user's retention window ("forget
    /// terms unseen for N days"), throttled to once per hour - the delete is
    /// cheap, but there's no reason to scan per dictation.
    private var lastRetentionPrune = 0.0
    private func pruneRetentionIfDue() {
        let days = Self.retentionDays
        guard days > 0, let store else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastRetentionPrune > 3600 else { return }
        lastRetentionPrune = now
        let deleted = store.pruneTermsUnseen(since: now - Double(days) * 86_400)
        if deleted > 0 {
            log.info("[TermMemory] retention: forgot \(deleted) term(s) unseen for \(days)+ days")
        }
    }

    // MARK: - Erase

    /// User-facing wipe: close and delete the SQLite file and reset every
    /// in-memory derivative (bias snapshot included), so nothing captured
    /// survives the button. The next `ensureStarted()` rebuilds from scratch.
    func eraseAll() {
        queue.async {
            self.store = nil          // closes the DatabaseQueue before the unlink
            self.admission = nil
            self.predictor = nil
            self.started = false
            self.lastRetentionPrune = 0
            self.lock.lock()
            self._snapshot = BiasSnapshot()
            self.lock.unlock()
            guard let path = Self.storePath() else { return }
            let fileManager = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let candidate = path + suffix
                guard fileManager.fileExists(atPath: candidate) else { continue }
                do {
                    try fileManager.removeItem(atPath: candidate)
                } catch {
                    log.error("[TermMemory] erase failed for \(candidate): \(error)")
                }
            }
            log.info("[TermMemory] term memory erased")
        }
    }

    // MARK: - Selection (read on the transcribe path)

    func snapshot() -> BiasSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    /// Must run on `queue`.
    private func refreshSnapshot() {
        guard let store else { return }
        let now = Date().timeIntervalSince1970
        let records = store.biasList(now: now, limit: Self.topK)
        let keys = records.map(\.term)
        let unconditional = store.aliases(forTerms: keys, tier: .unconditional)
        let gated = store.aliases(forTerms: Array(keys.prefix(Self.tier2TermCap)), tier: .gated)

        var aliasesByDisplay: [String: [String]] = [:]
        var tier2: [TermMemoryFuzzyMatcher.Candidate] = []
        for record in records {
            if let aliases = unconditional[record.term], !aliases.isEmpty {
                aliasesByDisplay[record.display] = aliases
            }
            if tier2.count < Self.tier2TermCap, let phones = record.phones {
                var surfaces = Set<String>()
                for alias in (gated[record.term] ?? []) + (unconditional[record.term] ?? []) {
                    surfaces.insert(TermMemoryFuzzyMatcher.normalize(alias))
                }
                tier2.append(.init(display: record.display, phones: phones,
                                   surfaceNorms: surfaces))
            }
        }
        let snapshot = BiasSnapshot(
            terms: records.map(\.display),
            unconditionalAliases: aliasesByDisplay,
            tier2Candidates: tier2,
            version: store.version)
        lock.lock()
        _snapshot = snapshot
        lock.unlock()
    }

    /// Must run on `queue`: predict aliases for recently-admitted terms.
    private func drainAliasBacklog() {
        guard let store, let predictor else { return }
        let pending = store.termsNeedingAliases(limit: Self.aliasBacklogPerCycle)
        for record in pending {
            store.storePrediction(term: record.term,
                                  prediction: predictor.predict(record.display))
        }
    }

    // MARK: - Tier-2 post-ASR pass

    /// Gated fuzzy restore over the final ASR text. Returns the input
    /// unchanged unless the tier-2 dev flag is on and a unique, unambiguous
    /// match clears the edit-distance gates. `language` is the backend's
    /// detected language (nil = unknown); non-English dictations are skipped.
    ///
    /// The match itself is bounded only by `tier2TermCap`, and the first call
    /// can force the phonetic lexicon to build (~3 MB parse), so it runs off
    /// the caller's actor: only Sendable values cross (candidates, text,
    /// language) and the matcher is built inside the detached task, which
    /// keeps its non-Sendable closures on one side of the boundary.
    func applyTier2IfEnabled(to text: String, language: String?) async -> String {
        guard Self.isEnabled,
              Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTermMemoryTier2Enabled],
              !text.isEmpty else { return text }
        let candidates = snapshot().tier2Candidates
        guard !candidates.isEmpty else { return text }
        return await Task.detached(priority: .userInitiated) {
            let selector = CapsTermSelector.shared
            let matcher = TermMemoryFuzzyMatcher(
                candidates: candidates,
                language: language,
                isKnownEnglishWord: { selector.isKnownEnglishWord($0) },
                isEverydayWord: { selector.isCommonWord($0) },
                phonesForSpoken: { PhoneticLexicon.shared.phones(forSpoken: $0) })
            let (result, applied) = matcher.apply(to: text)
            for rewrite in applied {
                log.info("[TermMemory] tier-2 rewrite (\(LogPrivacy.summary(rewrite.original)) -> \(LogPrivacy.summary(rewrite.replacement)))")
            }
            return result
        }.value
    }
}
