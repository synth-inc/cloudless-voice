// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintManager.swift
//  Onit
//
//  Created by Loyd Kim on 1/22/26.
//

/*
 * Singleton
 * Initialization
 * Configuration
 * Variables: Hint Window
 * Variables: More Menu Window
 * Variables: Transcription Window
 * Variables: Panels
 * Variables: Hover
 * Variables: Positioning
 * Variables: Detections
 * Variables: Subscriptions
 */

import Combine
import Defaults
import Foundation
import SwiftUI

enum HintMode {
    case tethered
    case pinned
    case untethered
}

enum HintPopUpMessageType: Equatable {
    case accessibilityLost
    /// Commented out for now until non-AX becomes the default state.
//        case screenRecordingLost
    case microphonePermissionLost
    case modelDownloading
    case modelsReady
    case transcriptionDemo
    case transcriptionSetup
    case transcriptionFailed
    case transcriptionSilent
    case transcriptionCancelled
    case transcriptionInputDeviceFailed
    case transcriptionInputDeviceUnplugged
    case transcriptionDetectedNewInputDevice
    case transcriptionCleanupLoading
    case transcriptionCleanupUnconfirmed
    /// The Rewrite stage (the user's own model) couldn't run; the text went in without it.
    case transcriptionRewriteFailed
    case updateAvailable
    case hover

    var autoDismissDuration: Duration? {
        switch self {
        case .transcriptionFailed,
                .transcriptionCancelled,
                .transcriptionInputDeviceFailed,
                .transcriptionInputDeviceUnplugged,
                .transcriptionCleanupLoading:
            return .seconds(4)
        case .transcriptionCleanupUnconfirmed:
            /// Two sentences to read, and it explains why cleanup stopped.
            return .seconds(8)
        case .transcriptionRewriteFailed:
            /// A reason to read, and what to check.
            return .seconds(6)
        default:
            return nil
        }
    }

    /// Dictation can't work until these clear, so they take over a presented paywall / success
    /// card; the pending card state is kept and the card comes back once they clear.
    var outranksDictationCard: Bool {
        switch self {
        case .accessibilityLost, .microphonePermissionLost, .modelDownloading:
            return true
        default:
            return false
        }
    }
}

/// Typed subset of `HintPopUpMessageType` for transcription session alerts.
/// Dedicated to providing type safety to transcription-related pop-up alerts.
enum TranscriptionAlertPopUpMessageType: Equatable {
    case failed
    case silent
    case cancelled
    case inputDeviceFailed
    case inputDeviceUnplugged
    case detectedNewInputDevice
    case cleanupModelLoading
    /// Smart Cleanup refused because the subscription couldn't be confirmed (offline).
    case cleanupUnconfirmed
    /// The Rewrite stage failed for `reason`; the text was inserted without it.
    case rewriteFailed(CleanupFailureNotice.Reason)

    var popUpMessageType: HintPopUpMessageType {
        switch self {
        case .failed: return .transcriptionFailed
        case .silent: return .transcriptionSilent
        case .cancelled: return .transcriptionCancelled
        case .inputDeviceFailed: return .transcriptionInputDeviceFailed
        case .inputDeviceUnplugged: return .transcriptionInputDeviceUnplugged
        case .detectedNewInputDevice: return .transcriptionDetectedNewInputDevice
        case .cleanupModelLoading: return .transcriptionCleanupLoading
        case .cleanupUnconfirmed: return .transcriptionCleanupUnconfirmed
        case .rewriteFailed: return .transcriptionRewriteFailed
        }
    }
}

@MainActor
final class HintManager: ObservableObject {
    // MARK: - Singleton

    static let shared = HintManager()
    
    // MARK: - Initialization

    private init() {
        class CustomPanel: NSPanel {
            override var canBecomeKey: Bool { false }
            override var canBecomeMain: Bool { false }
        }

        let window = CustomPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        self.hintWindow = window
    }

    // MARK: - Configuration

    func configure() {
        setupSubscriptions()
        startUpdateCheckSchedule()
    }

