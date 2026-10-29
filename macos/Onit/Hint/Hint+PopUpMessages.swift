// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Hint+PopUpMessages.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Variables: Active Pop-Up Message Type
 * Private Variables
 * Public Functions
 * Child Components
 * Simple Pop-Up Message View
 * Callback Pop-Up Message View
 * Input Device Selection Dropdown
 * Don't Show Toggle Button
 * Auto-Dismiss Timer Bar
 */

import Defaults
import KeyboardShortcuts
import SwiftUI

extension Hint {
    // MARK: - Variables: Active Pop-Up Message Type
    
    var activePopUpMessageType: HintPopUpMessageType? {
        if let activePopUpType = hintManager.activePopUpType {
            return activePopUpType
        } else if shouldShowTranscriptionOnHoverPopUpMessage {
            return .hover
        } else {
            return nil
        }
    }
    
    // MARK: - Private Variables
    
    private var currentFeatureButtonHoverText: (
        title: String,
        caption: String?
    )? {
        guard let hoveredFeatureButton = self.hoveredFeatureButton
        else {
            return nil
        }

        switch hoveredFeatureButton {
        case .transcription:
            if !transcriptionWarmedUp {
                return (String.localized("Warming up...", table: "MenuBar"), nil)
            } else if accessibilityPermissionLost && !onboardingWindowManager.onboardingWindowIsVisible {
                return (String.localized("Accessibility access required", table: "MenuBar"), nil)
            } else if microphonePermissionLost {
                return (String.localized("Microphone access required", table: "MenuBar"), nil)
            } else if transcriptionSetupIncomplete {
                return (String.localized("Complete Dictation Onboarding", table: "MenuBar"), nil)
            } else {
                return (String.localized("Start Dictating", table: "MenuBar"), transcriptionShortcutType.displayNameSymbol)
            }
        case .editTranscript:
            return (String.localized("Edit Last Transcript", table: "MenuBar"), nil)
        case .update:
            return (String.localized("Install New Update", table: "MenuBar"), nil)
        }
    }
    
    private var transcriptionShortcutText: String {
        // If the user just triggered dictation via an alternate slot, surface that shortcut
        // in the hint - e.g., laptop user sees "F12" while docked user sees "F19".
        if let alternateText = TranscriptionShortcutType.mostRecentlyUsedAlternateText {
            return alternateText
        }
        switch transcriptionShortcutType {
        case .capsLock:
            return "⇪ (Caps Lock)"
        case .rightCommand:
            return "Right ⌘ (Right Command)"
        case .commandDoubleTap:
            return "⌘⌘ (Command double-tap)"
        case .controlDoubleTap:
            return "⌃⌃ (Control double-tap)"
        case .fn:
            return "fn (function)"
        case .custom:
            return TranscriptionShortcutType.customShortcutNames[0].shortcutText
        }
    }
    
    private var shouldShowTranscriptionOnHoverPopUpMessage: Bool {
        return hoveredFeatureButton != nil && !shouldShowMoreMenu
    }
    
    // MARK: - Public Functions
    
