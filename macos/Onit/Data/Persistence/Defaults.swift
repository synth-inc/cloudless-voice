// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Defaults.swift
//  Onit
//
//  Created by Kévin Naudin on 29/01/2025.
//

import CoreGraphics
import Defaults
import Foundation

enum AuthFlowStatus: String, Defaults.Serializable {
    case hideAuth
    case showSignUp
    case showSignIn
}

enum FooterNotification: String, Defaults.Serializable {
    case discord
    case update
}

/// Controls how the correction overlay is positioned after a transcription paste.
/// Used in Developer Settings to force a specific positioning path for testing.
enum OverlayPositioningMode: String, Defaults.Serializable {
    /// Use screen recording + OCR diff to detect where text was pasted.
    case screenRecording
    /// Skip OCR; use Accessibility API bounds only (default).
    case ax
    /// Skip both OCR and AX; position near the mouse cursor.
    case mouse
    /// Skip OCR, AX, and mouse-anchoring; position the overlay near the Hint.
    /// This is the existing fallback when other detection paths fail, exposed
    /// as an explicit setting for users who want predictable Hint-anchored
    /// placement regardless of pasted-text detectability.
    case hint
}


struct WindowContextMostRecent: Codable, Hashable, Equatable, Defaults.Serializable {
    let pid: pid_t
    let hash: UInt
    
    static func == (lhs: WindowContextMostRecent, rhs: WindowContextMostRecent) -> Bool {
        return lhs.pid == rhs.pid && lhs.hash == rhs.hash
    }
}

extension Defaults.Keys {

    // Retired (Oct 2026): the per-provider API tokens, their validation flags and
    // "use<Provider>" switches inherited from the Onit sidebar app. Nothing reads them;
    // `LegacyProviderTokenWipe` deletes any stored values once. Never reuse these names.
    // See `LegacyProviderTokenWipe.retiredKeys` for the list.

    static let useLocal = Key<Bool>("useLocalModel", default: true)
    
    static let streamResponse = Key<StreamResponseConfig>("streamResponse", default: StreamResponseConfig.default)
    
    static let modeToggleShortcutDisabled = Key<Bool>("modeToggleShortcutDisabled", default: true)

    // Dialogs closed
    static let closedNoLocalModels = Key<Bool>("closedNoLocalModels", default: false)
    static let closedNoRemoteModels = Key<Bool>("closedNoRemoteModels", default: false)
    static let closedNewRemoteData = Key<Data>("closedNewRemoteData", default: Data())
    static let closedDeprecatedRemoteData = Key<Data>("closedDeprecatedRemoteData", default: Data())

    static let remoteModel = Key<AIModel?>("remoteModel", default: nil)
    static let localModel = Key<String?>("localModel", default: nil)
    static let mode = Key<InferenceMode>("mode", default: .remote)
    static let availableLocalModels = Key<[String]>("availableLocalModels", default: [])
    static let availableRemoteModels = Key<[AIModel]>("availableRemoteModels", default: [])
    static let availableCustomProviders = Key<[CustomProvider]>(
        "availableCustomProvider", default: [])
    static let userRemovedRemoteModels = Key<[AIModel]>("userRemovedRemoteModels", default: [])
    static let userAddedRemoteModels = Key<[AIModel]>("userAddedRemoteModels", default: [])

    // Stores unique model identifiers in the format "provider-id" or "customProviderName-id" for custom providers
    static let visibleModelIds = Key<Set<String>>("visibleModelIds", default: Set([]))
    static let visibleLocalModels = Key<Set<String>>("visibleLocalModels", default: Set([]))
    static let hasPerformedModelIdMigration = Key<Bool>(
        "hasPerformedModelIdMigration", default: false)

    // This migration adds the 'instruction' the response object, so it can be dynamic
    static let hasPerformedInstructionResponseMigration = Key<Bool>(
        "hasPerformedInstructionResponseMigration", default: false)
    static let needsHangingPromptCleanup = Key<Bool>(
        "needsHangingPromptCleanup", default: true)
    static let hasPerformedDatabaseMigration = Key<Bool>("hasPerformedDatabaseMigration", default: false)
    static let hasPerformedBackendMigration = Key<Bool>("hasPerformedBackendMigration", default: false)

    static let localEndpointURL = Key<URL>(
        "localEndpointURL", default: URL(string: "http://localhost:11434")!)

    // Feature flags
    static let usePinnedMode = Key<Bool?>("use_screen_mode_with_accessibility", default: nil)
    
    static let autoContextFromCurrentWindow = Key<Bool>("autoContextFromCurrentWindow", default: true)
    static let autoContextOnLaunchTethered = Key<Bool>("autoContextOnLaunchTethered", default: true)
    static let autoContextOnLaunchPinned = Key<Bool>("autoContextOnLaunchPinned", default: true)

    // General settings
    static let appAppearance = Key<AppAppearance>("appAppearance", default: .system)
    static let launchOnStartupRequested = Key<Bool>("launchOnStartupRequested", default: false)
    static let hideDockIcon = Key<Bool>("hideDockIcon", default: false)
    static let fontSize = Key<Double>("fontSize", default: 14.0)
    static let lineHeight = Key<Double>("lineHeight", default: 1.5)
    static let voiceSilenceThreshold = Key<Float>("voiceSilenceThreshold", default: -40)
    static let voiceSpeechPassThreshold = Key<Double>("voiceSpeechPassThreshold", default: 0.7)

