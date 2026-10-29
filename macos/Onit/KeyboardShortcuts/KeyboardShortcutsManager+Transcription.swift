// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  KeyboardShortcutsManager+Transcription.swift
//  Onit
//
//  Created by Loyd Kim on 2/18/26.
//

/*
 * Types
 * Properties
 * Functions: Register Transcription Shortcut
 * Public Functions: Enable & Disable Transcription Shortcut
 * Local Functions: Caps Lock Handlers
 * Private Functions: Key Down/Up Handler
 * Private Functions: Reset
 */

import Defaults
import Foundation
import KeyboardShortcuts

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

extension KeyboardShortcutsManager {
    // MARK: - Types
    
    private enum TranscriptionShortcutState {
        /// No transcription active via shortcut.
        case idle
        
        /// Key is held down, recording in progress (hold-to-record/hands-on).
        case holdRecording
        
        /// Key was released, waiting to see if a second tap follows within the double-tap window.
        case waitingForDoubleTap
        
        /// Double-tap detected, recording continues hands-free until the next single press stops it.
        case handsFree
    }
    
    private enum KeyDirection {
        case keyDown
        case keyUp
    }
    
    // MARK: - Properties
    
    private static var transcriptionShortcutState: TranscriptionShortcutState = .idle

    /// Shortcut Double-Tap: When entering hands-free transcription from a double-tap, the keyUp from the second tap should be ignored.
    private static var ignoreNextTranscriptionKeyUp = false

    private static var doubleTapTimerTask: Task<Void, Never>?

    /// Index of the custom-mode shortcut slot that currently owns the state machine.
    /// Presses from other slots are ignored while non-nil, so interleaving F19/F12 cannot corrupt state.
    private static var activeTranscriptionSlotIndex: Int?
    
    /// Small time window to detect a double-tap request.
    private static let doubleTapTimeWindow: Int = 400
    
    /// The `KeyboardShortcuts` library cannot express `.toggleTranscription` + `<custom shortcut>` as a valid shortcut binding.
    ///     For example, `.toggleTranscription + C/V` ("copy/paste last transcription").
    /// Therefore, we use this property to detect when `.toggleTranscription` is held (set to `true` when the shortcut is held).
    /// Then, we detect when a custom keystroke is pressed alongside the `.toggleTranscription` shortcut in `TranscriptionKeysManager`.
    ///     For example, we use this to detect when `C/V` is pressed to invoke "copy/paste last transcription."
    static var isToggleTranscriptionShortcutHeld: Bool = false

    /// Fires whenever the assigned transcription shortcut receives input (a key-down, or a completed
    /// double-tap), independent of whether transcription actually starts. The onboarding shortcut
    /// tester uses this to confirm "the shortcut works" even while the model is still downloading.
    /// Nil by default - no effect on normal transcription behavior.
    static var onTranscriptionShortcutDetected: (() -> Void)?

    /// When true, transcription shortcuts run in "test" mode: `onTranscriptionShortcutDetected` still
    /// fires, but no transcription session is ever started, toggled, or stopped. The onboarding
    /// Shortcut step sets this while it's visible so a test press stays completely silent - without
    /// it, the press would start a real recording (chime, overlay, history entry) whenever the models
    /// happen to be warmed. False by default - no effect on normal transcription behavior.
    static var isTranscriptionShortcutTestModeActive: Bool = false

    /// The shortcut type in effect before the onboarding Shortcut step switched to `.custom` (which
    /// clears the binding so the recorder starts empty). Held here rather than in the page's `@State`
    /// so the restore below survives the view being torn down or re-created - the user must never end
    /// up with `.custom` selected and nothing bound, which leaves dictation unreachable.
    static var transcriptionShortcutTypeBeforeCustom: TranscriptionShortcutType?

