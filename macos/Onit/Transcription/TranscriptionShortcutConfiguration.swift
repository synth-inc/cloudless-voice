// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionShortcutConfiguration.swift
//  Onit
//
//  Created by Kévin Naudin on 01/12/2026.
//

import Defaults
import Foundation
import KeyboardShortcuts

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

// MARK: - Shortcut Type

enum TranscriptionShortcutType: String, Codable, CaseIterable, Defaults.Serializable {
    case capsLock
    case fn
    case rightCommand
    case commandDoubleTap
    case controlDoubleTap
    case custom

    @MainActor
    var displayName: String {
        switch self {
        case .capsLock: return String.localized("Caps Lock", table: "Transcription")
        case .fn: return String.localized("Fn", table: "Transcription")
        case .rightCommand: return String.localized("Right Command", table: "Transcription")
        case .commandDoubleTap: return String.localized("Double-tap Command", table: "Transcription")
        case .controlDoubleTap: return String.localized("Double-tap Control", table: "Transcription")
        case .custom: return String.localized("Custom Shortcut", table: "Transcription")
        }
    }

    @MainActor
    var shortDisplayName: String {
        switch self {
        case .capsLock: return String.localized("Caps Lock", table: "Transcription")
        case .rightCommand: return String.localized("Right ⌘", table: "Transcription")
        case .commandDoubleTap: return String.localized("⌘⌘", table: "Transcription")
        case .controlDoubleTap: return String.localized("⌃⌃", table: "Transcription")
        case .fn: return String.localized("Fn", table: "Transcription")
        case .custom: return String.localized("Custom", table: "Transcription")
        }
    }

    @MainActor
    var displayNameSymbol: String {
        // When the most-recently-used trigger is an alternate slot (index > 0), show its text
        // so users switching between keyboards see the shortcut they actually just used.
        if let alternateText = TranscriptionShortcutType.mostRecentlyUsedAlternateText {
            return alternateText
        }
        switch self {
        case .capsLock: return "⇪"
        case .rightCommand: return "Right ⌘"
        case .commandDoubleTap: return "⌘⌘"
        case .controlDoubleTap: return "⌃⌃"
        case .fn: return "fn"
        case .custom: return TranscriptionShortcutType.customShortcutNames[0].shortcutText
        }
    }

    /// Whether this shortcut type supports hold-to-record mode.
    /// False for modifier keys commonly used in keyboard shortcuts (command, control),
    /// where holding down while pressing another key would conflict.
    var supportsHold: Bool {
        switch self {
        case .capsLock, .rightCommand, .fn, .custom: return true
        case .commandDoubleTap, .controlDoubleTap: return false
        }
    }

    // MARK: - Custom Shortcut Pool

    /// Maximum number of dictation shortcut slots a user can bind (slot 0 = main, 1..4 = alternates).
    static let customShortcutMaxCount: Int = KeyboardShortcuts.Name.transcriptionShortcutPool.count

    /// The full 5-slot pool (slot 0 = legacy `.toggleTranscription` / main, 1..4 = alternates).
    static var customShortcutNames: [KeyboardShortcuts.Name] {
        KeyboardShortcuts.Name.transcriptionShortcutPool
    }

    /// The currently active slots, clamped to 1..customShortcutMaxCount.
    static var activeCustomShortcutNames: [KeyboardShortcuts.Name] {
        let count = max(1, min(Defaults[TranscriptionConfigKeys.customShortcutCount], customShortcutMaxCount))
        return Array(customShortcutNames.prefix(count))
    }

    /// Slot names for alternates configured as capsLock type (used by CapsLock HID handler).
    static var capsLockAlternateSlotNames: [KeyboardShortcuts.Name] {
        let types = Defaults[TranscriptionConfigKeys.alternateSlotTypes]
        let pool = customShortcutNames
        return types.enumerated().compactMap { i, rawValue in
            rawValue == TranscriptionShortcutType.capsLock.rawValue ? pool[i + 1] : nil
        }
    }

    /// Returns the slot index for a given type configured as an alternate, or nil if not configured.
    static func alternateSlotIndex(for type: TranscriptionShortcutType) -> Int? {
        let types = Defaults[TranscriptionConfigKeys.alternateSlotTypes]
        guard let altIndex = types.firstIndex(of: type.rawValue) else { return nil }
        return altIndex + 1 // slot 0 is main; alternates start at 1
    }

    /// Slot index of the Fn alternate, if any.
    static var fnAlternateSlotIndex: Int? { alternateSlotIndex(for: .fn) }

    /// If the most-recently-used trigger was an alternate slot (index > 0) and it has a binding,
    /// returns its shortcut text. Otherwise returns nil so callers fall back to the main symbol.
    @MainActor
    static var mostRecentlyUsedAlternateText: String? {
        let active = activeCustomShortcutNames
        let mru = max(0, min(Defaults[TranscriptionConfigKeys.lastUsedCustomShortcutIndex], active.count - 1))
        guard mru > 0, mru < active.count else { return nil }
        // For special-type alternates (capsLock/fn), return the type's display symbol.
        let types = Defaults[TranscriptionConfigKeys.alternateSlotTypes]
        let altIndex = mru - 1
        if altIndex < types.count,
           let specialType = TranscriptionShortcutType(rawValue: types[altIndex]),
           specialType != .custom {
            // Return the symbol directly - calling displayNameSymbol would recurse back into this function.
            return specialType.shortDisplayName
        }
        let text = active[mru].shortcutText
        return text.isEmpty ? nil : text
    }