    /// Checks for an available update immediately on launch, then rechecks every 24 hours to catch updates released during long-running sessions.
    private func startUpdateCheckSchedule() {
        AppState.shared.checkForAvailableUpdate()

        let twentyFourHours: TimeInterval = 24 * 60 * 60
        
        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: twentyFourHours,
            repeats: true
        ) { _ in
            Task { @MainActor in
                AppState.shared.checkForAvailableUpdate()
            }
        }
    }
    
    // MARK: - Variables: Update Check

    private var updateCheckTimer: Timer? {
        willSet {
            updateCheckTimer?.invalidate()
        }
    }

    // MARK: - Variables: Hint Window
    
    private(set) var hintWindow: NSWindow
    
    var currentHintSize: CGSize = .zero
    
    var hintWindowIsVisible: Bool {
        return
            hintWindow.contentView != nil &&
            hintWindow.isVisible
    }
    
    // MARK: - Variables: Dictation Paywall

    /// Analytics mode of the pending Smart Cleanup paywall, so it can be re-shown when the hint
    /// moves to a new screen. Cleared when the user closes the upgrade dialog.
    var pendingCleanupPaywallMode: String? = nil

    /// Mode for the success dialog. Persists even if the upgrade dialog is closed, so the user
    /// sees the celebration UI whenever they subscribe.
    var pendingCleanupSuccessMode: String? = nil

    /// Set when a logged-out user taps "Upgrade": checkout resumes as soon as the account arrives.
    var pendingDictationCheckoutAfterLogin = false

    /// When checkout was last opened. A background poll runs for `checkoutPollWindow` after
    /// this so the webhook-created subscription is picked up even if the app is never
    /// re-activated (the Hint is non-activating, so a global-shortcut user may never switch back).
    var dictationCheckoutOpenedAt: Date? = nil
    let checkoutPollWindow: TimeInterval = 10 * 60
    var checkoutPollTask: Task<Void, Never>? = nil

    /// Bumped on logout; delayed paywall/success work captured under an older generation is
    /// dropped so one account's text never shows for the next.
    var dictationPaywallGeneration = 0

    /// True while the post-purchase success card is up; forces the Hint visible so a hidden or
    /// snoozed Hint still shows the card (and the Copy button for the blocked text).
    var isShowingDictationSuccessCard = false

    /// True while the paywall or success card occupies the shared more-menu window.
    /// See `showMoreMenu(swiftUIView:isDictationCard:)`. Published so the Hint re-shows the
    /// active pop-up the card was covering once it goes away.
    @Published var dictationCardIsPresented = false

    /// Whether `paywallShown` was already logged for the current block (re-presenting after a
    /// screen move or menu close must not count as a new impression).
    var dictationPaywallShownLogged = false

    // MARK: - Variables: More Menu Window
    
    var moreMenuWindow: NSWindow?
    
    var moreMenuWindowIsVisible: Bool {
        guard let moreMenuWindow = self.moreMenuWindow
        else {
            return false
        }
        
        return
            moreMenuWindow.contentView != nil &&
            moreMenuWindow.isVisible
    }
    
    @Published var activePopUpType: HintPopUpMessageType? = nil
    @Published var activeTranscriptionAlert: TranscriptionAlertPopUpMessageType? = nil

    var popUpAutoDismissTask: Task<Void, Never>? = nil
    var sessionDismissedPopUps: Set<HintPopUpMessageType> = []

    // MARK: - Variables: Snooze

    /// Clears `Defaults[.hintSnoozedUntil]` when the snooze elapses. See `rearmSnoozeExpiry()`.
    var snoozeExpiryTask: Task<Void, Never>? = nil

    // MARK: - Variables: Model Download

    /// Live download progress (0.0–1.0) for whichever onboarding model is currently downloading
    /// (dictation or the Smart Cleanup stack), mirrored from the active source by
    /// `modelDownloadProgressTimer` so SwiftUI can observe it. Drives the Hint pill's "X% ⟳" state.
    /// See [[HintManager+Download]] and [[ModelDownloadIndicator]].
    @Published var modelDownloadProgress: Double = 0

    /// The active model/phase label ("Downloading local dictation model…", "Loading Smart Cleanup
    /// model…", etc.), mirrored each poll tick. The persistent download toast re-renders off this so
    /// its text tracks the current model + phase instead of freezing on the value shown when it first
    /// appeared. Empty when nothing is preparing.
    @Published var modelDownloadLabel: String = ""

    /// Polls the active model's progress while any required model is downloading.
    var modelDownloadProgressTimer: Timer? {
        willSet {
            modelDownloadProgressTimer?.invalidate()
        }
    }

    /// True while a determinate download has stopped advancing for `downloadStallThreshold`
    /// seconds - the connection dropped mid-file and a Range-resume retry is imminent. The pill
    /// swaps its frozen "X% ⟳" for an indeterminate spinner so a stalled transfer never looks
    /// like a dead progress bar parked at 4%. See [[HintManager+Download]].
    @Published var modelDownloadStalled = false

    /// Stall bookkeeping for the poll tick: the last progress value seen and when it last moved.
    static let downloadStallThreshold: TimeInterval = 6
    var lastDownloadProgressValue: Double = -1
    var lastDownloadProgressAdvance = Date()
    
    var shouldShowAccessibilityLostPopUpMessage: Bool {
        return
            Defaults[.showHintAccessibilityAlert] &&
            !OnboardingWindowManager.shared.onboardingWindowIsVisible &&
            AccessibilityPermissionManager.shared.accessibilityPermissionStatus == .denied
    }

    /// Commented out for now until non-AX becomes the default state.