    /// Highlighted Text
    static let showHighlightedTextInput = Key<Bool>("showHighlightedTextInput", default: true)
    static let autoAddHighlightedTextToContext = Key<Bool>("autoAddHighlightedTextToContext", default: true)
    
    static let settingsPage = Key<SettingsPage>("settingsPage", default: .general)

    // Local model advanced options
    static let localKeepAlive = Key<String?>("localKeepAlive", default: nil)
    static let localNumCtx = Key<Int?>("localNumCtx", default: nil)
    static let localTemperature = Key<Double?>("localTemperature", default: nil)
    static let localTopP = Key<Double?>("localTopP", default: nil)
    static let localTopK = Key<Int?>("localTopK", default: nil)
    static let localRequestTimeout = Key<TimeInterval?>("localRequestTimeout", default: 60.0)
    
    // Debug settings
    static let launchShortcutToggleEnabled = Key<Bool>("launchShortcutToggleEnabled", default: true)
    static let escapeShortcutDisabled = Key<Bool>("escapeShortcutDisabled", default: false)
    static let openOnMouseMonitor = Key<Bool>("openOnMouseMonitor", default: false)
    
    // Onboarding
    static let showOnboardingAccessibility = Key<Bool>("showOnboardingAccessibility", default: true)
    static let authFlowStatus = Key<AuthFlowStatus>("authFlowStatus", default: .hideAuth)
    static let currentOnboardingStep = Key<OnboardingStep?>("currentOnboardingStep", default: nil)
    static let onboardingDismissed = Key<Bool>("onboardingDismissed", default: false)
    static let mainOnboardingCompleted = Key<Bool>("mainOnboardingCompleted", default: false)
    static let transcriptionSpecificStepsCompleted = Key<Bool>("transcriptionSpecificStepsCompleted", default: false)
    static let onboardingReferralCompleted = Key<Bool>("onboardingReferralCompleted", default: false)
    static let onboardingAuthSkipped = Key<Bool>("onboardingAuthSkipped", default: false)
    /// Whether the user has completed the new 6-step dictation demo. Drives the post-completion
    /// "Try it now" offer (shown only when the demo hasn't been completed).
    static let dictationDemoCompleted = Key<Bool>("dictationDemoCompleted", default: false)
    /// Set the moment the App Home setup card's "Try it now" actually opens the dictation demo -
    /// permanently hides the card, even if the demo is then closed unfinished (it stays available
    /// from Settings → Setup). Deliberately NOT set while the card is still showing Smart Cleanup
    /// download progress for a pending launch, since the card is that wait's only status surface.
    static let appHomeSetupCardDismissed = Key<Bool>("appHomeSetupCardDismissed", default: false)
    /// One-shot guard for the post-onboarding "Cloudless is ready!" Hint pop-up - set once it's been
    /// acknowledged (via "Try Cloudless" or close) so it doesn't re-announce on every relaunch.
    static let appHomeReadyToastShown = Key<Bool>("appHomeReadyToastShown", default: false)
    /// One-shot marker for the launch migration that suppresses the "Cloudless is ready!" nudge for
    /// users who were already set up before that nudge existed (the nudge shipped with the onboarding
    /// overhaul, after v4.4). Without this, every existing user would see it once on update. Runs
    /// exactly once; new users - onboarding not yet complete at first launch - are left untouched so
    /// they still see the nudge after onboarding, as intended.
    static let readyToastMigrationDone = Key<Bool>("readyToastMigrationDone", default: false)
    /// One-shot trigger: when set, the Voice Dictation → Configuration page opens the "Browse all
    /// models…" sheet on appear (then clears it). Lets the Home setup card's gear deep-link there.
    static let pendingOpenASRModelsSheet = Key<Bool>("pendingOpenASRModelsSheet", default: false)
    /// Debug-only: when true, the transcription Shortcut step treats models as still downloading
    /// and skips the live Dictation Demo (→ Discord), regardless of actual warmup state. Lets us
    /// exercise the "models not ready" onboarding branch without deleting model files. This app has
    /// no Experimental settings page, so flip it with
    /// `defaults write inc.synth.Onit.dev debugSimulateModelsDownloading -bool YES`.
    static let debugSimulateModelsDownloading = Key<Bool>("debugSimulateModelsDownloading", default: false)

    // Hint
    static let alwaysHideHint = Key<Bool>("alwaysHideHint", default: false)
    /// Absolute date until which the Hint is temporarily silenced, `nil` when no snooze is running.
    ///     Stored as a date (rather than a remaining duration) so the snooze survives a relaunch.
    ///     See `HintManager.isHintSnoozed`.
    static let hintSnoozedUntil = Key<Date?>("hintSnoozedUntil", default: nil)
    static let hintYPositionByApp = Key<[String: CGFloat]>("hintYPositionByApp", default: [:])
    static let hintYPositionForPinnedMode = Key<CGFloat?>("hintYPositionForPinnedMode", default: nil)
    static let hintYPositionForUntetheredModeScreens = Key<[String: CGFloat]>("hintYPositionForUntetheredModeScreens", default: [:])
    static let showHintAccessibilityAlert = Key<Bool>("showHintAccessibilityAlert", default: true)
//    static let showHintScreenRecordingAlert = Key<Bool>("showHintScreenRecordingAlert", default: true)
    static let showHintMicrophonePermissionAlert = Key<Bool>("showHintMicrophonePermissionAlert", default: true)
    static let showHintUpdateAvailableAlert = Key<Bool>("showHintUpdateAvailableAlert", default: true)
    static let dismissedUpdateAlertVersion = Key<String>("dismissedUpdateAlertVersion", default: "")
    static let showHintTranscriptionFailedAlert = Key<Bool>("showHintTranscriptionFailedAlert", default: true)
    static let showHintTranscriptionSilentAlert = Key<Bool>("showHintTranscriptionSilentAlert", default: true)
    static let showHintTranscriptionCancelledAlert = Key<Bool>("showHintTranscriptionCancelledAlert", default: true)
    static let showHintTranscriptionInputDeviceFailedAlert = Key<Bool>("showHintTranscriptionInputDeviceFailedAlert", default: true)
    static let showHintTranscriptionInputDeviceUnpluggedAlert = Key<Bool>("showHintTranscriptionInputDeviceUnpluggedAlert", default: true)
    static let showHintTranscriptionDetectedNewInputDeviceAlert = Key<Bool>("showHintTranscriptionDetectedNewInputDeviceAlert", default: true)