    /// Returns the default keyboard shortcut for this type.
    /// Returns nil for types handled outside the KeyboardShortcuts library.
    var defaultShortcut: KeyboardShortcuts.Shortcut? {
        switch self {
        case .capsLock:
            return .init(.capsLock, modifiers: [])
        case .rightCommand, .commandDoubleTap, .controlDoubleTap:
            // Handled via direct flagsChanged monitoring in KeystrokeNotificationManager
            return nil
        case .fn:
            // Fn key is handled via flagsChanged events in KeystrokeNotificationManager
            return nil
        case .custom:
            return .init(.space, modifiers: [.option])
        }
    }

    /// Whether this shortcut type requires HID remapping.
    var requiresHIDRemapping: Bool {
        return self == .capsLock
    }

    /// Whether this shortcut type uses the Fn key (handled via KeystrokeNotificationManager).
    var usesFnKey: Bool {
        return self == .fn
    }

    /// Whether this shortcut type routes through the KeyboardShortcuts library (.toggleTranscription).
    /// False for types that have their own event paths (Fn, Right Command, double-tap types).
    var usesKeyboardShortcutsLibrary: Bool {
        switch self {
        case .capsLock, .custom: return true
        case .fn, .rightCommand, .commandDoubleTap, .controlDoubleTap: return false
        }
    }

    /// Apply this shortcut type to the transcription shortcut
    /// - Parameters:
    ///   - previousType: The previous shortcut type, used to determine if we need to remove HID remapping.
    ///   - forceDefaultOnSwitch: When true, `.custom` is reset to its default shortcut even if a value is
    ///     already stored. UI call sites (settings/onboarding) pass `true` so re-selecting "Custom" seeds
    ///     a fresh default; background callers (app launch) must keep `false` to preserve the user's shortcut.
    @MainActor
    func apply(previousType: TranscriptionShortcutType? = nil, forceDefaultOnSwitch: Bool = false) {
        // Track shortcut type change
        if let previous = previousType, previous != self {
            AnalyticsManager.Transcription.shortcutTypeChanged(
                oldValue: previous.rawValue,
                newValue: self.rawValue
            )
        }

        let pool = TranscriptionShortcutType.customShortcutNames
        let active = TranscriptionShortcutType.activeCustomShortcutNames
        let inactive = Array(pool.dropFirst(active.count))

        // Slot 0 (main) handling per type.
        switch self {
        case .fn, .rightCommand, .commandDoubleTap, .controlDoubleTap:
            // Handled directly by KeystrokeNotificationManager - clear slot 0 to avoid a library ghost trigger.
            KeyboardShortcuts.setShortcut(nil, for: .toggleTranscription)
        case .capsLock:
            // Seed slot 0 with CapsLock. The library won't actually fire on bare CapsLock; the HID remap path triggers.
            if let shortcut = defaultShortcut {
                KeyboardShortcuts.setShortcut(shortcut, for: .toggleTranscription)
            }
        case .custom:
            // Preserve the user's custom binding across launches: only seed the default when
            // nothing is stored, or when the UI explicitly requests a reset.
            if let shortcut = defaultShortcut {
                let hasStoredShortcut = KeyboardShortcuts.getShortcut(for: .toggleTranscription) != nil
                if !hasStoredShortcut || forceDefaultOnSwitch {
                    KeyboardShortcuts.setShortcut(shortcut, for: .toggleTranscription)
                }
            }
        }

        // Slot 0 enable state: disabled for non-library types (fn, rightCommand, double-taps).
        if usesKeyboardShortcutsLibrary {
            KeyboardShortcuts.enable([.toggleTranscription])
        } else {
            KeyboardShortcuts.disable([.toggleTranscription])
        }

        // Alternate slots always fire via the library regardless of main type -
        // this lets CapsLock or Fn mode coexist with extra keyboard-specific shortcuts.
        let alternates = Array(active.dropFirst())
        if !alternates.isEmpty {
            KeyboardShortcuts.enable(alternates)
        }
        if !inactive.isEmpty {
            KeyboardShortcuts.disable(inactive)
        }

        // Handle HID remapping: always re-apply the full needed set after any type change.
        if requiresHIDRemapping || previousType?.requiresHIDRemapping == true {
            if KeystrokeNotificationManager.shared.isHIDRemappingNeededByAnyFeature() {
                KeystrokeNotificationManager.shared.applyHIDRemapping(context: "TranscriptionTypeChange-\(self.rawValue)")
            } else {
                KeystrokeNotificationManager.shared.removeHIDRemappingIfNotNeeded()
            }
        }
    }
}