    func showPopUpMessage(type: HintPopUpMessageType) {
        if type.outranksDictationCard && hintManager.dictationCardIsPresented {
            hintManager.hideMoreMenu(force: true)
        }

        switch type {
        case .accessibilityLost:
            hintManager.showMoreMenu(swiftUIView: accessibilityLostPopUpMessageView)
        /// Commented out for now until non-AX becomes the default state.
//        case .screenRecordingLost:
//            hintManager.showMoreMenu(swiftUIView: screenRecordingLostPopUpMessageView)
        case .microphonePermissionLost:
            hintManager.showMoreMenu(swiftUIView: microphonePermissionLostPopUpMessageView)
        case .modelDownloading:
            hintManager.showMoreMenu(swiftUIView: modelDownloadingPopUpMessageView)
        case .modelsReady:
            hintManager.showMoreMenu(swiftUIView: modelsReadyPopUpMessageView)
        case .transcriptionDemo:
            hintManager.showMoreMenu(swiftUIView: transcriptionDemoPopUpMessageView)
        case .transcriptionSetup:
            hintManager.showMoreMenu(swiftUIView: transcriptionSetupPopUpMessageView)
        case .transcriptionFailed:
            hintManager.showMoreMenu(swiftUIView: transcriptionFailedPopUpMessageView)
        case .transcriptionSilent:
            hintManager.showMoreMenu(swiftUIView: transcriptionSilentPopUpMessageView)
        case .transcriptionCancelled:
            hintManager.showMoreMenu(swiftUIView: transcriptionCancelledPopUpMessageView)
        case .transcriptionInputDeviceFailed:
            hintManager.showMoreMenu(swiftUIView: transcriptionInputDeviceFailedPopUpMessageView)
        case .transcriptionInputDeviceUnplugged:
            hintManager.showMoreMenu(swiftUIView: transcriptionInputDeviceUnpluggedPopUpMessageView)
        case .transcriptionDetectedNewInputDevice:
            hintManager.showMoreMenu(swiftUIView: transcriptionDetectedNewInputDevicePopUpMessageView)
        case .transcriptionCleanupLoading:
            hintManager.showMoreMenu(swiftUIView: transcriptionCleanupLoadingPopUpMessageView)
        case .transcriptionCleanupUnconfirmed:
            hintManager.showMoreMenu(swiftUIView: transcriptionCleanupUnconfirmedPopUpMessageView)
        case .transcriptionRewriteFailed:
            hintManager.showMoreMenu(swiftUIView: transcriptionRewriteFailedPopUpMessageView)
        case .updateAvailable:
            hintManager.showMoreMenu(swiftUIView: updateAvailablePopUpMessageView)
        case .hover:
            hintManager.showMoreMenu(swiftUIView: onHoverPopUpMessageView)
        }
    }
    
    // MARK: - Child Components
    
    private var accessibilityLostPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Accessibility access required", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.accessibilityLost.autoDismissDuration,
            callback: .init(
                text: String.localized("Grant Access", table: "MenuBar"),
                action: {
                    accessibilityPermissionManager.requestPermission()
                }
            )
        )
    }

    /// Commented out for now until non-AX becomes the default state.
