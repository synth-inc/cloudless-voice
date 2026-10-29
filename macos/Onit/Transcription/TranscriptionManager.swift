// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionManager.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

@preconcurrency import AVFoundation
@preconcurrency import Vision
import AppKit
import Combine
import Defaults
import Foundation

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// Manages the transcription feature lifecycle including model initialization,
/// shortcut handling, and active transcription sessions.
///
/// Uses Parakeet CoreML backend via Python server for batch ASR.
@MainActor
final class TranscriptionManager: ObservableObject {

    // MARK: - Singleton

    static let shared = TranscriptionManager()

    // MARK: - Published Properties

    /// Whether models are initialized and ready for transcription
    @Published private(set) var isInitialized = false

    /// Tracks whether we've already shown the "cleanup model loading" alert this session
    private var hasShownCleanupLoadingAlert = false

    /// Whether models are currently being downloaded/initialized
    @Published private(set) var isInitializing = false

    /// Model download progress (0.0 - 1.0)
    @Published private(set) var initializationProgress: Double = 0.0

    /// Whether a transcription session is currently active
    @Published private(set) var isTranscribing = false

    /// When true, a dictation session feeds the in-app onboarding demo only: the pipeline runs
    /// identically, but the result is NOT inserted into any app, saved to history, or counted.
    /// Off by default - no effect on normal transcription. Makes the demo accessibility-independent.
    var isDemoCaptureMode: Bool = false

    /// Preceding/following text the onboarding demo feeds to the cleanup pipeline (instead of the
    /// AX-read field context), so "continue a sentence" / "insert mid-sentence" steps can show
    /// context-aware merging. Only consulted while `isDemoCaptureMode` is true.
    var demoPrecedingText: String?
    var demoFollowingText: String?

    /// Belt-and-suspenders teardown for the onboarding demo - guarantees demo state can't linger
    /// outside the demo. Called from the onboarding window's close, alongside the view's `.onDisappear`.
    func resetDemoCaptureState() {
        isDemoCaptureMode = false
        demoPrecedingText = nil
        demoFollowingText = nil
    }

    /// Error message if initialization or transcription fails
    @Published private(set) var errorMessage: String?

    // MARK: - Activation Mode

    enum ActivationMode: String {
        case hold
        case toggle
        case handsfree
    }

    /// How the current transcription session was activated
    private(set) var activationMode: ActivationMode = .hold

    // MARK: - State

    /// Observable state for UI binding
    let state = TranscriptionState()

    /// Last successfully inserted transcription (persists after overlay dismissal for undo/edit)
    @Published private(set) var lastInsertedText: String?

    /// Target PID for the last transcription (needed for undo to send keystrokes to correct app)
    private var lastTargetPid: pid_t?

    /// The AX window element that was focused when the last transcription was pasted.
    /// Used to detect same-app window switches (e.g. two Chrome windows) and dismiss the overlay.
    private var lastTargetWindow: AXUIElement?

    /// The text that was most recently pasted, used by the AX positioning fallback to find the
    /// pasted range rather than relying on the post-paste selection (which is often empty).
    private var lastPastedText: String?

    /// Raw ASR text from the last transcription (persists after overlay dismissal for edit)
    private var lastRawASRText: String?

    /// Recorded audio samples from the last transcription (persists after overlay dismissal for edit)
    private var lastRecordedAudioSamples: [Float]?

    // MARK: - Private Properties

    private let microphoneManager = MicrophoneInputManager.shared
    // Per-backend ASR services are reached via ASRBackendRegistry (see
    // currentASRService); no per-service property needed here.
    private let nbestSelectionService = NbestSelectionService.shared
    private let llmService = TranscriptionLLMService.shared
    private let cleanupService = CleanupService.shared
    private let config = TranscriptionConfig.shared

    private var initializationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var audioStreamTask: Task<Void, Never>?
    private var recordedAudioProcessingTask: Task<Void, Never>?
    private var audioHydrationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Chunked-Streaming State

    /// Chunked-streaming session for the current dictation, or `nil`. Armed only
    /// when `chunkedStreamingEnabled` is on, the active backend advertises
    /// streaming, and an engine resolved (see `armStreamingSessionIfEligible`).
    /// **Every streaming branch gates on this being non-nil**, so when the flag
    /// is off it stays `nil` and the batch path runs unchanged. Confined to the
    /// MainActor like the rest of the manager; the session itself is an `actor`.
    private var streamingSession: StreamingDictationSession?

    /// The backend `streamingSession` was armed for. A mid-dictation backend
    /// change (e.g. the user switches models in Settings) invalidates the
    /// session - its segments were transcribed by an engine that's no longer
    /// active - so the dictation falls back to single-shot.
    private var streamingSessionBackend: TranscriptionBackend?

    /// Count of 16 kHz samples already handed to `streamingSession`. The feed
    /// sends the delta of the active service's *resampled* accumulation buffer,
    /// so the session observes byte-identical audio to the batch path without a
    /// second resampling stage. Reset per dictation in `armStreamingSessionIfEligible`.
    private var streamingFedSampleCount = 0

    private var targetPid: pid_t?
    private var targetAppName: String?
    private var targetAppBundleId: String?
    private var historySaveTask: Task<Int64?, Never>?

    /// Number of `saveCorrection` / `saveCorrectionToHistoryOnly` invocations
    /// whose detached persistence work is still in flight. Acts as a
    /// re-entrancy guard (e.g. user double-clicking "Save" or the keyboard
    /// shortcut firing twice) - without it, a second invocation can race the
    /// first and create a duplicate `TranscriptionCorrection` row + duplicate
    /// WAV file when `historyId` is unavailable (history feature disabled or
    /// `historySaveTask` resolves to nil).
    ///
    /// Counter rather than Bool so the guard outlives `dismissOverlay()` (which
    /// fires synchronously while the detached save is still running) - the
    /// detached task decrements when it finishes. `dismissOverlay()` no longer
    /// resets this; doing so used to release the guard before the actual save
    /// completed, defeating the protection.
    private var inflightSaveCount = 0
    private var isSavingCorrection: Bool { inflightSaveCount > 0 }

    /// Decrement `inflightSaveCount` from a non-isolated context.
    ///
    /// Detached save tasks call this via `await self?.decrementInflightSaveCount()`
    /// instead of wrapping the mutation in `MainActor.run { ... }`. The wrapped form
    /// captures task-isolated `self` into a main-actor-isolated closure, which Swift 6
    /// strict concurrency flags as a potential sending race; routing through a
    /// `@MainActor` method preserves isolation cleanly.
    @MainActor
    private func decrementInflightSaveCount() {
        inflightSaveCount = max(0, inflightSaveCount - 1)
    }

    // Analytics tracking
    private var sessionStartTime: Date?
    private var modelInitStartTime: Date?

    /// Timestamp of the shortcut tap that initiated the current recording session.
    /// Set by the shortcut handler before startTranscription/toggle is called so we can
    /// measure total latency from user intent to first audio frame.
    var shortcutTapTime: Date?

    /// Staging area for startup timing data collected after startRecording() returns.
    /// Held here until the first audio buffer arrives so all timings fire in one analytics event.
    var startupTimingSnapshot: StartupTimingSnapshot?

    /// Clipboard snapshot taken at transcription start, restored when overlay is dismissed
    private var clipboardSnapshot: PasteboardManager.Snapshot?

    private let insertService = TranscriptionInsertService()

    // MARK: - Correction Data Collection

    /// Accessibility context captured at transcription start
    private var precedingText: String?
    private var followingText: String?
    /// Whether the focused field at transcription start is an email composer,
    /// the only place the email layout runs (see `EmailComposer`). nil when the
    /// check did not run because the layout could not act.
    private var inEmailComposer: Bool?
    /// Bumped at each capture of the context above, so a slow AX read from one
    /// dictation cannot land in the next one.
    private var axContextGeneration = 0

    /// A wider slice of the preceding text, kept ONLY for Auto-dictionary term
    /// mining (the accessibility source). `precedingText` is capped at 200 chars
    /// because it also feeds capitalization + LM conditioning + history storage,
    /// where a large window would bloat payloads/latency. Term mining wants far
    /// more context to find proper nouns, so it uses this separate window.
    private var precedingTextForMining: String?
    /// How many chars before the cursor the AX term-miner scans.
    nonisolated private static let axMiningContextChars = 4000

    // MARK: - Dataset Collection

    /// Exclusion reason for corrections saved from the dictation overlay. These saves
    /// stay on this Mac: a correction is uploaded only when the user explicitly asks
    /// for a fix on that transcript (`RequestFixModal`), which clears the exclusion.
    /// A `contributing` value carried over from an older build is deliberately ignored.
    private static func eligibilitySnapshot() -> String? {
        TranscriptionCorrection.ExclusionReason.optOut
    }

    // MARK: - Key Code Constants

    /// Key codes for editing signals monitored during and after OCR.
    /// 51 = Delete, 123 = Left arrow, 124 = Right arrow
    private enum EditingKeyCode {
        static let delete: UInt16 = 51
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let set: Set<UInt16> = [delete, leftArrow, rightArrow]
    }

    // MARK: - Pasted Text Detection

    /// Set to true after the first dummy Vision OCR request fires, so we only warm up once per process lifetime.
    private nonisolated(unsafe) static var isVisionOCRWarmedUp = false

    /// Whether an editing keypress (delete/arrow) was detected during OCR detection window.
    private var editingSignalDetectedBeforeOverlay = false

    /// Key monitor active during OCR - catches editing signals before the overlay exists.
    private var preOverlayEditingMonitor: Any?

    /// OCR result held in reserve while post-OCR editing monitors are active.
    /// Passed to showTranscriptionOverlay when a signal fires.
    private var pendingCorrectionDetectionResult: PastedTextDetectionResult??

    /// Monitors active after OCR completes, waiting for the first editing signal.
    private var postOCRKeyMonitor: Any?
    private var postOCRClickMonitor: Any?
    private var postOCRScrollMonitor: Any?
    private var postOCRAppSwitchObserver: Any?
    private var postOCRDismissTask: Task<Void, Never>?
    private var overlayAutoDismissTask: Task<Void, Never>?


    /// Filename of the screenshot captured at dictation start (debug builds only).
    /// Stored in `TranscriptionHistoryManager.screenshotDirectoryURL` and referenced in the history record.
    private var sessionStartScreenshotFilename: String?

    /// Layer C - ephemeral dictionary terms mined from the session-start screenshot
    /// (OCR + caps heuristic). Populated asynchronously at dictation start, read by
    /// `buildASRPromptPayload`, and reset each session. Never persisted.
    private var onScreenMinedTerms: [String] = []

    /// In-flight Layer C mining; cancelled (and replaced) at each session start
    /// so a slow OCR can't stage terms from the previous session's window.
    private var onScreenMiningTask: Task<Void, Never>?

    /// Window-tree AX mining staged at dictation start (AX Layer C source only):
    /// the capped window text plus selector decisions, kept so the debug record
    /// written at prompt-build time covers both mining sources.
    private var axWindowMiningTrace: (text: String, decisions: [CapsTermSelector.Decision])?

    #if DEBUG || ONIT_BETA
    /// Task that captures the full-window AX context for saving in history (debug builds only).
    /// Started at dictation start but gated on OCR completion so it doesn't compete with
    /// the screenshot poll loop on the main actor.
    private var windowContextTask: Task<String?, Never>?

    /// Continuation that fires when OCR-based paste detection finishes (or is skipped).
    /// `captureWindowContextIfNeeded` waits on this before starting the heavy AX traversal.
    private var ocrDoneContinuation: CheckedContinuation<pid_t?, Never>?

    /// True once `signalOCRDone()` (or session cleanup) fired for this session.
    /// The capture task checks it before parking on the continuation - if the
    /// signal beat the task body (very short dictation), parking would leave the
    /// history save awaiting a continuation nobody will ever resume.
    private var ocrDoneSignaled = false
    #endif

    /// Screenshot captured just before pasting transcription text, used for before/after diff-based pasted text region detection.
    private var beforePasteScreenshot: CGImage?

    /// The screen region (in macOS coordinates) that the after-paste screenshot covers.
    private var screenshotCaptureRegion: CGRect?
    
    /// Result of detecting the pasted text region via OCR on the after-paste screenshot.
    struct PastedTextDetectionResult {
        /// Bounding box, in macOS screen coordinates, encompassing the pasted text region.
        let boundingBox: CGRect

    }
    
    /// The most recent pasted text detection result, used to position the transcription overlay near the pasted text.
    private var lastPastedTextDetectionResult: PastedTextDetectionResult?

    // MARK: - Edit-Last-Transcription Safety

    /// Max seconds after a paste during which `editLastTranscription()` may backspace-and-replace
    /// into the original target. After this window we fall back to copying the corrected text to
    /// the clipboard, so we never destructively edit unrelated content.
    private static let pasteSafetyTTL: TimeInterval = 30

    /// Characters intercepted by `TranscriptionKeysManager.transcriptionHeldShortcuts` while the
    /// transcription shortcut is held - these never reach the focused app, so the paste-safety
    /// monitor must NOT treat them as foreign keystrokes. Any other character typed while the
    /// shortcut is held falls through to the focused app and DOES mark safety dirty.
    /// Keep in sync with the dispatch table in `TranscriptionKeysManager`.
    private static let transcriptionHeldShortcutCharacters: Set<String> = ["c", "v", "e"]

    /// Timestamp of the most recent successful paste. Nil when no paste is replaceable.
    private var lastPasteTimestamp: Date?

    /// Set to true when a non-Onit keystroke fires after a paste, when the focused app changes
    /// to anything other than the original target (or Onit itself), or after `pasteSafetyTTL`
    /// elapses. Persists until the next paste resets it.
    private var pasteSafetyDirty: Bool = false

    private var pasteSafetyKeyMonitor: Any?
    private var pasteSafetyAppSwitchObserver: NSObjectProtocol?
    private var pasteSafetyExpirationTask: Task<Void, Never>?

    
    /// A sendable representation of an OCR text observation, extracted from `VNRecognizedTextObservation`.
    private struct RecognizedTextRegion: @unchecked Sendable {
        let text: String
        let bounds: CGRect
        let confidence: Float
        let candidate: VNRecognizedText?
    }
    
    // MARK: - Initialization
    
    private init() {
        setupObservers()
    }
    
    // MARK: - Public Methods - Model Lifecycle
    
    /// Initialize ASR models in background. Called at app launch.
    func initializeModelsInBackground() {
        guard !isInitialized && !isInitializing else { return }

        isInitializing = true
        errorMessage = nil
        modelInitStartTime = Date()

        // Track initialization started
        AnalyticsManager.Transcription.modelInitializationStarted()

        log.info("TranscriptionManager: Initializing Parakeet CoreML backend")

        // Scoring engine loading is handled by ScoringWarmupProvider
        // (downloads model first, then loads - no separate call needed here)

        initializeASRBackend()
    }

    /// Force-restart warmup polling. Cancels any in-flight `initializationTask` and
    /// relaunches `initializeModelsInBackground`. Used by the onboarding manual-retry
    /// button to recover from a stalled `isInitializing == true` state where the
    /// regular call would early-return on the guard above.
    ///
    /// Three layers of cancellation, because `Task.cancel()` alone is not enough:
    ///   1. Cancel the polling Task (was already in place).
    ///   2. Invalidate every in-flight URLSession inside `HuggingFaceModelDownloader` -
    ///      URLSession does not observe Swift Concurrency cancellation, so a stalled
    ///      `listFiles`/`downloadSingleFile` would otherwise keep its CheckedContinuation
    ///      suspended past the new init's lifetime. This also covers Llama, not just
    ///      Parakeet - both share the same downloader.
    ///   3. Force the WarmupCoordinator to cancel its per-provider Tasks and rebuild
    ///      them from scratch. Without this, `initializeASRBackend()` re-attaches
    ///      to the dying coordinator Task (because `failedProviders[providerId]` is
    ///      still nil at this point) instead of running a fresh warmup. For the
    ///      FluidAudio backend (where the URLSession lives inside the framework, not
    ///      the downloader), this is the only viable cancellation path - the provider
    ///      catches `CancellationError` and resets state to `.idle`.
    func restartInitialization() {
        initializationTask?.cancel()
        initializationTask = nil
        isInitializing = false
        errorMessage = nil
        HuggingFaceModelDownloader.shared.cancelActiveDownloads()
        WarmupCoordinator.shared.retryAllWarmups()
        initializeModelsInBackground()
    }

    /// Initialize the ASR backend via the warmup coordinator.
    private func initializeASRBackend() {
        let backend = TranscriptionConfig.shared.backend
        let providerId = ASRBackendRegistry.descriptor(for: backend).providerId

        let alreadyWarm = isBackendWarmedUp(backend)
        log.info("TranscriptionManager [init-backend]: backend=\(backend.rawValue) providerId=\(providerId) alreadyWarm=\(alreadyWarm)")

        // Check if the active backend is already warmed up
        if alreadyWarm {
            handleWarmupComplete()
            return
        }

        // If a previous warmup failed, clear the stale error and retry
        if WarmupCoordinator.shared.failedProviders[providerId] != nil {
            WarmupCoordinator.shared.retryWarmup(for: providerId)
        }

        // Observe the coordinator's warmup state
        observeBackendWarmupState(backend: backend, providerId: providerId)
    }

    /// Whether the warmup provider matching `backend` reports warmed-up.
    private func isBackendWarmedUp(_ backend: TranscriptionBackend) -> Bool {
        ASRBackendRegistry.descriptor(for: backend).isWarmedUp
    }

    /// Whether the on-disk files for the currently-selected ASR model exist.
    /// Used by the warmup observer to switch from the loose download timeout
    /// (30 min) to the tighter post-download warmup timeout. Backend-agnostic:
    /// reads the filesystem directly via `ASRModelDownloadManager.isInstalledOnDisk(_:)`
    /// - does NOT consult `installState` because that cache is only updated
    /// by user-driven `download()` calls from the picker. First-run downloads
    /// triggered by the warmup providers (MLXWarmupProvider, MoonshineWarmupProvider,
    /// WhisperCoreMLWarmupProvider) go through `HuggingFaceModelDownloader`
    /// directly and never touch `states`, so a cache lookup would always
    /// return false until the user happened to open the picker.
    @MainActor
    private func isModelDownloaded(for backend: TranscriptionBackend) -> Bool {
        let modelId = TranscriptionConfig.shared.selectedASRModelId
        if let model = ASRModel.byId(modelId), model.backend == backend {
            return ASRModelDownloadManager.isInstalledOnDisk(model)
        }
        // Fallback for `.fluidAudio`, which is wired up without a `ASRModel`
        // catalog row today - its warmup provider is the source of truth for
        // download completion.
        if backend == .fluidAudio {
            return FluidAudioWarmupProvider.shared.isWarmedUp
        }
        return false
    }

