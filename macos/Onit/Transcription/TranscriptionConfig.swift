// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionConfig.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import Defaults
import Foundation

// MARK: - Transcription Backend

enum TranscriptionBackend: String, Defaults.Serializable {
    case fluidAudio
    case parakeetCoreML
    /// NVIDIA Canary-1B-v2 attention encoder-decoder, isolated CoreML engine
    /// (`CanaryCoreMLEngine`). int4 bundle → macOS 15+.
    case canaryCoreML
    case whisperCoreML
    case moonshineONNX
    /// Every MLX-Swift model (Qwen3-ASR, Granite-Speech, …) routes through the
    /// single generic MLX backend; the specific model is resolved from the
    /// catalog id via `MLXModelRegistry`.
    case mlx
}

// MARK: - Transcription Config Keys Typealias

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

// MARK: - Transcription Config

@MainActor
final class TranscriptionConfig: ObservableObject {

    // MARK: - Singleton

    static let shared = TranscriptionConfig()

    // MARK: - Published Properties

    @Published var isEnabled: Bool {
        didSet {
            Defaults[.transcriptionEnabled] = isEnabled
        }
    }

    @Published var confidenceThreshold: Double {
        didSet {
            Defaults[ConfigKeys.confidenceThreshold] = confidenceThreshold
        }
    }

    @Published var autoPunctuation: Bool {
        didSet {
            Defaults[ConfigKeys.autoPunctuation] = autoPunctuation
        }
    }

    @Published var eouDebounceMs: Int {
        didSet {
            Defaults[ConfigKeys.eouDebounceMs] = eouDebounceMs
        }
    }

    /// Chunked-streaming transcription (BETA). Mirror of
    /// `ConfigKeys.chunkedStreamingEnabled`. When true, the pipeline transcribes
    /// audio segments in the background during pauses to cut latency at release.
    /// Only effective on chunk-capable backends (Parakeet CoreML and MLX/Qwen);
    /// see `TranscriptionBackend`. Off by default.
    @Published var chunkedStreamingEnabled: Bool {
        didSet {
            Defaults[ConfigKeys.chunkedStreamingEnabled] = chunkedStreamingEnabled
        }
    }

    /// Hold-to-record mode: hold shortcut to record, release to insert
    /// When false, uses toggle mode: press to start, press to stop
    @Published var holdToRecord: Bool {
        didSet {
            Defaults[.transcriptionHoldToRecord] = holdToRecord
        }
    }

    // MARK: - ASR Model Selection
    //
    // Source-of-truth contract - **READ THIS BEFORE TOUCHING THESE PROPERTIES.**
    //
    // The user-facing ASR selection has three storage locations that look like
    // they could each be written independently, but the contract is:
    //
    //   1. `selectedASRModelId` (@Published) - **the only writable source.**
    //   2. `selectedASRModel` (computed) - derived from #1, never written.
    //   3. `backend` (computed) - derived from #2, never written.
    //   4. `Defaults[ConfigKeys.selectedASRModelId]` - mirror of #1, written by didSet.
    //   5. `Defaults[ConfigKeys.backend]` - legacy key that warmup providers read
    //      directly (`SileroVADWarmupProvider`, `WhisperCoreMLWarmupProvider`,
    //      `ParakeetCoreMLWarmupProvider`, `FluidAudioWarmupProvider`). Written by
    //      didSet and at init so it always equals `selectedASRModel.backend`.
    //
    // **Never write `Defaults[ConfigKeys.backend]` directly** - go through
    // `selectedASRModelId =`. Direct writes to the legacy key bypass `featureStateChanged()`
    // and create divergence the warmup system can't recover from until next launch.
    // A test in `TranscriptionConfigASRModelTests` pins this invariant.

