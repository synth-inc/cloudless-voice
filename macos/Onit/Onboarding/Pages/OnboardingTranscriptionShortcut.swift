// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingTranscriptionShortcut.swift
//  Onit
//
//  Created by Loyd Kim on 6/8/26.
//

import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

struct OnboardingTranscriptionShortcut: View {
    // MARK: - Defaults

    @Default(.currentOnboardingStep) private var currentStep
    @Default(TranscriptionConfigKeys.shortcutType) private var shortcutType

    // MARK: - Observations

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared

    // MARK: - States

    /// Set true once the currently-selected shortcut actually triggers dictation.
    @State private var testPassed: Bool = false

    /// Tracks whether a custom shortcut has been recorded (gates Next when `.custom` is selected).
    @State private var hasCustomShortcut: Bool = false

    /// Set true to make the custom recorder start recording (when the custom row is selected).
    @State private var beginCustomRecording: Bool = false

    // MARK: - Private Variables

    private let selectableTypes: [TranscriptionShortcutType] = [
        .capsLock,
        .fn,
        .rightCommand,
        .commandDoubleTap,
        .controlDoubleTap
    ]

    private var nextDisabled: Bool {
        /// Custom requires a recorded shortcut before the user can continue.
        shortcutType == .custom && !hasCustomShortcut
    }

    // MARK: - Body

    var body: some View {
        OnboardingPage(
            bodyConfig: .init(removeContentSpacer: true),
            footerConfig: .init(showNextButton: false),
            bodyContent: {
                shortcutList
            },
            footerContent: {
                footer
            }
        )
        .onAppear {
            refreshHasCustomShortcut()
            /// Confirm the selected shortcut works by listening for its raw input - decoupled from
            /// transcription/model state. Test mode keeps the key handlers' state machine idle so a
            /// test press can never start a real dictation session (it would otherwise record and
            /// insert text whenever the models happen to be warmed).
            KeyboardShortcutsManager.isTranscriptionShortcutTestModeActive = true
            KeyboardShortcutsManager.onTranscriptionShortcutDetected = {
                testPassed = true
            }
            /// Defensive: a session started before this page appeared can't be stopped while test
            /// mode swallows the key handlers - end it now so it doesn't record forever.
            if transcriptionManager.isTranscribing {
                transcriptionManager.cancelTranscription()
            }
        }
        .onDisappear {
            KeyboardShortcutsManager.onTranscriptionShortcutDetected = nil
            KeyboardShortcutsManager.isTranscriptionShortcutTestModeActive = false
            KeyboardShortcutsManager.restoreShortcutTypeIfCustomIsEmpty()
        }
    }

    // MARK: - Child Components: Shortcut List