    /// Poll the active backend's warmup provider and flip `isInitialized` when ready.
    private func observeBackendWarmupState(backend: TranscriptionBackend, providerId: String) {
        initializationTask = Task {
            let downloadMaxWaitTime: TimeInterval = 1800 // 30 minutes max wait for model download on slow connection
            // Per-model timeout - see `ASRModel.warmupTimeoutSeconds`. Whisper
            // Large Turbo's first-load CoreML compile (~77 s) is the outlier
            // that motivates the per-model ceiling; everything else uses 60 s.
            let warmupMaxWaitTime: TimeInterval = await MainActor.run {
                let modelId = TranscriptionConfig.shared.selectedASRModelId
                return ASRModel.byId(modelId)?.warmupTimeoutSeconds ?? 60
            }
            let startTime = Date()
            let pollInterval: UInt64 = 500_000_000 // 500ms
            var warmupPhaseStartTime: Date? = nil

            while !Task.isCancelled {
                if await MainActor.run(body: { isBackendWarmedUp(backend) }) {
                    await MainActor.run {
                        handleWarmupComplete()
                    }
                    return
                }

                // Backend-agnostic: flip to the tighter warmup timeout the moment the
                // current backend's files are on disk. Previous code only watched the
                // Parakeet downloader, leaving Whisper / Moonshine / Qwen / MLX backends
                // stuck on the loose 30-min ceiling for the entire init.
                let downloadComplete = await MainActor.run { isModelDownloaded(for: backend) }
                if downloadComplete && warmupPhaseStartTime == nil {
                    warmupPhaseStartTime = Date()
                }

                // Check for timeout - shorter once we're past the download phase
                let elapsed = Date().timeIntervalSince(startTime)
                let timedOut: Bool
                if let warmupStart = warmupPhaseStartTime {
                    timedOut = Date().timeIntervalSince(warmupStart) > warmupMaxWaitTime
                } else {
                    timedOut = elapsed > downloadMaxWaitTime
                }

                if timedOut {
                    await MainActor.run {
                        let errorMessage = "ASR model initialization timed out"
                        self.errorMessage = errorMessage
                        isInitializing = false
                        // Publish the give-up to the coordinator: `isInitialized` stays false, so any
                        // readiness gate that waits on "preparing" (Hint pill, menu-bar download row,
                        // Home setup card, status header) would otherwise spin forever with no Retry.
                        WarmupCoordinator.shared.recordFailure(
                            .timeout(provider: providerId),
                            for: providerId
                        )
                        AnalyticsManager.Transcription.modelInitializationFailed(error: errorMessage)
                        modelInitStartTime = nil
                    }
                    log.error("TranscriptionManager: Warmup timed out after \(Int(elapsed))s")
                    return
                }

                // Check coordinator state for backend-specific failures
                let providerError = await MainActor.run { WarmupCoordinator.shared.failedProviders[providerId] }
                if let error = providerError {
                    await MainActor.run {
                        let errorMessage = "ASR model warmup failed: \(error.localizedDescription)"
                        self.errorMessage = errorMessage
                        isInitializing = false
                        AnalyticsManager.Transcription.modelInitializationFailed(error: errorMessage)
                        modelInitStartTime = nil
                    }
                    log.error("TranscriptionManager: Coordinator warmup failed: \(error.localizedDescription)")
                    return
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    /// Handle successful warmup completion
    private func handleWarmupComplete() {
        isInitialized = true
        isInitializing = false
        // Track initialization completed
        if let startTime = modelInitStartTime {
            let duration = Date().timeIntervalSince(startTime)
            AnalyticsManager.Transcription.modelInitializationCompleted(duration: duration)
        }
        modelInitStartTime = nil

        log.info("TranscriptionManager: Parakeet CoreML ASR model initialized successfully")
        log.info("TranscriptionManager: Config - nbestSelection=\(config.nbestSelectionEnabled), smartFormatting=\(config.smartFormattingEnabled)")

        // Preload overlay window to avoid delay on first trigger
        TranscriptionOverlayWindowController.shared.preload()

        // Warm up Vision OCR so the first post-paste OCR request doesn't hit cold-start latency.
        warmUpVisionOCRIfNeeded()

        // The improvement LLM (N-best + backtracking) is now warmed up by
        // ImprovementLLMWarmupProvider via WarmupCoordinator - no manual
        // kick-off needed here. startTranscription already calls
        // featureStateChanged() at app launch.
    }

    /// Check if models need to be initialized
    var needsInitialization: Bool {
        !isInitialized && !isInitializing
    }

    // MARK: - Public Methods - Transcription Control

    /// Toggle transcription on/off (called by OPTION+SPACE shortcut)
    func toggle(tapTime: Date? = nil) {
        if isTranscribing {
            stopTranscription()
        } else {
            let mode: ActivationMode = Defaults[TranscriptionConfigKeys.handsFreeOnly] ? .handsfree : .toggle
            startTranscription(activationMode: mode, tapTime: tapTime)
        }
    }

    enum ReTranscribeError: LocalizedError {
        case audioUnavailable
        case busy
        case settingsChanged

        var errorDescription: String? {
            switch self {
            case .audioUnavailable:
                return "Could not load the audio file for this transcript."
            case .busy:
                return "Transcription is currently in use. Please try again in a moment."
            case .settingsChanged:
                return "The transcription model or dictation settings changed. Please try again."
            }
        }
    }

    /// Set while a `reTranscribe` call is in flight. Prevents two re-transcribes
    /// (or a re-transcribe + a live recording) from sharing the underlying ASR
    /// model object concurrently.
    private(set) var isReTranscribing: Bool = false

    /// Re-transcribes the audio attached to an existing history record using the
    /// currently active backend, runs the smart-cleanup pipeline (when available)
    /// and writes the new raw + cleaned text back onto the same record.
    /// Audio, app metadata, timestamp and reviewStatus are preserved.
    /// - Parameter history: The history record to re-transcribe.
    /// - Returns: The updated record on success, or nil if the audio could not be loaded.
    func reTranscribe(history: TranscriptionHistory) async throws -> TranscriptionHistory? {
        guard let id = history.id else { return nil }

        // The active backend's ASR engine is a process-wide singleton; running a
        // re-transcribe while a live dictation (or another re-transcribe) is in
        // flight would race the model. Refuse the call rather than crash.
        guard !isTranscribing, !isReTranscribing, !FileTranscriptionService.shared.isRunning else {
            log.warning("[reTranscribe] id=\(id): refused - transcription pipeline busy")
            throw ReTranscribeError.busy
        }
        isReTranscribing = true
        defer { isReTranscribing = false }

        // Off the main actor: a file row's audio runs up to 30 min (57 MB of WAV).
        let historyManager = TranscriptionHistoryManager.shared
        guard let samples = await Task.detached(priority: .userInitiated, operation: {
                  historyManager.loadAudioSamples(for: history)
              }).value,
              !samples.isEmpty else {
            log.warning("[reTranscribe] id=\(id): audio unavailable")
            throw ReTranscribeError.audioUnavailable
        }

        let audioDuration = Double(samples.count) / 16000.0
        log.info("═══════════════════════════════════════════════════════════════")
        log.info("[reTranscribe] START id=\(id) backend=\(config.backend.rawValue) audio=\(String(format: "%.2f", audioDuration))s (\(samples.count) samples)")

        // 1. ASR - call the active backend's one-shot engine directly so we
        //    don't disturb the live recording session's accumulator state.
        //    Re-stage the prompt payload first: the side-channel still holds the
        //    glossary of the LAST live dictation (or nothing at startup), and the
        //    user may have changed dictionary settings since this row was made.
        //    A file row stages its own, in `transcribeInSegments`.
        let asrStart = Date()
        let rawText: String
        if history.isFromFile {
            rawText = try await transcribeInSegments(samples)
        } else {
            ASRPromptContext.shared.set(buildASRPromptPayload())
            rawText = try await ASREngineGate.asr.withEngine {
                try await ASRBackendRegistry.descriptor(for: config.backend).reTranscribe(samples)
            }
        }
        let asrMs = Date().timeIntervalSince(asrStart) * 1000
        log.info("[reTranscribe] ASR done in \(String(format: "%.0f", asrMs))ms - raw (\(rawText.count) chars)")

        // 2. Smart cleanup. Reuse the verdict of the live dictation: a row keeps
        //    neither the field role nor the page host, so one that never recorded
        //    a verdict re-transcribes flat rather than laying out what may well
        //    have been a subject line.
        let cleanup = try await cleanUpOffline(
            rawText,
            inEmailComposer: EmailComposer.isComposer(recorded: history.inEmailComposer),
            precedingText: history.precedingText,
            followingText: history.followingText,
            logTag: "reTranscribe"
        )

        let updated = try await TranscriptionHistoryManager.shared.updateTranscription(
            id: id,
            rawTranscription: rawText,
            cleanedTranscription: cleanup.text,
            cleanupMethod: cleanup.method,
            cleanupLogEntries: cleanup.logJSON,
            rewriteSourceText: cleanup.rewriteSource,
            rewriteModel: cleanup.rewriteModel
        )
        log.info("[reTranscribe] DONE id=\(id) - record updated")
        log.info("═══════════════════════════════════════════════════════════════")
        return updated
    }

    /// True while ASR or cleanup runs outside a live dictation (re-transcription, file
    /// transcription). The model lifecycles treat it as activity, so neither unloads a
    /// model under it.
    var isTranscribingOffline: Bool {
        isReTranscribing || FileTranscriptionService.shared.isRunning
    }

    /// Transcribes a clip of any length with the active backend: cuts it on pauses
    /// (`StreamingSegmenter`, with an offline tuning) and stitches the segment
    /// transcripts. A whole-clip engine call is wrong past a few seconds on some
    /// backends: Parakeet cuts every 15 s with no overlap, Qwen3/Granite stop decoding
    /// around 4 min. One engine call per segment also lets a live dictation's inference
    /// run between two segments, and gives cancellation a point to land on.
    ///
    /// Throws `ReTranscribeError.settingsChanged` when the model or the dictation master
    /// switch changes mid-clip: later segments would decode with another model, or
    /// reload one the app just unloaded.
    func transcribeInSegments(
        _ samples: [Float],
        onProgress: (Double) -> Void = { _ in }
    ) async throws -> String {
        let descriptor = ASRBackendRegistry.descriptor(for: config.backend)
        let modelId = config.selectedASRModelId
        // The user's dictionary only: the screen layers describe the live dictation's
        // window (building them rewrites its mined terms) and term memory holds terms seen
        // on screen, not heard in the file.
        // ponytail: staged once. A live dictation during the job stages its own payload,
        // which later MLX segments then read (screen terms, when that option is on).
        // Waiting for the dictation to end and re-staging per segment would close it.
        let previousPayload = ASRPromptContext.shared.snapshot()
        let previousBoost = ASRPromptContext.shared.trieBoost
        let filePayload = buildASRPromptPayload(includeScreenTerms: false)
        ASRPromptContext.shared.set(filePayload)
        defer {
            // Put the dictation staging back, unless something re-staged meanwhile: a
            // chunked-streaming dictation stages nothing of its own and would otherwise
            // decode with this job's glossary for the rest of the session.
            if ASRPromptContext.shared.snapshot() == filePayload {
                ASRPromptContext.shared.set(previousPayload)
                ASRPromptContext.shared.setTrieBoost(previousBoost)
            }
        }

        // The level scan walks the whole clip: keep it off the main actor.
        let options = await Task.detached(priority: .userInitiated) {
            StreamingSegmenterOptions.offline(for: samples)
        }.value
        let segmenter = StreamingSegmenter(options: options)
        let stitcher = TranscriptStitcher(repairsSegmentFinalPeriod: true)
        // The segments reload an idle-unloaded model through the engine, which leaves its
        // lifecycle suspended: no idle unload, no keep-alive, until the next dictation.
        // Recording activity re-arms it on the resident model, on every exit (done,
        // cancelled, failed). Not before the first engine call: the re-arm load would
        // race that call's own load.
        var usedEngine = false
        defer {
            if usedEngine, Defaults[.transcriptionEnabled] {
                ASRModelLifecycleService.shared.recordActivity()
            }
        }
        let totalSamples = Double(max(samples.count, 1))
        // Fed 12 s at a time, and only once the pending segments are drained, so the
        // cut segments never pile up into another copy of the whole clip.
        // ponytail: the segmenter still keeps every sample it was fed (2 copies of the
        // clip at the end, ~230 MB for 30 min); trim its buffer if longer files matter.
        let chunkSize = 12 * 16_000
        var fed = 0
        while true {
            var next = segmenter.tryTakeSegment()
            if next == nil, fed < samples.count {
                let end = min(fed + chunkSize, samples.count)
                segmenter.append(samples[fed..<end])
                fed = end
                continue
            }
            if next == nil {
                next = segmenter.takeTail()
            }
            guard let segment = next else { break }

            try Task.checkCancellation()
            guard config.selectedASRModelId == modelId, Defaults[.transcriptionEnabled] else {
                throw ReTranscribeError.settingsChanged
            }
            // Silent segments are skipped: near-silent audio measurably hallucinates.
            if segment.containsSpeech {
                usedEngine = true
                let text = try await ASREngineGate.asr.withEngine {
                    try await descriptor.reTranscribe(segment.samples)
                }
                // Same guard as the live chunked session: an echo would land in the
                // middle of the transcript, where nothing downstream catches it.
                if !ASRPromptContext.isPromptEcho(text) {
                    stitcher.append(text, hasSpeechOverlap: segment.hasSpeechOverlap)
                }
            }
            onProgress(Double(segment.endSample) / totalSamples)
        }
        return stitcher.text
    }

    /// Smart Formatting for a transcript that is not inserted live (re-transcription,
    /// file transcription). One site on purpose: the same audio must give the same text.
    /// Falls back to the raw text when cleanup is off, not ready, or fails.
    func cleanUpOffline(
        _ rawText: String,
        inEmailComposer: Bool,
        precedingText: String?,
        followingText: String?,
        logTag: String
    ) async throws -> (text: String, method: String?, logJSON: String?, rewriteSource: String?, rewriteModel: String?) {
        // Reload the cleanup LLM if it was idle-unloaded. These on-demand paths
        // never call `recordActivity()`, so this is their only reload trigger.
        await CleanupModelLifecycleService.shared.ensureResidentForCleanup()

        let cleanup = try await cleanupService.cleanupCancellable(CleanupInput(
            transcript: rawText,
            locale: config.cleanupLocale,
            precedingText: precedingText,
            followingText: followingText,
            inEmailComposer: inEmailComposer,
            vocabulary: cleanupVocabulary,
            isLive: false
        ))

        if let rewrite = cleanup.rewrite {
            log.info("[\(logTag)] Rewrite: \(Self.describe(rewrite))")
        }
        // Each stage is judged on its own: the rewrite succeeding doesn't turn a
        // failed or skipped first stage into a cleaned one.
        let firstStageText = cleanup.output?.text ?? rawText
        let smartChanged = firstStageText != rawText
        let rewritten = cleanup.rewriteApplied && cleanup.text != firstStageText
        let method = TranscriptionHistory.CleanupMethods.method(smartChanged: smartChanged, rewritten: rewritten)
        var logJSON: String? = nil
        switch cleanup.outcome {
        case .cleaned(let output, let durationMs):
            log.info("[\(logTag)] Cleanup done in \(String(format: "%.0f", durationMs))ms, changed=\(smartChanged) candidates=\(output.stats?.candidateCount ?? 0)")
            if smartChanged {
                log.info("[\(logTag)] Cleaned: \(LogPrivacy.summary(output.text))")
            }
        case .failed(.notEntitled):
            // No sales prompt for an offline job: the text is kept and the skip is logged.
            log.info("[\(logTag)] Smart Formatting: NOT ENTITLED (keeping the previous text)")
            logJSON = Self.notEntitledLogJSON()
        case .failed(let error):
            log.warning("[\(logTag)] Cleanup failed: \(error.localizedDescription)")
            let errorEntry = CleanupLogEntry(event: "swift_error", error: error.localizedDescription)
            logJSON = (try? JSONEncoder().encode([errorEntry])).flatMap { String(data: $0, encoding: .utf8) }
        case .disabled, .notReady:
            log.info("[\(logTag)] Cleanup skipped: provider=\(cleanup.providerID) outcome=\(cleanup.outcome)")
        }
        return (cleanup.text, method, logJSON, cleanup.rewriteSource, cleanup.rewriteModel)
    }

    /// One line for the logs about a cleanup stage's outcome.
    private static func describe(_ outcome: CleanupService.Outcome) -> String {
        switch outcome {
        case .cleaned(_, let ms): "applied in \(String(format: "%.0f", ms))ms"
        case .disabled: "off"
        case .notReady(let availability): "skipped, not ready (\(availability))"
        case .failed(let error): "failed, kept the previous text (\(error.localizedDescription))"
        }
    }

    /// History log entry for a Smart Cleanup refusal (live and offline flows share it).
    static func notEntitledLogJSON() -> String? {
        let skipEntry = CleanupLogEntry(event: "cleanup_skipped", reason: "not_entitled")
        return (try? JSONEncoder().encode([skipEntry])).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The user's dictionary terms, for cleanup providers that take a vocabulary.
    private var cleanupVocabulary: [String] {
        guard Defaults[.customDictionaryEnabled] else { return [] }
        return Defaults[.customDictionaryTermsV2].map(\.text)
    }

    /// Update the activation mode mid-session (e.g. hold → handsfree on double-tap)
    func setActivationMode(_ mode: ActivationMode) {
        activationMode = mode
    }

    /// Start transcription session
    func startTranscription(activationMode: ActivationMode = .hold, tapTime: Date? = nil) {
        shortcutTapTime = tapTime
        let startupClock = Date()
        func elapsed() -> String { String(format: "%.1f", Date().timeIntervalSince(startupClock) * 1000) }

        // Dismiss any existing transcription overlay (and its prompt list) from a previous session
        HintManager.shared.hideTranscriptionOverlayIfNeeded()
        // Stop any post-OCR editing monitors from the previous session that are still in their
        // 3-second window - otherwise stale monitors fire against the new TranscriptionState.
        stopPostOCREditingMonitors()

        // Clear any stale transcription alert from a previous session
        HintManager.shared.activeTranscriptionAlert = nil
        HintManager.shared.refreshPopUp()

        // Follow the user to whichever display they're dictating on - the hint
        // window is persistent, so it otherwise stays on the screen it first
        // appeared on instead of jumping to the active screen.
        HintManager.shared.repositionHintToActiveScreenIfNeeded()

        // Cancel any in-flight processing from a previous session
        clearRecordedAudioProcessingTask()
        log.info("[rec-startup] pre-guards done: \(elapsed())ms")

        guard !isTranscribing else { return }

        // A correction backtest takes exclusive use of the shared ASR engines
        // (it swaps their loaded model to score candidates). Refuse to start a
        // dictation while it runs - otherwise this recording could be
        // transcribed by a candidate model but saved as the selected one.
        guard !CorrectionBacktestRunner.isRunning else {
            state.errorMessage = String.localized(
                "Model testing is in progress. Try again when it finishes.",
                table: "Transcription"
            )
            return
        }

        self.activationMode = activationMode

        // If models not initialized, try to initialize first
        if !isInitialized {
            if isInitializing {
                state.errorMessage = String.localized("Please wait, models are still loading...", table: "Transcription")
                return
            }
            initializeModelsInBackground()
            state.errorMessage = String.localized("Initializing models, please try again...", table: "Transcription")
            return
        }

        // Past every early-return guard - a real dictation is now proceeding. The "Cloudless is
        // ready!" nudge exists solely to get the user here, so retire it now (not before the
        // guards, or a call that bails - already transcribing, model testing, models still
        // loading - would suppress the nudge forever without a dictation ever starting).
        if !Defaults[.appHomeReadyToastShown] {
            Defaults[.appHomeReadyToastShown] = true
            if HintManager.shared.activePopUpType == .modelsReady {
                HintManager.shared.dismissPopUp()
            }
        }

        // Capture the frontmost app's PID and info for text insertion
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            targetPid = frontApp.processIdentifier
            targetAppName = frontApp.localizedName
            targetAppBundleId = frontApp.bundleIdentifier
        }
        log.info("[rec-startup] frontmost app resolved: \(elapsed())ms")

        // In debug builds, capture a screenshot of the target window at dictation start.
        // Saved to Application Support and referenced in the history record for debugging.
        #if DEBUG || ONIT_BETA
        captureSessionStartScreenshot()
        // Gated on the same conditions as the mining it exists to debug: the
        // walk is a full AX traversal of the target window and its JSON lands
        // in history, so it must not run for a dictation Layer C won't mine.
        if let pid = targetPid, onScreenMiningWillRun {
            captureWindowContextIfNeeded(pid: pid)
        }
        #endif

        // Layer C - mine on-screen terms (OCR + caps) for this utterance's glossary.
        // Best-effort and off the audio hot-path; if it isn't ready by transcribe
        // time, the prompt simply uses the persistent dictionary.
        mineOnScreenTermsIfEnabled()

        isTranscribing = true
        // Dictation-start chime. Non-blocking: playback runs on a background queue
        // so the first-play asset decode (~160ms) never delays audio capture.
        // No-op unless the user enabled sound effects.
        SoundEffectsService.shared.play(.dictationStart)
        state.reset()
        state.isActive = true
        state.isInitializing = true
        sessionStartTime = Date()
        historySaveTask = nil

        // Reset audio buffer for new recording
        resetCurrentASR()

        // Arm the chunked-streaming session (no-op unless the flag is on AND the
        // active backend streams). Must precede audio capture so the first buffer
        // reaches the session. When it doesn't arm, `streamingSession` stays nil
        // and the batch path is untouched.
        armStreamingSessionIfEligible()

        // Track session started
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        AnalyticsManager.Transcription.sessionStarted(
            shortcutType: shortcutType,
            activationMode: activationMode.rawValue,
            appName: targetAppName,
            appBundleId: targetAppBundleId
        )

        // Record activity + re-arm: if the model was unloaded after inactivity,
        // this kicks off the reload now so it overlaps the user speaking. The
        // transcribe path self-heals as the guarantee if reload isn't done yet.
        ASRModelLifecycleService.shared.recordActivity()
        CleanupModelLifecycleService.shared.recordActivity()

        // Warm ANE/GPU models concurrently with the user speaking so that cold
        // models don't add 5-10s latency to the real ASR/cleanup path.
        RecordingStartWarmupService.shared.warmModelsForRecording()

        log.info("[rec-startup] spawning audio task: \(elapsed())ms")

        // Start audio capture
        transcriptionTask = Task {
            await performAudioCapture()
        }
    }

    private func clearRecordedAudioProcessingTask() {
        recordedAudioProcessingTask?.cancel()
        recordedAudioProcessingTask = nil
    }

    /// Stop transcription session and process the recorded audio
    func stopTranscription() {
        guard isTranscribing else { return }

        // Restart the inactivity countdown from the end of this session.
        ASRModelLifecycleService.shared.recordActivity()
        CleanupModelLifecycleService.shared.recordActivity()

        // Mark as no longer transcribing to prevent re-entry
        isTranscribing = false
        state.isActive = false
        state.isProcessing = true

        // Process the recorded audio
        recordedAudioProcessingTask = Task {
            // Stop audio capture
            microphoneManager.stopRecording()

            // Dictation-stop chime (no-op unless enabled). Fired AFTER the mic
            // stops so the chime can't bleed into the recording tail that the
            // drain below still consumes.
            SoundEffectsService.shared.play(.dictationStop)

            // Must `await` here to let the consumer drain remaining buffered audio.
            // Without this, the consumer is cancelled before it can process them, causing tail-end audio cutoff.
            await audioStreamTask?.value
            audioStreamTask = nil

            // Cancel the capture task
            transcriptionTask?.cancel()
            transcriptionTask = nil

            // Capture audio samples for playback before transcription
            state.recordedAudioSamples = currentASRAccumulatedSamples

            // Transcribe the accumulated audio (greedy decoding, single hypothesis)
            let audioDuration = currentASRAccumulatedDuration
            log.info("TranscriptionManager: Transcribing \(audioDuration)s of audio")

            do {
                // Get hypotheses from the configured ASR backend
                let asrStart = Date()
                let hypotheses: [NbestHypothesis]
                let detectedLanguage: String?
                let vadSuppressed: Bool

                // Chunked-streaming fast path: when a session is armed (flag on +
                // streaming backend), most of the audio was already transcribed
                // during recording, so only the short final tail remains. When
                // nothing is armed OR the session failed, `consumeStreamingSessionForStop`
                // returns nil and the single-shot `transcribeWithCurrentBackend`
                // below runs UNCHANGED - the whole streaming block is skipped
                // because `streamingSession` is nil whenever the flag is off.
                //
                // Guard first: a rapid re-trigger cancels this stop task AND arms
                // a new session before this drain resumes. Without this we'd read
                // `streamingSession` = the NEW session and finish() it mid-record,
                // forcing it onto single-shot. (The prior session was already torn
                // down by the new arm; here we just avoid touching the new one.)
                guard !Task.isCancelled else { return }
                if let outcome = await consumeStreamingSessionForStop() {
                    switch outcome {
                    case .assembled(let streamedHypotheses):
                        hypotheses = streamedHypotheses
                        // Streaming aggregates no per-clip language; report auto.
                        detectedLanguage = nil
                        vadSuppressed = false
                    case .empty:
                        // The streaming speech gate is the segmenter's energy
                        // threshold, not the batch Silero VAD run over the whole
                        // clip - so a streaming-empty is NOT authoritative (a quiet
                        // or distant dictation could be dropped). Fall back to a
                        // full-buffer single-shot; its Silero gate is the real
                        // empty-vs-speech judge and short-circuits truly silent
                        // audio without heavy inference.
                        (hypotheses, detectedLanguage, vadSuppressed) = try await transcribeWithCurrentBackend()
                    }
                } else {
                    (hypotheses, detectedLanguage, vadSuppressed) = try await transcribeWithCurrentBackend()
                }
                let asrDurationMs = Date().timeIntervalSince(asrStart) * 1000
                guard !Task.isCancelled else { return }

                guard !hypotheses.isEmpty else {
                    log.warning("TranscriptionManager: No transcription hypotheses returned")
                    handleEmptyTranscription(vadSuppressed: vadSuppressed)
                    return
                }

                // Log hypotheses
                for (i, h) in hypotheses.enumerated() {
                    log.info("TranscriptionManager: Hypothesis \(i + 1): [\(h.confidence)] \(LogPrivacy.summary(h.text))")
                }

                // Select best hypothesis using LLM if enabled and multiple hypotheses
                let selectedHypothesis: NbestHypothesis
                var nbestDurationMs: Double? = nil
                if config.nbestSelectionEnabled && hypotheses.count > 1 && nbestSelectionService.isReady {
                    log.info("TranscriptionManager: Using LLM to select best hypothesis from \(hypotheses.count) candidates")
                    let nbestStart = Date()
                    selectedHypothesis = try await nbestSelectionService.selectBest(from: hypotheses)
                    nbestDurationMs = Date().timeIntervalSince(nbestStart) * 1000
                } else {
                    // Use first hypothesis (highest confidence from ASR)
                    if !config.nbestSelectionEnabled {
                        log.info("TranscriptionManager: N-best selection disabled, using first hypothesis")
                    } else if hypotheses.count <= 1 {
                        log.info("TranscriptionManager: Only \(hypotheses.count) hypothesis, skipping LLM selection")
                    } else if !nbestSelectionService.isReady {
                        log.info("TranscriptionManager: N-best selection service not ready, using first hypothesis")
                    }
                    selectedHypothesis = hypotheses.first!
                }
                guard !Task.isCancelled else { return }

                let transcribedText = selectedHypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // raw_text is populated by the server when LM conditioning changed the text
                let greedyText = selectedHypothesis.raw_text?.trimmingCharacters(in: .whitespacesAndNewlines)

                // Apply Custom Dictionary CTC biasing before cleanup.
                // Pipeline: ASR → Custom Dictionary → Cleanup.
                // `rescore()` short-circuits when the feature is disabled, the CTC
                // model isn't ready, the dictionary is empty, or the audio buffer is missing.
                // Forward word-level timings from the selected hypothesis so KWS span
                // alignment uses exact decoder-frame positions instead of interpolation.
                let biasedText = await CustomDictionaryService.shared.rescore(
                    transcript: transcribedText,
                    audioSamples: state.recordedAudioSamples ?? [],
                    wordTimestamps: selectedHypothesis.wordTimestamps
                )

                // Restore dictionary terms the model wrote as separate words
                // (CapsTermSelector, macos/Onit.xcodeproj…). Deterministic, format-
                // blind, homophone-safe; gated by asrDictionaryFormatMatchEnabled.
                let formattedText = await applyFormatMatcherIfEnabled(to: biasedText)

                // Term-memory tier-2: gated fuzzy restore of store terms the
                // decode-time trie missed (phone/char edit distance against
                // predicted surfaces). No-op unless its dev flag is on.
                let tier2Text = await TermMemoryService.shared.applyTier2IfEnabled(
                    to: formattedText, language: detectedLanguage)

                // Expand user snippets: when the transcript contains a snippet's
                // name (its dictation trigger), splice in the replacement.
                // `SnippetsService` is @MainActor and `expand` is a pure function
                // over a snapshot, so this stays synchronous (no await → no
                // re-entrancy on the snippet list). Runs after the dictionary /
                // format-matcher and before Smart Cleanup so replacements flow
                // through the same downstream formatting as normal dictation.
                let expandedText = SnippetsService.shared.isEnabled
                    ? SnippetsService.expand(
                        in: tier2Text,
                        snippets: SnippetsService.shared.snippets,
                        keyword: Defaults[.snippetKeyword]
                    )
                    : tier2Text

                // Flag snippet-affected dictations so the correction/training
                // pipeline can identify and filter them downstream.
                state.snippetExpanded = expandedText != tier2Text

                if !expandedText.isEmpty {
                    await handleTranscriptionResult(
                        expandedText,
                        greedyText: greedyText,
                        asrDurationMs: asrDurationMs,
                        nbestDurationMs: nbestDurationMs,
                        detectedLanguage: detectedLanguage)
                } else {
                    handleEmptyTranscription()
                }

            } catch {
                guard !Task.isCancelled else { return }
                log.error("TranscriptionManager: Transcription failed: \(error.localizedDescription)")
                handleTranscriptionError(error)
            }
        }
    }

    /// Dismiss the overlay without saving corrections
    func dismissOverlay() {
        clipboardSnapshot = nil
        stopPostOCREditingMonitors()
        overlayAutoDismissTask?.cancel()
        overlayAutoDismissTask = nil
        pendingCorrectionDetectionResult = nil
        audioHydrationTask?.cancel()
        audioHydrationTask = nil
        // NOTE: `inflightSaveCount` is intentionally NOT reset here. The
        // detached save tasks decrement themselves when they finish; resetting
        // synchronously here would release the guard while the persistence is
        // still in flight (the original C9 bug).
        state.reset()
        HintManager.shared.hideTranscriptionOverlayIfNeeded()
    }
    
    // MARK: - Copy / Paste Last Transcription

    enum TranscriptionCopyPasteAnalyticsSource: String {
        case menuBar = "menu_bar"
        case hintMoreMenu = "hint_more_menu"
        case keyboardShortcut = "keyboard_shortcut"
    }

    func copyLastTranscription(for analyticsSource: TranscriptionCopyPasteAnalyticsSource) {
        let shortcutTypeForAnalytics = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        
        guard let mostRecentTranscription = TranscriptionHistoryManager.shared.mostRecentTranscription
        else {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: Defaults[.transcriptionHistoryEnabled] ?
                    .mostRecentTranscriptionDoesNotExist :
                    .transcriptionHistoryFeatureDisabled,
                actionSource: .copyLastTranscription
            )
            return
        }
        
        cancelTranscription()

        let mostRecentTranscriptionText =
            mostRecentTranscription.correctedTranscription ??
            mostRecentTranscription.cleanedTranscription

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(mostRecentTranscriptionText, forType: .string)

        AnalyticsManager.Transcription.lastTranscription(
            shortcutType: shortcutTypeForAnalytics,
            source: analyticsSource.rawValue,
            actionSource: .copyLastTranscription
        )
    }

    func pasteLastTranscription(for analyticsSource: TranscriptionCopyPasteAnalyticsSource) {
        let shortcutTypeForAnalytics = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        /// Don't paste into Onit itself, as this feature is meaningful only against external apps.
        if frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: .onitFrontmost,
                actionSource: .pasteLastTranscription
            )
            return
        }

        guard let mostRecentTranscription = TranscriptionHistoryManager.shared.mostRecentTranscription
        else {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: Defaults[.transcriptionHistoryEnabled] ?
                    .mostRecentTranscriptionDoesNotExist :
                    .transcriptionHistoryFeatureDisabled,
                actionSource: .pasteLastTranscription
            )
            return
        }

        cancelTranscription()

        let mostRecentTranscriptionText =
            mostRecentTranscription.pastedText

        /// Capture the target PID *before* entering the asynchronous Task.
        let targetPid = frontmostApp?.processIdentifier

        Task {
            _ = await PasteboardManager.shared.insertViaPaste(
                mostRecentTranscriptionText,
                targetPid: targetPid
            )
        }

        AnalyticsManager.Transcription.lastTranscription(
            shortcutType: shortcutTypeForAnalytics,
            source: analyticsSource.rawValue,
            actionSource: .pasteLastTranscription
        )
    }