//    private var screenRecordingLostPopUpMessageView: some View {
//        CallbackPopUpMessageView(
//            text: String.localized("Screen recording access required"),
//            systemIcon: .init(name: "exclamationmark.circle"),
//            autoDismissDuration: HintPopUpMessageType.screenRecordingLost.autoDismissDuration,
//            callback: .init(
//                text: String.localized("Grant Access", table: "MenuBar"),
//                action: {
//                    Task {
//                        _ = await self.screenRecordingPermissionManager.requestScreenRecordingPermission()
//                    }
//                }
//            )
//        )
//    }

    private var microphonePermissionLostPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Enable Microphone to Voice Dictate", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.microphonePermissionLost.autoDismissDuration,
            callback: .init(
                text: String.localized("Open System Settings", table: "MenuBar"),
                action: {
                    Task {
                        await microphoneInputManager.requestPermissionOrOpenSettings()
                    }
                }
            )
        )
    }

    private var modelDownloadingPopUpMessageView: some View {
        /// Reactive, phase-accurate label - "Downloading/Loading local dictation model…" vs
        /// "…Smart Cleanup model…" depending on what's preparing right now. Falls back to dictation
        /// copy if preparation just cleared.
        let label = ModelDownloadIndicator.current?.label
            ?? String.localized("Downloading local dictation model…", table: "MenuBar")

        /// Sized to content (`fixedSize`) rather than capped at the shared 256pt width, so the full
        /// label always fits on one line instead of truncating. Both lines share one treatment.
        return VStack(alignment: .center, spacing: 2) {
            Text(label)
                .styleText(
                    size: 14,
                    weight: .regular,
                    align: .center
                )

            Text(String.localized("(Don't quit the app)", table: "MenuBar"))
                .styleText(
                    size: 14,
                    weight: .regular,
                    align: .center
                )
        }
        .fixedSize()
        .padding(12)
        .background(Color.smoke)
        .addBorder(
            cornerRadius: 16,
            stroke: Color.T_4
        )
    }

    /// Post-onboarding "Cloudless is ready!" nudge - the Hint-pop-up replacement for the old notification
    /// toast. Persists (no auto-dismiss) until the user taps "Try Cloudless" or closes it; both acknowledge
    /// it so it doesn't reappear.
    private var modelsReadyPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Cloudless is ready!", table: "MenuBar"),
            subtext: String.localized("Your models are downloaded and the engine\nis warmed up, let's go!", table: "MenuBar"),
            systemIcon: .init(
                name: "checkmark.circle",
                color: Color.lime400
            ),
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            // Primary (blue) "Try Cloudless" - distinct from the default dark callback button style.
            TextButton(
                type: .primary,
                text: String.localized("Try Cloudless", table: "MenuBar")
            ) {
                hintManager.dismissPopUp()
                // Through the launcher so the demo's prerequisites are switched on (and restored
                // afterwards) on this entry point too - backtracking is off by default here, and its
                // demo step has nothing to show without it.
                DictationDemoLauncher.shared.launch()
            }
        }
    }

    private var transcriptionDemoPopUpMessageView: some View {
        SimplePopUpMessageView {
            VStack(alignment: .leading, spacing: 6) {
                Text(String.localized("Click handle or hold ", table: "MenuBar"))
                    .frame(maxWidth: .infinity)
                    .styleText(
                        size: 14,
                        weight: .regular,
                        align: .center
                    )
                
                Text(transcriptionShortcutText)
                    .styleText(
                        size: 14
                    )
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .addBorder(
                        cornerRadius: 6,
                        stroke: Color.T_3,
                        dotted: true
                    )
                
                Text(String.localized("to start voice dictating!", table: "MenuBar"))
                    .frame(maxWidth: .infinity)
                    .styleText(
                        size: 14,
                        weight: .regular,
                        align: .center
                    )
            }
        }
    }

    private var transcriptionSetupPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Complete setup to start dictating", table: "MenuBar"),
            systemIcon: .init(
                name: "exclamationmark.circle"
            ),
            autoDismissDuration: HintPopUpMessageType.transcriptionSetup.autoDismissDuration,
            callback: .init(
                text: String.localized("Complete setup", table: "MenuBar"),
                action: {
                    hintManager.dismissPopUp()
                    openTranscriptionOnboarding()
                }
            )
        ) {
            hintManager.dismissPopUp()
        }
    }
    
    private var transcriptionFailedPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Something Went Wrong", table: "MenuBar"),
            subtext: String.localized("An internal problem occurred.", table: "MenuBar") + "\n" + String.localized("Try again, or come back in a moment.", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.transcriptionFailed.autoDismissDuration,
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            DontShowToggleButton(defaultsKey: .showHintTranscriptionFailedAlert)
        }
    }
    
    private var transcriptionCleanupLoadingPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Smart Cleanup loading...", table: "MenuBar"),
            subtext: String.localized("Text inserted as spoken.", table: "MenuBar"),
            systemIcon: .init(name: "hourglass"),
            autoDismissDuration: HintPopUpMessageType.transcriptionCleanupLoading.autoDismissDuration
        ) {
            hintManager.dismissPopUp()
        }
    }

    private var transcriptionCleanupUnconfirmedPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: SmartCleanupUnconfirmedCopy.title,
            subtext: SmartCleanupUnconfirmedCopy.afterDictation,
            systemIcon: .init(name: "wifi.exclamationmark"),
            autoDismissDuration: HintPopUpMessageType.transcriptionCleanupUnconfirmed.autoDismissDuration
        ) {
            hintManager.dismissPopUp()
        }
    }

    /// Same shape as the cleanup alerts above: what happened, then what was inserted.
    /// The reason comes from the alert itself (`TranscriptionAlertPopUpMessageType`).
    private var transcriptionRewriteFailedPopUpMessageView: some View {
        let reason: CleanupFailureNotice.Reason = if case .rewriteFailed(let reason) = hintManager.activeTranscriptionAlert {
            reason
        } else {
            .other
        }
        return CallbackPopUpMessageView(
            text: String.localized("Rewrite skipped", table: "MenuBar"),
            subtext: reason.message + "\n" + String.localized("Text inserted without the rewrite.", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.transcriptionRewriteFailed.autoDismissDuration
        ) {
            hintManager.dismissPopUp()
        }
    }

    private var transcriptionSilentPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Silent Recording", table: "MenuBar"),
            subtext: String.localized("No speech was recognized.", table: "MenuBar"),
            systemIcon: .init(
                name: "exclamationmark.circle",
                color: Color.orange500
            ),
            autoDismissDuration: HintPopUpMessageType.transcriptionSilent.autoDismissDuration,
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            InputDeviceSelectionDropdown()
            DontShowToggleButton(defaultsKey: .showHintTranscriptionSilentAlert)
        }
    }

    private var transcriptionCancelledPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Dictation dismissed.", table: "MenuBar"),
            systemIcon: .init(name: "checkmark.circle", color: Color.lime400),
            autoDismissDuration: HintPopUpMessageType.transcriptionCancelled.autoDismissDuration,
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            DontShowToggleButton(defaultsKey: .showHintTranscriptionCancelledAlert)
        }
    }
    
    private var transcriptionInputDeviceFailedPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Recording failed.", table: "MenuBar"),
            subtext: String.localized("There was an issue setting up your microphone.\nPlease try again.", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.transcriptionInputDeviceFailed.autoDismissDuration,
            callback: .init(
                text: String.localized("Check microphones", table: "MenuBar"),
                action: {
                    AppWindowManager.shared.showWindow(settingsPage: .transcriptionBehavior)
                }
            ),
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            DontShowToggleButton(defaultsKey: .showHintTranscriptionInputDeviceFailedAlert)
        }
    }
    
    private var transcriptionInputDeviceUnpluggedPopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("Microphone disconnected.", table: "MenuBar"),
            subtext: String.localized("Dictation cancelled.", table: "MenuBar"),
            systemIcon: .init(name: "exclamationmark.circle"),
            autoDismissDuration: HintPopUpMessageType.transcriptionInputDeviceUnplugged.autoDismissDuration,
            callback: .init(
                text: String.localized("Check microphones", table: "MenuBar"),
                action: {
                    AppWindowManager.shared.showWindow(settingsPage: .transcriptionBehavior)
                }
            ),
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            DontShowToggleButton(defaultsKey: .showHintTranscriptionInputDeviceUnpluggedAlert)
        }
    }
    
    private var transcriptionDetectedNewInputDevicePopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: autoSwitchMicrophone
                ? String.localized("Microphone changed 🎙️", table: "MenuBar")
                : String.localized("New microphone detected.", table: "MenuBar"),
            subtext: autoSwitchMicrophone
                ? String.localized("A new microphone is used for dictation.", table: "MenuBar")
                : nil,
            systemIcon: autoSwitchMicrophone
                ? nil
                : .init(name: "checkmark.circle", color: Color.lime400),
            autoDismissDuration: HintPopUpMessageType.transcriptionDetectedNewInputDevice.autoDismissDuration,
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            InputDeviceSelectionDropdown()
            DontShowToggleButton(defaultsKey: .showHintTranscriptionDetectedNewInputDeviceAlert)
        }
    }

    private var updateAvailablePopUpMessageView: some View {
        CallbackPopUpMessageView(
            text: String.localized("A new update is available", table: "MenuBar"),
            systemIcon: .init(
                name: "arrow.down.circle",
                color: Color.lime400
            ),
            autoDismissDuration: HintPopUpMessageType.updateAvailable.autoDismissDuration,
            callback: .init(
                text: String.localized("Install Update", table: "MenuBar"),
                action: {
                    installUpdate()
                }
            ),
            closeAction: {
                hintManager.dismissPopUp()
            }
        ) {
            DontShowToggleButton(defaultsKey: .showHintUpdateAvailableAlert)
        }
    }

    @ViewBuilder
    private var onHoverPopUpMessageView: some View {
        if let hoverText = currentFeatureButtonHoverText {
            SimplePopUpMessageView {
                HStack(alignment: .center, spacing: 4) {
                    Text(hoverText.title)
                        .styleText(
                            size: 13,
                            weight: .regular
                        )
                    if let caption = hoverText.caption {
                        Text(caption)
                            .styleText(
                                size: 13,
                                weight: .regular,
                                color: Color.S_0.opacity(0.7)
                            )
                    }
                }
            }
        }
    }
    
    // MARK: - Simple Pop-Up Message View
    
    private struct SimplePopUpMessageView<Children: View>: View {
        let children: () -> Children
        
        var body: some View {
            children()
                .padding(12)
                .frame(maxWidth: 256)
                .background(Color.smoke)
                .addBorder(
                    cornerRadius: 16,
                    stroke: Color.T_4
                )
        }
    }
    
    // MARK: - Callback Pop-Up Message View

    private struct CallbackPopUpMessageView<Children: View>: View {
        struct SystemIcon {
            let name: String
            var color: Color = Color.red500
        }
        struct Callback {
            let text: String
            let action: () -> Void
        }

        private let text: String
        private let subtext: String?
        private let systemIcon: SystemIcon?
        private let autoDismissDuration: Duration?
        private let callback: Callback?
        private let closeAction: (() -> Void)?
        @ViewBuilder private let children: () -> Children

        init(
            text: String,
            subtext: String? = nil,
            systemIcon: SystemIcon? = nil,
            autoDismissDuration: Duration? = nil,
            callback: Callback? = nil,
            closeAction: (() -> Void)? = nil,
            @ViewBuilder children: @escaping () -> Children = { EmptyView() }
        ) {
            self.text = text
            self.subtext = subtext
            self.systemIcon = systemIcon
            self.autoDismissDuration = autoDismissDuration
            self.callback = callback
            self.closeAction = closeAction
            self.children = children
        }

        @State private var isHoveredCloseButton: Bool = false
        
        var body: some View {
            VStack(alignment: .center, spacing: 10) {
                if let systemIcon = self.systemIcon {
                    Image(systemName: systemIcon.name)
                        .font(.system(
                            size: 16,
                            weight: .medium
                        ))
                        .foregroundColor(systemIcon.color)
                }
                
                VStack(alignment: .center, spacing: 4) {
                    Text(text)
                        .styleText(
                            size: 15,
                            weight: .regular,
                            align: .center
                        )
                    
                    if let subtext = self.subtext {
                        Text(subtext)
                            .styleText(
                                size: 13,
                                weight: .regular,
                                color: Color.T_1,
                                align: .center
                            )
                    }
                }

                if let callback = self.callback {
                    TextButton(
                        text: callback.text,
                        colorConfig: .init(
                            text: Color.S_10,
                            background: Color.S_0
                        )
                    ) {
                        callback.action()
                    }
                }

                children()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 28)
            .background(Color.S_10.opacity(0.65))
            .background(Backgrounds.BrushedGlass())
            .overlay(alignment: .bottom) {
                if let autoDismissDuration = self.autoDismissDuration {
                    AutoDismissTimerBar(duration: autoDismissDuration)
                }
            }
            .addBorder(
                cornerRadius: 16,
                stroke: Color.T_4
            )
            .fixedSize()
            .overlay(alignment: .topTrailing) {
                closeButton
            }
        }
        
        @ViewBuilder
        private var closeButton: some View {
            if let closeAction = self.closeAction {
                Button {
                    closeAction()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(
                            size: 13,
                            weight: .medium
                        ))
                        .foregroundColor(isHoveredCloseButton ? Color.S_0 : Color.T_3)
                        .frame(
                            width: 20,
                            height: 20,
                            alignment: .center
                        )
                        .clipShape(Circle())
                        .addAnimation(dependency: isHoveredCloseButton)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(8)
                .onHover { isHovered in
                    isHoveredCloseButton = isHovered
                }
            }
        }
    }
    
    // MARK: - Input Device Selection Dropdown
    
    private struct InputDeviceSelectionDropdown: View {
        @Default(.transcriptionInputDevice) private var currentInputDevice

        @State private var showAvailableDevices: Bool = false

        private var currentInputDeviceName: String {
            if let currentInputDevice {
                return currentInputDevice.name
            } else {
                return String.localized("Select a microphone", table: "Transcription")
            }
        }

        var body: some View {
            TextButton(
                colorConfig: .init(
                    text: Color.S_0,
                    background: Color.T_8
                ),
                sizeConfig: .init(
                    horizontalPadding: 10,
                    height: 38,
                    cornerRadius: 8
                ),
                alignmentConfig: .init(
                    gap: 6
                ),
                statusConfig: .init(
                    fillContainer: true
                )
            ) {
                HStack(alignment: .center, spacing: 10) {
                    icon(systemName: "mic.fill")
                    Text(currentInputDeviceName)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .styleText(
                            size: 13,
                            weight: .regular
                        )
                        .truncateText()
                    icon(systemName: "chevron.down")
                }
            } action: {
                showAvailableDevices.toggle()
            }
            .frame(width: 220, alignment: .leading)
            .popover(
                isPresented: $showAvailableDevices,
                arrowEdge: .bottom
            ) {
                AvailableMicrophonesPopoverView(
                    show: $showAvailableDevices,
                    isOpaque: true
                )
            }
        }
        
        private func icon(systemName: String) -> some View {
            Image(systemName: systemName)
                .styleText(
                    size: 13
                )
        }
    }
    
    // MARK: - Don't Show Toggle Button
    
    private struct DontShowToggleButton: View {
        let defaultsKey: Defaults.Key<Bool>
        
        init(defaultsKey: Defaults.Key<Bool>) {
            self.defaultsKey = defaultsKey
            self._isEnabled = State(initialValue: Defaults[defaultsKey])
        }

        @State private var isEnabled: Bool
        @State private var isHovered: Bool = false
        @State private var isPressed: Bool = false
        
        private var background: Color {
            if isEnabled {
                return Color.T_7
            } else {
                return Color.S_0
            }
        }

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 0) {
                    if !isEnabled {
                        Image(systemName: "checkmark")
                            .styleText(
                                size: 10,
                                color: Color.S_10
                            )
                    }
                }
                .frame(width: 16, alignment: .center)
                .frame(height: 16, alignment: .center)
                .addButtonEffects(
                    background: background,
                    hoverBackground: background.opacity(0.7),
                    cornerRadius: 4,
                    isHovered: $isHovered,
                    isPressed: $isPressed
                ) {
                    Defaults[defaultsKey].toggle()
                }
                .addBorder(
                    cornerRadius: 4,
                    stroke: Color.T_4
                )

                Text(String.localized("Don't show again", table: "MenuBar"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_1
                    )
            }
            .onReceive(Defaults.publisher(defaultsKey).map(\.newValue)) { newValue in
                isEnabled = newValue
            }
        }
    }
    
    // MARK: - Auto-Dismiss Timer Bar

    private struct AutoDismissTimerBar: View {
        let duration: Duration

        @State private var progress: CGFloat = 1

        var body: some View {
            GeometryReader { geometry in
                LinearGradient(
                    stops: [
                        .init(color: Color.white, location: 0),
                        .init(color: Color.white, location: 0.85),
                        .init(color: Color.white.opacity(0), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(
                    width: geometry.size.width * progress,
                    height: 2
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
            .frame(height: 2)
            .onAppear {
                let seconds = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18

                withAnimation(.linear(duration: seconds)) {
                    progress = 0
                }
            }
        }
    }
}