    private var shortcutList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .center, spacing: 8) {
                ForEach(selectableTypes, id: \.self) { type in
                    shortcutRow(for: type)
                }

                customRow
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Child Components: Selectable Row

    @ViewBuilder
    private func shortcutRow(for type: TranscriptionShortcutType) -> some View {
        let isSelected = shortcutType == type

        TextButton(
            colorConfig: .init(
                background: isSelected ? Color.T_10 : Color.clear,
                hoverBackground: isSelected ? Color.clear : Color.T_9,
                border: Color.T_7
            ),
            sizeConfig: .init(
                horizontalPadding: 8,
                height: 62,
                cornerRadius: 14
            ),
            statusConfig: .init(
                selected: isSelected,
                fillContainer: true
            ),
            children: {
                rowContent(for: type, isSelected: isSelected)
            },
            action: {
                selectType(type)
            }
        )
        .frame(width: 373)
        .overlay(alignment: .leading) {
            if isSelected {
                testerView(for: type)
                    .fixedSize()
                    // Pin to the row's left edge, then push the full row width + 16pt gap to the
                    // right so it floats cleanly off the row's right edge (no layout impact).
                    .offset(x: 373 + 12)
            }
        }
    }

    private func rowContent(for type: TranscriptionShortcutType, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            keycap(symbol: keycapSymbol(for: type))

            VStack(alignment: .leading, spacing: 2) {
                Text(rowLabel(for: type, isSelected: isSelected))
                    .styleText(size: 14, weight: .regular, color: isSelected ? Color.S_0 : Color.S_1)

                if let sublabel = rowSublabel(for: type, isSelected: isSelected) {
                    Text(sublabel)
                        .styleText(size: 12, weight: .regular, color: Color.T_1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            radio(isSelected: isSelected)
        }
        .padding(.trailing, 8)
    }

    // MARK: - Child Components: Custom Recorder Row

    private var customRow: some View {
        let isSelected = shortcutType == .custom
        
        return VStack(alignment: .leading, spacing: 10) {
            TextButton(
                colorConfig: .init(
                    background: isSelected ? Color.T_10 : Color.clear,
                    hoverBackground: isSelected ? Color.clear : Color.T_9,
                    border: Color.T_7
                ),
                sizeConfig: .init(
                    horizontalPadding: 8,
                    height: 62,
                    cornerRadius: 14
                ),
                statusConfig: .init(
                    selected: isSelected,
                    fillContainer: true
                ),
                children: {
                    if isSelected {
                        // Selected: the recorder (overlaid below) takes the row - nothing else to show.
                        Spacer()

                        radio(isSelected: isSelected)
                            .padding(.trailing, 8)
                    } else {
                        // Unselected: same keycap + label treatment as every other row.
                        rowContent(for: .custom, isSelected: false)
                    }
                },
                action: {
                    selectCustom()
                }
            )
            .overlay(alignment: .center) {
                // Only while selected. The recorder is bound to `.toggleTranscription`, which is also
                // where the *special* types store their binding - so on an unselected row it would
                // display the active shortcut (e.g. CapsLock, whose glyph doesn't even render) and
                // imply a custom shortcut is already set.
                if isSelected {
                    AutoFocusShortcutRecorder(
                        name: .toggleTranscription,
                        beginRecording: $beginCustomRecording
                    ) { shortcut in
                        handleCustomRecord(shortcut)
                    }
                }
            }
            .overlay(alignment: .leading) {
                if isSelected && hasCustomShortcut {
                    testerView(for: .custom)
                        .fixedSize()
                        .offset(x: 373 + 12)
                }
            }

            if isSelected {
                Text(String.localized("Custom shortcut must combine one or more modifier keys (Shift, Cmd, Option, Control) with another key (letter, number, etc).", table: "Onboarding"))
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 373)
    }

    // MARK: - Child Components: Tester
    
    @ViewBuilder
    private func testerView(for type: TranscriptionShortcutType) -> some View {
        if testPassed {
            Text(String.localized("It's working!", table: "Onboarding"))
            .styleText(size: 13, weight: .regular)
            .padding(.horizontal, 8)
            .frame(width: 160, height: 50, alignment: .center)
            .background(Color.special2)
            .addBorder(
                cornerRadius: 14,
                stroke: Color.info500,
                dotted: true
            )
        } else {
            VStack(alignment: .center, spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text(
                        type.supportsHold
                            ? String.localized("Press & hold to test", table: "Onboarding")
                            : String.localized("Double-tap to test", table: "Onboarding")
                    )
                    .styleText(size: 13, weight: .regular)

                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color.S_0)
                        .onHover { isHovering in
                            if isHovering {
                                TooltipHelpers.setTooltipOnHover(
                                    isHovering: isHovering,
                                    tooltipPrompt: String.localized("Nothing happening? Try selecting a different shortcut.", table: "Onboarding")
                                )
                            } else {
                                TooltipManager.shared.setTooltip(nil)
                            }
                        }
                }

                Text(String.localized("Waiting...", table: "Onboarding"))
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
            }
            .padding(.horizontal, 8)
            .frame(width: 160, height: 50, alignment: .center)
            .addBorder(
                cornerRadius: 14,
                stroke: Color.T_4,
                dotted: true
            )
        }
    }

    // MARK: - Child Components: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 0) {
            Spacer()

            Text(String.localized("Tip: choose a key you don't normally use for anything else", table: "Onboarding"))
                .styleText(size: 13, weight: .regular, color: Color.T_2)

            Spacer()

            TextButton(
                type: .primary,
                text: String.localized("Next", table: "Onboarding"),
                statusConfig: .init(disabled: nextDisabled)
            ) {
                advance()
            }
            .background {
                KeyListener(key: .return, modifiers: []) {
                    if !nextDisabled { advance() }
                }
            }
        }
    }

    // MARK: - Child Components: Reusable Bits

    private func keycap(symbol: String) -> some View {
        Text(symbol)
            .styleText(size: 20, weight: .regular, color: Color.S_0)
            .frame(width: 36, height: 36)
            .background(Color.T_9)
            .cornerRadius(9)
    }

    @ViewBuilder
    private func radio(isSelected: Bool) -> some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.lime500)
                    .frame(width: 18, height: 18)

                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white)
            }
        } else {
            Circle()
                .fill(Color.T_9)
                .stroke(Color.T_7, lineWidth: 1)
                .frame(width: 18, height: 18)
        }
    }

    // MARK: - Private Functions: Display

    private func keycapSymbol(for type: TranscriptionShortcutType) -> String {
        switch type {
        case .capsLock: return "⇪"
        case .fn: return "fn"
        case .rightCommand: return "⌘"
        case .commandDoubleTap: return "⌘"
        case .controlDoubleTap: return "⌃"
        case .custom: return "⌘"
        }
    }

    private func rowLabel(for type: TranscriptionShortcutType, isSelected: Bool) -> String {
        switch type {
        case .capsLock:
            return isSelected
                ? String.localized("CapsLock", table: "Onboarding")
                : String.localized("CapsLock (default)", table: "Onboarding")
        case .fn:
            return String.localized("Fn (Function)", table: "Onboarding")
        case .rightCommand:
            return String.localized("Right Command", table: "Onboarding")
        case .commandDoubleTap:
            return String.localized("Double-tap Command", table: "Onboarding")
        case .controlDoubleTap:
            return String.localized("Double-tap Control", table: "Onboarding")
        case .custom:
            return String.localized("Custom Shortcut", table: "Onboarding")
        }
    }

    private func rowSublabel(for type: TranscriptionShortcutType, isSelected: Bool) -> String? {
        switch type {
        case .capsLock where isSelected:
            return String.localized("You can still use CapsLock by holding Shift", table: "Onboarding")
        default:
            return nil
        }
    }

    // MARK: - Private Functions: Selection

    private func selectType(_ type: TranscriptionShortcutType) {
        guard type != shortcutType else { return }
        KeyboardShortcutsManager.cancelIfActive()
        KeystrokeNotificationManager.shared.resetDoubleTapState()

        let previousType = shortcutType
        shortcutType = type
        /// CapsLock / Fn / Custom seed their default binding on switch; the others keep their fixed behavior.
        let forceDefault = (type == .capsLock || type == .fn)
        type.apply(previousType: previousType, forceDefaultOnSwitch: forceDefault)

        testPassed = false
        refreshHasCustomShortcut()
    }

    private func selectCustom() {
        if shortcutType != .custom {
            KeyboardShortcutsManager.cancelIfActive()
            KeystrokeNotificationManager.shared.resetDoubleTapState()

            let previousType = shortcutType
            // Remembered on the manager, not in this view's state: the restore below has to survive
            // the view being torn down (window close) or re-created (Next → Back).
            KeyboardShortcutsManager.transcriptionShortcutTypeBeforeCustom = previousType
            shortcutType = .custom
            TranscriptionShortcutType.custom.apply(previousType: previousType, forceDefaultOnSwitch: true)
            /// Start empty so the user records their own shortcut (mock shows an empty recorder + disabled Next).
            KeyboardShortcuts.setShortcut(nil, for: .toggleTranscription)

            hasCustomShortcut = false
            testPassed = false
        }

        /// Auto-focus the recorder so a single click on the custom row starts recording.
        beginCustomRecording = true
    }

    private func handleCustomRecord(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if shortcutType != .custom {
            shortcutType = .custom
        }
        hasCustomShortcut = shortcut != nil
        if hasCustomShortcut {
            KeyboardShortcutsManager.transcriptionShortcutTypeBeforeCustom = nil
        }
        testPassed = false
    }

    private func refreshHasCustomShortcut() {
        // Scoped to `.custom`: the binding is shared with the special types, so without this a
        // CapsLock user would count as "has a custom shortcut".
        hasCustomShortcut = shortcutType == .custom
            && KeyboardShortcuts.getShortcut(for: .toggleTranscription) != nil
    }

    // MARK: - Private Functions: Navigation

    private func advance() {
        guard !nextDisabled else { return }

        /// Models ready → run the live demo. Still downloading → skip the demo (it needs the models
        /// loaded) and continue the flow; the demo is offered again later from Home. Readiness spans
        /// the dictation model AND the full Smart Cleanup stack (the demo showcases Smart Cleanup),
        /// per `ModelDownloadIndicator.demoModelsReady`. `debugSimulateModelsDownloading` forces the
        /// skip branch for testing (see SettingsExperimental).
        let modelReady = ModelDownloadIndicator.demoModelsReady && !Defaults[.debugSimulateModelsDownloading]
        if modelReady {
            currentStep = currentStep?.nextStep()
        } else if let afterDemo = OnboardingStep.transcriptionDemo.nextStep() {
            currentStep = afterDemo
        } else {
            currentStep = currentStep?.nextStep()
        }
    }
}

// MARK: - Auto-Focusing Recorder

/// Wraps the KeyboardShortcuts library's `RecorderCocoa` so recording can be started
/// programmatically. The stock SwiftUI `Recorder` blocks auto-focus, so a single click on the
/// custom row otherwise couldn't begin recording. Recording starts the instant the underlying
/// view becomes first responder.
private struct AutoFocusShortcutRecorder: NSViewRepresentable {
    typealias NSViewType = KeyboardShortcuts.RecorderCocoa

    let name: KeyboardShortcuts.Name
    @Binding var beginRecording: Bool
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeNSView(context: NSViewRepresentableContext<Self>) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: name, onChange: onChange)
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: NSViewRepresentableContext<Self>) {
        nsView.shortcutName = name

        guard beginRecording else { return }

        // Defer past the current update cycle, then make it first responder to start recording.
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
            beginRecording = false
        }
    }
}