    // User Info
    static let userFullName = Key<String?>("userFullName", default: nil)
    static let userCompanyName = Key<String?>("userCompanyName", default: nil)
    
    // Tethered Button Menu
    static let tetheredButtonShowAppIcons = Key<Bool>("tetheredButtonShowAppIcons", default: true)
    static let tetheredButtonHiddenApps = Key<[String: Bool]>("tetheredButtonHiddenApps", default: [:])
    
    // Alerts
    static let showTwoWeekProTrialEndedAlert = Key<Bool>("showTwoWeekProTrialEndedAlert", default: false)
    static let hasClosedTrialEndedAlert = Key<Bool>("hasClosedTrialEndedAlert", default: false)
    
    // Notifications
    static let footerNotifications = Key<[FooterNotification]>("footerNotifications", default: [FooterNotification.discord])
    static let keyboardTurnedOffNotificationDismissedUntilDate = Key<Date?>("keyboardTurnedOffNotificationDismissedUntilDate", default: nil)

    // Stop generation behavior
    static let stopMode = Key<StopMode>("stopMode", default: .removePartial)
    static let stopModeUserConfigured = Key<Bool>("stopModeUserConfigured", default: false)
    
    // OCR Comparison - BETA Only.
    // DEPRECATED: ocrComparisonResults is now stored in temp directory. This key is only kept for migration.
    static let ocrComparisonResults = Key<Data?>("ocrComparisonResults", default: nil)
    static let enableOCRComparison = Key<Bool>("enableOCRComparison", default: false)
    static let enableAutoOCRComparison = Key<Bool>("enableAutoOCRComparison", default: false)

    // QuickEdit
    #if DEBUG || ONIT_BETA
    static let hideBugReportEmoji = Key<Bool>("hideBugReportEmoji", default: false)
    #endif
    #if DEBUG
    static let scoringDebugWindowOpen = Key<Bool>("scoringDebugWindowOpen", default: false)
    #endif
    // Screen recording
    static let screenRecordingPermissionAsked = Key<Bool>("screenRecordingPermissionAsked", default: false)

    static let capsLockModifierShortcuts = Key<[String]>("capsLockModifierShortcuts", default: [])

    /// Gates dictation data-collection in private-browser windows.
    static let typeaheadDisabledInPrivateBrowser = Key<Bool>("typeaheadDisabledInPrivateBrowser", default: true)