    @Published var selectedASRModelId: String {
        didSet {
            guard !isResettingToDefaults else { return }
            log.info("TranscriptionConfig: selectedASRModelId \(oldValue) → \(selectedASRModelId) (backend=\(selectedASRModel.backend.rawValue))")
            let previousBackend = Defaults[ConfigKeys.backend]
            Defaults[ConfigKeys.selectedASRModelId] = selectedASRModelId
            Defaults[ConfigKeys.backend] = selectedASRModel.backend
            // The dictionary's KWS readiness is computed per backend (Whisper
            // KWS is Parakeet-only; the others mark ready without loading it):
            // a stale "ready" from the previous backend would make detectKeywords
            // throw notLoaded on every dictation after switching back to Parakeet.
            if previousBackend != selectedASRModel.backend {
                Task { @MainActor in CustomDictionaryService.shared.invalidateModel() }
            }
            WarmupCoordinator.shared.featureStateChanged()
        }
    }

    /// Resolved model for the current selection. Falls back to the default catalog
    /// entry if `selectedASRModelId` points at an unknown id (e.g. a removed model
    /// or a stale persisted value), or at a model this machine cannot run.
    ///
    /// The availability fallback is what keeps a persisted MLX selection from
    /// reaching the engine on an Intel Mac, where touching MLX is a hard crash
    /// (see `MLXRuntime`). Because `backend` is derived from here, one guard
    /// covers the manager, the registry and every warmup provider.
    var selectedASRModel: ASRModel {
        guard let model = ASRModel.byId(selectedASRModelId),
              model.isAvailableForCurrentOS
        else { return .defaultModel }
        return model
    }

    /// ASR engine derived from the selected model. See contract above.
    var backend: TranscriptionBackend {
        selectedASRModel.backend
    }

    /// Set by `resetToDefaults()` to suppress mid-reset `featureStateChanged()` /
    /// `Defaults` writes triggered by individual property assignments. The coalesced
    /// notification fires once at the end of the reset.
    private var isResettingToDefaults = false

    // MARK: - N-best Configuration

    /// Number of hypotheses to generate (1-10)
    @Published var nbestCount: Int {
        didSet {
            Defaults[ConfigKeys.nbestCount] = nbestCount
        }
    }

    /// Enable LLM-based N-best hypothesis selection
    @Published var nbestSelectionEnabled: Bool {
        didSet {
            Defaults[ConfigKeys.nbestSelectionEnabled] = nbestSelectionEnabled
            // N-best consumes the improvement LLM. Same routing as backtracking
            // - warmup coordinator picks up the new isEnabled state.
            WarmupCoordinator.shared.featureStateChanged()
        }
    }

    // MARK: - Sampling Parameters

    /// Temperature for sampling (>1 = more diversity)
    @Published var temperature: Double {
        didSet {
            Defaults[ConfigKeys.temperature] = temperature
        }
    }

    /// Nucleus sampling threshold
    @Published var topP: Double {
        didSet {
            Defaults[ConfigKeys.topP] = topP
        }
    }

    // MARK: - Language

    /// Selected languages for multi-language forcing (ISO 639-1 codes).
    /// Empty = auto-detect. 1 = direct forcing. 2+ = mlx-whisper detection between candidates.
    @Published var transcriptionLanguages: [String] {
        didSet {
            Defaults[ConfigKeys.transcriptionLanguages] = transcriptionLanguages
        }
    }

    // MARK: - Recording Tail Buffer

    /// Additional recording time after key release in milliseconds (prevents word truncation)
    var recordingTailBufferMs: Int {
        Defaults[ConfigKeys.recordingTailBufferMs]
    }

    // MARK: - Dev Settings

    /// Force showing correction UI before inserting text (for testing/data collection)
    /// When enabled, text is not auto-inserted; user must confirm via correction UI
    @Published var forceCorrectionUI: Bool {
        didSet {
            Defaults[ConfigKeys.forceCorrectionUI] = forceCorrectionUI
        }
    }

    /// Enable full AX window context scrape after each dictation (DEBUG/ONIT_BETA only).
    /// Disable to skip the expensive AX tree traversal when diagnosing performance issues.
    @Published var windowContextScrapeEnabled: Bool {
        didSet {
            Defaults[ConfigKeys.windowContextScrapeEnabled] = windowContextScrapeEnabled
        }
    }

