// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  KeyboardShortcutsManager.swift
//  Onit
//
//  Created by Kévin Naudin on 11/02/2025.
//

@preconcurrency import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import PostHog
import SwiftData

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

@MainActor
class KeyboardShortcutsManager {

    // Dev build coexistence state
    private static var devBuildCancellables = Set<AnyCancellable>()
    private static var isDisabledForDevBuild = false

    private init() {}

    static var capsLockModifierShortcuts: [KeyboardShortcuts.Name] {
        get {
            return Defaults[.capsLockModifierShortcuts].compactMap { nameString in
                KeyboardShortcuts.Name.allCases.first { $0.rawValue == nameString }
            }
        }
        set {
            Defaults[.capsLockModifierShortcuts] = newValue.map { $0.rawValue }
        }
    }

    static func configure() {
        registerRemappedKeyConsumerShortcuts()
        registerTranscriptionShortcut()

        KeyboardShortcuts.enable([.remappedKeyConsumer, .remappedKeyConsumerShifted])

        KeyboardShortcuts.disable(capsLockModifierShortcuts)

        // Apply or remove HID remappings based on what features currently need.
        // This also cleans up stale mappings from a previous crash/force-quit.
        if KeystrokeNotificationManager.shared.isHIDRemappingNeededByAnyFeature() {
            KeystrokeNotificationManager.shared.applyHIDRemapping(context: "Startup")
        } else {
            KeystrokeNotificationManager.shared.removeHIDRemapping()
        }
    }

    static func setShortcut(name: KeyboardShortcuts.Name, shortcut: KeyboardShortcuts.Shortcut, usesCapsLockModifier: Bool) {
        var currentShortcuts = Self.capsLockModifierShortcuts

        if (usesCapsLockModifier) {
            // Add the shortcut to the list of capsLockShortcuts if not already present
            if !currentShortcuts.contains(name) {
                currentShortcuts.append(name)
            }
        } else {
            // Remove the shortcut from the list of capsLockShortcuts if present
            currentShortcuts.removeAll { $0 == name }
        }

        // Update the persistent storage
        Self.capsLockModifierShortcuts = currentShortcuts
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        // Re-evaluate HID remapping: apply if CapsLock is now needed, remove if not
        if KeystrokeNotificationManager.shared.isHIDRemappingNeededByAnyFeature() {
            KeystrokeNotificationManager.shared.applyHIDRemapping(context: "CapsLockModifierShortcut")
        } else {
            KeystrokeNotificationManager.shared.removeHIDRemappingIfNotNeeded()
        }
    }

    static func resetKeyboardShortcut(
        for shortcutName: KeyboardShortcuts.Name,
        to previousShortcut: KeyboardShortcuts.Shortcut? = nil
    ) {
        if let previousShortcut = previousShortcut {
            KeyboardShortcuts.setShortcut(previousShortcut, for: shortcutName)
        } else {
            KeyboardShortcuts.reset(shortcutName)
        }
    }

    // MARK: - Caps Lock State

    private static var isCapsLockPressed: Bool = false

    private static func onCapsDown() {
        guard !isCapsLockPressed else { return }
        isCapsLockPressed = true

        let usingCapsLockMain = Defaults[TranscriptionConfigKeys.shortcutType] == .capsLock
        let usingCapsLockAlt = !TranscriptionShortcutType.capsLockAlternateSlotNames.isEmpty
        if usingCapsLockMain || usingCapsLockAlt {
            isToggleTranscriptionShortcutHeld = true
        }

        /// Don't execute other caps lock shortcuts in transcription hold mode.
        let activatedTranscriptionHoldMode = handleTranscriptionOnCapsDownIfNeeded()
        if activatedTranscriptionHoldMode {
            return
        }

        executeCapsLockTappedShortcutsIfNeeded()
    }

    private static func onCapsUp() {
        guard isCapsLockPressed else { return }
        isCapsLockPressed = false

        let usingCapsLockMain = Defaults[TranscriptionConfigKeys.shortcutType] == .capsLock
        let usingCapsLockAlt = !TranscriptionShortcutType.capsLockAlternateSlotNames.isEmpty
        if usingCapsLockMain || usingCapsLockAlt {
            isToggleTranscriptionShortcutHeld = false
        }

        handleTranscriptionOnCapsUpIfNeeded()
    }

    // MARK: - Right Command State

    private static var isRightCommandPressed: Bool = false

    private static func onRightCommandDown() {
        guard !isRightCommandPressed else { return }
        isRightCommandPressed = true

        let usingRightCommandMain = Defaults[TranscriptionConfigKeys.shortcutType] == .rightCommand
        let usingRightCommandAlt = TranscriptionShortcutType.alternateSlotIndex(for: .rightCommand) != nil
        if usingRightCommandMain || usingRightCommandAlt {
            isToggleTranscriptionShortcutHeld = true
        }

        handleTranscriptionOnRightCommandDownIfNeeded()
    }

    private static func onRightCommandUp() {
        guard isRightCommandPressed else { return }
        isRightCommandPressed = false

        let usingRightCommandMain = Defaults[TranscriptionConfigKeys.shortcutType] == .rightCommand
        let usingRightCommandAlt = TranscriptionShortcutType.alternateSlotIndex(for: .rightCommand) != nil
        if usingRightCommandMain || usingRightCommandAlt {
            isToggleTranscriptionShortcutHeld = false
        }

        handleTranscriptionOnRightCommandUpIfNeeded()
    }

    private static func registerRemappedKeyConsumerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .remappedKeyConsumer) {
            Task { @MainActor in
                Self.onCapsDown()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .remappedKeyConsumer) {
            Task { @MainActor in
                Self.onCapsUp()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .remappedKeyConsumerShifted) {
            Task { @MainActor in
                CapsLockToggleManager.toggle()
            }
        }

        registerRightCommandHandler()
    }

    private static func registerRightCommandHandler() {
        KeystrokeNotificationManager.shared.onRightCommandStateChanged = { isPressed in
            Task { @MainActor in
                if isPressed {
                    Self.onRightCommandDown()
                } else {
                    Self.onRightCommandUp()
                }
            }
        }
    }

    // MARK: - Execution

    private static func executeShortcut(name: KeyboardShortcuts.Name) {
        AnalyticsManager.shortcutPressed(for: name.rawValue, panelOpened: false)

        switch name {
        // Speech transcription shortcut - all pool slots behave identically.
        case .toggleTranscription,
             .toggleTranscription2,
             .toggleTranscription3,
             .toggleTranscription4,
             .toggleTranscription5:
            guard Defaults[.transcriptionEnabled] else { return }
            TranscriptionManager.shared.toggle()

        default:
            print("KeyboardShortcut not handled: \(name)")
        }
    }

    static func executeCapsLockTappedShortcutsIfNeeded() {
        let eventMods = KeystrokeNotificationManager.shared.getCurrentModifierStates()
        // Alternate dictation pool slots (1..4) fire via the library's own onKeyDown handler.
        // Including them here would double-toggle dictation for any user who binds a CapsLock-containing
        // combo into an alternate. Slot 0 (`.toggleTranscription`) stays in the loop so CapsLock-mode
        // toggle behavior keeps working.
        // Alternate slots that are capsLock-type are detected here (not via onKeyDown/onKeyUp).
        // All other alternates (custom/fn) are excluded to prevent double-firing.
        let capsLockAlternateRawValues = Set(
            TranscriptionShortcutType.capsLockAlternateSlotNames.map { $0.rawValue }
        )
        let otherAlternateRawValues = Set(
            TranscriptionShortcutType.customShortcutNames.dropFirst().map { $0.rawValue }
        ).subtracting(capsLockAlternateRawValues)

        for name in KeyboardShortcuts.Name.allCases {
            if otherAlternateRawValues.contains(name.rawValue) { continue }
            if let shortcut = KeyboardShortcuts.getShortcut(for: name),
               shortcut.key == .capsLock {
                let shortcutMods = shortcut.modifiers
                let matches = [
                    (eventMods.command, shortcutMods.contains(.command)),
                    (eventMods.control, shortcutMods.contains(.control)),
                    (eventMods.shift, shortcutMods.contains(.shift)),
                    (eventMods.option, shortcutMods.contains(.option))
                ].allSatisfy { $0.0 == $0.1 }
                if !matches { continue }
                executeShortcut(name: name)
            }
        }
    }

    // MARK: - Dev Build Coexistence

    /// Start observing dev build detection service (Release builds only)
    static func observeDevBuildDetection() {
        #if !DEBUG
        DevBuildDetectionService.shared.$isDevBuildRunning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { isDevBuildRunning in
                if isDevBuildRunning {
                    disableAllForDevBuildCoexistence()
                } else {
                    restoreAfterDevBuildCoexistence()
                }
            }
            .store(in: &devBuildCancellables)
        #endif
    }

    /// Disable all shortcuts when dev build is running
    private static func disableAllForDevBuildCoexistence() {
        guard !isDisabledForDevBuild else { return }
        isDisabledForDevBuild = true

        // Disable all registered shortcuts
        var allShortcuts: [KeyboardShortcuts.Name] = []
        allShortcuts.append(contentsOf: TranscriptionShortcutType.customShortcutNames)
        allShortcuts.append(.remappedKeyConsumer)
        allShortcuts.append(.remappedKeyConsumerShifted)
        KeyboardShortcuts.disable(allShortcuts)

        TranscriptionKeysManager.shared.stop()
    }

    /// Restore shortcuts when dev build is no longer running
    private static func restoreAfterDevBuildCoexistence() {
        guard isDisabledForDevBuild else { return }
        isDisabledForDevBuild = false

        // Re-enable shortcuts based on their previous state
        // remapped key consumers are always enabled
        KeyboardShortcuts.enable([.remappedKeyConsumer, .remappedKeyConsumerShifted])

        // Re-enable transcription shortcut if the current type uses the KeyboardShortcuts library.
        // Fn, Right Command, and double-tap types are handled via their own event paths.
        let shortcutType = Defaults[TranscriptionConfigKeys.shortcutType]
        if Defaults[.transcriptionEnabled] {
            if shortcutType.usesKeyboardShortcutsLibrary {
                KeyboardShortcuts.enable(TranscriptionShortcutType.activeCustomShortcutNames)
            }
            TranscriptionKeysManager.shared.start()
        }
    }
}
