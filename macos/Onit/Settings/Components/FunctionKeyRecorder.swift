// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FunctionKeyRecorder.swift
//  Onit
//
//  Created by Kévin Naudin on 01/12/2026.
//

import AppKit
import KeyboardShortcuts
import SwiftUI

/// A custom keyboard shortcut recorder that allows function keys (F1-F20) without modifiers.
/// The standard KeyboardShortcuts.Recorder doesn't allow recording function keys alone.
struct FunctionKeyRecorder: View {
    let shortcutName: KeyboardShortcuts.Name
    var showClearButton: Bool = true
    var onShortcutChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    @StateObject private var recorder = FunctionKeyRecorderModel()

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleRecording) {
                Text(displayText)
                    .font(.system(size: 12))
                    .frame(minWidth: 80)
            }
            .buttonStyle(.bordered)

            if showClearButton && recorder.currentShortcut != nil && !recorder.isRecording {
                Button(action: clearShortcut) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            recorder.shortcutName = shortcutName
            recorder.onShortcutChange = onShortcutChange
            recorder.currentShortcut = KeyboardShortcuts.getShortcut(for: shortcutName)
        }
    }

    @MainActor
    private var displayText: String {
        if recorder.isRecording {
            return String.localized("Press a key...", table: "Settings")
        } else if recorder.currentShortcut != nil {
            let text = shortcutName.shortcutText
            return text.isEmpty ? String.localized("Record Shortcut", table: "Settings") : text
        } else {
            return String.localized("Record Shortcut", table: "Settings")
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording()
        }
    }

    private func clearShortcut() {
        KeyboardShortcuts.setShortcut(nil, for: shortcutName)
        recorder.currentShortcut = nil
        onShortcutChange?(nil)
    }

    private func shortcutDisplayString(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        var result = ""

        if shortcut.modifiers.contains(.control) { result += "^" }
        if shortcut.modifiers.contains(.option) { result += "⌥" }
        if shortcut.modifiers.contains(.shift) { result += "⇧" }
        if shortcut.modifiers.contains(.command) { result += "⌘" }

        if let key = shortcut.key {
            result += functionKeyName(for: key)
        }

        return result
    }

    private func functionKeyName(for key: KeyboardShortcuts.Key) -> String {
        switch key {
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        case .space: return "␣"
        case .return: return "⏎"
        case .delete: return "⌫"
        case .escape: return "⎋"
        case .tab: return "⇥"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        default:
            let char = key.rawValue
            if char >= 0 && char <= 127, let scalar = UnicodeScalar(char) {
                return String(Character(scalar)).uppercased()
            }
            return String.localized("Key %d", table: "Settings", char)
        }
    }
}

@MainActor
class FunctionKeyRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var currentShortcut: KeyboardShortcuts.Shortcut?

    var shortcutName: KeyboardShortcuts.Name?
    var onShortcutChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    private nonisolated(unsafe) var localMonitor: Any?

    nonisolated init() {}

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func startRecording() {
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            // Handle escape to cancel recording
            if event.keyCode == 53 {
                Task { @MainActor in
                    self.stopRecording()
                }
                return nil
            }

            // Create shortcut from the event
            if let shortcut = self.createShortcut(from: event) {
                Task { @MainActor in
                    if let name = self.shortcutName {
                        KeyboardShortcuts.setShortcut(shortcut, for: name)
                    }
                    self.currentShortcut = shortcut
                    self.onShortcutChange?(shortcut)
                    self.stopRecording()
                }
                return nil
            }

            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private nonisolated func createShortcut(from event: NSEvent) -> KeyboardShortcuts.Shortcut? {
        let key = KeyboardShortcuts.Key(rawValue: Int(event.keyCode))

        var modifiers: NSEvent.ModifierFlags = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }

        // Allow function keys without modifiers
        let isFunctionKey = isFunctionKeyCode(event.keyCode)

        // For non-function keys, require at least one modifier (excluding shift alone)
        if !isFunctionKey {
            let hasValidModifier = modifiers.contains(.command) ||
                                   modifiers.contains(.option) ||
                                   modifiers.contains(.control)
            if !hasValidModifier {
                return nil
            }
        }

        return KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
    }

    private nonisolated func isFunctionKeyCode(_ keyCode: UInt16) -> Bool {
        // Key codes for F1-F20
        let functionKeyCodes: Set<UInt16> = [
            122, // F1
            120, // F2
            99,  // F3
            118, // F4
            96,  // F5
            97,  // F6
            98,  // F7
            100, // F8
            101, // F9
            109, // F10
            103, // F11
            111, // F12
            105, // F13
            107, // F14
            113, // F15
            106, // F16
            64,  // F17
            79,  // F18
            80,  // F19
            90,  // F20
        ]
        return functionKeyCodes.contains(keyCode)
    }
}