    // MARK: - LM Conditioning

    @Published var lmConditioningEnabled: Bool {
        didSet {
            Defaults[ConfigKeys.lmConditioningEnabled] = lmConditioningEnabled
            WarmupCoordinator.shared.featureStateChanged()
        }
    }

    // MARK: - Smart Formatting

    @Published var smartFormattingEnabled: Bool {
        didSet {
            // A fully open build has no Smart Cleanup to turn on (see
            // `SmartCleanupAvailability`). Assigning inside `didSet` doesn't re-run it.
            if smartFormattingEnabled, !SmartCleanupAvailability.isCompiledIn {
                smartFormattingEnabled = false
                // Reached from `cleanupProviderID = smart` too: put the provider back
                // so the two stay mirrors and "smart" isn't stored.
                if cleanupProviderID == CleanupProviderID.smart {
                    cleanupProviderID = CleanupProviderID.none
                }
                return
            }
            Defaults[ConfigKeys.smartFormattingEnabled] = smartFormattingEnabled
            // Keep the provider choice in step with the Settings toggle.
            if smartFormattingEnabled, cleanupProviderID != CleanupProviderID.smart {
                cleanupProviderID = CleanupProviderID.smart
            } else if !smartFormattingEnabled, cleanupProviderID == CleanupProviderID.smart {
                cleanupProviderID = CleanupProviderID.none
            }
            WarmupCoordinator.shared.featureStateChanged()
        }
    }

    /// The `CleanupProvider` that cleans a dictation (see `CleanupProviderID`).
    ///
    /// `smartFormattingEnabled` stays its mirror (on ⇔ "smart"; off for every other
    /// provider): the Settings toggle binds to it. Each setter updates the other.
    /// Warmup decides whether to load the Smart Cleanup models from the provider,
    /// not the toggle (`isSmartCleanupSelected`).
    @Published var cleanupProviderID: String {
        didSet {
            Defaults[ConfigKeys.cleanupProviderID] = cleanupProviderID
            let isSmart = cleanupProviderID == CleanupProviderID.smart
            if smartFormattingEnabled != isSmart {
                smartFormattingEnabled = isSmart
            }
        }
    }

    /// Rewrite: after cleanup, hand the text to the user's own model
    /// (`BYOKCleanupProvider`) with their prompt. Runs after any cleanup choice,
    /// on the raw transcript when cleanup is off. Settings > Rewrite.
    @Published var rewriteEnabled: Bool {
        didSet { Defaults[ConfigKeys.rewriteEnabled] = rewriteEnabled }
    }

    /// The provider id to use at launch, from what was stored.
    ///
    /// Before providers there was only the Smart Cleanup toggle: on → "smart",
    /// off → "none". The toggle also wins over a stored "smart" / "none", since an
    /// older build that shares these prefs only writes the toggle. "byok" was
    /// briefly a cleanup choice before it became the Rewrite stage: it means no
    /// cleanup (`init` turns Rewrite on for it). Any other stored id is a provider
    /// the toggle doesn't describe, and is kept.
    nonisolated static func resolvedCleanupProviderID(stored: String?, smartFormattingEnabled: Bool) -> String {
        if let stored, stored != CleanupProviderID.smart, stored != CleanupProviderID.none {
            return stored == CleanupProviderID.byok ? CleanupProviderID.none : stored
        }
        return smartFormattingEnabled ? CleanupProviderID.smart : CleanupProviderID.none
    }

    /// The provider a fresh install starts on, and what "Reset to defaults" goes back
    /// to: the toggle's own default, read through the migration.
    nonisolated static var defaultCleanupProviderID: String {
        resolvedCleanupProviderID(stored: nil, smartFormattingEnabled: ConfigKeys.smartFormattingEnabled.defaultValue)
    }

