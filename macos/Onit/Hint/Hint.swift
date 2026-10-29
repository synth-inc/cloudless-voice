// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Hint.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Environments
 * Defaults
 * Properties
 * Observations
 * States
 * Private Variables
 * Private Variables: Transcription
 * Body
 * Functions (only used within Hint & Hint extensions)
 */

import Defaults
import Foundation
import KeyboardShortcuts
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

struct Hint: View {
    // MARK: - Environments

    @Environment(\.appState) var appState

    // MARK: - Defaults

    @Default(.tetheredButtonHiddenApps) var tetheredButtonHiddenApps
    @Default(.tetheredButtonShowAppIcons) var tetheredButtonShowAppIcons
    @Default(.transcriptionEnabled) var transcriptionEnabled
    @Default(.alwaysHideHint) var alwaysHideHint
    @Default(.hintSnoozedUntil) var hintSnoozedUntil
    @Default(.transcriptionInputDevice) var transcriptionInputDevice
    @Default(.mainOnboardingCompleted) var mainOnboardingCompleted
    @Default(.currentOnboardingStep) var currentOnboardingStep
    @Default(.transcriptionSpecificStepsCompleted) var transcriptionSpecificStepsCompleted
    @Default(TranscriptionConfigKeys.shortcutType) var transcriptionShortcutType
    @Default(.transcriptionAutoSwitchMicrophone) var autoSwitchMicrophone
    
    @Default(.showHintTranscriptionFailedAlert) var showHintTranscriptionFailedAlert
    @Default(.showHintTranscriptionSilentAlert) var showHintTranscriptionSilentAlert
    @Default(.showHintTranscriptionCancelledAlert) var showHintTranscriptionCancelledAlert
    @Default(.showHintTranscriptionInputDeviceFailedAlert) var showHintTranscriptionInputDeviceFailedAlert
    @Default(.showHintTranscriptionInputDeviceUnpluggedAlert) var showHintTranscriptionInputDeviceUnpluggedAlert
    @Default(.showHintTranscriptionDetectedNewInputDeviceAlert) var showHintTranscriptionDetectedNewInputDeviceAlert

    // MARK: - Properties

    var onDragChanged: () -> Void
    var onDragEnded: () -> Void

    // MARK: - Observations

    @ObservedObject var hintManager = HintManager.shared
    @ObservedObject var transcriptionManager = TranscriptionManager.shared
    @ObservedObject var transcriptionState = TranscriptionManager.shared.state
    @ObservedObject var microphoneInputManager = MicrophoneInputManager.shared
    @ObservedObject var onboardingWindowManager = OnboardingWindowManager.shared
    @ObservedObject var lastTranscriptionState = LastTranscriptionState.shared

    @ObservedObject var accessibilityPermissionManager = AccessibilityPermissionManager.shared
    /// Commented out for now until non-AX becomes the default state.
//    @ObservedObject private var screenRecordingPermissionManager = ScreenRecordingPermissionManager.shared
    
    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States
    
    @State var shouldShowMoreMenu: Bool = false
    @State var isDragging: Bool = false
    @State private var dragStartTime: Date? = nil
    @State var clickOutsideLocalMonitor: Any? = nil
    @State var clickOutsideGlobalMonitor: Any? = nil
    @State var hoveredFeatureButton: HoveredFeatureButton? = nil

    // MARK: - Private Variables
    
    private var shouldExpandHint: Bool {
        let transcriptionActive =
            transcriptionIsRecording ||
            transcriptionIsProcessing

        let isHovered = hintManager.isHintHovered

        return
            transcriptionActive ||
            shouldShowMoreMenu ||
            isHovered
    }
    
    // MARK: - Private Variables: Transcription
    
    var transcriptionWarmedUp: Bool {
        return transcriptionManager.isInitialized
    }

    var transcriptionIsRecording: Bool {
        return transcriptionManager.isTranscribing
    }

    var transcriptionIsProcessing: Bool {
        return transcriptionState.isProcessing
    }
    
    var isTranscriptionActive: Bool {
        return
            transcriptionIsRecording ||
            transcriptionIsProcessing
    }
    