    // Transcription (Speech-to-Text)
    static let transcriptionEnabled = Key<Bool>("transcriptionEnabled", default: true)
    /// Which perplexity-scoring LM the pipeline uses (see `ScoringModel`).
    /// Defaults to the English Llama 3.2 1B; a user whose language it handles
    /// poorly can switch to a language-specialized model (e.g. RoLlama).
    static let selectedScoringModelId = Key<String>("selectedScoringModelId", default: ScoringModel.englishLlama.id)
    /// PRO: user-added custom scoring models (any MLX HuggingFace repo). Validated
    /// on add; see `ScoringModel` + the Smart Formatting settings.
    static let customScoringModels = Key<[ScoringModel]>("customScoringModels", default: [])
    /// DEBUG A/B toggle for the Parakeet offline-warmup fix. When true (default),
    /// FluidAudioWarmupProvider loads already-downloaded models via `loadFromCache`
    /// (no network). When false, it always calls `downloadAndLoad`, which does a
    /// timeout-less HuggingFace Hub round-trip and hangs with no wifi - i.e. flip
    /// this OFF to reproduce the original bug and confirm the fix's effect.
    static let parakeetOfflineWarmupEnabled = Key<Bool>("parakeetOfflineWarmupEnabled", default: true)
    static let transcriptionHoldToRecord = Key<Bool>("transcriptionHoldToRecord", default: true)
    static let transcriptionInputDevice: Key<MicrophoneInputDevice?> = Key("transcriptionInputDevice", default: nil)
    static let transcriptionAutoSwitchMicrophone = Key<Bool>("transcriptionAutoSwitchMicrophone", default: false)
    static let transcriptionDuckAudio = Key<Bool>("transcriptionDuckAudio", default: false)
    /// Play short sound effects at dictation start/stop. Off by default.
    static let transcriptionSoundEffectsEnabled = Key<Bool>("transcriptionSoundEffectsEnabled", default: false)
    /// Playback volume for dictation sound effects (0.0–1.0). Defaults to half.
    static let transcriptionSoundEffectsVolume = Key<Double>("transcriptionSoundEffectsVolume", default: 0.5)
    static let transcriptionDictationRepairEnabled = Key<Bool>("transcriptionDictationRepairEnabled", default: true)
    static let transcriptionCompletedCount = Key<Int>("transcriptionCompletedCount", default: 0)
    /// Kill switch for the Spotlight-only Accessibility insertion workaround. When true (default),
    /// dictated text focused in the macOS Spotlight search field is inserted via the Accessibility
    /// API instead of synthesized ⌘V (which lands on the wrong process behind Spotlight's panel).
    /// When false, all insertions use the normal paste path.
    static let spotlightAXInsertEnabled = Key<Bool>("spotlightAXInsertEnabled", default: true)
    #if DEBUG || ONIT_BETA
    static let transcriptionAlwaysShowCorrectionPrompt = Key<Bool>("transcriptionAlwaysShowCorrectionPrompt", default: true)
    static let autoeditEnabled = Key<Bool>("autoeditEnabled", default: false)
    static let autoeditLocalModel = Key<String?>("autoeditLocalModel", default: nil)
    static let autoeditPrompt = Key<String>("autoeditPrompt", default: """
        Improve the selected text while keeping my original voice and intent.
        - Fix spelling, grammar, and clarity issues
        - Make it more concise and easier to read without removing important details
        - Preserve personal touches, casual phrasing, and a friendly but professional tone
        - Do not sound robotic, overly polished, or like AI-written text
        - Avoid common AI tells (for example: em dashes, generic transitions, or corporate fluff)

        Style guidance:
        - Casual, direct, and human
        - Professional but approachable
        - Confident, not salesy

        Context awareness:
        - If the text is UI, website, or product copy, optimize it to be clear, compelling, and user-focused
        - If it's a message or note, prioritize natural flow and authenticity

        Output rules:
        - Do not add new information
        - Do not change the meaning
        - Return only the improved text as a single version
        - Do not provide multiple options, alternatives, or variations

        Punctuation rules:
        - Do not use em dashes or dash-based sentence breaks of any kind
        - Rewrite sentences that would normally use an em dash using commas, periods, or parentheses instead
        - If an em dash appears in the input, remove it in the output
        - Add punctuation to break up run-on sentences and newlines to break up excessively long paragraphs
        """)
    #else
    static let transcriptionAlwaysShowCorrectionPrompt = Key<Bool>("transcriptionAlwaysShowCorrectionPrompt", default: false)
    #endif
    static let transcriptionOverlayPositioningMode = Key<OverlayPositioningMode>("transcriptionOverlayPositioningMode", default: .ax)
    #if DEBUG || ONIT_BETA
    /// Ordered list of recently used correction tags (most recent first).
    static let transcriptionRecentTags = Key<[String]>("transcriptionRecentTags", default: [])
    #endif
    static let transcriptionHistoryEnabled = Key<Bool>("transcriptionHistoryEnabled", default: true)
    /// Lifetime count of corrections successfully uploaded to Firebase,
    /// keyed by Firebase account uid (== onit accountId as a string).
    static let transcriptionContributionsByAccount = Key<[String: Int]>("transcriptionContributionsByAccount", default: [:])
    static let transcriptionHasConsentedToSendingTranscriptionData = Key<Bool>("transcriptionHasConsentedToSendingTranscriptionData", default: false)
    /// Whether the Parakeet CoreML model has completed warmup at least once on this device.
    /// Used to distinguish first-time model downloads from subsequent reloads in analytics.
    static let parakeetWarmupCompletedOnce = Key<Bool>("parakeetWarmupCompletedOnce", default: false)
    /// Whether any Whisper CoreML model has completed warmup at least once on this device.
    /// Mirrors `parakeetWarmupCompletedOnce` so analytics can tell a first-time download
    /// from a subsequent reload.
    static let whisperWarmupCompletedOnce = Key<Bool>("whisperWarmupCompletedOnce", default: false)
    /// Whether the Moonshine ONNX model has completed warmup at least once on this device.
    /// Mirrors `parakeetWarmupCompletedOnce` / `whisperWarmupCompletedOnce` so analytics can
    /// tell a first-time download from a subsequent reload.
    static let moonshineWarmupCompletedOnce = Key<Bool>("moonshineWarmupCompletedOnce", default: false)
    /// Whether the Qwen3-ASR MLX model has completed warmup at least once on this device.
    /// Mirrors the other backend warmup flags so analytics can tell a first-time download
    /// from a subsequent reload.
    static let qwen3WarmupCompletedOnce = Key<Bool>("qwen3WarmupCompletedOnce", default: false)
    /// Whether any MLX-based ASR model has completed warmup at least once on this device.
    static let mlxWarmupCompletedOnce = Key<Bool>("mlxWarmupCompletedOnce", default: false)
    /// Whether the scoring cleanup model has completed warmup at least once on this device.
    /// Used to distinguish first-time model downloads from subsequent reloads in analytics.
    static let scoringWarmupCompletedOnce = Key<Bool>("scoringWarmupCompletedOnce", default: false)
    /// Whether the fine-tuned improvement LLM (used for N-best selection and the
    /// Smart Cleanup backtracking pass) has completed warmup at least once on this device.
    /// Used to distinguish first-time model downloads from subsequent reloads in analytics.
    static let improvementLLMWarmupCompletedOnce = Key<Bool>("improvementLLMWarmupCompletedOnce", default: false)