    /// Whether Smart Cleanup is the active provider, from what's stored.
    ///
    /// The warmup providers ask this (not the toggle's key) before loading the Smart
    /// Cleanup models, so another provider never pays for them. Readable before
    /// `TranscriptionConfig.shared` exists, and agrees with it once it does.
    nonisolated static var isSmartCleanupSelected: Bool {
        isSmartCleanupSelected(
            storedProviderID: Defaults[ConfigKeys.cleanupProviderID],
            smartFormattingEnabled: Defaults[ConfigKeys.smartFormattingEnabled]
        )
    }

    nonisolated static func isSmartCleanupSelected(storedProviderID: String?, smartFormattingEnabled: Bool) -> Bool {
        resolvedCleanupProviderID(stored: storedProviderID, smartFormattingEnabled: smartFormattingEnabled)
            == CleanupProviderID.smart
    }

    @Published var sfBacktrackingEnabled: Bool {
        didSet {
            Defaults[ConfigKeys.sfBacktrackingEnabled] = sfBacktrackingEnabled
            // Backtracking consumes the improvement LLM. Route through the
            // shared warmup pipeline so the model load surfaces in the same
            // app-wide status / retry surface as the other providers.
            WarmupCoordinator.shared.featureStateChanged()
        }
    }

    @Published var sfPunctuationEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfPunctuationEnabled] = sfPunctuationEnabled }
    }

    @Published var sfEmojiEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfEmojiEnabled] = sfEmojiEnabled }
    }

    @Published var sfFormattingEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfFormattingEnabled] = sfFormattingEnabled }
    }

    @Published var sfFillersEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfFillersEnabled] = sfFillersEnabled }
    }

    @Published var sfEmailsUrlsEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfEmailsUrlsEnabled] = sfEmailsUrlsEnabled }
    }

    @Published var sfEmailLayoutEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfEmailLayoutEnabled] = sfEmailLayoutEnabled }
    }

    @Published var sfDuplicatesEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfDuplicatesEnabled] = sfDuplicatesEnabled }
    }

    @Published var sfNumbersEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfNumbersEnabled] = sfNumbersEnabled }
    }

    @Published var sfNumberStyle: String {
        didSet { Defaults[ConfigKeys.sfNumberStyle] = sfNumberStyle }
    }

    @Published var sfAbbreviateLargeNumbers: Bool {
        didSet { Defaults[ConfigKeys.sfAbbreviateLargeNumbers] = sfAbbreviateLargeNumbers }
    }

    @Published var sfCapitalizationEnabled: Bool {
        didSet { Defaults[ConfigKeys.sfCapitalizationEnabled] = sfCapitalizationEnabled }
    }

    // MARK: - Initialization

    /// A fully open build can't run Smart Cleanup (see `SmartCleanupAvailability`).
    /// Store it as off before anything reads the setting, since the warmup providers
    /// read the stored keys directly to decide which models to load. Prefs inherited
    /// from the official app (same bundle id) would otherwise still say "smart".
    private static func storeSmartCleanupOffIfUnavailable() {
        guard !SmartCleanupAvailability.isCompiledIn else { return }
        Defaults[ConfigKeys.smartFormattingEnabled] = false
        if Defaults[ConfigKeys.cleanupProviderID] == CleanupProviderID.smart {
            Defaults[ConfigKeys.cleanupProviderID] = CleanupProviderID.none
        }
    }

    private init() {
        Self.storeSmartCleanupOffIfUnavailable()
        // Dictate exposes a single "Hands-free" switch; `transcriptionHoldToRecord`
        // is a vestigial key with no UI of its own. Repair the invalid combination
        // (hands-free OFF *and* hold OFF) - it strands the user in toggle mode
        // ("press again to stop") with no way back to hold-to-talk. This combo can
        // be inherited from the prefs of another build that shares this bundle id
        // (e.g. the released Onit). Hands-free OFF must always mean hold-to-talk.
        if !Defaults[ConfigKeys.handsFreeOnly] && !Defaults[.transcriptionHoldToRecord] {
            Defaults[.transcriptionHoldToRecord] = true
        }

        self.isEnabled = Defaults[.transcriptionEnabled]
        self.confidenceThreshold = Defaults[ConfigKeys.confidenceThreshold]
        self.autoPunctuation = Defaults[ConfigKeys.autoPunctuation]
        self.eouDebounceMs = Defaults[ConfigKeys.eouDebounceMs]
        self.chunkedStreamingEnabled = Defaults[ConfigKeys.chunkedStreamingEnabled]
        self.holdToRecord = Defaults[.transcriptionHoldToRecord]
        // Reconcile a persisted selection this machine cannot run *before* the
        // mirror is written, so the id, the legacy backend key and the computed
        // `backend` all agree. `recommendedDefaultModelId` picks an MLX model on
        // any machine with 32 GB+, which is unavailable on Intel and on macOS 14;
        // resolving only in `selectedASRModel` would leave the mirror on `.mlx`
        // while the manager routed to Parakeet, and `ParakeetCoreMLWarmupProvider`
        // (which reads the mirror) would never enable - no download, no warmup,
        // dictation dead until the 30-minute observer ceiling.
        let persistedModelId = Defaults[ConfigKeys.selectedASRModelId]
        let resolvedModelId = ASRModel.byId(persistedModelId)?.isAvailableForCurrentOS == true
            ? persistedModelId
            : ASRModel.defaultModelId
        //
        // The resolution stays IN MEMORY: `Defaults[selectedASRModelId]` is left
        // exactly as the user left it. Persisting the fallback would turn "no
        // explicit choice, recommend by RAM" into a stored explicit choice - a
        // 32 GB Mac first launched on macOS 14 (or once under Rosetta) would be
        // pinned to Parakeet for good, even after upgrading to macOS 15.
        self.selectedASRModelId = resolvedModelId
        // `didSet` does not fire during `init`, so the mirror is written by hand.
        // Nothing outside this file reads the persisted id directly.
        Defaults[ConfigKeys.backend] = ASRModel.byId(resolvedModelId)?.backend
            ?? ASRModel.defaultModel.backend
        self.nbestCount = Defaults[ConfigKeys.nbestCount]
        self.nbestSelectionEnabled = Defaults[ConfigKeys.nbestSelectionEnabled]
        self.temperature = Defaults[ConfigKeys.temperature]
        self.topP = Defaults[ConfigKeys.topP]
        self.transcriptionLanguages = Defaults[ConfigKeys.transcriptionLanguages]
        self.forceCorrectionUI = Defaults[ConfigKeys.forceCorrectionUI]
        self.windowContextScrapeEnabled = Defaults[ConfigKeys.windowContextScrapeEnabled]
        // LM Conditioning
        self.lmConditioningEnabled = Defaults[ConfigKeys.lmConditioningEnabled]
        // Smart Formatting
        let storedCleanupProviderID = Defaults[ConfigKeys.cleanupProviderID]
        let cleanupProviderID = Self.resolvedCleanupProviderID(
            stored: storedCleanupProviderID,
            smartFormattingEnabled: Defaults[ConfigKeys.smartFormattingEnabled]
        )
        self.cleanupProviderID = cleanupProviderID
        // The toggle mirrors the provider, whatever an older build left in its key
        // (it may have switched the toggle on while another provider is stored).
        self.smartFormattingEnabled = cleanupProviderID == CleanupProviderID.smart
        // `didSet` does not fire during `init`, so both are written by hand.
        Defaults[ConfigKeys.cleanupProviderID] = cleanupProviderID
        Defaults[ConfigKeys.smartFormattingEnabled] = cleanupProviderID == CleanupProviderID.smart
        // "Your own model" as a cleanup choice became the Rewrite stage.
        if storedCleanupProviderID == CleanupProviderID.byok {
            Defaults[ConfigKeys.rewriteEnabled] = true
        }
        self.rewriteEnabled = Defaults[ConfigKeys.rewriteEnabled]
        self.sfBacktrackingEnabled = Defaults[ConfigKeys.sfBacktrackingEnabled]
        self.sfPunctuationEnabled = Defaults[ConfigKeys.sfPunctuationEnabled]
        self.sfEmojiEnabled = Defaults[ConfigKeys.sfEmojiEnabled]
        self.sfFormattingEnabled = Defaults[ConfigKeys.sfFormattingEnabled]
        self.sfFillersEnabled = Defaults[ConfigKeys.sfFillersEnabled]
        self.sfEmailsUrlsEnabled = Defaults[ConfigKeys.sfEmailsUrlsEnabled]
        self.sfEmailLayoutEnabled = Defaults[ConfigKeys.sfEmailLayoutEnabled]
        self.sfDuplicatesEnabled = Defaults[ConfigKeys.sfDuplicatesEnabled]
        self.sfNumbersEnabled = Defaults[ConfigKeys.sfNumbersEnabled]
        self.sfNumberStyle = Defaults[ConfigKeys.sfNumberStyle]
        self.sfAbbreviateLargeNumbers = Defaults[ConfigKeys.sfAbbreviateLargeNumbers]
        self.sfCapitalizationEnabled = Defaults[ConfigKeys.sfCapitalizationEnabled]
    }

    // MARK: - Public Methods

    /// Cleanup rules the pipeline runs with, derived from the dictation
    /// language lock.
    ///
    /// French only when the user has locked dictation to FR. Mixed or
    /// auto-detect modes stay on the English defaults - the FR preprocess would
    /// otherwise apply FR-specific transformations to non-FR utterances in a
    /// bilingual session. Whisper's per-utterance language detection isn't
    /// wired through to the cleanup layer yet, so this conservative rule is the
    /// safe default.
    ///
    /// Exposed rather than computed inline: Settings shows the defaults that
    /// will actually fire, and anything reading per-locale cleanup data has to
    /// agree with what the pipeline was handed.
    var cleanupLocale: CleanupLocale {
        (transcriptionLanguages == ["fr"]) ? .french : .english
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        isResettingToDefaults = true
        defer {
            isResettingToDefaults = false
            // Coalesced post-reset sync: write Defaults once + notify warmup once,
            // so intermediate property assignments don't fire dozens of
            // `featureStateChanged()` calls with half-reset state.
            Defaults[ConfigKeys.selectedASRModelId] = selectedASRModelId
            Defaults[ConfigKeys.backend] = selectedASRModel.backend
            WarmupCoordinator.shared.featureStateChanged()
        }
        isEnabled = true
        confidenceThreshold = 0.5
        autoPunctuation = true
        eouDebounceMs = 1280
        chunkedStreamingEnabled = false
        holdToRecord = true
        selectedASRModelId = ASRModel.defaultModelId
        nbestCount = 3
        nbestSelectionEnabled = true
        temperature = 1.5
        topP = 0.95
        transcriptionLanguages = []
        forceCorrectionUI = false
        windowContextScrapeEnabled = true
        // LM Conditioning
        lmConditioningEnabled = false
        // Smart Formatting (the toggle follows the provider)
        cleanupProviderID = Self.defaultCleanupProviderID
        rewriteEnabled = false
        sfBacktrackingEnabled = true
        sfPunctuationEnabled = true
        sfEmojiEnabled = true
        sfFormattingEnabled = true
        sfFillersEnabled = true
        sfEmailsUrlsEnabled = true
        sfEmailLayoutEnabled = false
        sfDuplicatesEnabled = true
        sfNumbersEnabled = true
        sfNumberStyle = "with_comma"
        sfAbbreviateLargeNumbers = false
        sfCapitalizationEnabled = true
    }
}

// MARK: - Cleanup provider selection

/// Something that holds the active cleanup provider id. `TranscriptionConfig` in
/// the app; a plain object in tests.
@MainActor
protocol CleanupProviderSelecting: AnyObject {
    var cleanupProviderID: String { get set }
    var rewriteEnabled: Bool { get set }
}

extension TranscriptionConfig: CleanupProviderSelecting {}