    /// Undoes that switch when `.custom` is still selected with nothing recorded. Called both from
    /// the page's `.onDisappear` and from the onboarding window's `windowWillClose`, since neither
    /// Back nor closing the window is gated on having recorded a shortcut. Idempotent.
    static func restoreShortcutTypeIfCustomIsEmpty() {
        guard let previousType = transcriptionShortcutTypeBeforeCustom else { return }
        transcriptionShortcutTypeBeforeCustom = nil

        guard Defaults[Defaults.Keys.TranscriptionConfigKeys.shortcutType] == .custom,
              KeyboardShortcuts.getShortcut(for: .toggleTranscription) == nil
        else {
            return
        }

        Defaults[Defaults.Keys.TranscriptionConfigKeys.shortcutType] = previousType
        previousType.apply(previousType: .custom, forceDefaultOnSwitch: true)
    }

    // MARK: - Functions: Register Transcription Shortcut
    
    /// Registers the speech transcription shortcut.
    /// Supports multiple shortcut types: CapsLock, Fn, or Custom.
    /// And three interaction patterns:
    /// - Hold mode (default): hold to record, release to stop and insert (when `transcriptionHoldToRecord` is true`
    /// - Toggle mode: press to start, press again to stop (when `transcriptionHoldToRecord` is false)
    /// - Double-tap mode: double-tap to start hands-free recording, single press to stop
    static func registerTranscriptionShortcut() {
        /// Register handlers for every slot in the custom-mode shortcut pool.
        /// Slot 0 is the legacy `.toggleTranscription` Name - also used by CapsLock mode and onboarding - so capsLock and first-time custom behavior remain unchanged.
        for (index, name) in TranscriptionShortcutType.customShortcutNames.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) {
                Task { @MainActor in
                    isToggleTranscriptionShortcutHeld = true
                    handleKeyPress(for: .keyDown, slotIndex: index)
                }
            }
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in
                    isToggleTranscriptionShortcutHeld = false
                    handleKeyPress(for: .keyUp, slotIndex: index)
                }
            }
        }

        /// Register Fn key handler (handled via `KeystrokeNotificationManager`)
        registerFnKeyHandler()

        /// Register command/control double-tap handlers
        registerDoubleTapHandlers()

        /// Enable slots at startup. Slot 0 follows the main type; alternate slots always use the library.
        if Defaults[.transcriptionEnabled] {
            let type = Defaults[TranscriptionConfigKeys.shortcutType]
            let active = TranscriptionShortcutType.activeCustomShortcutNames
            if type.usesKeyboardShortcutsLibrary {
                KeyboardShortcuts.enable(active)
            } else {
                let alternates = Array(active.dropFirst())
                if !alternates.isEmpty { KeyboardShortcuts.enable(alternates) }
            }
            TranscriptionKeysManager.shared.start()
        }
    }

    /// Re-applies the active-slot enable/disable state after the user adds or removes a slot in Settings.
    /// Handles all shortcut types - alternates fire through the library regardless of the main type.
    @MainActor
    static func refreshCustomTranscriptionShortcutPool() {
        guard Defaults[.transcriptionEnabled] else { return }

        let type = Defaults[TranscriptionConfigKeys.shortcutType]
        let pool = TranscriptionShortcutType.customShortcutNames
        let active = TranscriptionShortcutType.activeCustomShortcutNames
        let inactive = Array(pool.dropFirst(active.count))

        // Slot 0 follows the main type: disabled for non-library types, enabled otherwise.
        if type.usesKeyboardShortcutsLibrary {
            KeyboardShortcuts.enable([.toggleTranscription])
        } else {
            KeyboardShortcuts.disable([.toggleTranscription])
        }

        // Alternates (slots 1..count-1) always fire via the library.
        let alternates = Array(active.dropFirst())
        if !alternates.isEmpty {
            KeyboardShortcuts.enable(alternates)
        }
        if !inactive.isEmpty {
            KeyboardShortcuts.disable(inactive)
        }
    }
    
    /// Registers the Fn key handler for transcription via `KeystrokeNotificationManager`
    private static func registerFnKeyHandler() {
        KeystrokeNotificationManager.shared.onFnKeyStateChanged = { fnEvent in
            guard Defaults[.transcriptionEnabled] else { return }

            let mainType = Defaults[TranscriptionConfigKeys.shortcutType]
            let fnAlternateSlotIndex = TranscriptionShortcutType.fnAlternateSlotIndex

            if mainType == .fn {
                isToggleTranscriptionShortcutHeld = fnEvent.isPressed
                // Main Fn slot is always slot 0.
                if fnEvent.isPressed {
                    handleKeyPress(for: .keyDown, slotIndex: 0)
                } else {
                    handleKeyPress(for: .keyUp, slotIndex: 0)
                }
            } else if let altIndex = fnAlternateSlotIndex {
                isToggleTranscriptionShortcutHeld = fnEvent.isPressed
                // Fn configured as an alternate - fire through the appropriate slot.
                if fnEvent.isPressed {
                    handleKeyPress(for: .keyDown, slotIndex: altIndex)
                } else {
                    handleKeyPress(for: .keyUp, slotIndex: altIndex)
                }
            }
        }
    }

    /// Registers command and control double-tap handlers via `KeystrokeNotificationManager`
    private static func registerDoubleTapHandlers() {
        KeystrokeNotificationManager.shared.onCommandDoubleTap = {
            guard Defaults[.transcriptionEnabled] else { return }
            let isMain = Defaults[TranscriptionConfigKeys.shortcutType] == .commandDoubleTap
            let isAlternate = TranscriptionShortcutType.alternateSlotIndex(for: .commandDoubleTap) != nil
            guard isMain || isAlternate else { return }
            Task { @MainActor in handleDoubleTapTriggered() }
        }

        KeystrokeNotificationManager.shared.onControlDoubleTap = {
            guard Defaults[.transcriptionEnabled] else { return }
            let isMain = Defaults[TranscriptionConfigKeys.shortcutType] == .controlDoubleTap
            let isAlternate = TranscriptionShortcutType.alternateSlotIndex(for: .controlDoubleTap) != nil
            guard isMain || isAlternate else { return }
            Task { @MainActor in handleDoubleTapTriggered() }
        }
    }

    @MainActor
    private static func handleDoubleTapTriggered() {
        onTranscriptionShortcutDetected?()

        /// Test mode (onboarding Shortcut step): the detection above is the whole point - never
        /// toggle an actual transcription session.
        guard !isTranscriptionShortcutTestModeActive else { return }

        let transcriptionWasCancelled =
            transcriptionShortcutState != .idle &&
            !TranscriptionManager.shared.isTranscribing

        if transcriptionWasCancelled {
            resetTranscriptionShortcutState()
        }

        TranscriptionManager.shared.toggle(tapTime: Date())
    }

    // MARK: - Public Functions: Enable & Disable Transcription Shortcut

    /// Enable transcription shortcuts (called when feature is enabled)
    static func enableTranscriptionShortcuts() {
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType]
        if shortcutType.usesKeyboardShortcutsLibrary {
            KeyboardShortcuts.enable(TranscriptionShortcutType.activeCustomShortcutNames)
        }
        // Apply shortcut type configuration
        shortcutType.apply()

        TranscriptionKeysManager.shared.start()
    }

    /// Disable transcription shortcuts (called when feature is disabled)
    static func disableTranscriptionShortcuts() {
        KeyboardShortcuts.disable(TranscriptionShortcutType.customShortcutNames)

        isToggleTranscriptionShortcutHeld = false

        TranscriptionKeysManager.shared.stop()
    }
    
    // MARK: - Local Functions: Caps Lock Handlers
    
    /// True when the user has chosen "hands-free only" - bypasses the hold/double-tap state machine.
    private static var isHandsFreeOnly: Bool {
        Defaults[TranscriptionConfigKeys.handsFreeOnly]
    }

    /// Returns `true` if caps lock was consumed for transcription hold mode (caller should skip other caps lock shortcuts).
    @discardableResult
    static func handleTranscriptionOnCapsDownIfNeeded() -> Bool {
        guard Defaults[.transcriptionEnabled] else { return false }
        // In hands-free-only mode, CapsLock should fall through to the toggle path
        // (executeCapsLockTappedShortcutsIfNeeded) - never enter hold-recording.
        guard !isHandsFreeOnly else { return false }

        if isTranscriptionUsingCapsLock() {
            if Defaults[.transcriptionHoldToRecord] {
                handleKeyPress(for: .keyDown, slotIndex: 0)
                return true
            }
            // Toggle mode: handled by executeCapsLockTappedShortcutsIfNeeded()
        }

        // CapsLock alternates - also route through hold path if hold-to-record is on.
        if Defaults[.transcriptionHoldToRecord] {
            let pool = TranscriptionShortcutType.customShortcutNames
            for altName in TranscriptionShortcutType.capsLockAlternateSlotNames {
                if let slotIndex = pool.firstIndex(of: altName) {
                    handleKeyPress(for: .keyDown, slotIndex: slotIndex)
                    return true
                }
            }
        }

        return false
    }

    static func handleTranscriptionOnCapsUpIfNeeded() {
        guard Defaults[.transcriptionEnabled] else { return }
        guard !isHandsFreeOnly else { return }

        if isTranscriptionUsingCapsLock() && Defaults[.transcriptionHoldToRecord] {
            handleKeyPress(for: .keyUp, slotIndex: 0)
            return
        }

        if Defaults[.transcriptionHoldToRecord] {
            let pool = TranscriptionShortcutType.customShortcutNames
            for altName in TranscriptionShortcutType.capsLockAlternateSlotNames {
                if let slotIndex = pool.firstIndex(of: altName) {
                    handleKeyPress(for: .keyUp, slotIndex: slotIndex)
                    return
                }
            }
        }
    }
    
    private static func isTranscriptionUsingCapsLock() -> Bool {
        return Defaults[TranscriptionConfigKeys.shortcutType] == .capsLock
    }

    // MARK: - Local Functions: Right Command Handlers

    /// Returns `true` if Right Command was consumed for transcription hold mode.
    @discardableResult
    static func handleTranscriptionOnRightCommandDownIfNeeded() -> Bool {
        guard Defaults[.transcriptionEnabled] else { return false }

        if isTranscriptionUsingRightCommand() {
            handleKeyPress(for: .keyDown, slotIndex: 0)
            return true
        } else if let altIndex = TranscriptionShortcutType.alternateSlotIndex(for: .rightCommand) {
            handleKeyPress(for: .keyDown, slotIndex: altIndex)
            return true
        }
        return false
    }

    static func handleTranscriptionOnRightCommandUpIfNeeded() {
        guard Defaults[.transcriptionEnabled] else { return }

        if isTranscriptionUsingRightCommand() {
            handleKeyPress(for: .keyUp, slotIndex: 0)
        } else if let altIndex = TranscriptionShortcutType.alternateSlotIndex(for: .rightCommand) {
            handleKeyPress(for: .keyUp, slotIndex: altIndex)
        }
    }

    private static func isTranscriptionUsingRightCommand() -> Bool {
        return Defaults[TranscriptionConfigKeys.shortcutType] == .rightCommand
    }
    
    // MARK: - Private Functions: Key Down/Up Handler
    
    @MainActor
    private static func handleKeyPress(
        for direction: KeyDirection,
        slotIndex: Int = 0
    ) {
        guard Defaults[.transcriptionEnabled] else { return }

        /// Surface shortcut input to listeners (e.g. the onboarding shortcut tester) on press.
        if direction == .keyDown {
            onTranscriptionShortcutDetected?()
        }

        /// Test mode (onboarding Shortcut step): the detection above is the whole point - keep the
        /// state machine idle so neither key-down nor key-up can start or stop a real session.
        guard !isTranscriptionShortcutTestModeActive else { return }

        /// Resetting states if needed.
        let transcriptionWasCancelled =
            transcriptionShortcutState != .idle &&
            !TranscriptionManager.shared.isTranscribing
        
        if transcriptionWasCancelled {
            resetTranscriptionShortcutState()
            
            if direction == .keyUp {
                return
            }
        }

        /// Slot gating: while the state machine is non-idle and owned by a specific slot, presses from any other slot are dropped.
        if let owner = activeTranscriptionSlotIndex, owner != slotIndex {
            return
        }

        let holdSupported = Defaults[TranscriptionConfigKeys.shortcutType].supportsHold
        guard !isHandsFreeOnly && Defaults[.transcriptionHoldToRecord] && holdSupported
        else {
            /// Toggle mode (non-hold) or hands-free-only: bypass the state machine entirely.
            /// Double-tap hands-free is only available in hold-to-record mode.
            /// A simple key-up toggles transcription on/off; `toggle()` picks `.handsfree` when
            /// hands-free-only is enabled, otherwise `.toggle`.
            if direction == .keyUp {
                Defaults[TranscriptionConfigKeys.lastUsedCustomShortcutIndex] = slotIndex
                TranscriptionManager.shared.toggle(tapTime: Date())
            }
            return
        }
        
        /// Handling key down/up action pathways.
        switch transcriptionShortcutState {
        case .idle:
            /// Hold mode on key down (hold shortcut to record).
            if direction == .keyDown {
                transcriptionShortcutState = .holdRecording
                activeTranscriptionSlotIndex = slotIndex
                Defaults[TranscriptionConfigKeys.lastUsedCustomShortcutIndex] = slotIndex

                TranscriptionManager.shared.startTranscription(activationMode: .hold, tapTime: Date())
            }
            /// No-op on key up.
            else {
                break
            }
            
        case .holdRecording:
            /// Mid-recording during key down. No-op.
            if direction == .keyDown {
                break
            }
            /// Start by entering "waiting for double-tap" state on key up and then monitor for a double-tap request.
            /// If double-tap was not requested, it means we're on hold mode. Key up should stop transcription.
            else {
                transcriptionShortcutState = .waitingForDoubleTap
                
                doubleTapTimerTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(doubleTapTimeWindow))
                    guard !Task.isCancelled else { return }
                    
                    /// No double-tap detected (we're in hold mode). Stop transcription to enter speech-to-text pipeline.
                    transcriptionShortcutState = .idle
                    activeTranscriptionSlotIndex = nil
                    if TranscriptionManager.shared.isTranscribing {
                        TranscriptionManager.shared.stopTranscription()
                    }
                }
            }
            
        case .waitingForDoubleTap:
            /// Double-tap was requested. Enter hands-free mode.
            if direction == .keyDown {
                doubleTapTimerTask?.cancel()
                doubleTapTimerTask = nil
                transcriptionShortcutState = .handsFree
                ignoreNextTranscriptionKeyUp = true

                TranscriptionManager.shared.setActivationMode(.handsfree)
            } else {
                /// No-op on key up.
                break
            }
            
        /// 1. Enter hands-free mode with ignoring first key-up (because we enter this mode with the key already pressed down).
        /// 2. On second key down-up rotation, properly enter the `stopTranscription()` pipeline.
        case .handsFree:
            /// User pressed the shortcut to stop.
            /// This is a defensive reset to ensure that the upcoming key-up will trigger `stopTranscription()`.
            if direction == .keyDown {
                ignoreNextTranscriptionKeyUp = false
            }
            else {
                /// Lifting finger from double-tap that entered hands-free mode. Ignore.
                if ignoreNextTranscriptionKeyUp {
                    ignoreNextTranscriptionKeyUp = false
                }
                /// Lifting finger from the stop press. End hands-free recording with a single tap.
                else {
                    transcriptionShortcutState = .idle
                    activeTranscriptionSlotIndex = nil
                    TranscriptionManager.shared.stopTranscription()
                }
            }
        }
    }
    
    // MARK: - Private Functions: Reset

    /// Resets the transcription shortcut state machine to idle.
    /// Called defensively when the state machine is out of sync with `TranscriptionManager`
    /// (e.g., transcription was cancelled via the UI cancel button).
    private static func resetTranscriptionShortcutState() {
        doubleTapTimerTask?.cancel()
        doubleTapTimerTask = nil
        transcriptionShortcutState = .idle
        ignoreNextTranscriptionKeyUp = false
        activeTranscriptionSlotIndex = nil
    }

    /// Cancels any active transcription and resets the state machine.
    /// Call before changing the shortcut type to prevent an orphaned recording state
    /// when the key-up event for the previous type will no longer be handled.
    @MainActor
    static func cancelIfActive() {
        if TranscriptionManager.shared.isTranscribing {
            TranscriptionManager.shared.cancelTranscription()
        }
        if transcriptionShortcutState != .idle {
            resetTranscriptionShortcutState()
        }
    }
}