    // Custom Dictionary (CTC biasing)
    static let customDictionaryEnabled = Key<Bool>("customDictionaryEnabled", default: false)
    /// Layer A - the post-decode confusions + proxy + Llama-NLL-gate substitution
    /// in `CustomDictionaryService.rescore`. OFF by default: the dictionary ships
    /// via Layer B prompt biasing (Qwen3/Granite). The proxy/gate is the historical
    /// weak link (unreliable proxy selection), so it's opt-in, not removed.
    static let customDictionaryRescoreEnabled = Key<Bool>("customDictionaryRescoreEnabled", default: false)
    /// V2 storage with full term metadata (id, text, createdAt). The legacy `customDictionaryTerms`
    /// key (Key<[String]>) is no longer read - BETA testers' existing terms will be reset.
    static let customDictionaryTermsV2 = Key<[CustomDictionaryTerm]>("customDictionaryTermsV2", default: [])
    static let customDictionaryPendingSuggestions = Key<[String]>("customDictionaryPendingSuggestions", default: [])
    /// Lowercased terms the user explicitly dismissed (×) from the correction
    /// "New terms" bar. Mining never auto-adds these again; they render as
    /// disabled chips whose + re-adds them (which also clears them from here).
    static let customDictionaryDismissedTerms = Key<[String]>("customDictionaryDismissedTerms", default: [])
    /// Sentinel set to true once the V1 → V2 `customDictionaryTerms` migration has run on this device.
    /// Lets `cleanupLegacyStorage()` short-circuit instead of probing UserDefaults on every launch.
    static let customDictionaryLegacyCleared = Key<Bool>("customDictionaryLegacyCleared", default: false)
    /// Sentinel set to true once the default "Onit" term has been seeded into the dictionary.
    static let customDictionarySeeded = Key<Bool>("customDictionarySeeded", default: false)
    /// DEBUG-only kill switch for the audio KWS path. When `true`, `rescore()`
    /// behaves as if the model never loaded - the common-mistakes substring
    /// path becomes the only way replacements can fire. Used to verify the
    /// fallback works without breaking the build.
    static let customDictionaryDisableKWS = Key<Bool>("customDictionaryDisableKWS", default: false)

    // Snippets
    /// Whether snippet auto-expansion runs in the dictation pipeline. Flipped on
    /// automatically the first time the user adds a snippet (mirrors the custom
    /// dictionary's auto-enable-on-add). Seeded example snippets alone do NOT
    /// enable it, so the educational defaults never fire until the user opts in.
    static let snippetsEnabled = Key<Bool>("snippetsEnabled", default: false)
    /// V1 storage for user snippets (id, name, replacement, createdAt).
    static let snippetsV1 = Key<[Snippet]>("snippetsV1", default: [])
    /// The customizable trigger keyword appended to snippet base names to form
    /// their dictation trigger. Single source of truth: changing it retroactively
    /// re-targets every snippet whose `appendsKeyword` is true. An empty keyword
    /// matches the base name alone (never a trailing-space trigger).
    static let snippetKeyword = Key<String>("snippetKeyword", default: "snippet")
    /// One-shot guard for the migration that split the welded " snippet" suffix
    /// out of stored `Snippet.name`s and set each snippet's `appendsKeyword` flag.
    static let snippetsKeywordMigrated = Key<Bool>("snippetsKeywordMigrated", default: false)

    // App Window
    static let appHomeCuratedSocialsSectionDismissedForever = Key<Bool>(
        "appHomeCuratedSocialsSectionDismissedForever",
        default: false
    )
    
    static let appHomeCuratedSocialsSectionDismissedAt = Key<Date?>(
        "appHomeCuratedSocialsSectionDismissedAt",
        default: nil
    )
    
    static let appHomeCuratedSocialsDailyStackDoneDismissedAt = Key<Date?>(
        "appHomeCuratedSocialsDailyStackDoneDismissedAt",
        default: nil
    )
    
    static let appHomeCuratedSocialsStackDoneDismissedAt = Key<Date?>(
        "appHomeCuratedSocialsStackDoneDismissedAt",
        default: nil
    )

    // MARK: - Smart Cleanup Paywall

    /// When the Smart Cleanup upgrade prompt was last shown after a refused cleanup, so it
    /// doesn't follow every dictation. See `SmartCleanupUpgradePrompt`.
    static let smartCleanupUpgradePromptLastShownAt = Key<Date?>("smartCleanupUpgradePromptLastShownAt", default: nil)

    // Retired (Oct 2026): dictation is free and unlimited, the dictation word meter is gone.
    // Its keys are no longer read or written, and existing values are left in place. Never
    // reuse these names with another meaning. The meter's old Keychain items are left too.
    // "dictationWordsUsedThisPeriod" (Int), "dictationPeriodStartDate" (Date?),
    // "dictationPeriodAnchorDay" (Int?), "dictationPaywallDebugForceFreeTier" (Bool).

    // MARK: - Transcription Config Keys

    /// Keys for advanced transcription configuration settings
    /// Access via: Defaults[Defaults.Keys.TranscriptionConfigKeys.keyName]
    enum TranscriptionConfigKeys {
        // Confidence & Audio
        static let confidenceThreshold = Key<Double>("transcriptionConfidenceThreshold", default: 0.5)
        static let autoPunctuation = Key<Bool>("transcriptionAutoPunctuation", default: true)
        static let eouDebounceMs = Key<Int>("transcriptionEouDebounceMs", default: 1280)