//    var shouldShowScreenRecordingLostPopUpMessage: Bool {
//        return
//            Defaults[.showHintScreenRecordingAlert] &&
//            !OnboardingWindowManager.shared.onboardingWindowIsVisible &&
//            Defaults[.quickEditConfig].isEnabled &&
//            !ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
//    }

    var shouldShowMicrophonePermissionLostPopUpMessage: Bool {
        return
            Defaults[.showHintMicrophonePermissionAlert] &&
            !OnboardingWindowManager.shared.onboardingWindowIsVisible &&
            Defaults[.transcriptionEnabled] &&
            !MicrophoneInputManager.shared.hasPermission
    }

    var shouldShowTranscriptionDemoPopUpMessage: Bool {
        return
            OnboardingWindowManager.shared.onboardingWindowIsVisible &&
            (Defaults[.currentOnboardingStep] == .transcriptionDemo ||
             OnboardingWindowManager.shared.demoOnly)
    }

    /// The post-onboarding "Cloudless is ready!" nudge - shown once the full Smart Cleanup stack is warmed,
    /// the demo hasn't been done, and onboarding's closed. One-shot: acknowledged on dismiss.
    var shouldShowModelsReadyPopUpMessage: Bool {
        return
            !Defaults[.appHomeReadyToastShown] &&
            Defaults[.mainOnboardingCompleted] &&
            !Defaults[.dictationDemoCompleted] &&
            !OnboardingWindowManager.shared.onboardingWindowIsVisible &&
            ModelDownloadIndicator.demoModelsReady
    }

    var shouldShowTranscriptionSetupPopUpMessage: Bool {
        return
            !sessionDismissedPopUps.contains(.transcriptionSetup) &&
            Defaults[.transcriptionEnabled] &&
            !Defaults[.transcriptionSpecificStepsCompleted] &&
            (!OnboardingWindowManager.shared.onboardingWindowIsVisible || Defaults[.mainOnboardingCompleted])
    }

    var shouldShowUpdateAvailablePopUpMessage: Bool {
        guard let availableVersion = AppState.shared.availableUpdateVersion else { return false }
        return
            Defaults[.showHintUpdateAvailableAlert] &&
            Defaults[.dismissedUpdateAlertVersion] != availableVersion &&
            AppState.shared.isUpdateAvailable
    }
    
    var isTranscriptionActive: Bool {
        return
            TranscriptionManager.shared.isTranscribing ||
            TranscriptionManager.shared.state.isProcessing
    }
    
    // MARK: - Variables: Transcription Window

    var transcriptionOverlayWindow: ToggleableKeyPanel?

    var transcriptionOverlayHostingController: NSHostingController<TranscriptionOverlayView>?

    /// Global key monitor active only while the transcription overlay is visible.
    /// Whether the user has manually dragged the overlay (disables auto-repositioning).
    var userHasManuallyPositionedOverlay: Bool = false

    /// Guard flag to distinguish programmatic moves from user drags.
    /// When true, window move notifications are ignored to prevent falsely setting `userHasManuallyPositionedOverlay` when initially summoning the overlay.
    var isProgrammaticallyPositioningOverlay: Bool = false

    /// Whether the overlay is anchored to the caret position (vs. hint-relative).
    /// When true, hint movement does not trigger overlay repositioning.
    var isCaretAnchoredOverlay: Bool = false

    /// Mouse position captured when entering Force Correction UI mode.
    /// When set, the overlay is positioned so the primary footer button lands under the mouse
    /// so the user can insert without moving their cursor.
    var forceCorrectionUIMouseAnchor: CGPoint? = nil

    var transcriptionOverlayWindowIsVisible: Bool {
        guard let transcriptionOverlayWindow = self.transcriptionOverlayWindow
        else {
            return false
        }
        
        return
            transcriptionOverlayWindow.contentView != nil &&
            transcriptionOverlayWindow.isVisible
    }

    /// Used to disable the Hint's undo-last-transcription button when the undo is already in-flight.
    @Published var isUndoingLastTranscription: Bool = false

    // MARK: - Variables: Show

    /// Timer for debouncing show operations.
    var showDebounceTimer: Timer? {
        willSet {
            showDebounceTimer?.invalidate()
        }
    }
    
    /// Debounce delay for showing the hint.
    let showDebounceDelay: TimeInterval = 0.1
    
    // MARK: - Variables: Hover
    
    /// Handling hint hovering on the AppKit window level, rather than the SwiftUI view level, to prevent layout change timing mismatches which cause flickering and multi-monitor bleeding.
    @Published var isHintHovered: Bool = false

    var localMouseEventMonitorForHoverTracking: Any?
    var globalMouseEventMonitorForHoverTracking: Any?

    /// Timer to debounce hover exit to prevent flicker during layout transitions.
    var hoverExitDebounceTimer: Timer? {
        willSet {
            hoverExitDebounceTimer?.invalidate()
        }
    }

    /// Debounce delay for hover exit (prevents flicker during layout changes).
    let hoverExitDebounceDelay: TimeInterval = 0.1

    // MARK: - Variables: Positioning
    
    /// Y-position for hint window drag.
    var lastYComputed: CGFloat? = nil
    
    // MARK: - Variables: Detections
    
    /// Current screen the hint is displayed on. Used to maintain proper monitor reference when repositioning. Helps with multi-monitor setups.
    var currentScreen: NSScreen? = nil

    /// Screen the hint sat on before immersive mode hid it. `hideHint()` clears `currentScreen`,
    /// so without this the hint would come back on whichever screen the cursor happens to be on,
    /// which during fullscreen playback is usually the screen showing the video.
    var screenBeforeImmersive: NSScreen? = nil
    
    /// Guard flag to prevent infinite constraint update loops when underlying hint SwiftUI view's size updates.
    var isHandlingFrameChange = false

    /// True while the user is actively dragging the hint, so automatic re-positioning/re-sizing is suspended.
    var isDraggingHint = false
    /// Mouse / window Y captured at drag start, used to follow the cursor 1:1 while dragging.
    var hintDragStartMouseY: CGFloat?
    var hintDragStartWindowY: CGFloat?

    // MARK: - Variables: Subscriptions
    
    var cancellables = Set<AnyCancellable>()
}