    var transcriptionSetupIncomplete: Bool {
        return
            !transcriptionSpecificStepsCompleted &&
            !onboardingWindowManager.onboardingWindowIsVisible
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: Self.outerHStackSpacing) {
            if shouldExpandHint {
                moreMenuButton

                HStack(alignment: .center, spacing: Self.innerHStackSpacing) {
                    editLastTranscriptButton
                    transcriptionButton
                    updateButton
                }
            } else if hintManager.isAnyModelPreparing {
                downloadProgressPill
            } else {
                logoButton
            }
        }
        .padding(Self.hintPadding)
        .background(
            ZStack {
                Backgrounds.BrushedGlass()
                Color.S_10.opacity(0.6)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 999,
                    bottomLeadingRadius: 999,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 999,
                bottomLeadingRadius: 999,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .strokeBorder(Color.T_5, lineWidth: 1)
            .mask(
                HStack(spacing: 0) {
                    Color.black
                    Color.clear.frame(width: 1)
                }
            )
        )
        .fixedSize()
        .simultaneousGesture(
            DragGesture()
                .onChanged { _ in
                    if dragStartTime == nil {
                        dragStartTime = Date()
                    }

                    if let startTime = dragStartTime,
                       Date().timeIntervalSince(startTime) > 0.1
                    {
                        if !isDragging {
                            isDragging = true
                        }
                        onDragChanged()
                    }
                }
                .onEnded { _ in
                    dragStartTime = nil
                    onDragEnded()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isDragging = false
                    }
                }
        )
        .onAppear {
            /// Show initial pop-up if needed.
            if let activePopUpMessageType = self.activePopUpMessageType,
                !shouldShowMoreMenu
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showPopUpMessage(type: activePopUpMessageType)
                }
            }
        }
        .onDisappear {
            removeClickOutsideMonitor()
            hintManager.hideMoreMenu()
        }
        .onChange(of: activePopUpMessageType) { oldPopUpMessageType, newPopUpMessageType in
            /// A pop-up that took over the dictation card cleared: bring the card back.
            if oldPopUpMessageType?.outranksDictationCard == true,
               newPopUpMessageType?.outranksDictationCard != true
            {
                hintManager.reshowPendingDictationPaywallIfNeeded()
            }

            if let popUpMessageType = newPopUpMessageType {
                /// Show pop-up when we're not showing the more menu so that they don't clash.
                if !shouldShowMoreMenu {
                    /// Defer to the next run loop cycle so that we can measure accurate more menu dimensions.
                    /// This in turn allows us to more accurately position the pop-up messages.
                    DispatchQueue.main.async {
                        showPopUpMessage(type: popUpMessageType)
                    }
                }
            } else {
                /// Hide pop-up if there is no active pop-up message to show.
                if !shouldShowMoreMenu {
                    hintManager.hideMoreMenu()
                }
            }
        }
        .onChange(of: hintManager.dictationCardIsPresented) { _, isPresented in
            /// The dictation card covered any pop-up raised meanwhile: show it now.
            if !isPresented,
               !hintManager.moreMenuWindowIsVisible,
               !shouldShowMoreMenu,
               let popUpMessageType = activePopUpMessageType
            {
                DispatchQueue.main.async {
                    showPopUpMessage(type: popUpMessageType)
                }
            }
        }
        .onChange(of: hoveredFeatureButton) { _, currentHoveredFeatureButton in
            let shouldShowHoverPopUpMessage =
                currentHoveredFeatureButton != nil &&
                activePopUpMessageType == .hover &&
                !shouldShowMoreMenu
            
            if shouldShowHoverPopUpMessage {
                showPopUpMessage(type: .hover)
            }
        }
        .onChange(of: transcriptionShortcutType) { _, _ in
            if let popUpMessageType = activePopUpMessageType,
               (popUpMessageType == .transcriptionDemo || popUpMessageType == .hover)
            {
                showPopUpMessage(type: popUpMessageType)
            }
        }
        .onChange(of: hintManager.modelDownloadLabel) { _, _ in
            /// Keep the persistent download toast's text in sync with the current model/phase.
            /// Re-showing also re-measures + repositions it for the new label's width.
            if activePopUpMessageType == .modelDownloading && !shouldShowMoreMenu {
                showPopUpMessage(type: .modelDownloading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            /// Refresh the pop-up if transcription custom shortcut was changed via KeyboardShortcuts.Recorder.
            if let popUpMessageType = activePopUpMessageType,
               (popUpMessageType == .transcriptionDemo || popUpMessageType == .hover),
               transcriptionShortcutType == .custom
            {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    showPopUpMessage(type: popUpMessageType)
                }
            }
        }
        .id(localization.currentLanguage)
    }
    
    // MARK: - Functions (only used within Hint & Hint extensions)

    func openTranscriptionOnboarding() {
        OnboardingWindowManager.shared.showWindow(startingAt: .transcriptionSetup)
    }

}