        /// Chunked-streaming transcription (BETA). When true, the dictation
        /// pipeline transcribes VAD/silence-aligned audio segments in the
        /// background during pauses so the final transcript assembles quickly at
        /// key release instead of one single-shot pass. Off by default; only
        /// takes effect when the active ASR engine supports per-segment decoder
        /// context (Parakeet CoreML and the MLX/Qwen backend) - other engines
        /// silently stay single-shot. Mirrored on `TranscriptionConfig`.
        static let chunkedStreamingEnabled = Key<Bool>("transcriptionChunkedStreamingEnabled", default: false)

        // N-best Configuration
        static let nbestCount = Key<Int>("transcriptionNbestCount", default: 3)
        static let nbestSelectionEnabled = Key<Bool>("transcriptionNbestSelectionEnabled", default: false)

        // Sampling Parameters
        static let temperature = Key<Double>("transcriptionTemperature", default: 1.5)
        static let topP = Key<Double>("transcriptionTopP", default: 0.95)

        /// User-facing ASR model selection (id from `ASRModel.catalog`).
        /// `backend` below is derived from this selection but is also written back
        /// to UserDefaults so the warmup providers - which read the legacy key
        /// directly without going through `TranscriptionConfig` - keep working.
        static let selectedASRModelId = Key<String>("transcriptionSelectedASRModelId", default: ASRModel.recommendedDefaultModelId)

        // Recording
        static let recordingTailBufferMs = Key<Int>("transcriptionRecordingTailBufferMs", default: 300)
        static let forceCorrectionUI = Key<Bool>("transcriptionForceCorrectionUI", default: false)
        #if DEBUG
        /// Day-bucket (yyyy-MM-dd in the user's calendar) the DEBUG daily reset last forced
        /// forceCorrectionUI back to true. Nil means it has never run.
        static let forceCorrectionUILastResetDay = Key<String?>("transcriptionForceCorrectionUILastResetDay", default: nil)
        #endif
        static let windowContextScrapeEnabled = Key<Bool>("transcriptionWindowContextScrapeEnabled", default: true)
        static let shortcutType = Key<TranscriptionShortcutType>("transcriptionShortcutType", default: .capsLock)

        /// When true, the dictation shortcut is press-once-to-start, press-again-to-stop, always
        /// in hands-free activation mode. Bypasses hold-to-record and double-tap behaviors.
        static let handsFreeOnly = Key<Bool>("transcriptionHandsFreeOnly", default: false)

        /// Number of active slots in the custom dictation shortcut pool (1..5).
        static let customShortcutCount = Key<Int>("transcriptionCustomShortcutCount", default: 1)
        /// Index of the most-recently-triggered custom dictation shortcut slot. Used by the hint to show the shortcut most relevant to the user's current keyboard.
        static let lastUsedCustomShortcutIndex = Key<Int>("transcriptionLastUsedCustomShortcutIndex", default: 0)
        /// Type of each alternate slot (slots 1..N). Values: "capsLock", "fn", or "custom". Missing entries default to "custom".
        static let alternateSlotTypes = Key<[String]>("transcriptionAlternateSlotTypes", default: [])