    func correctAndTeachLastTranscription(for analyticsSource: TranscriptionCopyPasteAnalyticsSource) {
        let shortcutTypeForAnalytics = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        /// Don't open the correction overlay if Onit is somehow already frontmost.
        if frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: .onitFrontmost,
                actionSource: .correctAndTeach
            )
            return
        }

        guard let mostRecentTranscription = TranscriptionHistoryManager.shared.mostRecentTranscription
        else {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: Defaults[.transcriptionHistoryEnabled] ?
                    .mostRecentTranscriptionDoesNotExist :
                    .transcriptionHistoryFeatureDisabled,
                actionSource: .correctAndTeach
            )
            return
        }

        // A saved correction is a recognizer-level text, so a rewritten row opens on the
        // recognizer text (`recognizerText`), not on the rewrite that was pasted.
        let displayedText = (
            mostRecentTranscription.correctedTranscription ??
            mostRecentTranscription.recognizerText
        ).trimmingCharacters(in: .whitespaces)

        guard !displayedText.isEmpty
        else {
            AnalyticsManager.Transcription.lastTranscription(
                shortcutType: shortcutTypeForAnalytics,
                source: analyticsSource.rawValue,
                noOpReason: .mostRecentTranscriptionTextEmpty,
                actionSource: .correctAndTeach
            )
            return
        }

        cancelTranscription()
        HintManager.shared.hideTranscriptionOverlayIfNeeded()

        let rawText = mostRecentTranscription.rawTranscription.trimmingCharacters(in: .whitespaces)

        /// Hydrate state from the persisted record.
        state.reset()
        state.isCorrectingAndTeachingWithLastHistory = true
        state.insertedText = displayedText
        state.originalTranscription = displayedText
        state.correctionText = displayedText
        state.rawASRText = rawText
        state.isCompleted = true

        /// For training-data uploads, override the "original" with the `cleanedTranscription` so that re-correcting a row that was already corrected uploads the right data for training.
        let cleanedText = mostRecentTranscription.recognizerText.trimmingCharacters(in: .whitespaces)
        state.trainingOriginalTextOverride = cleanedText

        /// Capture target PID from the user's current app (mirrors `pasteLastTranscription`).
        targetPid = frontmostApp?.processIdentifier

        /// Hydrate the session-scoped instance state that `saveCorrection()` reads when the user submits the correction.
        let historyId = mostRecentTranscription.id
        historySaveTask = Task<Int64?, Never> { historyId }
        precedingText = mostRecentTranscription.precedingText
        followingText = mostRecentTranscription.followingText
        inEmailComposer = mostRecentTranscription.inEmailComposer
        axContextGeneration += 1
        targetAppName = mostRecentTranscription.appName
        targetAppBundleId = mostRecentTranscription.appBundleId

        state.enterCorrectionMode()
        HintManager.shared.showTranscriptionOverlay(state: state)
        HintManager.shared.enableTranscriptionOverlayEditMode()
        HintManager.shared.updateTranscriptionOverlaySize()

        /// Hydrate audio samples off the main thread.
        audioHydrationTask?.cancel()
        let transcriptionHistoryRow = mostRecentTranscription
        let historyManager = TranscriptionHistoryManager.shared
        audioHydrationTask = Task.detached {
            guard let samples = historyManager.loadAudioSamples(for: transcriptionHistoryRow) else { return }
            if Task.isCancelled { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.state.recordedAudioSamples = samples
            }
        }

        AnalyticsManager.Transcription.lastTranscription(
            shortcutType: shortcutTypeForAnalytics,
            source: analyticsSource.rawValue,
            actionSource: .correctAndTeach
        )
    }

    /// Edit the last transcription by reopening the correction UI
    func editLastTranscription() {
        guard let lastText = lastInsertedText, !lastText.isEmpty else {
            log.info("TranscriptionManager: No last transcription to edit")
            return
        }

        // No-op when an overlay is already on screen - the user should interact with it directly.
        guard !HintManager.shared.transcriptionOverlayWindowIsVisible else {
            log.info("TranscriptionManager: editLastTranscription called while overlay is visible, ignoring")
            return
        }

        let canReplace = canSafelyReplaceLastPaste

        // Set up state for correction mode with the last inserted text
        state.reset()
        state.insertedText = lastText.trimmingCharacters(in: .whitespaces)
        state.originalTranscription = lastText.trimmingCharacters(in: .whitespaces)
        state.correctionText = lastText.trimmingCharacters(in: .whitespaces)
        state.rawASRText = lastRawASRText ?? ""
        state.recordedAudioSamples = lastRecordedAudioSamples
        state.isCompleted = true
        state.canReplacePastedText = canReplace

        // Store target PID for when correction is saved
        targetPid = lastTargetPid

        // Enter correction mode BEFORE showing overlay so fittingSize reflects TranscriptionCorrectionView
        state.enterCorrectionMode()

        // Only anchor at the original paste location when we can still safely replace it. If we've
        // moved on, the anchor would point at stale screen coordinates - show near the cursor instead.
        HintManager.shared.showTranscriptionOverlay(
            state: state,
            pastedTextDetectionResult: canReplace ? lastPastedTextDetectionResult : nil
        )
        HintManager.shared.enableTranscriptionOverlayEditMode()
        HintManager.shared.updateTranscriptionOverlaySize()

        log.info("TranscriptionManager: Opened edit UI for last transcription (canReplace=\(canReplace), \(LogPrivacy.summary(lastText)))")
    }

    // MARK: - Edit-Last-Transcription Safety

    /// Whether `editLastTranscription` can safely backspace-and-repaste in the original target.
    private var canSafelyReplaceLastPaste: Bool {
        guard let ts = lastPasteTimestamp, let last = lastInsertedText, !last.isEmpty else { return false }
        if pasteSafetyDirty { return false }
        return Date().timeIntervalSince(ts) <= Self.pasteSafetyTTL
    }

    /// Install monitors that watch for events which make in-place replacement unsafe:
    /// any keystroke outside Onit, a switch to any app other than the original target, or the
    /// `pasteSafetyTTL` timeout. Call after a successful paste, once `lastInsertedText` is set.
    private func installPasteSafetyMonitors() {
        resetPasteSafety()
        lastPasteTimestamp = Date()
        pasteSafetyDirty = false

        let originalPid = lastTargetPid

        // Global keyDown fires for events delivered to OTHER apps - so typing inside our own
        // (key) overlay window is correctly ignored. We additionally guard against our own
        // dispatch-table commands (Caps+C / Caps+V / Caps+E) that fire while the transcription
        // shortcut is held: these are intercepted by `TranscriptionKeysManager` and never reach
        // the focused app, so they must NOT mark dirty. Any OTHER character typed while the
        // shortcut is held (e.g. Caps+X) falls through to the focused app and MUST mark dirty -
        // otherwise a follow-up Caps+E would replace-in-place over the just-typed character.
        // Keys must stay in sync with `TranscriptionKeysManager.transcriptionHeldShortcuts`.
        pasteSafetyKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let isOnitInterceptedShortcut = KeyboardShortcutsManager.isToggleTranscriptionShortcutHeld
                && Self.transcriptionHeldShortcutCharacters.contains(typed)
            Task { @MainActor in
                guard !isOnitInterceptedShortcut else { return }
                self?.markPasteSafetyDirty(reason: "keystroke")
            }
        }

        pasteSafetyAppSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedPid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            let isOnit = activatedPid == ProcessInfo.processInfo.processIdentifier
            // The original target re-activating is fine (e.g. user clicked back into the app).
            // Onit activating is fine (we activate it for our overlay).
            if isOnit || activatedPid == originalPid { return }
            Task { @MainActor in self?.markPasteSafetyDirty(reason: "app_switch") }
        }

        pasteSafetyExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Int(Self.pasteSafetyTTL)))
            guard !Task.isCancelled else { return }
            self?.markPasteSafetyDirty(reason: "timeout")
        }
    }

    private func markPasteSafetyDirty(reason: String) {
        guard !pasteSafetyDirty else { return }
        pasteSafetyDirty = true
        log.info("TranscriptionManager: paste safety dirty (\(reason))")
        // Tear down monitors - the flag persists until the next paste replaces it.
        removePasteSafetyMonitors()
    }

    private func resetPasteSafety() {
        removePasteSafetyMonitors()
        pasteSafetyDirty = false
        lastPasteTimestamp = nil
    }

    private func removePasteSafetyMonitors() {
        if let m = pasteSafetyKeyMonitor {
            NSEvent.removeMonitor(m)
            pasteSafetyKeyMonitor = nil
        }
        if let o = pasteSafetyAppSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            pasteSafetyAppSwitchObserver = nil
        }
        pasteSafetyExpirationTask?.cancel()
        pasteSafetyExpirationTask = nil
    }

    /// Undo the last transcription by sending backspace keystrokes
    func undoLastTranscription() {
        guard !HintManager.shared.isUndoingLastTranscription,
              let lastText = lastInsertedText,
              !lastText.isEmpty
        else {
            log.info("TranscriptionManager: No last transcription to undo")
            return
        }

        let charCount = lastText.count

        HintManager.shared.isUndoingLastTranscription = true
        HintManager.shared.hideTranscriptionOverlayIfNeeded()

        Task {
            // Activate the target application first so it receives the key events
            if let pid = lastTargetPid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
                try? await Task.sleep(for: .milliseconds(200))
            }

            // Delete all the characters using the fast batch-delete path
            await fastDeleteCharacters(count: charCount, targetPid: lastTargetPid)

            log.info("TranscriptionManager: Undid last transcription (\(charCount) characters)")

            // Clear last inserted text so undo can't be repeated
            await MainActor.run {
                lastInsertedText = nil
                lastTargetPid = nil
                lastRawASRText = nil
                lastRecordedAudioSamples = nil
                resetPasteSafety()
            }

            HintManager.shared.isUndoingLastTranscription = false
        }
    }

    /// Whether there's a last transcription available for edit/undo
    var hasLastTranscription: Bool {
        guard let text = lastInsertedText else { return false }
        return !text.isEmpty
    }

    /// Save the correction and replace text in target app
    /// - Parameter markAsReviewed: when `true`, an explicit confirm gesture
    ///   propagates to the history row - an edit promotes to `.corrected`, a
    ///   no-edit confirm promotes `.unreviewed → .reviewed`. When `false`
    ///   (e.g. the "Feeling lazy, paste now" button, which is the user
    ///   explicitly saying "I didn't look"), the history row's
    ///   `correctedTranscription` and `reviewStatus` are left untouched even
    ///   if the user happened to type something in the overlay - the audio is
    ///   still saved and the text is still pasted, but the review state
    ///   doesn't move. Default `true` so all other callers keep propagating
    ///   the signal.
    func saveCorrection(markAsReviewed: Bool = true) {
        guard !isSavingCorrection else {
            log.info("[TranscriptionManager] saveCorrection called while a save is already in flight, ignoring")
            return
        }
        inflightSaveCount += 1

        audioHydrationTask?.cancel()
        audioHydrationTask = nil

        let originalText = state.originalTranscription
        let correctedText = state.correctionText
        let isCorrectingAndTeachingWithLastHistory = state.isCorrectingAndTeachingWithLastHistory

        // Trailing whitespace is whatever the cleanup library produced - don't append our own.
        // The library's `TrailingSpaceScorer` decides when a space is appropriate; second-
        // guessing it here was the source of inconsistencies in earlier iterations.

        // Capture before overwriting - replaceInsertedText needs the original as deletion target.
        let originalInsertedText = lastInsertedText

        // Update lastInsertedText for undo/edit functionality when not entering from the "Correct & Teach Onit" entry point from the Hint More Menu
        if !isCorrectingAndTeachingWithLastHistory && !correctedText.isEmpty {
            lastInsertedText = correctedText
            lastTargetPid = targetPid
        }

        // Capture audio samples before dismissOverlay() resets state.
        // Also persist to lastRecordedAudioSamples so re-opening the edit UI
        // (via editLastTranscription) still has audio on the 2nd+ correction.
        let audioSamples = state.recordedAudioSamples
        if !isCorrectingAndTeachingWithLastHistory {
            lastRecordedAudioSamples = audioSamples
        }
        let capturedPrecedingText = precedingText
        let capturedFollowingText = followingText
        let capturedAppName = targetAppName
        let capturedAppBundleId = targetAppBundleId
        let capturedRawASRText = state.rawASRText
        let capturedInsertedText = state.insertedText

        // Capture and clear snapshot - we'll restore it after paste completes
        // This prevents dismissOverlay from restoring immediately (race condition)
        let snapshotToRestore = clipboardSnapshot
        clipboardSnapshot = nil

        // Propagate the user's confirmation to the history row. Edits route
        // through `update(... correctedTranscription:)` which promotes to
        // `.corrected`. No-edit confirms route through `updateReviewStatus`
        // and only promote `.unreviewed → .reviewed` (never demote a row
        // that already reached `.corrected` on a prior pass). When
        // `markAsReviewed == false` ("Feeling lazy"), neither branch runs -
        // the history row's review state is intentionally left untouched.
        let saveTask = historySaveTask
        let didEdit = originalText != correctedText
        if markAsReviewed {
            Task {
                guard let historyId = await saveTask?.value else { return }
                if didEdit {
                    try? await TranscriptionHistoryManager.shared.update(
                        id: historyId,
                        correctedTranscription: correctedText,
                        precedingText: capturedPrecedingText,
                        followingText: capturedFollowingText
                    )
                } else {
                    if let current = await TranscriptionHistoryManager.shared.fetch(id: historyId),
                       current.reviewStatus == .unreviewed {
                        _ = try? await TranscriptionHistoryManager.shared.updateReviewStatus(
                            id: historyId,
                            status: .reviewed
                        )
                    }
                }
            }
        }

        if didEdit && markAsReviewed {
            // Detect candidate custom dictionary terms from this correction.
            // Skipped on "Feeling lazy" - that path explicitly signals the
            // edit wasn't a deliberate review, so it shouldn't seed term
            // suggestions either.
            CustomDictionaryService.shared.detectAndQueueSuggestions(
                raw: originalText, corrected: correctedText)
            // Persistent term memory: a correction that introduced a term is
            // the strongest sighting evidence there is (weight 10, pins).
            TermMemoryService.shared.recordCorrection(
                raw: originalText, corrected: correctedText,
                appBundle: capturedAppBundleId)
        }

        AnalyticsManager.Transcription.correctionSaved(
            wasEdited: originalText != correctedText,
            originalLength: originalText.count,
            correctedLength: correctedText.count,
            appName: capturedAppName,
            appBundleId: capturedAppBundleId
        )

        // Persist the correction locally. It stays on this Mac: only an explicit
        // "Request fix" on the transcript uploads it. savedByAccountId is captured
        // on the main actor so the upload can be scoped to the account that saved it.
        let capturedHistoryTask = historySaveTask
        let capturedSavedByAccountId = AuthManager.shared.account.map { String($0.id) }
        let capturedExcludedReason = Self.eligibilitySnapshot()
        let capturedSnippetExpanded = state.snippetExpanded
        Task { @MainActor [weak self] in
            let resolvedHistoryId = await capturedHistoryTask?.value
            try? await TranscriptionCorrectionManager.shared.saveCorrection(
                originalTranscription: originalText,
                rawTranscription: capturedRawASRText,
                snippetExpanded: capturedSnippetExpanded,
                correctedTranscription: correctedText,
                audioSamples: audioSamples,
                sampleRate: 16000,
                precedingText: capturedPrecedingText,
                followingText: capturedFollowingText,
                appName: capturedAppName,
                appBundleId: capturedAppBundleId,
                historyId: resolvedHistoryId,
                excludedReason: capturedExcludedReason,
                savedByAccountId: capturedSavedByAccountId
            )
            await self?.decrementInflightSaveCount()
        }

        // Short-circuit when our goal is to only correct and teach Onit using the last history item.
        if isCorrectingAndTeachingWithLastHistory {
            if let snapshot = snapshotToRestore {
                PasteboardManager.shared.restore(snapshot, force: true)
            }
            dismissOverlay()
            return
        }

        if config.forceCorrectionUI {
            // Text wasn't auto-pasted, so insert it fresh
            if !correctedText.isEmpty {
                // Apply the cleanup pipeline's preceding-char-consume decision IF the user's edit
                // didn't invalidate it. Auto-paste mode applies this inline before insertion at
                // line ~2491; here we apply it on the deferred paste path. The signature check
                // catches the common invalidation case (user capitalized the first word → no
                // longer a continuation → don't consume the preceding comma/period).
                let consumeChars: Int
                if state.deletePrecedingChars > 0,
                   correctedText.leadingBoundarySignature == state.leadingBoundarySnapshot {
                    consumeChars = state.deletePrecedingChars
                } else {
                    consumeChars = 0
                    if state.deletePrecedingChars > 0 {
                        log.info("TranscriptionManager: consume-preceding-chars decision invalidated by user edit - skipping consume")
                    }
                }

                Task { [consumeChars] in
                    // Activate the target application first
                    if let pid = targetPid, let app = NSRunningApplication(processIdentifier: pid) {
                        app.activate()
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    // Consume preceding punctuation per cleanup decision, if still valid.
                    if consumeChars > 0, let pid = targetPid {
                        log.info("TranscriptionManager: Deleting \(consumeChars) preceding chars (consume punctuation) before deferred paste")
                        await deletePrecedingCharacters(count: consumeChars, targetPid: pid)
                    }
                    _ = await PasteboardManager.shared.insertViaPaste(correctedText, skipInternalRestore: snapshotToRestore != nil)

                    // Restore clipboard after paste has time to complete
                    try? await Task.sleep(for: .milliseconds(300))
                    if let snapshot = snapshotToRestore {
                        PasteboardManager.shared.restore(snapshot, force: true)
                    }
                }
            } else if let snapshot = snapshotToRestore {
                // No paste needed, restore immediately
                PasteboardManager.shared.restore(snapshot, force: true)
            }
        } else {
            // Text was auto-pasted, only replace if it was actually changed
            if correctedText != originalText && !correctedText.isEmpty {
                if state.canReplacePastedText {
                    // Pause safety monitors during our own injection so the backspaces/paste
                    // we send don't trip the dirty flag for next time.
                    resetPasteSafety()
                    Task {
                        // Use the pre-save snapshot of lastInsertedText so the deletion count exactly
                        // matches what was actually pasted - originalText alone omits the trailing space
                        // when needsTrailingSpace was false, causing one extra character to be deleted.
                        let actualOriginal = originalInsertedText ?? (originalText + " ")
                        await replaceInsertedText(
                            original: actualOriginal,
                            replacement: correctedText,
                            skipInternalRestore: snapshotToRestore != nil
                        )

                        // Restore clipboard after paste has time to complete
                        try? await Task.sleep(for: .milliseconds(300))
                        if let snapshot = snapshotToRestore {
                            PasteboardManager.shared.restore(snapshot, force: true)
                        }

                        // Re-arm safety tracking against the new text so a follow-up Caps+E within
                        // the next 30 s can also replace in place.
                        await MainActor.run { self.installPasteSafetyMonitors() }
                    }
                } else {
                    // Unsafe to backspace into whatever the user is now focused on -
                    // put the corrected text on the clipboard instead and don't touch the app.
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(correctedText, forType: .string)
                    log.info("TranscriptionManager: Copied corrected text to clipboard (in-place replace not safe)")
                    // Intentionally do NOT restore snapshotToRestore - the corrected text on the
                    // clipboard is the user-visible result and must not be overwritten.
                }
            } else if let snapshot = snapshotToRestore {
                // No paste needed, restore immediately
                PasteboardManager.shared.restore(snapshot, force: true)
            }
        }

        // Dismiss the overlay (won't restore clipboard - already handled above)
        dismissOverlay()
    }

    /// Save the correction to history without touching the already-pasted text in the target app.
    /// Use when the text was already auto-pasted and the user wants to update the history record
    /// (to keep it clean) without triggering another paste or replacement.
    /// - Parameter markAsReviewed: see the matching note on `saveCorrection`.
    ///   The "Just save" button keeps the default (`true`) - clicking it is
    ///   an explicit acknowledgement that the transcript is acceptable.
    func saveCorrectionToHistoryOnly(markAsReviewed: Bool = true) {
        guard !isSavingCorrection else {
            log.info("[TranscriptionManager] saveCorrectionToHistoryOnly called while a save is already in flight, ignoring")
            return
        }
        inflightSaveCount += 1

        let originalText = state.originalTranscription
        let correctedText = state.correctionText

        if !correctedText.isEmpty {
            // Trailing whitespace is whatever the cleanup library produced - don't append our own.
            lastInsertedText = correctedText
            lastTargetPid = targetPid
        }

        let audioSamples = state.recordedAudioSamples
        lastRecordedAudioSamples = audioSamples
        let capturedPrecedingText = precedingText
        let capturedFollowingText = followingText
        let capturedAppName = targetAppName
        let capturedAppBundleId = targetAppBundleId

        let snapshotToRestore = clipboardSnapshot
        clipboardSnapshot = nil

        let saveTask = historySaveTask
        let didEdit = originalText != correctedText
        if markAsReviewed {
            Task {
                guard let historyId = await saveTask?.value else { return }
                if didEdit {
                    try? await TranscriptionHistoryManager.shared.update(
                        id: historyId,
                        correctedTranscription: correctedText,
                        precedingText: capturedPrecedingText,
                        followingText: capturedFollowingText
                    )
                } else {
                    if let current = await TranscriptionHistoryManager.shared.fetch(id: historyId),
                       current.reviewStatus == .unreviewed {
                        _ = try? await TranscriptionHistoryManager.shared.updateReviewStatus(
                            id: historyId,
                            status: .reviewed
                        )
                    }
                }
            }
        }

        AnalyticsManager.Transcription.correctionSaved(
            wasEdited: originalText != correctedText,
            originalLength: originalText.count,
            correctedLength: correctedText.count,
            appName: capturedAppName,
            appBundleId: capturedAppBundleId
        )

        // Persistent term memory: the "Just save" path is still a real user
        // correction - record its introduced terms as correction sightings.
        if didEdit {
            TermMemoryService.shared.recordCorrection(
                raw: originalText, corrected: correctedText,
                appBundle: capturedAppBundleId)
        }

        // Mirror the correction into the corrections store so the "Just save"
        // path lands in the same pipeline as the regular "Save correction" flow.
        let capturedRawASRText = state.rawASRText
        let capturedHistoryTask = historySaveTask
        let capturedSavedByAccountId = AuthManager.shared.account.map { String($0.id) }
        let capturedExcludedReason = Self.eligibilitySnapshot()
        let capturedSnippetExpanded = state.snippetExpanded
        Task { @MainActor [weak self] in
            let resolvedHistoryId = await capturedHistoryTask?.value
            try? await TranscriptionCorrectionManager.shared.saveCorrection(
                originalTranscription: originalText,
                rawTranscription: capturedRawASRText,
                snippetExpanded: capturedSnippetExpanded,
                correctedTranscription: correctedText,
                audioSamples: audioSamples,
                sampleRate: 16000,
                precedingText: capturedPrecedingText,
                followingText: capturedFollowingText,
                appName: capturedAppName,
                appBundleId: capturedAppBundleId,
                historyId: resolvedHistoryId,
                excludedReason: capturedExcludedReason,
                savedByAccountId: capturedSavedByAccountId
            )
            await self?.decrementInflightSaveCount()
        }

        if let snapshot = snapshotToRestore {
            PasteboardManager.shared.restore(snapshot, force: true)
        }

        dismissOverlay()
    }

    /// Replace the originally inserted text with the corrected text
    /// Uses backspace to delete differing suffix, then pastes the replacement.
    /// `skipInternalRestore` must only be true when the caller owns a clipboard
    /// snapshot it will restore itself; otherwise the internal restore is the
    /// only thing preventing the pasted fragment from sticking on the clipboard.
    private func replaceInsertedText(original: String, replacement: String, skipInternalRestore: Bool) async {
        guard let pid = targetPid else { return }

        // Compute common prefix to avoid deleting and reinserting shared characters
        let sharedPrefix = original.commonPrefix(with: replacement)
        let charsToDelete = max(0, original.count - sharedPrefix.count)
        let textToInsert = String(replacement.dropFirst(sharedPrefix.count))

        // If nothing to change, return early
        guard charsToDelete > 0 || !textToInsert.isEmpty else { return }

        // Activate the target application first so it receives the key events
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            try? await Task.sleep(for: .milliseconds(200)) // Wait for app to become foreground
        }

        // Delete characters using the fast batch-delete path
        if charsToDelete > 0 {
            await fastDeleteCharacters(count: charsToDelete, targetPid: pid)
        }

        // Insert the new text via paste. When the caller restores its own user
        // snapshot afterwards, skip the internal restore to avoid competing writes;
        // when it has none (e.g. Caps+E re-edit, where no snapshot was taken), keep
        // the internal restore so the user's clipboard isn't left overwritten.
        if !textToInsert.isEmpty {
            _ = await PasteboardManager.shared.insertViaPaste(textToInsert, skipInternalRestore: skipInternalRestore)
        }
    }

    /// Delete `count` characters via a fast backspace loop on a userInteractive background queue.
    ///
    /// Posts each down/up event pair with a 1.5 µs throttle (`usleep(1500)`) so the HID layer
    /// doesn't coalesce or drop events - empirically reliable for 1–500+ characters. Using
    /// `.privateState` for the event source makes events independent of the user's live modifier
    /// keys, preventing an accidentally-held ⌘ from turning ⌫ into ⌘⌫ (line-delete).
    ///
    /// The function is `async` and awaits full completion before returning, so callers can
    /// sequence further work (text insertion, clipboard restore, etc.) without additional sleeps.
    private func fastDeleteCharacters(count: Int, targetPid: pid_t?) async {
        guard count > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                guard let source = CGEventSource(stateID: .privateState) else {
                    cont.resume(); return
                }
                source.localEventsSuppressionInterval = 0.0
                let backspaceKey: CGKeyCode = 0x33
                for i in 0..<count {
                    let down = CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: true)
                    let up   = CGEvent(keyboardEventSource: source, virtualKey: backspaceKey, keyDown: false)
                    down?.flags = []
                    up?.flags = []
                    if let pid = targetPid {
                        down?.postToPid(pid)
                        up?.postToPid(pid)
                    } else {
                        down?.post(tap: .cghidEventTap)
                        up?.post(tap: .cghidEventTap)
                    }
                    if i + 1 < count { usleep(1500) }
                }
                cont.resume()
            }
        }
    }

    /// Delete characters by sending backspace key events.
    /// Creates fresh CGEvent objects per keypress - reusing the same event pointer
    /// after posting is unreliable and can cause drops under rapid firing.
    func deleteCharacters(count: Int) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms per keypress
        }
    }

    /// Re-reads the text before the cursor via AX, used to verify deletion results.
    private func readCurrentPrecedingText(from pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return nil }
        let axElement = element as! AXUIElement
        guard let context = try? AccessibilityTextExtractor.shared.extractTextCursorContext(from: axElement) else {
            log.warning("TranscriptionManager: AX text re-read failed - deletion verification skipped")
            return nil
        }
        return String(context.textBeforeCursor.replacingOccurrences(of: "\0", with: " ").suffix(200))
    }

    /// Delete trailing punctuation / spaces before the insertion point.
    /// Wraps `fastDeleteCharacters` with a server-safety cap of 20 characters.
    /// Includes an AX re-read guard: if the focused element's text no longer ends with
    /// a sentence terminator the user may have moved focus, so deletion is skipped.
    private func deletePrecedingCharacters(count: Int, targetPid: pid_t?) async {
        guard count > 0 else { return }
        // Sanity cap: server should never return more than ~5; cap at 20 to prevent
        // a server bug from silently destroying paragraphs of user content.
        let clampedCount = min(count, 20)
        // AX re-read guard: if the focused element's current text no longer ends
        // with a sentence terminator (., !, ?) followed only by whitespace, the
        // user typed / moved focus between recording start and stop - the
        // scored position is stale and the backspaces would eat unrelated text.
        if let pid = targetPid,
           let current = readCurrentPrecedingText(from: pid) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = trimmed.last, Self.sentenceEnders.contains(last) else {
                log.info("TranscriptionManager: AX state changed since recording - skipping \(clampedCount)-char deletion")
                return
            }
        }
        await fastDeleteCharacters(count: clampedCount, targetPid: targetPid)
    }

    enum CancelTranscriptionReason {
        case inputDeviceUnplugged
        case recordingFailed
        case recordingCancelled
    }

    /// Cancel transcription session without inserting text
    func cancelTranscription(reason: CancelTranscriptionReason? = nil) {
        guard isTranscribing else { return }

        // Restart the inactivity countdown from the end of this session.
        ASRModelLifecycleService.shared.recordActivity()
        CleanupModelLifecycleService.shared.recordActivity()

        // Track session cancelled
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        if let startTime = sessionStartTime {
            let duration = Date().timeIntervalSince(startTime)
            AnalyticsManager.Transcription.sessionCancelled(
                shortcutType: shortcutType,
                activationMode: activationMode.rawValue,
                duration: duration,
                appName: targetAppName,
                appBundleId: targetAppBundleId
            )
        }

        // Restore user's original clipboard contents
        if let snapshot = clipboardSnapshot {
            PasteboardManager.shared.restore(snapshot, force: true)
            clipboardSnapshot = nil
        }

        // Cancel tasks
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioStreamTask?.cancel()
        audioStreamTask = nil

        // Dispose any armed chunked-streaming session (cancels its worker + resets
        // stitcher/segmenter state via the session's own teardown). No-op when
        // none was armed.
        teardownStreamingSession()

        // Stop microphone
        microphoneManager.stopRecording()

        // Reset audio buffer
        resetCurrentASR()

        isTranscribing = false
        state.isActive = false
        state.isInitializing = false
        state.isProcessing = false
        state.currentTranscription = ""
        state.audioLevel = 0.0
        sessionStartTime = nil
        targetAppName = nil
        targetAppBundleId = nil
        historySaveTask = nil
        axContextGeneration += 1
        
        if let cancelReason = reason {
            switch cancelReason {
            case .inputDeviceUnplugged:
                HintManager.shared.showTranscriptionAlert(.inputDeviceUnplugged)
            case .recordingFailed:
                HintManager.shared.showTranscriptionAlert(.inputDeviceFailed)
            case .recordingCancelled:
                HintManager.shared.showTranscriptionAlert(.cancelled)
            }
        }
    }

    /// Cleanup resources on app termination
    func cleanup() {
        cancelTranscription()
        isInitialized = false
        llmService.unloadModel()
    }
    

    // MARK: - ASR Helpers

    /// The active backend's service.
    private var currentASRService: ASRBackendService {
        ASRBackendRegistry.descriptor(for: config.backend).service
    }

    /// Get accumulated audio samples
    private var currentASRAccumulatedSamples: [Float] { currentASRService.accumulatedSamples }

    /// Get accumulated audio duration
    private var currentASRAccumulatedDuration: Double { currentASRService.accumulatedDuration }

    /// Reset the ASR audio buffer
    private func resetCurrentASR() { currentASRService.reset() }

    /// Append audio to ASR
    private func appendAudioToCurrentASR(_ buffer: AVAudioPCMBuffer) { currentASRService.appendAudio(buffer) }

    // MARK: - Chunked Streaming

    /// What consuming the streaming session at stop produced.
    private enum StreamingStopOutcome {
        /// A streamed transcript is ready - run it through the normal downstream
        /// (dictionary rescore → format matcher → snippets → insert).
        case assembled([NbestHypothesis])
        /// The session drained cleanly but produced no speech. Not trusted as
        /// final - the streaming speech gate is energy-based, not the batch Silero
        /// VAD - so the caller single-shots the full buffer to confirm.
        case empty
    }

    /// Arm a chunked-streaming session for the dictation about to start, iff the
    /// `chunkedStreamingEnabled` flag is on AND the active backend advertises
    /// streaming AND its engine resolves. Fail-soft: any miss leaves
    /// `streamingSession` nil and the dictation stays on the (byte-for-byte
    /// unchanged) single-shot batch path. Must run before the first audio buffer
    /// is fed. Called from `startTranscription`.
    private func armStreamingSessionIfEligible() {
        // Reset per-dictation streaming state up front. Tear down (not just drop)
        // any prior session: a rapid stop→start can arm this before the previous
        // stop task consumes its session, and nil-ing the reference alone would
        // orphan that session's worker Task + audio buffer (the parked worker
        // keeps the session alive forever). `teardownStreamingSession` cancels
        // the worker and clears the same three fields.
        teardownStreamingSession()

        guard config.chunkedStreamingEnabled else { return }

        let backend = config.backend
        let descriptor = ASRBackendRegistry.descriptor(for: backend)
        guard descriptor.supportsChunkedStreaming,
              let engine = descriptor.streamingEngine() else {
            log.info("[streaming] enabled but backend=\(backend.rawValue) has no streaming engine - staying single-shot")
            return
        }

        // Resolve the language hint once for the whole dictation, mirroring the
        // single-language forcing the batch services do (`transcriptionLanguages`
        // count == 1 → force it; multiple / none → nil = auto). Per-clip Whisper
        // detection (Parakeet's multi-language batch path) has no streaming
        // analogue, and streaming reports `detectedLanguage = nil`, so a hint a
        // backend ignores (MLX Granite) is harmless here.
        let languages = config.transcriptionLanguages
        let language = languages.count == 1 ? languages.first : nil

        streamingSession = StreamingDictationSession(engine: engine, language: language)
        streamingSessionBackend = backend
        log.info("[streaming] session armed backend=\(backend.rawValue) language=\(language ?? "auto")")
    }

    /// Feed the newly-accumulated 16 kHz samples to the armed streaming session
    /// (no-op when none is armed). Sends the delta of the active service's
    /// *resampled* accumulation buffer - a COW read + tail slice, so the session
    /// observes exactly the batch path's audio without a second resampling stage
    /// and its missing-samples sanity check never spuriously trips. Invalidates
    /// the session if the active backend changed mid-dictation (→ single-shot at stop).
    private func feedStreamingSessionIfArmed() async {
        guard let session = streamingSession else { return }

        // Backend switched mid-dictation (e.g. the user changed the model in
        // Settings): the segments were transcribed by an engine that's no longer
        // active. Distrust the session and fall back to single-shot at stop -
        // achieved by nil-ing `streamingSession` (stop then single-shots) and
        // cancelling the worker so it stops hitting the engine for dead audio.
        guard streamingSessionBackend == config.backend else {
            log.warning("[streaming] backend changed mid-session (\(streamingSessionBackend?.rawValue ?? "nil") → \(config.backend.rawValue)) - invalidating, single-shot at stop")
            await session.cancel()
            streamingSession = nil
            streamingSessionBackend = nil
            return
        }

        // The service accumulates resampled 16 kHz mono float32; grab it (COW,
        // O(1)) and hand the session only the frames added since the last feed.
        let accumulated = currentASRService.accumulatedSamples
        let total = accumulated.count
        guard total > streamingFedSampleCount else { return }
        let delta = Array(accumulated[streamingFedSampleCount..<total])
        streamingFedSampleCount = total
        await session.append(samples: delta, absoluteSampleCount: total)
    }

    /// Consume the armed streaming session at stop. Returns:
    ///   - `nil` when no session is armed (flag off / non-streaming backend) OR
    ///     the session failed / was invalidated - all meaning "run the single-shot
    ///     batch path", which is then byte-for-byte the pre-streaming behavior.
    ///   - `.assembled(hypotheses)` when the streamed transcript is ready.
    ///   - `.empty` when the session drained cleanly but produced no speech.
    /// Always disarms the session before returning so the fallback single-shot
    /// isn't gated behind it (the session releases its engine on any nil path).
    private func consumeStreamingSessionForStop() async -> StreamingStopOutcome? {
        guard let session = streamingSession else { return nil }
        // Disarm now: assemble, empty, and fall-back-to-single-shot are all
        // terminal for this session.
        streamingSession = nil
        let armedBackend = streamingSessionBackend
        streamingSessionBackend = nil

        // Backend changed after the last feed observed it (defensive; the feed
        // loop usually catches this first) → distrust the segments, single-shot.
        if armedBackend != config.backend {
            log.warning("[streaming] backend changed before stop - single-shot fallback")
            await session.cancel()
            return nil
        }

        // Mid-recording failure (engine error / dropped-frame shortfall) already
        // flagged the session → single-shot the full buffer.
        if await session.isFailed {
            log.info("[streaming] session already failed - single-shot fallback")
            await session.cancel()
            return nil
        }

        // finish() drains the worker then transcribes the final tail. It returns
        // nil on failure, deadline overrun, OR an empty assembly - distinguish
        // empty from failure via `isFailed` (settled by the time finish returns).
        // Both a hard failure and a streaming-empty end up single-shotting the full
        // buffer, but they are reported distinctly for logging clarity. The tail
        // segment self-heals an idle-unload in this post-stop window via the
        // engine's own ensureLoaded().
        guard let result = await session.finish() else {
            if await session.isFailed {
                log.warning("[streaming] finish failed / timed out - single-shot fallback")
                return nil
            }
            log.info("[streaming] finish assembled no text - empty dictation")
            return .empty
        }

        log.info("[streaming] assembled transcript (\(result.text.count) chars, timestamps=\(result.wordTimestamps != nil ? "yes" : "no"))")
        // A single hypothesis: N-best selection downstream is skipped for count
        // <= 1, and rescore / format matcher / snippets all run on this text. The
        // absolute word timeline (or nil) feeds the custom-dictionary rescore.
        let hypothesis = NbestHypothesis(
            text: result.text,
            rawText: nil,
            score: 0,
            confidence: 1,
            wordTimestamps: result.wordTimestamps)
        return .assembled([hypothesis])
    }

    /// Dispose the armed streaming session (cancel its worker + release its
    /// engine) and clear the per-dictation feed state. No-op when nothing is
    /// armed. The cancel is fire-and-forget because the cancel paths are
    /// synchronous - an in-flight segment finishes on its own and its result is
    /// discarded (same as the session's own timeout path).
    private func teardownStreamingSession() {
        if let session = streamingSession {
            Task { await session.cancel() }
        }
        streamingSession = nil
        streamingSessionBackend = nil
        streamingFedSampleCount = 0
    }

    /// Transcribe using the active backend.
    /// - Returns: Tuple of (hypotheses, detected ISO 639-1 language code or nil if auto, vad_suppressed flag)
    private func transcribeWithCurrentBackend() async throws -> ([NbestHypothesis], String?, Bool) {
        // Centralised dispatch log - single filter (`[asr-dispatch]`) to answer
        // "which model just transcribed this clip?" without juggling per-service
        // log prefixes.
        let model = config.selectedASRModel
        log.info("[asr-dispatch] model=\"\(model.displayName)\" id=\(model.id) backend=\(config.backend.rawValue)")
        // Stage the dictionary glossary for the MLX transcribers (Qwen3/Granite)
        // to read via the side-channel. Empty when prompt-biasing is off → nil
        // context, i.e. no behavior change for everyone else.
        ASRPromptContext.shared.set(buildASRPromptPayload())
        // One inference at a time across dictation, file jobs, re-transcription and pings.
        return try await ASREngineGate.asr.withEngine(jumpQueue: true) {
            try await currentASRService.transcribe()
        }
    }

    /// Build the ASR prompt-biasing payload (custom-dictionary glossary). Empty
    /// - meaning no biasing - unless the prompt-biasing flag *and* the dictionary
    /// master toggle are on, the backend is MLX, and there are terms. Reads the
    /// persisted Defaults directly (thread-safe; no actor hop needed).
    /// - Parameter includeScreenTerms: false keeps the user's dictionary only, for audio
    ///   that did not come from the screen: no mined screen terms, and no term memory
    ///   (terms seen on screen across apps), neither in the glossary nor in the trie
    ///   boost aliases.
    private func buildASRPromptPayload(includeScreenTerms: Bool = true) -> ASRPromptContext.Payload {
        var payload = ASRPromptContext.Payload()
        // Prompt biasing must be enabled and the backend MLX (only Qwen3/Granite read it).
        guard Defaults[Defaults.Keys.TranscriptionConfigKeys.asrDictionaryPromptEnabled],
              config.backend == .mlx else { return payload }

        var terms: [String] = []
        var seen = Set<String>()
        func add(_ candidates: [String]) {
            for raw in candidates {
                let term = raw.trimmingCharacters(in: .whitespaces)
                let key = term.lowercased()
                guard !term.isEmpty, !seen.contains(key) else { continue }
                terms.append(term); seen.insert(key)
            }
        }
        // Layer B - the user's saved dictionary (when the dictionary feature is on).
        if Defaults[.customDictionaryEnabled] {
            add(Defaults[.customDictionaryTermsV2].map(\.text))
        }
        // Layer C - ephemeral mined terms (user terms take precedence).
        if includeScreenTerms, Defaults[Defaults.Keys.TranscriptionConfigKeys.asrOnScreenTermsEnabled] {
            if onScreenTermsUseAXEffective {
                // Accessibility source: mine the preceding text now (it's ready by
                // transcribe time; the word list was warmed at dictation start)
                // and union it with the window-tree walk staged at dictation
                // start. Preceding-text terms come first - they're closest to
                // where the user is typing.
                let axText = precedingTextForMining ?? precedingText ?? ""
                let result = CapsTermSelector.shared.selectCapsTermsTraced(axText)
                var merged = result.terms
                var seen = Set(merged.map { $0.lowercased() })
                for term in onScreenMinedTerms where seen.insert(term.lowercased()).inserted {
                    merged.append(term)
                }
                add(merged)
                // Also stage the AX-mined terms for the deterministic format
                // matcher. `applyFormatMatcherIfEnabled` reads `onScreenMinedTerms`
                // (populated only by the OCR path) - without this, an AX-mined term
                // reaches the prompt but NOT the matcher, so a camelCase term the
                // model spells as separate words (e.g. "preceding text for mining")
                // never gets deterministically merged back. This runs before
                // transcribe (in transcribeWithCurrentBackend), so it's ready when
                // the matcher runs on the output.
                onScreenMinedTerms = merged
                #if DEBUG
                log.info("[asr-prompt] Layer C (AX) mined \(merged.count) term(s) from \(axText.count) preceding + \(axWindowMiningTrace?.text.count ?? 0) window-tree chars")
                #endif
                #if DEBUG || ONIT_BETA
                var recordedText = axText
                if let treeText = axWindowMiningTrace?.text, !treeText.isEmpty {
                    recordedText += (recordedText.isEmpty ? "" : "\n") + "⸻ window tree ⸻\n" + treeText
                }
                let treeChars = axWindowMiningTrace?.text.count ?? 0
                ASRPromptContext.shared.recordOnScreenMining(
                    terms: merged, ocrText: recordedText,
                    decisions: result.decisions + (axWindowMiningTrace?.decisions ?? []),
                    screenshot: nil, hasCommonList: result.hasCommonList,
                    source: treeChars > 0
                        ? "Accessibility (window tree \(treeChars) chars + preceding text \(axText.count) chars)"
                        : "Accessibility (preceding text only - window walk empty or not finished)")
                #endif
            } else {
                add(onScreenMinedTerms)   // OCR source, mined at dictation start
            }
        }
        // Layer D - persistent term memory: top-K terms by ACT-R activation,
        // accumulated across apps and days. Appended after the user dictionary
        // and current-screen terms so the glossary cap slices the head (saved +
        // screen first); the decode-time trie carries the full list. The AX
        // mining above is also recorded as sightings (the OCR path records at
        // capture time in `mineOnScreenTermsIfEnabled`).
        if includeScreenTerms, TermMemoryService.isEnabled {
            if Defaults[Defaults.Keys.TranscriptionConfigKeys.asrOnScreenTermsEnabled],
               onScreenTermsUseAXEffective {
                TermMemoryService.shared.recordScreenSightings(
                    terms: onScreenMinedTerms, viaAccessibility: true,
                    appBundle: targetAppBundleId)
            }
            add(TermMemoryService.shared.snapshot().terms)
        }
        payload.dictionaryTerms = terms
        #if DEBUG
        log.info("[asr-prompt] staged \(terms.count) term(s)")
        #endif
        stageTrieBoost(termsStaged: !terms.isEmpty, includeTermMemory: includeScreenTerms)
        return payload
    }

    /// EXPERIMENTAL decode-time trie boost (Qwen3 only): stage the per-dictation
    /// settings alongside the prompt payload. Aliases come from each saved
    /// term's `commonMistakes`, minus any surface made purely of known-English
    /// words - a real word must never become an unconditional decode-time
    /// rewrite (those belong to the gated post-ASR path). Cleared whenever the
    /// feature is off so a toggle flip never leaves stale settings staged.
    private func stageTrieBoost(termsStaged: Bool, includeTermMemory: Bool) {
        // NOTE: reached only when `buildASRPromptPayload`'s prompt-bias guard
        // passed (asrDictionaryPromptEnabled has no user-facing toggle and
        // defaults on, so in practice this is always reachable). The persistent
        // term store can activate the boost even with the dictionary toggle
        // off - its terms are in the staged payload either way.
        let memoryOn = includeTermMemory && TermMemoryService.isEnabled
        guard termsStaged,
              Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTrieBoostEnabled],
              Defaults[.customDictionaryEnabled] || memoryOn else {
            ASRPromptContext.shared.setTrieBoost(.init())
            return
        }
        // Fail CLOSED: no unconditional rewrites without the real-word guard
        // (review finding - a missing frequency list must not open the gate).
        // Term-memory aliases fail closed the same way: their generation runs
        // the guard, so with no word list none are ever generated.
        var aliases: [String: [String]]
        if Defaults[.customDictionaryEnabled], CapsTermSelector.shared.hasCommonWordList {
            aliases = Self.safeBoostAliases(
                terms: Defaults[.customDictionaryTermsV2].map { ($0.text, $0.commonMistakes) },
                isKnownEnglishWord: { CapsTermSelector.shared.isKnownEnglishWord($0) })
        } else {
            aliases = [:]
        }
        if memoryOn, CapsTermSelector.shared.hasCommonWordList {
            // The merge only resolves collisions - the saved dictionary's
            // terms and aliases win over term-memory predictions.
            aliases = Self.mergingMemoryAliases(
                into: aliases,
                memory: TermMemoryService.shared.snapshot().unconditionalAliases)
        }
        ASRPromptContext.shared.setTrieBoost(
            .init(enabled: true, strength: 4, maxBacktracks: 16, aliases: aliases))
        #if DEBUG
        log.info("[asr-prompt] trie boost staged (\(aliases.count) term(s) with aliases)")
        #endif
    }

    /// Merge term-memory unconditional aliases under the saved dictionary's:
    /// a surface already used as a term or claimed as an alias is never
    /// re-claimed, and aliases under 3 chars are dropped (same floor as
    /// `safeBoostAliases`). Deterministic iteration for testability.
    nonisolated static func mergingMemoryAliases(
        into existing: [String: [String]],
        memory: [String: [String]]
    ) -> [String: [String]] {
        var merged = existing
        var claimed = Set(existing.keys.map { $0.lowercased() })
        for surfaces in existing.values {
            for s in surfaces { claimed.insert(s.lowercased()) }
        }
        for term in memory.keys.sorted() {
            let key = term.lowercased()
            guard !claimed.contains(key) else { continue }
            var safe: [String] = []
            for alias in memory[term] ?? [] {
                let trimmed = alias.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 3, !claimed.contains(trimmed.lowercased()) else { continue }
                safe.append(trimmed)
                claimed.insert(trimmed.lowercased())
            }
            if !safe.isEmpty {
                merged[term] = safe
                claimed.insert(key)
            }
        }
        return merged
    }

    /// Filter each term's `commonMistakes` down to surfaces safe to use as
    /// unconditional decode-time rewrites: ≥3 chars, not another term or an
    /// already-claimed alias, and not made purely of known-English words
    /// ("calendar", "not in" - those belong to the gated post-ASR path).
    /// Extracted + testable: this filter is the precision guard for the whole
    /// trie-boost feature.
    nonisolated static func safeBoostAliases(
        terms: [(text: String, commonMistakes: [String])],
        isKnownEnglishWord: (String) -> Bool
    ) -> [String: [String]] {
        var aliases: [String: [String]] = [:]
        var claimed = Set(terms.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for term in terms {
            // Key by the TRIMMED term text - the trie build looks aliases up
            // by the trimmed surface, so an untrimmed key silently drops them
            // (review finding).
            let key = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var safe: [String] = []
            for alias in term.commonMistakes {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 3, !claimed.contains(trimmed.lowercased()) else { continue }
                // Require alphabetic content, and split on ALL whitespace so a
                // tab-separated phrase can't bypass the guard (review finding).
                guard trimmed.rangeOfCharacter(from: .letters) != nil else { continue }
                let words = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace })
                guard !words.isEmpty,
                      !words.allSatisfy({ isKnownEnglishWord(String($0)) }) else { continue }
                safe.append(trimmed)
                claimed.insert(trimmed.lowercased())
            }
            if !safe.isEmpty { aliases[key] = safe }
        }
        return aliases
    }

    /// Assemble the term set the format matcher runs with: the saved dictionary
    /// (when enabled) PLUS the on-screen mined terms. Extracted + testable because
    /// dropping `onScreenMined` here is exactly the regression that let an
    /// AX-mined camelCase term reach the prompt but not the deterministic matcher.
    nonisolated static func assembleFormatMatcherTerms(
        dictionaryEnabled: Bool,
        savedTerms: [String],
        onScreenMined: [String]
    ) -> [String] {
        var terms: [String] = []
        if dictionaryEnabled { terms += savedTerms }
        terms += onScreenMined
        return terms.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Layer-B companion: restore each dictionary term's exact written form in the
    /// ASR output when the model emitted it as separate words. Deterministic and
    /// model-free; runs on every backend. Gated by `asrDictionaryFormatMatchEnabled`.
    private func applyFormatMatcherIfEnabled(to text: String) async -> String {
        let enabled = Defaults[Defaults.Keys.TranscriptionConfigKeys.asrDictionaryFormatMatchEnabled]
        #if DEBUG || ONIT_BETA
        // Record every exit path so the debug view always explains the matcher's
        // status (off / no terms / ran-no-change / replacements made).
        ASRPromptContext.shared.recordFormatMatch(before: text, after: text,
                                                  enabled: enabled, termCount: 0)
        #endif
        guard enabled, !text.isEmpty else { return text }
        let terms = Self.assembleFormatMatcherTerms(
            dictionaryEnabled: Defaults[.customDictionaryEnabled],
            savedTerms: Defaults[.customDictionaryTermsV2].map(\.text),
            onScreenMined: onScreenMinedTerms
        )
        guard !terms.isEmpty else { return text }

        let matcher = DictionaryFormatMatcher(terms: terms)

        // Gate to a FIXPOINT: excluding a vetoed span can expose shorter or
        // interior matches the dry pass never visited (it records only the
        // longest match per position) - those must be gated too, or a vetoed
        // merge gets silently replaced by an ungated sub-match. Each round
        // either ends (no new ambiguous candidates / no new vetoes) or grows
        // the exclusion set, so the loop is bounded.
        var excluded: Set<DictionaryFormatMatcher.Replacement> = []
        var scored: Set<DictionaryFormatMatcher.Replacement> = []
        var result = text
        var replacements: [DictionaryFormatMatcher.Replacement] = []
        var vetoed: Set<DictionaryFormatMatcher.Replacement> = []
        while true {
            let pass = matcher.applyDetailed(to: text, excluding: excluded)
            result = pass.text
            replacements = pass.replacements
            let unscored = pass.replacements.filter { $0.ambiguous && !scored.contains($0) }
            if unscored.isEmpty { break }
            scored.formUnion(unscored)
            let newVetoes = await perplexityVetoes(for: unscored, in: text)
            if newVetoes.isEmpty { break }
            vetoed.formUnion(newVetoes)
            excluded.formUnion(newVetoes)
        }

        #if DEBUG
        if result != text { log.info("[asr-format] \(LogPrivacy.summary(text)) -> \(LogPrivacy.summary(result))") }
        for v in vetoed { log.info("[asr-format] gate vetoed a replacement (\(LogPrivacy.summary(v.spoken)) -> \(LogPrivacy.summary(v.term)))") }
        #endif
        #if DEBUG || ONIT_BETA
        ASRPromptContext.shared.recordFormatMatch(
            before: text, after: result, enabled: true, termCount: terms.count,
            replacements: replacements.map { (spoken: $0.spoken, term: $0.term) },
            vetoed: vetoed.map { (spoken: $0.spoken, term: $0.term) })
        #endif
        return result
    }

    /// Gate threshold for format merges, in the NLL gate's normalized units
    /// (Δ_norm = (nllOrig − nllVariant)/nllOrig; positive = variant fits BETTER).
    /// Identifiers always pay a small intrinsic token tax vs natural words, so
    /// unlike Layer A's 0.0 default this is a small negative BUDGET: the merge
    /// survives unless it reads ≳5% worse than the spoken phrase. Provisional -
    /// calibrate from the gate's Δ_norm logs.
    private static let formatGateThreshold: Double = -0.05

    /// Run each AMBIGUOUS candidate merge through the existing perplexity
    /// candidate pipeline (`CustomDictionaryNLLGate`, same as Layer A / KWS
    /// replacements): the gate scores the sentence with the formatted term
    /// substituted at the exact span position and accepts/rejects against the
    /// threshold. Skips entirely (keeping today's deterministic behavior) when
    /// the gate is disabled or the scoring model isn't loaded - the gate's own
    /// unloaded behavior is reject-conservative, which would wrongly veto here.
    private func perplexityVetoes(
        for candidates: [DictionaryFormatMatcher.Replacement],
        in text: String
    ) async -> Set<DictionaryFormatMatcher.Replacement> {
        let ambiguous = candidates.filter(\.ambiguous)
        guard !ambiguous.isEmpty,
              Defaults[Defaults.Keys.TranscriptionConfigKeys.asrDictionaryFormatMatchPerplexityGate],
              await MLXScoringEngine.shared.isLoaded else { return [] }

        var vetoes: Set<DictionaryFormatMatcher.Replacement> = []
        for rep in ambiguous {
            let decision = await CustomDictionaryNLLGate.shared.evaluate(
                asrSentence: text,
                confusionSpan: rep.spoken,
                proxyWord: rep.term,                 // the formatted term IS the probe
                threshold: Self.formatGateThreshold,
                spanWordRange: (startWord: rep.startWord, width: rep.wordWidth)
            )
            #if DEBUG
            if let t = decision.trace {
                log.info("[asr-format] gate (\(LogPrivacy.summary(rep.spoken)) -> \(LogPrivacy.summary(rep.term))) "
                         + "Δ_norm=\(String(format: "%.4f", t.deltaNorm)) → \(decision.accept ? "merge" : "veto")")
            }
            #endif
            // Veto only on a SCORED rejection (trace present). An untraced
            // reject means the gate was unavailable (e.g. scorer unloaded
            // between our isLoaded check and evaluate) - fall back to the
            // deterministic merge rather than blanket-vetoing the session.
            if !decision.accept, decision.trace != nil { vetoes.insert(rep) }
        }
        return vetoes
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Forward audio level from microphone manager
        microphoneManager.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.state.audioLevel = level
            }
            .store(in: &cancellables)

        // Handle microphone errors
        microphoneManager.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.state.errorMessage = error.localizedDescription

                // If the active device was disconnected mid-recording, cancel the session gracefully.
                if case MicrophoneError.activeInputDeviceDisconnected = error,
                    self.isTranscribing
                {
                    self.cancelTranscription(reason: .inputDeviceUnplugged)
                }
            }
            .store(in: &cancellables)

        // Re-observe warmup when the user picks a different ASR model.
        // `WarmupCoordinator.featureStateChanged()` already kicks off the new
        // provider's warmup as a side-effect of `selectedASRModelId.didSet`,
        // but `isInitialized` / `isInitializing` would otherwise stay frozen on
        // the previous backend's state - the Model Status pill in Settings
        // would keep saying "Ready" while Whisper is actually still loading.
        // `dropFirst()` skips the initial value publication so the launch-time
        // `initializeModelsInBackground()` flow stays in charge of the very
        // first warmup.
        config.$selectedASRModelId
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newId in
                guard let self else { return }
                let newBackend = TranscriptionConfig.shared.backend
                let alreadyWarm = isBackendWarmedUp(newBackend)
                log.info("TranscriptionManager [sink-asr-switch]: id=\(newId) backend=\(newBackend.rawValue) alreadyWarm=\(alreadyWarm) - restarting warmup observation")
                initializationTask?.cancel()
                initializationTask = nil
                // Always reset to .loading so the Settings pill reflects the
                // hand-off even when the new backend's provider is still flagged
                // warm from a previous session - `initializeASRBackend` will
                // short-circuit via `handleWarmupComplete` if so, flipping back
                // to .initialized after the UI shows the transition.
                isInitialized = false
                isInitializing = true
                errorMessage = nil
                modelInitStartTime = Date()
                initializeASRBackend()
            }
            .store(in: &cancellables)
    }

    /// Capture audio from microphone and accumulate in ASR service buffer
    private func performAudioCapture() async {
        let audioCaptureClock = Date()
        func elapsedMs() -> Double { Date().timeIntervalSince(audioCaptureClock) * 1000 }
        func elapsed() -> String { String(format: "%.1f", elapsedMs()) }
        log.info("[rec-startup] audio task began executing: \(elapsed())ms")

        // Set up the stream consumer BEFORE starting recording so the continuation is ready when the first callback fires.
        // AsyncStream's build closure runs immediately on init.
        let audioStream = microphoneManager.audioBufferStream

        // Start microphone
        do {
            try await microphoneManager.startRecording()
            let startRecordingMs = elapsedMs()
            let configureAudioEngineMs = microphoneManager.lastConfigureAudioEngineMs
            let audioOutputUnitStartMs = microphoneManager.lastAudioOutputUnitStartMs
            log.info("[rec-startup] startRecording() returned: \(elapsed())ms")
            await MainActor.run {
                state.isInitializing = false

                // Clipboard snapshot stays on MainActor - PasteboardManager is not thread-safe.
                let clipboardStart = Date()
                clipboardSnapshot = PasteboardManager.shared.snapshot()
                let clipboardMs = Date().timeIntervalSince(clipboardStart) * 1000
                log.info("[rec-startup] clipboard snapshot (deferred): \(elapsed())ms")

                // Stash timing values for the startup analytics event, which fires on the first
                // audio buffer so tap_to_first_buffer_ms can be included in the same event.
                startupTimingSnapshot = StartupTimingSnapshot(
                    taskSchedulingMs: startRecordingMs,
                    startRecordingMs: startRecordingMs,
                    configureAudioEngineMs: configureAudioEngineMs,
                    audioOutputUnitStartMs: audioOutputUnitStartMs,
                    clipboardSnapshotMs: clipboardMs
                )
            }

            // Clear stale context from the previous session immediately so LM conditioning
            // never uses outdated text if the background AX call fails or returns early.
            precedingText = nil
            followingText = nil
            precedingTextForMining = nil
            inEmailComposer = nil
            axContextGeneration += 1

            // Onboarding demo: feed the injected context instead of reading Onit's own focused field.
            if isDemoCaptureMode {
                precedingText = demoPrecedingText
                followingText = demoFollowingText
            }

            // Capture AX context on a background thread so it never blocks the MainActor,
            // waveform UI, or audio stream setup. AXUIElementCopyAttributeValue is Mach IPC
            // and is thread-safe from any thread - no MainActor required for the read path.
            // The result is written back via MainActor.run once the IPC returns.
            let capturedPid = targetPid
            let capturedBundleId = targetAppBundleId
            // The composer check costs AX round-trips, so it only runs when the
            // email layout could act on its verdict (same gate as the Settings row).
            let detectsEmailComposer = config.smartFormattingEnabled && config.sfEmailLayoutEnabled
                && config.cleanupLocale != .french
            let generation = axContextGeneration
            Task.detached { [weak self] in
                guard let pid = capturedPid else { return }
                let axStart = Date()

                let appElement = AXUIElementCreateApplication(pid)
                var focusedElement: CFTypeRef?
                var axElement: AXUIElement?
                if AXUIElementCopyAttributeValue(
                    appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement
                ) == .success, let element = focusedElement,
                   CFGetTypeID(element) == AXUIElementGetTypeID() {
                    axElement = (element as! AXUIElement)
                }

                var context: (preceding: String, precedingForMining: String, following: String)?
                if let axElement, let fullText = axElement.value() {
                    // Fall back to end-of-text when selectedTextRange returns nil (apps that don't
                    // support the AX cursor attribute). Using 0 (start) would give empty preceding
                    // text and silently skip smart capitalization; end-of-text is the better guess
                    // since users typically dictate at the cursor, which is usually near the end.
                    let cursorRange = axElement.selectedTextRange()
                    let cursorPosition = cursorRange?.location ?? fullText.count
                    let safePosition = max(0, min(cursorPosition, fullText.count))
                    let beforeCursor = String(fullText.prefix(safePosition))
                    let afterCursor = String(fullText.dropFirst(safePosition))

                    let cleanBefore = beforeCursor.replacingOccurrences(of: "\0", with: " ")
                    context = (
                        preceding: String(cleanBefore.suffix(200)),
                        precedingForMining: String(cleanBefore.suffix(Self.axMiningContextChars)),
                        following: String(afterCursor.replacingOccurrences(of: "\0", with: " ").prefix(500))
                    )
                    let axMs = Date().timeIntervalSince(axStart) * 1000
                    log.info("[rec-startup] AX context captured (background): \(String(format: "%.1f", axMs))ms, \(fullText.count) chars, cursor=\(cursorRange != nil ? "known" : "end-fallback")")
                }

                // Decided even when the focused element or its text cannot be
                // read: a mail client's bundle id is enough on its own.
                var inEmailComposer: Bool?
                if detectsEmailComposer {
                    #if DEBUG
                    let detectStart = Date()
                    #endif
                    let role = axElement?.role()
                    var host: String?
                    let composer = EmailComposer.isComposer(bundleId: capturedBundleId) {
                        host = axElement.flatMap { EmailComposer.webPageHost(of: $0, role: role) }
                        return host
                    }
                    inEmailComposer = composer
                    #if DEBUG
                    let detectMs = Date().timeIntervalSince(detectStart) * 1000
                    log.info("[email-layout] composer=\(composer) bundle=\(capturedBundleId ?? "nil") hasHost=\(host != nil) role=\(role ?? "nil") in \(String(format: "%.1f", detectMs))ms")
                    #endif
                }

                guard context != nil || inEmailComposer != nil else { return }
                let capturedContext = context
                let verdict = inEmailComposer
                await MainActor.run { [weak self] in
                    // Don't clobber the onboarding demo's injected context with the (Onit) AX read,
                    // nor the next dictation's context with this one's late read.
                    guard let self, !self.isDemoCaptureMode, self.axContextGeneration == generation else { return }
                    self.inEmailComposer = verdict
                    guard let capturedContext else { return }
                    self.precedingText = capturedContext.preceding
                    self.precedingTextForMining = capturedContext.precedingForMining
                    self.followingText = capturedContext.following
                    #if DEBUG || ONIT_BETA
                    self.state.precedingContext = capturedContext.preceding
                    self.state.followingContext = capturedContext.following
                    #endif
                }
            }
        } catch {
            await MainActor.run {
                let errorMessage = "Microphone error: \(error.localizedDescription)"
                state.errorMessage = errorMessage

                // Track session failed
                let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
                AnalyticsManager.Transcription.sessionFailed(
                    shortcutType: shortcutType,
                    activationMode: activationMode.rawValue,
                    error: errorMessage,
                    appName: targetAppName,
                    appBundleId: targetAppBundleId
                )

                cancelTranscription(reason: .recordingFailed)
            }
            return
        }

        // Accumulate audio buffers (no streaming transcription - batch mode)
        audioStreamTask = Task {
            var isFirstBuffer = true
            for await buffer in audioStream {
                guard !Task.isCancelled else { break }
                if isFirstBuffer {
                    isFirstBuffer = false
                    let tapToFirstBufferMs = shortcutTapTime.map { Date().timeIntervalSince($0) * 1000 }
                    if let ms = tapToFirstBufferMs {
                        log.info("[rec-startup] first audio frame: \(String(format: "%.1f", ms))ms after shortcut tap")
                    }
                    if let snapshot = startupTimingSnapshot {
                        AnalyticsManager.Transcription.recordingStartupTiming(
                            taskSchedulingMs: snapshot.taskSchedulingMs,
                            startRecordingMs: snapshot.startRecordingMs,
                            configureAudioEngineMs: snapshot.configureAudioEngineMs,
                            audioOutputUnitStartMs: snapshot.audioOutputUnitStartMs,
                            clipboardSnapshotMs: snapshot.clipboardSnapshotMs,
                            axContextMs: 0,
                            tapToFirstBufferMs: tapToFirstBufferMs
                        )
                        startupTimingSnapshot = nil
                    }
                }
                appendAudioToCurrentASR(buffer)
                // In ADDITION to the full-buffer accumulation above (which
                // playback, rescore, and the single-shot fallback all depend on),
                // feed the newly-resampled delta to the streaming session. Gated
                // on an armed session so the flag-off audio loop is untouched.
                // Kept here - the sole consumer of the audio stream - so the
                // session and the service observe the same frames in the same order.
                if streamingSession != nil {
                    await feedStreamingSessionIfArmed()
                }
            }
        }

        // Wait for audio stream task (will be cancelled when stopTranscription is called)
        await audioStreamTask?.value
    }

    /// Handle successful transcription result
    private func handleTranscriptionResult(_ text: String, greedyText: String? = nil, asrDurationMs: Double = 0, nbestDurationMs: Double? = nil, detectedLanguage: String? = nil) async {
        // Silent-audio guard: on (near-)empty audio Qwen3 occasionally ECHOES the
        // glossary prompt back as its "transcription" - the user would get our own
        // instruction text pasted. That's never real speech: fire the empty path.
        guard !ASRPromptContext.isPromptEcho(text) else {
            log.warning("[asr-prompt] transcript is a glossary-prompt echo - treating as empty")
            handleEmptyTranscription()
            return
        }
        // Calculate ASR transcription time
        let asrEndTime = CFAbsoluteTimeGetCurrent()
        var asrTimeMs: Double = 0
        if let startTime = sessionStartTime {
            asrTimeMs = (asrEndTime - startTime.timeIntervalSinceReferenceDate - Date.timeIntervalBetween1970AndReferenceDate) * 1000
            // Actually use CFAbsoluteTime for consistency
            asrTimeMs = asrEndTime * 1000  // Will be recalculated below
        }

        let lmConditioningApplied = greedyText != nil   // server only sends raw_text when LM changed something
        // The truly raw greedy text (before LM conditioning); falls back to `text` if conditioning was off
        let rawGreedyText = greedyText ?? text

        // Store greedy ASR text for debugging (before LM conditioning, not conditioned output)
        state.rawASRText = rawGreedyText

        log.info("═══════════════════════════════════════════════════════════════")
        log.info("TRANSCRIPTION PIPELINE - RESULT RECEIVED")
        log.info("═══════════════════════════════════════════════════════════════")
        if lmConditioningApplied {
            log.info("Stage 1 Raw STT   (\(rawGreedyText.count) chars)")
            log.info("Stage 2 Acoustic  (\(text.count) chars)")
        } else {
            log.info("Raw ASR text (\(text.count) chars)")
        }
        if let startTime = sessionStartTime {
            let asrDuration = Date().timeIntervalSince(startTime) * 1000
            log.info("ASR transcription time: \(String(format: "%.2f", asrDuration))ms")
        }

        // Smart Formatting: model-based cleanup via Swift pipeline (CoreML)
        var finalText = text
        var smartFormattingApplied = false
        var cleanupDurationMs: Double? = nil
        var cleanupCandidateCount: Int? = nil
        var cleanupCategoriesEvaluated: [String: Int]? = nil
        var cleanupCategoriesApplied: [String: Int]? = nil
        var cleanupLogEntriesJSON: String? = nil
        var deletePrecedingChars = 0
        // True when the library scored trailing-space and baked the decision into finalText.
        // When false, fall back to the app heuristic for trailing space.
        var trailingSpaceHandledByLibrary = false

        // Sanitise AX context for the cleanup pipeline:
        //  - strip null chars (some apps insert \0 in AX value)
        //  - cap preceding to last 200 chars (capitalization scoring window)
        //  - cap following to 500 chars (more than enough for trailing-punct context)
        let cleanedPreceding: String? = precedingText.map {
            let stripped = $0.replacingOccurrences(of: "\0", with: " ")
            return stripped.count > 200 ? String(stripped.suffix(200)) : stripped
        }
        let cleanedFollowing: String? = followingText.map {
            let stripped = $0.replacingOccurrences(of: "\0", with: " ")
            return stripped.count > 500 ? String(stripped.prefix(500)) : stripped
        }
        // Guarantee the cleanup LLMs are resident before the provider's readiness
        // check: if they were idle-unloaded, the recording-start re-arm has usually
        // already reloaded them (overlapping speech); this awaits that (or loads now)
        // so an idle-then-short dictation still gets Smart Cleanup instead of raw text.
        await CleanupModelLifecycleService.shared.ensureResidentForCleanup()

        let cleanupInput = CleanupInput(
            transcript: text,
            locale: config.cleanupLocale,
            precedingText: cleanedPreceding,
            followingText: cleanedFollowing,
            inEmailComposer: inEmailComposer == true,
            vocabulary: cleanupVocabulary,
            appContext: .init(name: targetAppName, bundleIdentifier: targetAppBundleId)
        )
        // The onboarding demo's dictations don't spend the free Smart Cleanup words. The
        // scope is task-local, so the cleanup must run inside it on this task (or a child),
        // never on a detached one.
        let cleanup = if isDemoCaptureMode {
            await SmartCleanupEntitlement.withoutMetering { await cleanupService.cleanup(cleanupInput) }
        } else {
            await cleanupService.cleanup(cleanupInput)
        }
        finalText = cleanup.text

        switch cleanup.outcome {
        case .cleaned(let output, let elapsed):
            let stats = cleanup.statsForInsertion
            // The first stage's own verdict: the rewrite (below) is judged separately.
            smartFormattingApplied = (output.text != text)
            // Smart Cleanup only: the bring-your-own-model path reports no analytics,
            // and this feeds `transcription_session_completed`.
            cleanupDurationMs = cleanup.providerID == CleanupProviderID.smart ? elapsed : nil
            cleanupCandidateCount = stats?.candidateCount
            cleanupCategoriesEvaluated = stats?.categoriesEvaluated
            cleanupCategoriesApplied = stats?.categoriesApplied
            deletePrecedingChars = stats?.deletePrecedingChars ?? 0
            log.info("───────────────────────────────────────────────────────────────")
            log.info("SMART FORMATTING SUMMARY")
            log.info("───────────────────────────────────────────────────────────────")
            log.info("Original: \(LogPrivacy.summary(text))")
            log.info("Cleaned:  \(LogPrivacy.summary(output.text))")
            log.info("Changed:  \(smartFormattingApplied)")
            log.info("Chunks:   \(stats?.chunkCount ?? 1)")
            if let report = stats?.debugReport {
                log.info("Report:   \(report.split(separator: "\n").count) line(s)")
            }
            if deletePrecedingChars > 0 {
                log.info("Delete:   \(deletePrecedingChars) preceding chars (consume punct)")
            }
            trailingSpaceHandledByLibrary = stats?.trailingSpaceHandled ?? false
            log.info("Formatting time: \(String(format: "%.2f", elapsed))ms")

        case .failed(.notEntitled):
            // Smart Cleanup refused (free words used up, or no free tier in this build).
            // The raw transcript is pasted as usual; the upgrade prompt is rate-limited and
            // follows the paste rather than racing it. The onboarding demo never prompts.
            log.info("Smart Formatting: NOT ENTITLED (pasting raw text)")
            if let json = Self.notEntitledLogJSON() {
                cleanupLogEntriesJSON = json
            }
            if !isDemoCaptureMode {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    HintManager.shared.smartCleanupRefused(mode: "after_dictation")
                }
            }

        case .failed(let error):
            log.warning("Cleanup failed (provider=\(cleanup.providerID)): \(error.localizedDescription)")
            // Smart Cleanup only: the bring-your-own-model path reports no analytics.
            if cleanup.providerID == CleanupProviderID.smart {
                AnalyticsManager.Transcription.cleanupSwiftError(error: error.localizedDescription)
            }
            let errorEntry = CleanupLogEntry(event: "swift_error", error: error.localizedDescription)
            if let data = try? JSONEncoder().encode([errorEntry]),
               let json = String(data: data, encoding: .utf8) {
                cleanupLogEntriesJSON = json
            }

        case .notReady(.unavailable(let reason)):
            // Can't run on this Mac or build: nothing is loading, so no loading notice.
            log.info("Cleanup: SKIPPED, provider=\(cleanup.providerID) unavailable (\(reason))")

        case .notReady(let availability) where cleanup.providerID != CleanupProviderID.smart:
            // Another provider that isn't set up: nothing is loading, so no loading
            // notice and no warmup skip. Settings shows what's missing.
            log.info("Cleanup: SKIPPED, provider=\(cleanup.providerID) not ready (\(availability))")

        case .notReady(let availability):
            // Smart Cleanup enabled but model still loading - show one-time notice then pass through
            log.info("Smart Formatting: SKIPPED (\(availability))")
            let skipEntry = CleanupLogEntry(event: "cleanup_skipped", reason: "warmup_not_complete")
            if let data = try? JSONEncoder().encode([skipEntry]),
               let json = String(data: data, encoding: .utf8) {
                cleanupLogEntriesJSON = json
            }
            if !hasShownCleanupLoadingAlert {
                hasShownCleanupLoadingAlert = true
                HintManager.shared.showTranscriptionAlert(.cleanupModelLoading)
            }

        case .disabled:
            log.info("Smart Formatting: DISABLED (skipping cleanup)")
        }
        // The Rewrite stage (Settings > Rewrite) ran after the stage above, and judged on
        // its own: `cleanup.text` is already its result when it succeeded.
        var rewritten = false
        if let rewrite = cleanup.rewrite {
            log.info("Rewrite:  \(Self.describe(rewrite))")
            rewritten = cleanup.rewriteApplied && finalText != (cleanup.output?.text ?? text)
            if case .notReady = rewrite {
                // Rewrite is on but the model isn't set up: say so, rather than
                // looking like the rewrite does nothing.
                CleanupFailureNotice.shared.cleanupFailed(.notConfigured)
            }
        }

        // Fire analytics for any cleanup_skipped or pipeline_error entries (covers all branches)
        if let entries = cleanupLogEntriesJSON.flatMap({ json -> [CleanupLogEntry]? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([CleanupLogEntry].self, from: data)
        }) {
            for entry in entries {
                if entry.event == "cleanup_skipped", let reason = entry.reason {
                    AnalyticsManager.Transcription.cleanupSkipped(reason: reason)
                } else if entry.event == "pipeline_error", let error = entry.error {
                    AnalyticsManager.Transcription.cleanupPipelineError(error: error)
                }
            }
        }

        // Log total pipeline timing
        if let startTime = sessionStartTime {
            let totalDuration = Date().timeIntervalSince(startTime) * 1000
            log.info("═══════════════════════════════════════════════════════════════")
            log.info("TOTAL PIPELINE TIMING")
            log.info("═══════════════════════════════════════════════════════════════")
            log.info("  Total Session:  \(String(format: "%8.2f", totalDuration))ms")
            log.info("═══════════════════════════════════════════════════════════════")
        }

        // Dictation is free and unlimited: nothing here meters or blocks it. Only Smart
        // Cleanup is metered, inside the TranscriptionCleanup library (see above).

        state.insertedText = finalText
        state.wasSmartFormattingApplied = smartFormattingApplied || rewritten

        // Leading and trailing space are now baked into finalText by the library
        // (Capitalization.apply for leading sep, TrailingSpaceScorer for trailing).
        // When the library scored trailing space, trust finalText verbatim; otherwise
        // fall back to a simple heuristic - skip the trailing space only when
        // followingText already starts with one, or when the text already ends on
        // whitespace (an email header "Hi Kevin,\n", a dictated "new line" or tab):
        // a space after a line break would open the next line.
        var textToInsert: String
        if trailingSpaceHandledByLibrary {
            textToInsert = finalText
        } else {
            let needsTrailingSpace = finalText.last?.isWhitespace != true && !(followingText?.hasPrefix(" ") ?? false)
            textToInsert = finalText + (needsTrailingSpace ? " " : "")
        }

        // Capture duration before resetting sessionStartTime (used in analytics below)
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        let sessionDuration = sessionStartTime.map { Date().timeIntervalSince($0) }

        // Save transcription to history for playback (if history recording is enabled).
        // Runs concurrently to avoid blocking text insertion. The Task is stored so
        // saveCorrection() can await the history ID if the user edits the transcription.
        // `isDemoCaptureMode` excluded: an onboarding demo dictation must not land in the user's
        // transcript history (see the property's contract), otherwise the six scripted demo phrases
        // show up as real dictations - again on every re-run from Home / Settings → Setup.
        if Defaults[.transcriptionHistoryEnabled] && !isDemoCaptureMode {
            // Capture volatile manager state now - cleanup at the end of handleTranscriptionResult
            // clears these before the historySaveTask body executes.
            let capturedScreenshotFilename = sessionStartScreenshotFilename
            let capturedAppName = targetAppName
            let capturedAppBundleId = targetAppBundleId
            // Same capture rule for the replay metadata: read inside the Task
            // (after the windowContext await), a fast follow-up dictation or a
            // model switch would mis-attribute the prompt/model on this row.
            let capturedASRModelId = config.selectedASRModel.id
            let capturedRewritten = rewritten
            let rewriteSourceText = cleanup.rewriteSource
            let rewriteModel = cleanup.rewriteModel
            // The caret context and composer verdict too: the next dictation resets them.
            let capturedPrecedingText = precedingText
            let capturedFollowingText = followingText
            let capturedInEmailComposer = inEmailComposer
            #if DEBUG || ONIT_BETA
            let capturedWindowContextTask = windowContextTask
            let capturedASRPrompt = ASRPromptContext.shared.lastResolvedPrompt
            #endif
            historySaveTask = Task {
                do {
                    let cleanupMethod = TranscriptionHistory.CleanupMethods.method(
                        smartChanged: smartFormattingApplied,
                        rewritten: capturedRewritten,
                        lmConditioningApplied: lmConditioningApplied
                    )
                    #if DEBUG || ONIT_BETA
                    let windowContext = await capturedWindowContextTask?.value
                    let asrPromptForHistory = capturedASRPrompt
                    #else
                    let windowContext: String? = nil
                    let asrPromptForHistory: String? = nil
                    #endif
                    return try await TranscriptionHistoryManager.shared.saveTranscription(
                        rawTranscription: rawGreedyText,
                        cleanedTranscription: finalText,
                        audioSamples: state.recordedAudioSamples,
                        sampleRate: 16000,
                        appName: capturedAppName,
                        appBundleId: capturedAppBundleId,
                        cleanupMethod: cleanupMethod,
                        cleanupLogEntries: cleanupLogEntriesJSON,
                        precedingText: capturedPrecedingText,
                        followingText: capturedFollowingText,
                        inEmailComposer: capturedInEmailComposer,
                        screenshotFilename: capturedScreenshotFilename,
                        windowContextSnapshot: windowContext,
                        asrPrompt: asrPromptForHistory,
                        asrModel: capturedASRModelId,
                        rewriteSourceText: rewriteSourceText,
                        rewriteModel: rewriteModel
                    )
                } catch {
                    log.error("[TranscriptionManager] Failed to save transcription to history: \(error)")
                    return nil
                }
            }
        }

        // Persistent term memory: the kept dictation's mineable terms are a
        // dictated-and-kept sighting (weight 3) - the cross-app transfer
        // event ("dictate it in Calendar Monday, hot for Zoom Wednesday").
        // Independent of the history toggle; stores terms only, never text.
        TermMemoryService.shared.recordDictatedKept(
            finalText: finalText, appBundle: targetAppBundleId)

        // Reset state
        state.isInitializing = false
        state.currentTranscription = ""
        state.audioLevel = 0.0
        sessionStartTime = nil

        // Increment completed transcription count (demo dictations don't count as real ones)
        if !isDemoCaptureMode {
            Defaults[.transcriptionCompletedCount] += 1
        }

        // Always show the overlay so editing signals (delete, arrow, click) can be detected.
        // The "Not quite right?" button itself is shown only on those signals (or immediately
        // for employees via the alwaysShowCorrectionPrompt toggle).
        let shouldShowCorrectionPrompt = Defaults[.transcriptionAlwaysShowCorrectionPrompt]

        // Insert text in target app or show correction UI first (if forceCorrectionUI is enabled)
        if isDemoCaptureMode {
            // Onboarding demo capture: don't insert into any app or show the correction overlay. Expose
            // the consume count + exact inserted text so the demo can reconstruct merged sentences
            // (preceding − deletePrecedingChars + inserted + following). Set the consume count FIRST,
            // because the demo's `state.$insertedText` observer fires synchronously on the next line and
            // must read the up-to-date `deletePrecedingChars` (otherwise it reconstructs with a stale 0).
            state.deletePrecedingChars = deletePrecedingChars
            state.insertedText = textToInsert
        } else if config.forceCorrectionUI {
            // Forward the cleanup pipeline's preceding-char-consume decision to the overlay.
            // In auto-paste mode this fires inline at line ~2491. Here we defer it to the moment
            // the user clicks "I've edited this, paste" in saveCorrection. Capturing the leading
            // boundary signature of the cleaned text lets that paste step invalidate the consume
            // if the user's edit altered the boundary semantics (e.g. capitalized the first word).
            state.deletePrecedingChars = deletePrecedingChars
            state.leadingBoundarySnapshot = deletePrecedingChars > 0
                ? textToInsert.leadingBoundarySignature
                : ""

            // Capture mouse position now so HintManager can position the overlay with the
            // primary insert button directly under the cursor - UNLESS the user has explicitly
            // chosen .hint positioning mode, in which case respect that and flow through to
            // the hint-anchored fallback (positioning mode .mouse / .ax / .screenRecording all
            // still get the mouse-anchored "button under cursor" ergonomic).
            if Defaults[.transcriptionOverlayPositioningMode] != .hint {
                HintManager.shared.forceCorrectionUIMouseAnchor = NSEvent.mouseLocation
            }
            HintManager.shared.showTranscriptionOverlay(state: state)
            state.showCorrectionPrompt()
            state.enterCorrectionMode()
            HintManager.shared.enableTranscriptionOverlayEditMode()
            HintManager.shared.updateTranscriptionOverlaySize()
            // No OCR in this path - unblock the AX capture so it doesn't wait forever.
            #if DEBUG || ONIT_BETA
            signalOCRDone()
            #endif

            // Track session (no insertion in this path)
            if let duration = sessionDuration {
                AnalyticsManager.Transcription.sessionCompleted(
                    shortcutType: shortcutType,
                    activationMode: activationMode.rawValue,
                    duration: duration,
                    textLength: finalText.count,
                    appName: targetAppName,
                    appBundleId: targetAppBundleId,
                    asrDurationMs: asrDurationMs,
                    nbestDurationMs: nbestDurationMs,
                    cleanupDurationMs: cleanupDurationMs,
                    cleanupCandidateCount: cleanupCandidateCount,
                    cleanupCategoriesEvaluated: cleanupCategoriesEvaluated,
                    cleanupCategoriesApplied: cleanupCategoriesApplied,
                    detectedLanguage: detectedLanguage,
                    vadEnabled: FeatureFlagManager.shared.sileroVadEnabled
                )
            }
        } else {
            // Consume preceding punctuation (e.g. period+space) before inserting so
            // Smart Capitalization can continue a sentence in lowercase.
            if deletePrecedingChars > 0 {
                log.info("TranscriptionManager: Deleting \(deletePrecedingChars) preceding chars (consume punctuation)")
                await deletePrecedingCharacters(count: deletePrecedingChars, targetPid: targetPid)
            }
            // Store the target window frame for OCR-based pasted text detection after paste.
            storeScreenshotCaptureRegionIfNeeded()
            await captureBeforePasteScreenshotIfNeeded()

            // Insert text in target app, then show correction prompt
            #if DEBUG || ONIT_BETA
            var autoEditOutput: String? = nil
            if Defaults[.autoeditEnabled] {
                let improved = await AutoEditService.shared.improve(textToInsert)
                if improved != textToInsert {
                    autoEditOutput = improved
                    textToInsert = improved
                    CleanupDebugHistory.shared.setAutoEditText(improved)
                }
            }
            #endif
            let insertStart = Date()
            // Returns true only when the Spotlight Accessibility workaround handled the insertion.
            // In that case the persistent-target follow-ups below (phantom-space append, undo state,
            // paste-safety monitors, correction overlay) MUST be skipped - Spotlight is an ephemeral
            // panel whose pid is not the frontmost app, so postToPid/AX against `targetPid` would hit
            // the wrong process.
            let usedSpotlightAXInsert = await insertService.insertText(textToInsert, targetPid: targetPid)
            let insertionDurationMs = Date().timeIntervalSince(insertStart) * 1000
            log.info("TranscriptionManager: Text insertion took \(String(format: "%.2f", insertionDurationMs))ms")

            #if DEBUG || ONIT_BETA
            // Patch the history record with the AutoEdit output once the save task has completed.
            if let captured = autoEditOutput {
                let capturedSaveTask = historySaveTask
                Task {
                    if let historyId = await capturedSaveTask?.value {
                        try? await TranscriptionHistoryManager.shared.updateAutoEditText(captured, for: historyId)
                    }
                }
            }
            #endif

            // Track session completed (after insertion so we can include insertion latency)
            if let duration = sessionDuration {
                AnalyticsManager.Transcription.sessionCompleted(
                    shortcutType: shortcutType,
                    activationMode: activationMode.rawValue,
                    duration: duration,
                    textLength: finalText.count,
                    appName: targetAppName,
                    appBundleId: targetAppBundleId,
                    asrDurationMs: asrDurationMs,
                    nbestDurationMs: nbestDurationMs,
                    cleanupDurationMs: cleanupDurationMs,
                    insertionDurationMs: insertionDurationMs,
                    cleanupCandidateCount: cleanupCandidateCount,
                    cleanupCategoriesEvaluated: cleanupCategoriesEvaluated,
                    cleanupCategoriesApplied: cleanupCategoriesApplied,
                    detectedLanguage: detectedLanguage,
                    vadEnabled: FeatureFlagManager.shared.sileroVadEnabled
                )
            }

            // Spotlight insertion is ephemeral (non-activating panel, pid != frontmost app), so
            // none of the persistent-target follow-ups below apply. Skip the phantom-space append,
            // undo/in-place-edit state registration, paste-safety monitors, and correction overlay -
            // registering any of them would postToPid/AX against the wrong process. Still unblock the
            // AX capture continuation in DEBUG/beta builds so nothing waits forever.
            if usedSpotlightAXInsert {
                // Invalidate any prior in-place-edit / undo target so a later Caps+E is a no-op
                // rather than fast-deleting against a stale process. We intentionally do NOT register
                // Spotlight as a target: its pid is ephemeral and not the frontmost app.
                lastInsertedText = nil
                lastTargetPid = nil
                lastTargetWindow = nil
                lastPastedText = nil
                lastPasteTimestamp = nil
                #if DEBUG || ONIT_BETA
                signalOCRDone()
                #endif
            } else {
            // Phantom-space safety net for the FALLBACK heuristic path only.
            // When the heuristic skipped the trailing space because followingText started with
            // a space, that space might have been a phantom (Claude Code, iTerm pad rows in AX).
            // Verify via AX what's actually after the cursor; if it's not a space, append one.
            //
            // Skip this when the library's TrailingSpaceScorer ran - it scored real content
            // post-cursor and intentionally chose "without_space" (e.g. before "!", ")", "'s").
            // Running the verifier would override that decision and produce wrong output.
            if !trailingSpaceHandledByLibrary, textToInsert.last?.isWhitespace != true, let pid = targetPid {
                let spaceAppended = await appendTrailingSpaceIfMissingViaAX(targetPid: pid)
                if spaceAppended {
                    textToInsert += " "
                    log.info("TranscriptionManager: Appended missing trailing space (AX phantom space corrected)")
                }
            }

            // Store for undo/edit functionality (includes trailing space)
            lastInsertedText = textToInsert
            lastTargetPid = targetPid
            lastPastedText = finalText
            lastTargetWindow = targetPid.flatMap { pid in
                let app = AXUIElementCreateApplication(pid)
                var windowRef: AnyObject?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success
                else { return nil }
                return (windowRef as! AXUIElement)
            }
            lastRawASRText = state.rawASRText
            lastRecordedAudioSamples = state.recordedAudioSamples

            // Start watching for events that would make a later Caps+E in-place replace unsafe.
            installPasteSafetyMonitors()

            if shouldShowCorrectionPrompt {
                // Install a temporary monitor to catch editing signals during OCR.
                editingSignalDetectedBeforeOverlay = false
                preOverlayEditingMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if EditingKeyCode.set.contains(event.keyCode) {
                        Task { @MainActor in self?.editingSignalDetectedBeforeOverlay = true }
                    }
                }

                let pastedTextDetectionResult = await detectPastedTextRegionViaOCRIfNeeded(
                    pastedText: finalText
                )
                lastPastedTextDetectionResult = pastedTextDetectionResult

                // OCR is done - safe to start the AX window context capture now.
                #if DEBUG || ONIT_BETA
                signalOCRDone()
                #endif

                if let monitor = preOverlayEditingMonitor {
                    NSEvent.removeMonitor(monitor)
                    preOverlayEditingMonitor = nil
                }

                pendingCorrectionDetectionResult = pastedTextDetectionResult

                // Always show the "Not quite right?" prompt immediately after paste.
                // If a pre-OCR editing signal already fired, highlight it right away.
                showCorrectionPromptOverlay(
                    pastedTextDetectionResult: pastedTextDetectionResult,
                    highlighted: editingSignalDetectedBeforeOverlay,
                    signalType: editingSignalDetectedBeforeOverlay ? "key_delete_pre_ocr" : nil
                )
                editingSignalDetectedBeforeOverlay = false
            } else if let snapshot = clipboardSnapshot {
                // No overlay/prompt will be shown, so restore the user's original clipboard now.
                // Must wait longer than insertViaPaste's internal restoreDelay (0.25s) so the
                // target app has consumed Cmd+V before we overwrite the pasteboard.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    // A new dictation may have replaced the snapshot during the
                    // 400ms window - restoring or clearing would then hand the
                    // next save flow a stale/no snapshot. Only act if ours is
                    // still the current one (changeCount identifies the write).
                    guard clipboardSnapshot?.changeCount == snapshot.changeCount else { return }
                    PasteboardManager.shared.restore(snapshot, force: true)
                    clipboardSnapshot = nil
                }
                // OCR was skipped - still need to unblock the AX capture.
                #if DEBUG || ONIT_BETA
                signalOCRDone()
                #endif
            }
            } // end !usedSpotlightAXInsert
        }

        resetSessionArtifacts()
    }

    /// Per-session state that must be cleared whether the dictation was inserted or blocked by
    /// the paywall. Note: do NOT call stopPostOCREditingMonitors() or clear
    /// pendingCorrectionDetectionResult here. If startPostOCREditingMonitors() was called, those
    /// monitors must stay active until the user presses an editing key/click
    /// (showPendingCorrectionOverlay) or the 3s dismiss task fires.
    private func resetSessionArtifacts() {
        state.isProcessing = false
        targetAppName = nil
        targetAppBundleId = nil
        axContextGeneration += 1

        beforePasteScreenshot = nil
        screenshotCaptureRegion = nil
        sessionStartScreenshotFilename = nil
        #if DEBUG || ONIT_BETA
        releaseWindowContextCapture()
        #endif
        if let monitor = preOverlayEditingMonitor {
            NSEvent.removeMonitor(monitor)
            preOverlayEditingMonitor = nil
        }
        editingSignalDetectedBeforeOverlay = false
    }

    /// Handle empty transcription (no speech detected)
    private func handleEmptyTranscription(vadSuppressed: Bool = false) {
        let recordingDuration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0

        // Track session completed with no text
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        if recordingDuration > 0 {
            AnalyticsManager.Transcription.sessionCompleted(
                shortcutType: shortcutType,
                activationMode: activationMode.rawValue,
                duration: recordingDuration,
                textLength: 0,
                appName: targetAppName,
                appBundleId: targetAppBundleId,
                vadSuppressed: vadSuppressed,
                vadEnabled: FeatureFlagManager.shared.sileroVadEnabled
            )
        }

        // Reset state
        state.isInitializing = false
        state.isProcessing = false
        state.currentTranscription = ""
        state.audioLevel = 0.0
        sessionStartTime = nil
        targetAppName = nil
        targetAppBundleId = nil
        historySaveTask = nil
        axContextGeneration += 1
        #if DEBUG || ONIT_BETA
        releaseWindowContextCapture()
        #endif

        if recordingDuration >= 4 {
            HintManager.shared.showTranscriptionAlert(.silent)
        }
    }

    /// Handle transcription error
    private func handleTranscriptionError(_ error: Error) {
        state.errorMessage = error.localizedDescription
        let recordingDuration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0

        // Track session failed
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType].rawValue
        AnalyticsManager.Transcription.sessionFailed(
            shortcutType: shortcutType,
            activationMode: activationMode.rawValue,
            error: error.localizedDescription,
            appName: targetAppName,
            appBundleId: targetAppBundleId
        )

        // Reset state
        state.isInitializing = false
        state.isProcessing = false
        state.currentTranscription = ""
        state.audioLevel = 0.0
        sessionStartTime = nil
        targetAppName = nil
        targetAppBundleId = nil
        historySaveTask = nil
        axContextGeneration += 1
        #if DEBUG || ONIT_BETA
        releaseWindowContextCapture()
        #endif

        if recordingDuration >= 2 {
            HintManager.shared.showTranscriptionAlert(.failed)
        }
    }
    
    // MARK: - Correction Overlay Trigger

    /// Shows the "Not quite right?" overlay immediately after paste.
    /// - Parameters:
    ///   - pastedTextDetectionResult: OCR/AX result for overlay positioning.
    ///   - highlighted: Whether to show at full opacity immediately (e.g. pre-OCR signal already fired).
    ///   - signalType: If non-nil, logs a correction signal analytics event.
    private func showCorrectionPromptOverlay(
        pastedTextDetectionResult: PastedTextDetectionResult?,
        highlighted: Bool = false,
        signalType: String? = nil
    ) {
        // In mouse / hint modes we don't need bounds - skip the AX call so the nil result
        // routes to the explicit positioning path in showTranscriptionOverlay (mouse cursor
        // for .mouse, hint anchor for .hint, both via the existing fallback chain).
        let result: PastedTextDetectionResult?
        let positioningMode = Defaults[.transcriptionOverlayPositioningMode]
        if positioningMode == .mouse || positioningMode == .hint {
            result = nil
        } else {
            result = pastedTextDetectionResult ?? detectPastedTextBoundsViaAX()
        }

        if let signalType {
            AnalyticsManager.Transcription.correctionSignalDetected(signalType: signalType)
        }

        if highlighted {
            state.isHighlighted = true
        }

        HintManager.shared.showTranscriptionOverlay(state: state, pastedTextDetectionResult: result)
        state.showCorrectionPrompt()
        HintManager.shared.updateTranscriptionOverlaySize()

        // Start monitors - editing signals bump opacity to 1.0 but don't open correction mode.
        startPostOCREditingMonitors(pastedTextBounds: result?.boundingBox)
    }

    /// Called when an editing signal (delete, arrow, click) fires while the overlay is visible.
    /// Logs the event and highlights the overlay without entering correction mode.
    private func handleEditingSignal(signalType: String) {
        stopPostOCREditingMonitors()
        AnalyticsManager.Transcription.correctionSignalDetected(signalType: signalType)
        state.isHighlighted = true
    }

    /// Installs post-OCR monitors that watch for editing signals and highlight the overlay.
    private func startPostOCREditingMonitors(pastedTextBounds: CGRect?) {
        // Highlight overlay on delete/arrow keys (editing signal).
        // Delayed 1s to skip auto-insertions (auto-indent, spaces) that apps produce right after paste.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.postOCRKeyMonitor == nil else { return }
            self.postOCRKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                if EditingKeyCode.set.contains(keyCode) {
                    let signal = keyCode == EditingKeyCode.delete ? "key_delete" : "key_arrow"
                    Task { @MainActor in self?.handleEditingSignal(signalType: signal) }
                } else {
                    // Dismiss on real typing - but ignore whitespace-only characters
                    // (spaces/tabs/newlines auto-inserted by apps after paste).
                    guard let chars = event.characters,
                          !chars.isEmpty,
                          !chars.allSatisfy({ $0.isWhitespace })
                    else { return }
                    Task { @MainActor in self?.dismissOverlay() }
                }
            }
        }

        // Delayed 1s to avoid dismissing on clicks that are part of the paste flow itself.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.postOCRClickMonitor == nil else { return }
            let capturedBounds = pastedTextBounds
            self.postOCRClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let mouse = NSEvent.mouseLocation
                if let bounds = capturedBounds, bounds.contains(mouse) {
                    Task { @MainActor in self?.handleEditingSignal(signalType: "click_in_bounds") }
                }
                // Click outside the overlay window → dismiss.
                Task { @MainActor in
                    guard let overlayWindow = HintManager.shared.transcriptionOverlayWindow else { return }
                    if !overlayWindow.frame.contains(mouse) {
                        self?.dismissOverlay()
                    }
                }
            }
        }

        // App/window switch → dismiss, but ignore activations of the target app itself
        // (we activate it for paste, and the overlay window briefly makes Onit active before
        // returning focus - both of those would fire this notification spuriously).
        let targetPidForObserver = lastTargetPid
        let targetWindowForObserver = lastTargetWindow
        postOCRAppSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPid = activatedApp?.processIdentifier
            let isOnitApp = activatedPid == ProcessInfo.processInfo.processIdentifier

            if isOnitApp {
                return
            }

            if activatedPid == targetPidForObserver {
                // Same app - check if the window changed.
                if let pid = targetPidForObserver, let originalWindow = targetWindowForObserver {
                    let app = AXUIElementCreateApplication(pid)
                    var windowRef: AnyObject?
                    let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
                    if result == .success, let currentWindow = windowRef {
                        if CFEqual(originalWindow, currentWindow as CFTypeRef) {
                        } else {
                            self?.dismissOverlay()
                        }
                    } else {
                    }
                } else {
                }
            } else {
                self?.dismissOverlay()
            }
        }

        // Scroll anywhere → user is navigating, dismiss the overlay.
        // Delayed 1s to skip auto-scrolls that apps trigger immediately after paste.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.postOCRScrollMonitor == nil else { return }
            self.postOCRScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard abs(event.scrollingDeltaY) > 2 || abs(event.scrollingDeltaX) > 2 else { return }
                Task { @MainActor in self?.dismissOverlay() }
            }
        }

        // Stop editing monitors after 3 seconds.
        postOCRDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.stopPostOCREditingMonitors()
        }

        // Auto-dismiss the overlay after 10 seconds.
        overlayAutoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.dismissOverlay()
        }
    }

    /// Removes all post-OCR editing monitors and cancels the monitor expiry task.
    /// Does NOT cancel overlayAutoDismissTask - that lives until dismissOverlay() is called.
    private func stopPostOCREditingMonitors() {
        if let m = postOCRKeyMonitor { NSEvent.removeMonitor(m); postOCRKeyMonitor = nil }
        if let m = postOCRClickMonitor { NSEvent.removeMonitor(m); postOCRClickMonitor = nil }
        if let m = postOCRScrollMonitor { NSEvent.removeMonitor(m); postOCRScrollMonitor = nil }
        if let m = postOCRAppSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(m); postOCRAppSwitchObserver = nil }
        postOCRDismissTask?.cancel()
        postOCRDismissTask = nil
        pendingCorrectionDetectionResult = nil
    }

    // MARK: - OCR-Based Pasted Text Detection

    /// Stores the target app's window frame before pasting, so we know where to capture the before-paste and after-paste screenshots.
    private func storeScreenshotCaptureRegionIfNeeded() {
        guard Defaults[.transcriptionOverlayPositioningMode] == .screenRecording else { return }
        guard ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled else { return }
        guard let pid = targetPid else { return }

        let windowFrame = pid.firstMainWindow?.getFrame(convertedToGlobalCoordinateSpace: true)

        guard let windowFrame else { return }
        screenshotCaptureRegion = windowFrame
    }

    /// Captures a screenshot of the target app window before the paste occurs.
    /// Used in tandem with the after-paste screenshot to diff and isolate the newly-pasted text region.
    /// This allows OCR to pinpoint where newly added text was added to the user's target app.
    private func captureBeforePasteScreenshotIfNeeded() async {
        guard let screenshotCaptureRegion = self.screenshotCaptureRegion else {
            log.warning("[SmartPos] captureBeforePasteScreenshot: skipped - screenshotCaptureRegion is nil")
            return
        }
        guard let appName = targetAppName else {
            log.warning("[SmartPos] captureBeforePasteScreenshot: skipped - targetAppName is nil")
            return
        }

        do {
            beforePasteScreenshot = try await ScreenRecordingManager.captureWindowScreenshot(
                from: appName,
                windowFrame: screenshotCaptureRegion
            )
            if let img = beforePasteScreenshot {
                log.info("[SmartPos] captureBeforePasteScreenshot: captured \(img.width)x\(img.height)px")
            } else {
                log.warning("[SmartPos] captureBeforePasteScreenshot: capture returned nil")
            }
        } catch {
            log.warning("[SmartPos] captureBeforePasteScreenshot: capture threw - \(error.localizedDescription)")
        }
    }

    /// Uses AX APIs to find the bounds of the pasted text in the target app.
    /// Looks up the cursor position after paste, then constructs the range spanning the pasted
    /// text length backwards from it to get the actual bounding rect of the inserted text.
    /// Falls back to the cursor rect if the pasted text range can't be resolved.
    /// Waits for the target app's UI to settle, then reads AX bounds of the pasted text.
    /// The delay is critical - apps like Claude Code reflow their input field after paste,
    /// so reading bounds immediately gives the pre-reflow position.
    private func detectPastedTextBoundsViaAXAfterDelay(delayMs: Int = 500) async -> PastedTextDetectionResult? {
        try? await Task.sleep(for: .milliseconds(delayMs))
        return detectPastedTextBoundsViaAX()
    }

    /// Reads the character immediately after the cursor via AX. If it is NOT a space (meaning the
    /// app's AX previously reported a phantom leading space in followingText), appends a space and
    /// returns true. Returns false if AX is unavailable or the character is already a space.
    private func appendTrailingSpaceIfMissingViaAX(targetPid: pid_t) async -> Bool {
        let app = AXUIElementCreateApplication(targetPid)
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef as! AXUIElement?
        else { return false }

        // Get cursor position.
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        else { return false }
        var cfRange = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange)
        let cursorOffset = cfRange.location + cfRange.length

        // Read 1 character after cursor.
        var nextRange = CFRange(location: cursorOffset, length: 1)
        var nextRangeValue = AXValueCreate(.cfRange, &nextRange)!
        var nextCharRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXStringForRangeParameterizedAttribute as CFString,
            nextRangeValue, &nextCharRef
        ) == .success, let nextChar = nextCharRef as? String
        else { return false }

        guard nextChar != " " && nextChar != "\n" && !nextChar.isEmpty else { return false }

        // The character after the cursor is not a space - append one. Use a direct
        // keystroke rather than insertViaPaste(" ") to avoid touching the clipboard:
        // when chained right after the main paste, the clipboard snapshot captured by
        // insertViaPaste would not be the user's original content and the temporary
        // restore would briefly write the wrong value to the pasteboard.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {
                guard let source = CGEventSource(stateID: .privateState) else {
                    cont.resume(); return
                }
                source.localEventsSuppressionInterval = 0.0
                let spaceKey: CGKeyCode = 0x31
                let down = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: spaceKey, keyDown: false)
                down?.flags = []
                up?.flags = []
                down?.postToPid(targetPid)
                up?.postToPid(targetPid)
                cont.resume()
            }
        }
        return true
    }

    private func detectPastedTextBoundsViaAX() -> PastedTextDetectionResult? {
        guard let pid = lastTargetPid else {
            log.info("[OCR] AX fallback: no target pid")
            return nil
        }

        let app = AXUIElementCreateApplication(pid)

        var focusedElementRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElement = focusedElementRef as! AXUIElement?
        else {
            log.info("[OCR] AX fallback: could not get focused element")
            return nil
        }

        // Get cursor position after paste (selection is typically zero-length at end of pasted text).
        var selectedRangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRange = selectedRangeRef
        else {
            log.info("[OCR] AX fallback: could not get selected text range")
            return nil
        }

        var cfRange = CFRange()
        AXValueGetValue(selectedRange as! AXValue, .cfRange, &cfRange)
        let cursorOffset = cfRange.location + cfRange.length

        // Build the range for the pasted text by stepping back from the cursor.
        // AX uses UTF-16 code units, so use NSString.length for accuracy with emoji/surrogates.
        let pastedLength = (lastPastedText as NSString?)?.length ?? 0
        let pastedRangeStart = max(0, cursorOffset - pastedLength)
        let pastedRange = CFRange(location: pastedRangeStart, length: cursorOffset - pastedRangeStart)

        // Get bounds for the pasted text range.
        var mutablePastedRange = pastedRange
        let axRange = AXValueCreate(.cfRange, &mutablePastedRange)!
        var boundsRef: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        )

        if boundsResult == .success,
           let boundsValue = boundsRef,
           CFGetTypeID(boundsValue as CFTypeRef) == AXValueGetTypeID() {
            var pastedRect = CGRect.zero
            AXValueGetValue(boundsValue as! AXValue, .cgRect, &pastedRect)
            if !pastedRect.isEmpty {
                // AX returns rects in Quartz screen coordinates (top-left origin, y increases down).
                // Convert to Cocoa screen coordinates (bottom-left origin, y increases up).
                let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
                let cocoaRect = CGRect(
                    x: pastedRect.origin.x,
                    y: screenHeight - pastedRect.origin.y - pastedRect.height,
                    width: pastedRect.width,
                    height: pastedRect.height
                )
                return PastedTextDetectionResult(boundingBox: cocoaRect)
            }
        }

        // If pasted range bounds failed, fall back to cursor position bounds.
        var cursorBoundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRange as CFTypeRef,
            &cursorBoundsRef
        ) == .success,
              let cursorBoundsValue = cursorBoundsRef,
              CFGetTypeID(cursorBoundsValue as CFTypeRef) == AXValueGetTypeID()
        else {
            log.info("[OCR] AX fallback: cursor bounds also failed")
            return nil
        }

        var cursorRect = CGRect.zero
        AXValueGetValue(cursorBoundsRef as! AXValue, .cgRect, &cursorRect)
        guard !cursorRect.isEmpty else {
            log.info("[OCR] AX fallback: empty cursor rect")
            return nil
        }

        let screenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let cocoaCursor = CGRect(
            x: cursorRect.origin.x,
            y: screenHeight - cursorRect.origin.y - cursorRect.height,
            width: cursorRect.width,
            height: cursorRect.height
        )
        return PastedTextDetectionResult(boundingBox: cocoaCursor)
    }

    /// Detects the pasted text bounding box by finding diff regions in the before/after paste screenshots and then running OCR on each diff region.
    ///     1. Captures an "after paste" screenshot after a short delay (time buffer for the paste to render).
    ///     2. Diffs the before and after screenshots to isolate the region that changed (where text was inserted).
    ///     3. Crops the after screenshot to the diff bounding box (our diff regions) and runs OCR on the cropped regions.
    ///     4. Searches the OCR results for the pasted text using a cascade of matching strategies.
    ///     5. Returns the bounding box and estimated cursor position of the matched text region.
    ///
    /// Falls back to full-screenshot OCR if the before screenshot is unavailable or the diff produces no changed regions.
    private func detectPastedTextRegionViaOCRIfNeeded(
        pastedText: String
    ) async -> PastedTextDetectionResult? {
        let tTotal = Date()
        log.info("[SmartPos] detectPastedTextRegionViaOCRIfNeeded: start")

        let positioningMode = Defaults[.transcriptionOverlayPositioningMode]
        guard positioningMode == .screenRecording else {
            switch positioningMode {
            case .ax:
                log.info("[OCR] bail: positioning mode is AX - skipping OCR, using AX bounds")
                return await detectPastedTextBoundsViaAXAfterDelay()
            case .mouse:
                log.info("[OCR] bail: positioning mode is Mouse - skipping OCR and AX")
                return nil
            case .hint:
                log.info("[OCR] bail: positioning mode is Hint - skipping OCR and AX")
                return nil
            case .screenRecording:
                return nil  // unreachable: outer guard already excluded screenRecording
            }
        }

        guard ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
        else {
            log.info("[OCR] bail: screen recording not enabled - attempting AX fallback")
            return detectPastedTextBoundsViaAX()
        }

        guard let screenshotCaptureRegion = self.screenshotCaptureRegion
        else {
            log.info("[OCR] bail: screenshotCaptureRegion is nil (window frame was not stored before paste)")
            return detectPastedTextBoundsViaAX()
        }

        // Without a before screenshot the diff produces no clusters, forcing a fallback to
        // full-screenshot Vision OCR - which can take 20+ seconds on large retina displays.
        // Fall back to AX positioning instead, which is instant and avoids the Vision queue.
        // Also snapshot it into a local constant right now - the defer below nils self.beforePasteScreenshot
        // on exit, but a concurrent session's defer could race and clobber it before we use it.
        guard let capturedBeforePasteScreenshot = self.beforePasteScreenshot else {
            log.info("[OCR] bail: before screenshot unavailable - skipping Vision OCR, using AX fallback")
            return detectPastedTextBoundsViaAX()
        }

        /// Clean up stored state regardless of outcome.
        defer {
            self.beforePasteScreenshot = nil
            self.screenshotCaptureRegion = nil
            self.sessionStartScreenshotFilename = nil
        }

        /// Poll every 100ms, diffing each screenshot against the before-paste baseline.
        /// When a diff is detected, OCR confirms the pasted text is present before proceeding.
        /// Falls back after 20 attempts (~2000ms total).
        let tPoll = Date()
        let pasteRenderResult = await waitForPasteToRender(in: screenshotCaptureRegion, appName: targetAppName, pastedText: pastedText, beforePasteScreenshot: capturedBeforePasteScreenshot)
        log.info("[SmartPos] waitForPasteToRender (poll+OCR): \(Int(Date().timeIntervalSince(tPoll) * 1000))ms, matched=\(pasteRenderResult?.matchedBoundsInVisionCoordinates != nil)")

        guard let pasteRenderResult else {
            log.info("[OCR] bail: failed to capture after-paste screenshot from region \(screenshotCaptureRegion)")
            return nil
        }

        let ocrTargetImage = pasteRenderResult.ocrTargetImage
        let cropOriginInPixels = pasteRenderResult.cropOriginInPixels
        let matchedBoundsInVisionCoordinates = pasteRenderResult.matchedBoundsInVisionCoordinates

        let screenScaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0

        let pastedTextBoundingBox: CGRect? = matchedBoundsInVisionCoordinates.map {
            calculatePastedTextBoundingBox(
                from: ocrTargetImage,
                using: screenshotCaptureRegion,
                screenScaleFactor,
                $0,
                cropOriginInPixels
            )
        }

        if matchedBoundsInVisionCoordinates == nil {
            log.info("[OCR] bail: no match found for the pasted text (\(LogPrivacy.summary(pastedText)))")
        } else {
            log.info("[OCR] match found: \(matchedBoundsInVisionCoordinates!)")
        }

        log.info("[SmartPos] detectPastedTextRegionViaOCRIfNeeded: total \(Int(Date().timeIntervalSince(tTotal) * 1000))ms")

        guard let boundingBox = pastedTextBoundingBox else { return nil }

        return PastedTextDetectionResult(boundingBox: boundingBox)
    }
    
    // MARK: - Capture After Paste Screenshot

    /// Polls every 100ms for up to 20 attempts (~2000ms total) waiting for the paste to render.
    /// Each poll takes a screenshot, checks for a visible diff, and if a diff is found runs OCR
    /// to confirm the pasted text is present in the changed region. Returns the first screenshot
    /// where OCR confirms the paste, or the last screenshot if the timeout is reached.
    private func waitForPasteToRender(in screenshotCaptureRegion: CGRect, appName: String?, pastedText: String, beforePasteScreenshot: CGImage) async -> PasteRenderResult? {
        let pollIntervalMs: UInt64 = 100
        let maxAttempts = 20

        // Normalize a CGImage to DeviceRGB so both before and after go through the same
        // color space when converted to pixel buffers. Without this, an untagged before
        // image vs a sRGB-tagged after image produces spurious diffs across the whole frame.
        func normalizeColorSpace(_ image: CGImage) -> CGImage {
            let w = image.width, h = image.height
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage() ?? image
        }

        let tPollLoop = Date()
        for attempt in 1...maxAttempts {
            let tAttempt = Date()
            try? await Task.sleep(for: .milliseconds(pollIntervalMs))

            guard let appName,
                  let screenshot = try? await ScreenRecordingManager.captureWindowScreenshot(
                      from: appName,
                      windowFrame: screenshotCaptureRegion
                  ) else { continue }
            let tScreenshot = Date().timeIntervalSince(tAttempt) * 1000

            var diffRegions: [ImageDifferenceRegion] = []
            let tDiff = Date()
            if beforePasteScreenshot.width == screenshot.width,
               beforePasteScreenshot.height == screenshot.height,
               let (regions, _, _) = try? ImageDifferenceDetector.computeChangedRegions(
                   before: normalizeColorSpace(beforePasteScreenshot),
                   after: normalizeColorSpace(screenshot),
                   tileChangeRatioThreshold: 0.01
               )
            {
                diffRegions = regions
            }
            let tDiffMs = Date().timeIntervalSince(tDiff) * 1000
            let diffRegionCount = diffRegions.count
            let diffDetected = diffRegionCount > 0
            let ms = attempt * Int(pollIntervalMs)
            log.info("[SmartPos] poll \(attempt): screenshot=\(Int(tScreenshot))ms diff=\(Int(tDiffMs))ms regions=\(diffRegionCount) elapsed=\(Int(Date().timeIntervalSince(tPollLoop) * 1000))ms")

            if diffDetected {
                // Diff found - confirm via OCR that the pasted text is actually in the changed region.
                // This prevents false positives from unrelated UI churn (e.g. other text cycling on screen).
                let ocrResult = await runOCROnAfterPasteScreenshot(on: screenshot, before: beforePasteScreenshot, using: pastedText)
                if ocrResult.matchedBoundsInVisionCoordinates != nil {
                    log.info("[OCR] diff + OCR confirmed after \(attempt) attempt(s) (\(ms)ms), regions=\(diffRegionCount)")
                    return PasteRenderResult(
                        ocrAttempts: ocrResult.ocrAttempts,
                        ocrTargetImage: ocrResult.ocrTargetImage,
                        cropOriginInPixels: ocrResult.cropOriginInPixels,
                        matchedBoundsInVisionCoordinates: ocrResult.matchedBoundsInVisionCoordinates
                    )
                }

                log.info("[OCR] poll \(attempt): diff detected but OCR found no match (regions=\(diffRegionCount)), continuing")
            }

            if attempt == maxAttempts {
                log.info("[OCR] paste render timeout after \(attempt) attempts, regions=\(diffRegionCount) - running OCR on last screenshot")
                let ocrResult = await runOCROnAfterPasteScreenshot(on: screenshot, before: beforePasteScreenshot, using: pastedText)
                return PasteRenderResult(
                    ocrAttempts: ocrResult.ocrAttempts,
                    ocrTargetImage: ocrResult.ocrTargetImage,
                    cropOriginInPixels: ocrResult.cropOriginInPixels,
                    matchedBoundsInVisionCoordinates: ocrResult.matchedBoundsInVisionCoordinates
                )
            }

            log.info("[OCR] poll \(attempt): no diff (regions=\(diffRegionCount))")
        }

        return nil
    }

    // MARK: - Run OCR on After-Paste Screenshot
    
    /// First, try cropping before/after screenshot diffs into their own diff regions to be OCR'd.
    ///     Try each diff cluster in order (largest first).
    ///
    /// Then, for each cluster, crop the after-paste screenshot to that cluster's bounding box, run OCR, and check if the pasted text is found.
    ///     The first cluster whose crop contains the pasted text wins.
    ///
    /// Falls back to the full after-paste screenshot if no cluster matches or no clusters exist.
    private func runOCROnAfterPasteScreenshot(
        on afterPasteScreenshot: CGImage,
        before beforePasteScreenshot: CGImage,
        using pastedText: String
    ) async -> (
        ocrTargetImage: CGImage,
        cropOriginInPixels: CGPoint,
        matchedBoundsInVisionCoordinates: CGRect?,
        /// Every OCR attempt made, in order. Each entry has a label (e.g. "diff_cluster_0"),
        /// the detected regions with their text, and whether it produced a match.
        /// Always populated so the debug viewer can show what OCR saw even on failure.
        ocrAttempts: [(label: String, regions: [RecognizedTextRegion], matched: Bool)]
    ) {
        var ocrTargetImage: CGImage = afterPasteScreenshot
        var cropOriginInPixels: CGPoint = .zero
        var matchedBoundsInVisionCoordinates: CGRect?
        var ocrAttempts: [(label: String, regions: [RecognizedTextRegion], matched: Bool)] = []

        let tCrop = Date()
        let croppedDiffRegions = await cropAfterScreenshotToDiffedRegions(from: afterPasteScreenshot, beforePasteScreenshot: beforePasteScreenshot)
        log.info("[SmartPos] crop diff regions: \(Int(Date().timeIntervalSince(tCrop) * 1000))ms, clusters=\(croppedDiffRegions.count)")

        log.info("[OCR] diff produced \(croppedDiffRegions.count) cluster(s), searching for the pasted text (\(LogPrivacy.summary(pastedText)))")

        for (i, diffRegion) in croppedDiffRegions.enumerated() {
            let tClusterOCR = Date()
            guard let detectedTextRegions = await detectTextRegions(in: diffRegion.image)
            else {
                log.info("[OCR] cluster \(i): OCR returned no regions")
                continue
            }
            log.info("[SmartPos] cluster \(i) OCR: \(Int(Date().timeIntervalSince(tClusterOCR) * 1000))ms, regions=\(detectedTextRegions.count), matched=\(findPastedTextInOCRResults(using: pastedText, in: detectedTextRegions) != nil)")

            log.info("[OCR] cluster \(i) (\(detectedTextRegions.count) regions, \(detectedTextRegions.reduce(0) { $0 + $1.text.count }) chars)")

            if let match = findPastedTextInOCRResults(using: pastedText, in: detectedTextRegions) {
                log.info("[OCR] cluster \(i): MATCHED")
                ocrAttempts.append((label: "diff_cluster_\(i)", regions: detectedTextRegions, matched: true))
                ocrTargetImage = diffRegion.image
                cropOriginInPixels = diffRegion.originInPixels
                matchedBoundsInVisionCoordinates = match
                break
            } else {
                log.info("[OCR] cluster \(i): no match")
                ocrAttempts.append((label: "diff_cluster_\(i)", regions: detectedTextRegions, matched: false))
            }
        }

        /// If no cluster contained the pasted text, fall back to OCR on the full after-paste screenshot.
        if matchedBoundsInVisionCoordinates == nil {
            ocrTargetImage = afterPasteScreenshot
            cropOriginInPixels = .zero

            let tFallbackOCR = Date()
            if let fullScreenTextRegions = await detectTextRegions(in: ocrTargetImage) {
                log.info("[OCR] fallback (full screenshot, \(fullScreenTextRegions.count) regions, \(fullScreenTextRegions.reduce(0) { $0 + $1.text.count }) chars)")
                matchedBoundsInVisionCoordinates = findPastedTextInOCRResults(using: pastedText, in: fullScreenTextRegions)
                let matched = matchedBoundsInVisionCoordinates != nil
                log.info("[SmartPos] fallback full-screenshot OCR: \(Int(Date().timeIntervalSince(tFallbackOCR) * 1000))ms, matched=\(matched)")
                log.info("[OCR] fallback: \(matched ? "MATCHED" : "no match")")
                ocrAttempts.append((label: "fallback_full_screenshot", regions: fullScreenTextRegions, matched: matched))
            }
        }

        return (ocrTargetImage, cropOriginInPixels, matchedBoundsInVisionCoordinates, ocrAttempts)
    }
    
    // MARK: - Crop After Screenshot to Diffed Regions

    /// 1. Diffs the before/after paste screenshots.
    /// 2. Computes the bounding box of all changed regions.
    /// 3. Crops the after screenshot to that bounding box.
    private struct CroppedDiffRegion: Sendable {
        /// The cropped image from the after-paste screenshot's diff region.
        let image: CGImage
        /// The pixel-space origin of the after-paste screenshot's diff image.
        let originInPixels: CGPoint
    }

    /// Bundles the screenshot with the OCR results computed during the paste-render poll,
    /// so the caller can use the results directly without re-running OCR.
    private struct PasteRenderResult {
        let ocrAttempts: [(label: String, regions: [RecognizedTextRegion], matched: Bool)]
        let ocrTargetImage: CGImage
        let cropOriginInPixels: CGPoint
        let matchedBoundsInVisionCoordinates: CGRect?
    }

    /// Returns cropped images for each spatially contiguous tile cluster, sorted by tile count - descending.
    /// Each crop is a candidate region where the pasted text might be located.
    /// The caller should try each candidate in order and use the first one where OCR matches the pasted text.
    ///
    /// Runs the GPU image diff, BFS clustering, and cropping off the main actor to avoid blocking the main thread.
    private func cropAfterScreenshotToDiffedRegions(
        from afterPasteScreenshot: CGImage,
        beforePasteScreenshot: CGImage
    ) async -> [CroppedDiffRegion] {

        guard beforePasteScreenshot.width == afterPasteScreenshot.width,
              beforePasteScreenshot.height == afterPasteScreenshot.height
        else {
            log.warning("TranscriptionManager: Skipping Before/after screenshot diffing because they have different dimensions.")
            return []
        }

        return await Task.detached(priority: .userInitiated) {
            self.computeCroppedDiffRegions(
                beforePasteScreenshot: beforePasteScreenshot,
                afterPasteScreenshot: afterPasteScreenshot
            )
        }.value
    }
    
    // MARK: - Compute Cropped Diff Regions

    /// 1. Diffs the before/after screenshots.
    /// 2. Clusters the changed tiles detected in the diff.
    /// 3. Crops the after-paste scerenshot to each cluster's bounding box.
    ///
    /// Note: This function reads no mutable state from `self` and is safe to call off the main actor.
    private nonisolated func computeCroppedDiffRegions(
        beforePasteScreenshot: CGImage,
        afterPasteScreenshot: CGImage
    ) -> [CroppedDiffRegion] {
        /// Get before/after diff regions.
        guard let beforeAfterDiffRegions = findBeforeAfterScreenshotDiffRegions(
            beforePasteScreenshot,
            afterPasteScreenshot
        )
        else {
            return []
        }

        /// Bail if no diff regions were found.
        guard !beforeAfterDiffRegions.isEmpty
        else {
            log.info("TranscriptionManager: No changed regions detected in before/after screenshots diff")
            return []
        }

        /// Get grouped tile clusters from before/after diff regions. We're going to apply OCR to the results.
        let diffRegionTileClusters = findAllContiguousTileClusters(from: beforeAfterDiffRegions)

        guard !diffRegionTileClusters.isEmpty
        else {
            log.info("TranscriptionManager: No contiguous tile clusters found after spatial filtering")
            return []
        }

        let croppedImageHeight = CGFloat(afterPasteScreenshot.height)
        let afterPasteScreenshotImageRect = CGRect(
            x: 0,
            y: 0,
            width: afterPasteScreenshot.width,
            height: afterPasteScreenshot.height
        )

        /// Our result that we return at the end.
        var croppedDiffRegions: [CroppedDiffRegion] = []

        /// Looping through each diff region tile clusters and appending valid cropped diff regions from the after-paste screenshot.
        for diffRegionTileCluster in diffRegionTileClusters {
            let unionRect = diffRegionTileCluster
                .map(\.rect)
                .reduce(diffRegionTileCluster[0].rect) {
                    $0.union($1)
                }

            let clampedRect = unionRect.intersection(afterPasteScreenshotImageRect)
            guard !clampedRect.isEmpty
            else {
                continue
            }

            let croppingRect = CGRect(
                x: clampedRect.origin.x,
                y: croppedImageHeight - clampedRect.origin.y - clampedRect.height,
                width: clampedRect.width,
                height: clampedRect.height
            )

            guard let croppedImage = afterPasteScreenshot.cropping(to: croppingRect)
            else {
                continue
            }

            croppedDiffRegions.append(CroppedDiffRegion(
                image: croppedImage,
                originInPixels: clampedRect.origin
            ))
        }

        return croppedDiffRegions
    }
    
    private nonisolated func findBeforeAfterScreenshotDiffRegions(
        _ beforePasteScreenshot: CGImage,
        _ afterPasteScreenshot: CGImage
    ) -> [ImageDifferenceRegion]? {
        do {
            let (changedRegions, _, _) = try ImageDifferenceDetector.computeChangedRegions(
                before: beforePasteScreenshot,
                after: afterPasteScreenshot,
                tileChangeRatioThreshold: 0.01
            )
            return changedRegions
        } catch {
            log.warning("TranscriptionManager: Before/after screenshot image diff failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Finds all spatially contiguous tile clusters using BFS flood-fill, sorted by tile count descending.
    ///     * Two tiles are considered adjacent if the vertical gap between their rects is at most `maxVerticalGap` pixels.
    ///     * Horizontal position is intentionally ignored because pasted text that wraps to a new line produces changed tiles at the right edge of one line and the left edge of the next - far apart horizontally but vertically adjacent.
    ///     * Using vertical-only proximity groups all tiles in the same horizontal band while separating noise tiles at distant vertical positions (e.g. a target app whose title bar auto-disappears after a few seconds).
    private nonisolated func findAllContiguousTileClusters(
        from beforeAfterDiffRegions: [ImageDifferenceRegion],
        maxVerticalGap: CGFloat = 96
    ) -> [[ImageDifferenceRegion]] {
        guard !beforeAfterDiffRegions.isEmpty
        else {
            return []
        }

        var visited = IndexSet()
        var allContiguousTileClusters: [[Int]] = []

        for startIndex in beforeAfterDiffRegions.indices where !visited.contains(startIndex) {
            var queue = [startIndex]
            var clusterIndices: [Int] = []
            visited.insert(startIndex)

            while !queue.isEmpty {
                let current = queue.removeFirst()
                clusterIndices.append(current)

                for candidate in beforeAfterDiffRegions.indices where !visited.contains(candidate) {
                    let rectA = beforeAfterDiffRegions[current].rect
                    let rectB = beforeAfterDiffRegions[candidate].rect
                    let verticalGap = max(0, max(rectA.minY - rectB.maxY, rectB.minY - rectA.maxY))

                    if verticalGap <= maxVerticalGap {
                        visited.insert(candidate)
                        queue.append(candidate)
                    }
                }
            }

            allContiguousTileClusters.append(clusterIndices)
        }

        return allContiguousTileClusters
            .sorted { $0.count > $1.count }
            .map { indices in
                indices.map {
                    beforeAfterDiffRegions[$0]
                }
            }
    }
    
    // MARK: - Detect Text Regions In After-Paste Screenshot

    /// Run OCR on the after-paste screenshot to find all text regions.
    /// Fires a dummy VNRecognizeTextRequest on a 4x4 blank image to pull the Vision OCR model into ANE/GPU memory.
    /// Called once at recording start so the first real OCR request doesn't pay the cold-start penalty (~7s).
    private func warmUpVisionOCRIfNeeded() {
        guard !Self.isVisionOCRWarmedUp,
              ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
        else { return }
        Self.isVisionOCRWarmedUp = true

        // Use .userInitiated so the warmup task runs immediately and beats the first real OCR request.
        // .background tasks don't get CPU until the system is idle - they lose the race against real OCR.
        Task.detached(priority: .userInitiated) {
            let size = 4
            guard let ctx = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let dummyImage = ctx.makeImage() else { return }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: dummyImage, options: [:])
            try? handler.perform([request])
            log.info("[SmartPos] Vision OCR warmup complete")
        }
    }

    private func detectTextRegions(in afterPasteScreenshot: CGImage) async -> [RecognizedTextRegion]? {
        do {
            let detectedTextRegions: [RecognizedTextRegion]
            detectedTextRegions = try await performTextRecognition(on: afterPasteScreenshot)
            return detectedTextRegions
        } catch {
            return nil
        }
    }
    
    /// Runs text recognition on an image using Apple's Vision framework.
    private nonisolated func performTextRecognition(
        on afterPasteScreenshot: CGImage
    ) async throws -> [RecognizedTextRegion] {
        // Downsample large retina screenshots before running OCR.
        // Vision .accurate on a 3456×2048px image can take 23+ seconds.
        // Capping at 1200px wide keeps OCR fast while preserving recognition quality.
        let image: CGImage = {
            let maxDimension: CGFloat = 1200
            let w = CGFloat(afterPasteScreenshot.width)
            let h = CGFloat(afterPasteScreenshot.height)
            guard w > maxDimension || h > maxDimension else { return afterPasteScreenshot }
            let scale = min(maxDimension / w, maxDimension / h)
            let newWidth = Int(w * scale)
            let newHeight = Int(h * scale)
            let colorSpace = afterPasteScreenshot.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: afterPasteScreenshot.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: afterPasteScreenshot.bitmapInfo.rawValue
            ) else { return afterPasteScreenshot }
            ctx.interpolationQuality = .high
            ctx.draw(afterPasteScreenshot, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return ctx.makeImage() ?? afterPasteScreenshot
        }()

        // Task.detached is required because VNImageRequestHandler.perform is synchronous
        // and would otherwise block the cooperative thread pool. We hold an explicit reference
        // so we can cancel it via withTaskCancellationHandler - detached tasks are NOT
        // cancelled automatically when their creator is cancelled, which was causing a Vision
        // queue backlog: rapid dictation sessions stacked up, each waiting for the previous
        // 20+ second OCR, keeping isProcessing=true forever.
        let detachedTask = Task.detached(priority: .userInitiated) { [image] () throws -> [RecognizedTextRegion] in
            // If the outer session was already cancelled (e.g. user dictated again before
            // we started), skip Vision entirely rather than joining a backed-up queue.
            try Task.checkCancellation()

            let recognizeTextRequest = VNRecognizeTextRequest()
            recognizeTextRequest.recognitionLevel = .accurate
            recognizeTextRequest.usesLanguageCorrection = false

            let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
            try requestHandler.perform([recognizeTextRequest])

            let recognizedTextResults = (recognizeTextRequest.results as? [VNRecognizedTextObservation]) ?? []
            return recognizedTextResults.compactMap { result -> RecognizedTextRegion? in
                guard let candidate = result.topCandidates(1).first else { return nil }
                return RecognizedTextRegion(
                    text: candidate.string,
                    bounds: result.boundingBox,
                    confidence: candidate.confidence,
                    candidate: candidate
                )
            }
        }

        // Propagate cancellation from the outer task into the detached task.
        // When the outer recordedAudioProcessingTask is cancelled (new session started),
        // this cancels the detached task so task.value throws immediately, allowing
        // isProcessing → false without waiting for Vision to finish.
        return try await withTaskCancellationHandler {
            try await detachedTask.value
        } onCancel: {
            detachedTask.cancel()
        }
    }
    
    // MARK: - Find Pasted Text In OCR Results
    
    /// Searches OCR observations for the pasted text using a cascade of matching strategies.
    /// Returns the matched bounds in Vision normalized coordinates (origin bottom-left, values 0-1).
    private func findPastedTextInOCRResults(
        using pastedText: String,
        in detectedTextRegions: [RecognizedTextRegion]
    ) -> CGRect? {
        let normalizedSearchText = normalizeTextForOCRMatching(pastedText)

        guard !normalizedSearchText.isEmpty else { return nil }

        let textRegionsBoundingBoxes = extractDetectedTextRegionsBoundingBoxes(
            from: detectedTextRegions
        )
        
        /// Strategy 1: Exact match in a single region.
        if let exactMatch = findTextRegionExactMatch(
            from: textRegionsBoundingBoxes,
            using: normalizedSearchText
        ) {
            return exactMatch
        }

        /// Strategy 2: Multi-region match (text spanning multiple OCR lines).
        ///     Prefers the tightest match (fewest regions) to avoid overly broad bounding boxes.
        if let bestMultiRegionMatch = findBestMultiRegionMatch(
            from: textRegionsBoundingBoxes,
            using: normalizedSearchText
        ) {
            return bestMultiRegionMatch
        }
        
        /// Strategy 3: Partial match (at least 50% of the text matched).
        if let bestPartialMatch = findBestPartialMatch(
            from: textRegionsBoundingBoxes,
            using: normalizedSearchText
        ) {
            return bestPartialMatch
        }

        /// Strategy 4: Retry all strategies with OCR-lenient normalization.
        ///     Collapses visually ambiguous characters that OCR frequently confuses
        ///         e.g. lowercase L and uppercase I are identical in many fonts.
        /// This is intentionally a fallback - as the lossy normalization increases the risk of false positives, so we only use it when precise matching failed.
        if let lenientMatch = applyOCRLenientMatch(
            from: textRegionsBoundingBoxes,
            using: normalizedSearchText
        ) {
            return lenientMatch
        }

        return nil
    }
    
    /// Normalizes text for OCR matching by lowercasing, normalizing quotes/apostrophes, collapsing whitespace, and trimming.
    private func normalizeTextForOCRMatching(_ text: String) -> String {
        return text
            .lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")  /// Left single quote → ASCII
            .replacingOccurrences(of: "\u{2019}", with: "'")  /// Right single quote → ASCII
            .replacingOccurrences(of: "\u{201C}", with: "\"") /// Left double quote → ASCII
            .replacingOccurrences(of: "\u{201D}", with: "\"") /// Right double quote → ASCII
            .replacingOccurrences(of: "\u{2014}", with: "-")  /// Em dash → hyphen
            .replacingOccurrences(of: "\u{2013}", with: "-")  /// En dash → hyphen
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    typealias OCRTextRegionsBoundingBoxes = [(
        text: String,
        bounds: CGRect,
        candidate: VNRecognizedText?
    )]
    
    /// Extract text regions with their bounding boxes, filtered by confidence and sorted top-to-bottom.
    private func extractDetectedTextRegionsBoundingBoxes(
        from detectedTextRegions: [RecognizedTextRegion]
    ) -> OCRTextRegionsBoundingBoxes {
        var textRegionsBoundingBoxes: OCRTextRegionsBoundingBoxes = []

        for detectedTextRegion in detectedTextRegions {
            guard detectedTextRegion.confidence >= 0.3 else { continue }

            let normalizedText = normalizeTextForOCRMatching(detectedTextRegion.text)
            textRegionsBoundingBoxes.append((
                text: normalizedText,
                bounds: detectedTextRegion.bounds,
                candidate: detectedTextRegion.candidate
            ))
        }

        /// Sort top-to-bottom (higher minY = higher on screen in Vision coordinates).
        textRegionsBoundingBoxes.sort {
            $0.bounds.minY > $1.bounds.minY
        }
        
        return textRegionsBoundingBoxes
    }
    
    private func findTextRegionExactMatch(
        from textRegionsBoundingBoxes: OCRTextRegionsBoundingBoxes,
        using normalizedSearchText: String
    ) -> CGRect? {
        for region in textRegionsBoundingBoxes {
            guard region.text.contains(normalizedSearchText) else { continue }

            // If the region text equals the search text, the whole-region bounds are already tight.
            // If the search text is a substring (e.g. "Very cool." inside "Testing this. Very cool."),
            // use VNRecognizedText.boundingBox(for:) to get the tight sub-observation bounds.
            if region.text == normalizedSearchText {
                return region.bounds
            }

            if let candidate = region.candidate,
               let matchRange = region.text.range(of: normalizedSearchText) {
                // Map normalized-string range back to original candidate string by character offset.
                // Normalization is mostly case-folding (1:1), so offsets are valid in the common case.
                let startOffset = region.text.distance(from: region.text.startIndex, to: matchRange.lowerBound)
                let endOffset   = region.text.distance(from: region.text.startIndex, to: matchRange.upperBound)
                let origStr = candidate.string
                if let origStart = origStr.index(origStr.startIndex, offsetBy: startOffset,  limitedBy: origStr.endIndex),
                   let origEnd   = origStr.index(origStr.startIndex, offsetBy: endOffset,    limitedBy: origStr.endIndex),
                   origStart < origEnd,
                   let tightObs  = try? candidate.boundingBox(for: origStart..<origEnd) {
                    return tightObs.boundingBox
                }
            }

            // Fallback: return whole-region bounds if tight extraction failed.
            return region.bounds
        }

        return nil
    }
    
    private func findBestMultiRegionMatch(
        from textRegionsBoundingBoxes: OCRTextRegionsBoundingBoxes,
        using normalizedSearchText: String
    ) -> CGRect? {
        var bestMultiRegionMatch: (
            startIndex: Int,
            endIndex: Int,
            regionCount: Int
        )? = nil

        for startIndex in 0..<textRegionsBoundingBoxes.count {
            for endIndex in startIndex..<min(startIndex + 10, textRegionsBoundingBoxes.count) {
                let selectedTextRegions = Array(textRegionsBoundingBoxes[startIndex...endIndex])
                let combinedText = selectedTextRegions.map(\.text).joined(separator: " ")

                if combinedText.contains(normalizedSearchText) {
                    let regionCount = endIndex - startIndex + 1
                    if bestMultiRegionMatch == nil || regionCount < bestMultiRegionMatch!.regionCount {
                        bestMultiRegionMatch = (
                            startIndex: startIndex,
                            endIndex: endIndex,
                            regionCount: regionCount
                        )
                    }
                }
            }
        }

        if let match = bestMultiRegionMatch {
            let selectedRegions = Array(textRegionsBoundingBoxes[match.startIndex...match.endIndex])
            return combineBoundsInVisionCoordinates(selectedRegions.map(\.bounds))
        }
        
        return nil
    }
    
    /// Combines multiple Vision-coordinate bounding boxes into a single encompassing bounding box.
    private func combineBoundsInVisionCoordinates(_ bounds: [CGRect]) -> CGRect {
        guard !bounds.isEmpty else { return .zero }

        let minX = bounds.map(\.minX).min() ?? 0
        let maxX = bounds.map(\.maxX).max() ?? 0
        let minY = bounds.map(\.minY).min() ?? 0
        let maxY = bounds.map(\.maxY).max() ?? 0

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
    
    private func findBestPartialMatch(
        from textRegionsBoundingBoxes: OCRTextRegionsBoundingBoxes,
        using normalizedSearchText: String
    ) -> CGRect? {
        var bestPartialMatch: (
            bounds: CGRect,
            matchLength: Int
        )? = nil

        for startIndex in 0..<textRegionsBoundingBoxes.count {
            for endIndex in startIndex..<min(startIndex + 10, textRegionsBoundingBoxes.count) {
                let selectedTextRegions = Array(textRegionsBoundingBoxes[startIndex...endIndex])
                let combinedText = selectedTextRegions.map(\.text).joined(separator: " ")

                let isPrefix = normalizedSearchText.hasPrefix(combinedText)
                let isSuffix = normalizedSearchText.hasSuffix(combinedText)
                let isSubstring = normalizedSearchText.contains(combinedText)

                if (isPrefix || isSuffix || isSubstring) && combinedText.count >= normalizedSearchText.count / 2 {
                    if bestPartialMatch == nil || combinedText.count > bestPartialMatch!.matchLength {
                        bestPartialMatch = (
                            bounds: combineBoundsInVisionCoordinates(selectedTextRegions.map(\.bounds)),
                            matchLength: combinedText.count
                        )
                    }
                }
            }
        }

        if let match = bestPartialMatch {
            return match.bounds
        }
        
        return nil
    }
    
    private func applyOCRLenientMatch(
        from textRegionsBoundingBoxes: OCRTextRegionsBoundingBoxes,
        using normalizedSearchText: String
    ) -> CGRect? {
        let lenientNormalizedSearchText = normalizeTextForOCRLenientMatching(normalizedSearchText)
        
        let lenientRegions: OCRTextRegionsBoundingBoxes = textRegionsBoundingBoxes.map { region in
            (
                text: normalizeTextForOCRLenientMatching(region.text),
                bounds: region.bounds,
                candidate: region.candidate
            )
        }

        /// Lenient Strategy 1
        if let exactMatch = findTextRegionExactMatch(
            from: lenientRegions,
            using: lenientNormalizedSearchText)
        {
            return exactMatch
        }
        
        /// Lenient Strategy 2
        if let multiRegionMatch = findBestMultiRegionMatch(
            from: lenientRegions,
            using: lenientNormalizedSearchText
        ) {
            return multiRegionMatch
        }
        
        /// Lenient Strategy 3
        if let partialMatch = findBestPartialMatch(
            from: lenientRegions,
            using: lenientNormalizedSearchText
        ) {
            return partialMatch
        }
        
        return nil
    }
    
    /// Sometimes, OCR will fail to recognize the difference between two similar-looking characters, like a lowercase "L" and a capital "i".
    /// Only used as a fallback when precise matching fails, since collapsing visually similar characters increases the risk of false positives.
    private func normalizeTextForOCRLenientMatching(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "l", with: "i")  /// Lowercase L → I (OCR confuses I/l in many fonts)
    }
    
    // MARK: - Private Functions: Calculate Pasted Text Bounding Box
    
    /// Convert from Vision normalized coordinates (origin bottom-left, values 0-1) to macOS screen coordinates.
    ///
    /// When the OCR was successfully performed on a cropped region of the full screenshot:
    ///     * `cropOriginInPixels` represents the pixel offset of that crop within the full screenshot. This allows us to get the correct bounding box on the pasted text, relative to the original screenshot capture region, as opposed to getting one that's relative to the cropped region.
    ///     * The Vision coordinates are first mapped to the cropped image's pixel space, then shifted by the crop offset to get full-screenshot pixel coordinates
    ///     * And finally converted to macOS screen coordinates.
    private func calculatePastedTextBoundingBox(
        from ocrTargetImage: CGImage,
        using screenshotCaptureRegion: CGRect,
        _ screenScaleFactor: CGFloat,
        _ matchedBoundsInVisionCoordinates: CGRect,
        _ cropOriginInPixels: CGPoint = .zero
    ) -> CGRect {
        let imageWidthInPoints = CGFloat(ocrTargetImage.width) / screenScaleFactor
        let imageHeightInPoints = CGFloat(ocrTargetImage.height) / screenScaleFactor

        let cropOffsetXInPoints = cropOriginInPixels.x / screenScaleFactor
        let cropOffsetYInPoints = cropOriginInPixels.y / screenScaleFactor

        return CGRect(
            x: screenshotCaptureRegion.minX + cropOffsetXInPoints + matchedBoundsInVisionCoordinates.minX * imageWidthInPoints,
            y: screenshotCaptureRegion.minY + cropOffsetYInPoints + matchedBoundsInVisionCoordinates.minY * imageHeightInPoints,
            width: matchedBoundsInVisionCoordinates.width * imageWidthInPoints,
            height: matchedBoundsInVisionCoordinates.height * imageHeightInPoints
        )
    }

    // MARK: - Debug Capture (Screenshot + Window Context)

    #if DEBUG || ONIT_BETA

    /// Fires a background task to capture the full-window AX content.
    /// The task waits for `signalOCRDone()` before starting the AX traversal so it
    /// doesn't compete with the OCR screenshot poll loop on the main actor.
    private func captureWindowContextIfNeeded(pid: pid_t) {
        // Drain any straggler from a session that ended without reaching the
        // cleanup tail (e.g. a failed transcription): unpark it so it exits,
        // and cancel so a still-running walk stops at the next tree node.
        ocrDoneContinuation?.resume(returning: nil)
        ocrDoneContinuation = nil
        windowContextTask?.cancel()
        ocrDoneSignaled = false
        windowContextTask = Task {
            // Block until OCR-based paste detection finishes (or is skipped).
            // This prevents the heavy AX traversal from competing with the screenshot
            // poll loop, which also runs on the main actor.
            let capturedPid = await withCheckedContinuation { cont in
                if ocrDoneSignaled {
                    cont.resume(returning: targetPid)
                } else {
                    ocrDoneContinuation = cont
                }
            }
            guard !Task.isCancelled else { return nil }
            guard let pid = capturedPid else { return nil }
            // Same reason as the mining walk: this Task inherits the main actor,
            // and firstMainWindow is a chain of synchronous AX roundtrips.
            let mainWindow = await Task.detached(priority: .utility) {
                UncheckedAXElement(element: pid.firstMainWindow)
            }.value.element
            guard let mainWindow else { return nil }

            let start = Date()
            // Cache allowed here (unlike the mining walk): this is debug context
            // capture, and the mining walk primed the same window seconds ago.
            let results = await AccessibilityParsingManager.shared.parseElement(mainWindow, ignoreCache: false)
            guard !results.isEmpty else { return nil }
            let elapsed = Date().timeIntervalSince(start) * 1000
            log.info("[TranscriptionManager] Window AX scrape took \(String(format: "%.0f", elapsed))ms, \(results.count) keys")
            guard let data = try? JSONSerialization.data(withJSONObject: results),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
    }

    /// Session-end release for the window-context capture. Resumes any pending
    /// continuation: Swift requires CheckedContinuations to be resumed exactly
    /// once, nil-ing without resuming leaks. Do NOT cancel the capture task
    /// here: on the nominal path this runs synchronously after signalOCRDone(),
    /// so on the main actor the resumed task hasn't executed yet, and cancelling
    /// would kill every capture before its first instruction (the history save
    /// would record NULL forever). The task is bounded by the 10s parse timeout
    /// and the history save holds its own reference; any straggler is drained at
    /// the next session's capture start.
    /// Idempotent, so the empty/error paths can call it without double-resuming.
    private func releaseWindowContextCapture() {
        ocrDoneSignaled = true
        ocrDoneContinuation?.resume(returning: nil)
        ocrDoneContinuation = nil
        windowContextTask = nil
    }

    /// Signals `captureWindowContextIfNeeded` that OCR is done and the AX traversal can start.
    /// Must be called once per session - either after `detectPastedTextRegionViaOCRIfNeeded`
    /// returns, or when the correction-prompt path is skipped.
    private func signalOCRDone() {
        ocrDoneSignaled = true
        ocrDoneContinuation?.resume(returning: targetPid)
        ocrDoneContinuation = nil
    }


    /// Captures a screenshot of the frontmost window at dictation start (debug builds only).
    /// Saves to Application Support/Onit/transcription_history_screenshots/ and stores the filename
    /// in `sessionStartScreenshotFilename` so it gets referenced in the history record.
    private func captureSessionStartScreenshot() {
        guard ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled else { return }
        guard let appName = targetAppName else { return }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "start_\(timestamp).png"

        Task {
            do {
                let image = try await ScreenRecordingManager.captureWindowScreenshot(
                    from: appName,
                    windowFrame: nil
                )
                if let saved = TranscriptionHistoryManager.shared.saveScreenshot(image, filename: filename) {
                    await MainActor.run { self.sessionStartScreenshotFilename = saved }
                    log.info("[TranscriptionManager] Saved session-start screenshot: \(saved)")
                }
            } catch {
                log.debug("[TranscriptionManager] Session-start screenshot failed: \(error)")
            }
        }
    }
    #endif

    /// Layer C - OCR the on-screen window at dictation start and mine candidate
    /// dictionary terms with the deterministic caps heuristic, staging them in
    /// `onScreenMinedTerms` for `buildASRPromptPayload`. No-op unless on-screen
    /// terms + prompt biasing are enabled on an MLX backend. Runs entirely off the
    /// audio path; failures are swallowed (the glossary falls back to the
    /// persistent dictionary). Language correction is disabled so Vision doesn't
    /// normalise jargon ("Posthog" → "Post hog").
    /// Effective Layer C source: accessibility preceding-text when the user chose
    /// it (debug source switch) OR when screen recording isn't granted - the OCR
    /// path would silently no-op, and most users haven't granted that permission.
    /// AX text covers less of the screen but works with the accessibility
    /// permission dictation already requires.
    private var onScreenTermsUseAXEffective: Bool {
        Defaults[Defaults.Keys.TranscriptionConfigKeys.asrOnScreenTermsUseAccessibility]
            || !ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
    }

    /// Whether Layer C will actually mine this dictation. Single definition so
    /// the debug capture can't outlive the mining it exists to debug: gating it
    /// on the on-screen flag alone still walked the whole AX tree for a user who
    /// had that flag on but the dictionary prompt off.
    private var onScreenMiningWillRun: Bool {
        Defaults[Defaults.Keys.TranscriptionConfigKeys.asrOnScreenTermsEnabled]
            && Defaults[Defaults.Keys.TranscriptionConfigKeys.asrDictionaryPromptEnabled]
            && config.backend == .mlx
    }

    /// Joins the text-bearing values of a parsed AX window into one mining
    /// input. Keys that can't contain on-screen vocabulary are dropped; the
    /// rest are sorted so output is deterministic. The app name and window
    /// title stay in - they often carry exactly the project/product names the
    /// glossary wants.
    nonisolated static func axMiningText(from parsed: [String: String]) -> String {
        let skipped: Set<String> = [AccessibilityParsedElements.elapsedTime]
        return parsed.keys.sorted()
            .filter { !skipped.contains($0) }
            .compactMap { key -> String? in
                let value = parsed[key, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value == "Unknown" ? nil : value
            }
            .joined(separator: "\n")
    }

    private func mineOnScreenTermsIfEnabled() {
        onScreenMiningTask?.cancel()
        onScreenMinedTerms = []
        axWindowMiningTrace = nil
        #if DEBUG || ONIT_BETA
        ASRPromptContext.shared.recordOnScreenMining(terms: [], ocrText: nil)
        #endif
        // Term memory initializes off-thread at dictation start so its cached
        // bias snapshot is ready by transcribe time (no-op when disabled).
        TermMemoryService.shared.warmUp()
        guard onScreenMiningWillRun else { return }

        // Never mine Onit's own windows. For an in-process AX element, AppKit runs the
        // window's accessibility accessors on the *calling* thread; because this walk runs
        // off the main actor (deliberately, so an unresponsive target can't stall startup),
        // that trips a MainActor isolation check on the window (e.g. CenteredWindow.canBecomeKey)
        // → SIGTRAP. The onboarding demo hits this because you dictate into Onit's own window.
        // Mining our own UI has no value regardless - the general AX observers already skip Onit.
        if let pid = targetPid, pid == ProcessInfo.processInfo.processIdentifier { return }

        // Accessibility source: walk the target window's AX tree now and mine
        // terms from everything visible, not just the field being dictated into.
        // Parser output is capped (AccessibilityParserConfig) so a terminal's
        // scrollback can't flood the selector. Cursor-preceding text is still
        // mined at transcribe time in `buildASRPromptPayload` and unioned with
        // these terms; if this walk isn't done by then, the prompt simply uses
        // the preceding text. The word list is warmed off-thread either way so
        // selection stays off the transcribe hot-path.
        if onScreenTermsUseAXEffective {
            Task.detached(priority: .utility) { _ = CapsTermSelector.shared }
            guard let pid = targetPid else { return }
            onScreenMiningTask = Task { [weak self] in
                // This Task inherits the main actor, so resolving the window in
                // it would run firstMainWindow (a chain of synchronous AX
                // roundtrips to the target app) on the main thread, before the
                // mic is even started. Hop off the actor for the roundtrip: an
                // unresponsive target then delays only this mining task.
                let window = await Task.detached(priority: .utility) {
                    UncheckedAXElement(element: pid.firstMainWindow)
                }.value.element
                guard let window else { return }
                // ignoreCache: this walk must see the screen as it is at
                // dictation start, not a cached snapshot up to 30s old.
                let parsed = await AccessibilityParsingManager.shared.parseElement(window, ignoreCache: true)
                let axWindowText = Self.axMiningText(from: parsed)
                guard !axWindowText.isEmpty else { return }
                let result = await Task.detached(priority: .utility) {
                    CapsTermSelector.shared.selectCapsTermsTraced(axWindowText)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.axWindowMiningTrace = (text: axWindowText, decisions: result.decisions)
                // Merge instead of overwrite - `buildASRPromptPayload` already
                // staged preceding-text terms if this walk finished late.
                var merged = self.onScreenMinedTerms
                var seen = Set(merged.map { $0.lowercased() })
                for term in result.terms where seen.insert(term.lowercased()).inserted {
                    merged.append(term)
                }
                self.onScreenMinedTerms = merged
            }
            return
        }

        // OCR source: capture the CORRECT foreground window. Resolve its title +
        // frame from the target pid exactly like the QuickEdit non-accessibility
        // trigger (capturing by app name alone grabbed the wrong window). AX reads
        // run on the main actor; OCR + caps selection are pushed off it.
        guard ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled,
              let appName = targetAppName else { return }
        let window = targetPid?.firstMainWindow
        let windowTitle = window?.title()
        let windowFrame = window?.getFrame()
        onScreenMiningTask = Task { [weak self] in
            do {
                let (observations, image) = try await WindowCaptureOCR().captureWindowAndExtractText(
                    from: appName, appTitle: windowTitle, windowFrame: windowFrame,
                    usesLanguageCorrection: false)
                let ocrText = observations.map(\.text).joined(separator: "\n")
                let result = await Task.detached(priority: .utility) {
                    CapsTermSelector.shared.selectCapsTermsTraced(ocrText)
                }.value
                // A slow OCR from session N must not land after session N+1
                // reset the staging - the glossary would carry terms from the
                // wrong window. The next session cancelled us at its start.
                guard !Task.isCancelled else { return }
                self?.onScreenMinedTerms = result.terms
                // Persistent term memory: the OCR pass just sighted these
                // terms on screen - evidence that used to be discarded.
                TermMemoryService.shared.recordScreenSightings(
                    terms: result.terms, viaAccessibility: false,
                    appBundle: self?.targetAppBundleId)
                #if DEBUG || ONIT_BETA
                let shot = TranscriptionHistoryManager.shared.saveScreenshot(
                    image, filename: "layerc_\(Int(Date().timeIntervalSince1970 * 1000)).png")
                TranscriptionHistoryManager.shared.pruneLayerCScreenshots(keepLatest: 20)
                ASRPromptContext.shared.recordOnScreenMining(
                    terms: result.terms, ocrText: ocrText, decisions: result.decisions,
                    screenshot: shot, hasCommonList: result.hasCommonList,
                    source: "OCR (window screenshot)")
                #endif
                log.info("[asr-prompt] Layer C mined \(result.terms.count) on-screen term(s)")
            } catch {
                log.debug("[asr-prompt] Layer C OCR mining failed: \(error.localizedDescription)")
            }
        }
    }


    /// Sentence-terminating punctuation expected at the end of preceding text when
    /// `deletePrecedingChars` is about to fire (mirror of `Capitalization.sentenceEnders`).
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
}

// MARK: - Startup Timing

struct StartupTimingSnapshot {
    let taskSchedulingMs: Double
    let startRecordingMs: Double
    let configureAudioEngineMs: Double
    let audioOutputUnitStartMs: Double
    let clipboardSnapshotMs: Double
}