        // Language
        static let transcriptionLanguages = Key<[String]>("transcriptionLanguages", default: [])
        // VAD silence filter
        static let sileroVadEnabled = Key<Bool>("transcriptionSileroVadEnabled", default: true)
        static let sileroVadUserConfigured = Key<Bool>("transcriptionSileroVadUserConfigured", default: false)
        // Onset silence prepend - prepends 3s of silence before transcription to give
        // the model warm-up time and recover words spoken at the very start of a recording
        static let onsetSilencePrependEnabled = Key<Bool>("transcriptionOnsetSilencePrependEnabled", default: false)
        // ASR Backend
        static let backend = Key<TranscriptionBackend>("transcriptionBackend", default: .parakeetCoreML)
        /// MLX GPU recyclable-buffer-pool cap in MB. 0 = Auto (use the per-model
        /// default declared in the adapter). Bounds the Metal cache that
        /// otherwise grows unbounded across inferences (observed at ~12 GB).
        /// User-tunable via Advanced Settings. Applied in `MLXASREngine`.
        static let mlxCacheLimitMB = Key<Int>("transcriptionMLXCacheLimitMB", default: 0)
        /// Minutes of dictation inactivity after which the resident ASR model is
        /// unloaded to reclaim RAM (Granite ~8-10 GB, Qwen ~5.5 GB). The model
        /// transparently reloads on the next dictation (reload ≤1 s for all
        /// backends except Whisper ~5.4 s), masked by the user speaking. 0 =
        /// never unload (keep the model resident for the whole session). Read by
        /// `ASRModelLifecycleService`.
        static let asrInactivityUnloadMinutes = Key<Int>("transcriptionASRInactivityUnloadMinutes", default: 30)
        /// Inject the custom-dictionary glossary into the ASR model's prompt
        /// (Qwen3 `context:` / Granite `userPrompt:`) to bias spelling. Only the
        /// MLX backend reads it; non-MLX models ignore it. Default ON - this is
        /// core pipeline now (no user-facing toggle; the old toggle was removed
        /// to reduce settings complexity).
        static let asrDictionaryPromptEnabled = Key<Bool>("transcriptionASRDictionaryPromptEnabled", default: true)
        /// Decode-time token-trie boosting of dictionary terms in the Qwen3 MLX
        /// decoder (shallow fusion with rollback revocation; see the vendored
        /// `TrieBoost.swift`). Fixes proper-noun mishearings ("Calender" for
        /// "Kalender") at the decoder instead of after it. Opt-in / OFF by default - only `Qwen3MLXAdapter`
        /// reads it. Kept off pending an honest re-eval: the shipping numbers were
        /// overfit to hardcoded aliases + β=6, while production runs β=4 with empty
        /// commonMistakes; default-on also needs the async-overlap latency work
        /// (~+150-200 ms/utterance today) and echo hardening on 4-bit first.
        static let asrTrieBoostEnabled = Key<Bool>("transcriptionASRTrieBoostEnabled", default: false)
        /// Layer C ("autodictionary") - at dictation start, OCR the on-screen
        /// window, mine candidate terms with the deterministic "caps" heuristic
        /// (`CapsTermSelector`), and merge them (ephemerally) into the
        /// prompt-biasing glossary for that utterance only. Opt-in / OFF by
        /// default - kept off pending the trie-boost re-eval (it feeds the boost
        /// glossary, compounding the same latency/echo risks) and a privacy review
        /// of default-on screen capture. Both the mining and the payload are gated
        /// to `config.backend == .mlx` (Qwen3/Granite), so it's inert on every
        /// other backend. The OCR source falls back to accessibility cursor-text
        /// when screen recording isn't granted. Mined terms are never saved.
        static let asrOnScreenTermsEnabled = Key<Bool>("transcriptionASROnScreenTermsEnabled", default: false)
        /// Layer C term source. false (default) = screenshot OCR of the focused
        /// window; true = the accessibility preceding-text around the cursor. OCR
        /// won the eval (target on-screen 81% vs ~20% for preceding text), but the
        /// AX source needs no screen-recording permission and no capture latency.
        static let asrOnScreenTermsUseAccessibility = Key<Bool>("transcriptionASROnScreenTermsUseAccessibility", default: false)
        /// Post-ASR deterministic restore of a dictionary term's exact written form
        /// (camelCase/snake/kebab/paths) when the model emitted it as separate words.
        /// Format-blind matcher with a common-bigram homophone guard ("on it" stays
        /// "on it") + perplexity gate for ambiguous spans. Runs on any backend.
        /// Default ON - core pipeline; the toggle is DEBUG/BETA-only.
        static let asrDictionaryFormatMatchEnabled = Key<Bool>("transcriptionASRDictionaryFormatMatchEnabled", default: true)
        /// Show the debug chrome (context row, tag row, scoring-debug button) in
        /// the in-flow correction overlay. Toggled from the overlay itself
        /// (bottom-right ladybug) to preview the production-clean layout.
        /// DEBUG/BETA builds only - release builds compile the chrome out entirely.
        static let transcriptionOverlayDebugUI = Key<Bool>("transcriptionOverlayDebugUI", default: true)
        /// Perplexity-gate AMBIGUOUS format-matcher merges (spoken span is all
        /// common English words, e.g. "start recording" → start_recording): score
        /// the sentence both ways with MLXScoringEngine and veto the merge when
        /// the formatted variant fits the context worse than the threshold.
        /// Distinctive spans merge deterministically without scoring.
        static let asrDictionaryFormatMatchPerplexityGate = Key<Bool>("transcriptionASRFormatMatchPerplexityGate", default: true)
        /// EXPERIMENTAL - persistent term memory:
        /// accumulate screen/dictation/correction sightings in a local ACT-R
        /// activation store and feed the top-K terms into the biasing layers at
        /// every dictation, so terms transfer across apps and days. Dev flag,
        /// off by default; requires `asrDictionaryPromptEnabled` + MLX backend.
        static let asrTermMemoryEnabled = Key<Bool>("transcriptionASRTermMemoryEnabled", default: false)
        /// Bias-list size fed to the decode-time trie by term memory. The replay
        /// eval: K=100 → 45.7% needed-term coverage, K=500 → 57%, K=2000 → 64%
        /// (oracle 68.6%); the admission chain is what keeps large K safe
        /// (~1-2% materially-harmful clip rate at 5,688 terms). Clamped 25–2000.
        static let asrTermMemoryTopK = Key<Int>("transcriptionASRTermMemoryTopK", default: 500)
        /// Tier-2 gated fuzzy post-ASR restore of term-memory terms (phone/char
        /// edit distance vs predicted surfaces). Separate flag: it rewrites
        /// final text, so it carries its own precision risk. Off by default.
        static let asrTermMemoryTier2Enabled = Key<Bool>("transcriptionASRTermMemoryTier2Enabled", default: false)
        /// EXPERIMENTAL - always-on ambient capture for term memory: on
        /// app-focus change (1s dwell) and a 2s resample while active, grab
        /// the focused window and mine its text (AX tree walk, or screenshot
        /// OCR when that permission + preference allow), recording the terms
        /// as ambient sightings. Cost gate is CHANGE DETECTION, not time
        /// throttling: the grab is diffed against the last mined capture
        /// (ImageDifferenceDetector tile diff / AX text hash) and the
        /// expensive OCR runs only when content actually changed. Skips when
        /// input-idle, in Low Power Mode, and during secure input. Standing
        /// capture posture - its own opt-in, off by default.
        static let asrTermMemoryAmbientEnabled = Key<Bool>("transcriptionASRTermMemoryAmbientEnabled", default: false)
        /// Retention window: hard-delete a remembered term when its most
        /// recent sighting is older than this many days (aliases + log rows
        /// go with it). 0 = keep forever - activation already demotes stale
        /// terms out of the bias list, so this is a privacy/hygiene control,
        /// not a ranking one. Surfaced as a picker (Never/6mo/1y/2y/5y).
        static let asrTermMemoryRetentionDays = Key<Int>("transcriptionASRTermMemoryRetentionDays", default: 0)

        // Smart Formatting
        static let smartFormattingEnabled = Key<Bool>("transcriptionSmartFormattingEnabled", default: SmartCleanupAvailability.isCompiledIn)
        /// Id of the `CleanupProvider` that cleans a dictation (`CleanupProviderID`).
        /// Nil until first launched on a build that has providers, then migrated from
        /// `smartFormattingEnabled` (see `TranscriptionConfig.resolvedCleanupProviderID`).
        static let cleanupProviderID = Key<String?>("transcriptionCleanupProviderID", default: nil)
        /// Rewrite: after cleanup (or instead of it, when cleanup is off), send the
        /// text to the user's own model with their prompt (`CleanupService` runs the
        /// two in series).
        static let rewriteEnabled = Key<Bool>("transcriptionRewriteEnabled", default: false)
        // LM Conditioning (acoustic matching)
        static let lmConditioningEnabled = Key<Bool>("transcriptionLMConditioningEnabled", default: false)
        static let sfBacktrackingEnabled = Key<Bool>("sfBacktrackingEnabled", default: false)
        static let sfPunctuationEnabled = Key<Bool>("sfPunctuationEnabled", default: true)
        static let sfEmojiEnabled = Key<Bool>("sfEmojiEnabled", default: true)
        /// User-defined / overridden emoji triggers (spoken name -> glyph), merged on
        /// top of the built-in defaults. Empty = use built-in defaults only.
        static let emojiCustomGlyphs = Key<[String: String]>("emojiCustomGlyphs", default: [:])
        /// Semantic (embedding cosine) emoji matching for non-exact spoken names,
        /// e.g. "crying emoji" -> 😭. On by default; users can disable it.
        static let emojiSemanticMatchingEnabled = Key<Bool>("emojiSemanticMatchingEnabled", default: true)
        static let sfFormattingEnabled = Key<Bool>("sfFormattingEnabled", default: true)
        static let sfFillersEnabled = Key<Bool>("sfFillersEnabled", default: true)
        static let sfEmailsUrlsEnabled = Key<Bool>("sfEmailsUrlsEnabled", default: true)
        /// Lay a dictated email out over several lines (greeting, body, signature).
        /// English only, only in an email composer (`EmailComposer`), and only when
        /// the text is recognized as an email. On by default: it's well-scoped
        /// (fires only in a detected mail app/site on text that looks like an email).
        static let sfEmailLayoutEnabled = Key<Bool>("sfEmailLayoutEnabled", default: true)

        // Email-layout customization (all layered on top of built-in defaults;
        // an add/remove pair per list so a user can both extend and disable
        // built-ins). See `EmailLayoutTermsManager` and `EmailComposer`.
        /// Greeting openers the user added on top of the built-in list ("sup").
        static let emailGreetingAddTriggers = Key<[String]>("emailGreetingAddTriggers", default: [])
        /// Built-in greeting openers the user turned off ("hey").
        static let emailGreetingRemoveTriggers = Key<[String]>("emailGreetingRemoveTriggers", default: [])
        /// Sign-off closers the user added on top of the built-in list ("peace").
        static let emailSignOffAddTriggers = Key<[String]>("emailSignOffAddTriggers", default: [])
        /// Built-in sign-off closers the user turned off ("thanks").
        static let emailSignOffRemoveTriggers = Key<[String]>("emailSignOffRemoveTriggers", default: [])
        /// Extra app bundle ids the user treats as an email composer.
        static let emailComposerAddBundleIds = Key<[String]>("emailComposerAddBundleIds", default: [])
        /// Built-in mail-app bundle ids the user turned off.
        static let emailComposerRemoveBundleIds = Key<[String]>("emailComposerRemoveBundleIds", default: [])
        /// Extra webmail hosts the user treats as an email composer.
        static let emailComposerAddHosts = Key<[String]>("emailComposerAddHosts", default: [])
        /// Built-in webmail hosts the user turned off.
        static let emailComposerRemoveHosts = Key<[String]>("emailComposerRemoveHosts", default: [])

        static let sfDuplicatesEnabled = Key<Bool>("sfDuplicatesEnabled", default: true)
        static let sfNumbersEnabled = Key<Bool>("sfNumbersEnabled", default: true)
        static let sfNumberStyle = Key<String>("sfNumberStyle", default: "with_comma")
        static let sfAbbreviateLargeNumbers = Key<Bool>("sfAbbreviateLargeNumbers", default: false)
        static let sfCapitalizationEnabled = Key<Bool>("sfCapitalizationEnabled", default: true)

        // Transcript history UI
        /// Whether the transcript list shows the inline word-level diff between
        /// raw ASR and the current displayed text (post smart-cleanup + manual edits).
        static let showTranscriptEdits = Key<Bool>("transcriptionShowEdits", default: true)
    }

    // Timed Check Dates
    static let lastCheckedValidRemoteTokens = Key<Date?>("lastCheckedValidRemoteTokens", default: nil)

    // Localization (app UI language)
    static let translationSourceLanguageCode = Key<String?>("translationSourceLanguageCode", default: nil)

    // VAD warmup analytics
    static let vadWarmupCompletedOnce = Key<Bool>("vadWarmupCompletedOnce", default: false)
}

extension NSRect: Defaults.Serializable {

}
