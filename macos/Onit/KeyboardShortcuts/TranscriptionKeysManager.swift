// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionKeysManager.swift
//  Onit
//
//  Created by Loyd Kim on 4/24/26.
//

import AppKit
import Carbon
import CoreGraphics
import Defaults
import Foundation

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

@MainActor
final class TranscriptionKeysManager {
    // MARK: - Singleton

    static let shared = TranscriptionKeysManager()

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var permissionRetryTimer: Timer?
    
    /// We create a run loop source to the `CGEventTap` that allows us to execute our custom keyboard shortcut callbacks so that macOS can actually respond to keystroke events.
    /// Without explicitly removing these run loop sources, we end up keeping references to invalidated sources, resulting in the accumulation of memory leaks per `start()`/`stop()` cycle.
    /// Therefore, we must run `CFRunLoopRemoveSource` to tear these down and prevent memory leaks.
    /// However, `CFRunLoopRemoveSource` requires the *exact same* `CFRunLoopSource` handle we originally added.
    ///     We can't re-derive a run loop source, as calling `CFMachPortCreateRunLoopSource()` in `start()` a second time creates a *new, different* source.
    /// By caching our run loop source here, we can ensure we properly tear it down when calling `resetRunLoopSourceIfNeeded()`.
    private var runLoopSource: CFRunLoopSource?

    /// Only ever written to; never read from. Held purely to keep `cachedKeyboardLayoutPointer`'s backing bytes alive.
    /// `TISInputSource` owns the `CFData` that the pointer points into.
    /// Without this ARC-held reference, the source would deallocate at the end of `getKeyboardLayoutPointer()`, freeing those bytes.
    /// The next `UCKeyTranslate` call would then read freed memory, potentially producing undefined behavior, crashes, or garbage characters.
    private var cachedInputSourceForKeyboardLayoutPointer: TISInputSource?
    
    /// Caches the active keyboard layout so `getBaseCharacter(from:)` avoids a TIS lookup + `CFDataGetBytePtr` on every keystroke.
    /// Invalidated on `kTISNotifySelectedKeyboardInputSourceChanged` (see `startObservingInputSourceChanges()`).
    private var cachedKeyboardLayoutPointer: UnsafePointer<UCKeyboardLayout>?

    private var isEnabled: Bool = false
    private var inputSourceObserverActive: Bool = false

    // MARK: - Initializer

    private init() {}
    
    // MARK: - Private Variables

    private let permissionRetryInterval: TimeInterval = 3.0

    /// Returns `true` if at least one active shortcut slot uses a type that can be physically held
    /// (capsLock, fn, rightCommand, or custom). Double-tap types (commandDoubleTap, controlDoubleTap)
    /// return `false` - they can't be held, so C/V interception would never fire and we'd risk
    /// swallowing the user's real copy/paste keystrokes.
    private var anyActiveShortcutSupportsHold: Bool {
        let mainType = Defaults[TranscriptionConfigKeys.shortcutType]
        if mainType.supportsHold { return true }

        let alternateTypes = Defaults[TranscriptionConfigKeys.alternateSlotTypes].compactMap {
            TranscriptionShortcutType(rawValue: $0)
        }
        return alternateTypes.contains { $0.supportsHold }
    }

    // MARK: - Public Functions: Start & Stop

    /// Installs a `CGEventTap` that observes `keyDown` events at the HID layer.
    /// This allows us to implement custom keyboard shortcuts that the `KeyboardShortcuts` library can't.
    /// No-ops when a tap is already installed (`isEnabled` == `true`), so this method is safe to call repeatedly.
    /// Also no-ops when every active shortcut slot is a double-tap type (commandDoubleTap / controlDoubleTap)
    /// because those types can never be "held", so the C/V shortcuts would never fire - and more importantly,
    /// an active CGEventTap could silently intercept the user's real Cmd+C / Cmd+V copy-paste commands.
    func start() {
        guard !isEnabled else { return }

        // Defense-in-depth: even though AppDelegate short-circuits on test
        // boot, some code paths construct managers directly. Don't install
        // the global event tap during XCTest - the user's real Onit.app
        // already has one, and a second tap from the test process would
        // double-fire dictation hotkeys.
        guard !TestEnvironment.isRunningTests() else {
            log.info("TranscriptionKeysManager: XCTest detected - skipping CGEventTap installation")
            return
        }

        guard anyActiveShortcutSupportsHold else {
            log.info("TranscriptionKeysManager: all active shortcuts are double-tap types - skipping CGEventTap installation to avoid intercepting copy/paste.")
            return
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon
                else {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<TranscriptionKeysManager>.fromOpaque(refcon).takeUnretainedValue()

                /// Re-enable event tap if disabled by the system (timeout / user input).
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.eventTap {
                        CGEvent.tapEnable(
                            tap: tap,
                            enable: true
                        )
                    }
                    /// Note: Calling `@MainActor` methods of `manager` is safe here because we install this method on `CFRunLoopGetMain`.
                    manager.reportCgEventTapAutoDisable(reason: type)
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown
                else {
                    return Unmanaged.passUnretained(event)
                }

                /// Note: Calling `@MainActor` methods of `manager` is safe here because we install this method on `CFRunLoopGetMain`.
                let shouldConsumeKeyStroke = manager.handleKeyDown(event: event)

                return shouldConsumeKeyStroke ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque() /// NOTE: If this class ever stops being a singleton in a future update, this line would become unsafe. Just flagging.
        )

        guard let tap = eventTap
        else {
            /// If we entered this `else` branch, it most likely means that the user didn't grant accessibility permission.
            /// We no-op here so that the rest of Onit keeps working, but we start a retry poll so granting permission mid-session recovers the tap automatically.
            
            log.warning("TranscriptionKeysManager: CGEvent.tapCreate returned nil - copy/paste last transcription shortcuts will be non-functional. Most likely cause: accessibility permission not granted.")
            AnalyticsManager.Transcription.transcriptionKeysTapCreationFailed()
            
            startPermissionRetryIfNeeded()
            return
        }

        guard CGEvent.tapIsEnabled(tap: tap)
        else {
            /// There is a known macOS "silent disable race" where `CGEvent.tapCreate` occasionally returns a non-nil tap. For example:
            ///     * After re-signing the app bundle.
            ///     * Launching Onit from different launch services (Finder double-click, Dock click, `open` command), rather than direct binary execution.
            /// This results in a false-positive that prevents our custom shortcut combos (e.g. "copy last transcription", "paste last transcription") from executing.
            /// We treat this edge case as a tap creation failure, so we invalidate (clean up) the tap and then schedule a retry.

            log.warning("TranscriptionKeysManager: CGEvent.tapCreate returned a tap that reports !isEnabled - silent disable race. Cleaning up and scheduling retry.")
            AnalyticsManager.Transcription.transcriptionKeysTapCreationFailed()
            
            CFMachPortInvalidate(tap)
            startPermissionRetryIfNeeded()
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            source,
            .commonModes
        )

        CGEvent.tapEnable(
            tap: tap,
            enable: true
        )

        isEnabled = true

        stopPermissionRetry()
        startObservingInputSourceChangesIfNeeded()
    }

    /// Tears down the `CGEventTap`, removes the run loop source, stops permission polling, stops observing keyboard-layout changes, and drops the cached keyboard layout.
    /// Safe to call even if no tap is installed.
    func stop() {
        /// Always tear these down, even when `isEnabled` is false, as a failed tap install may have left a dangling retry timer, observer, or cached layout in memory.
        stopPermissionRetry()
        stopObservingInputSourceChanges()
        invalidateKeyboardLayoutCache()
        KeyboardShortcutsManager.isToggleTranscriptionShortcutHeld = false

        guard isEnabled else { return }
        isEnabled = false
        
        resetRunLoopSourceIfNeeded()
        resetEventTapIfNeeded()
    }

    // MARK: - Private Functions: Permission Retry

    /// Polls `AXIsProcessTrusted()` every few seconds and re-attempts tap installation once accessibility permission is granted.
    /// No-ops if a retry is already scheduled.
    private func startPermissionRetryIfNeeded() {
        guard permissionRetryTimer == nil else { return }

        permissionRetryTimer = Timer.scheduledTimer(
            withTimeInterval: permissionRetryInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                if AXIsProcessTrusted() {
                    TranscriptionKeysManager.shared.start()
                }
            }
        }
    }

    private func stopPermissionRetry() {
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
    }

    // MARK: - Private Functions: Input Source Observation & Resets

    private func startObservingInputSourceChangesIfNeeded() {
        guard !inputSourceObserverActive else { return }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in
                    TranscriptionKeysManager.shared.invalidateKeyboardLayoutCache()
                }
            },
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )

        inputSourceObserverActive = true
    }

    private func stopObservingInputSourceChanges() {
        guard inputSourceObserverActive else { return }

        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged),
            nil
        )

        inputSourceObserverActive = false
    }

    private func invalidateKeyboardLayoutCache() {
        cachedInputSourceForKeyboardLayoutPointer = nil
        cachedKeyboardLayoutPointer = nil
    }
    
    private func resetRunLoopSourceIfNeeded() {
        if let runLoopSource = self.runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
            self.runLoopSource = nil
        }
    }
    
    private func resetEventTapIfNeeded() {
        if let eventTap = self.eventTap {
            CGEvent.tapEnable(
                tap: eventTap,
                enable: false
            )
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    // MARK: - Private Functions: Report Auto-Disable

    private func reportCgEventTapAutoDisable(reason: CGEventType) {
        let reasonString: String
        
        switch reason {
        case .tapDisabledByTimeout:
            reasonString = "timeout"
        case .tapDisabledByUserInput:
            reasonString = "user_input"
        default:
            reasonString = "unknown"
        }

        AnalyticsManager.Transcription.transcriptionKeysTapAutoDisabled(reason: reasonString)
    }

    // MARK: - Private Functions: Handle Key Down

    /// Dispatch table for shortcuts active while `.toggleTranscription` is held.
    /// Keyed by the base character produced by the pressed key (rather than keycode) so it works correctly across QWERTY, Dvorak, AZERTY, QWERTZ, Colemak, and non-Latin layouts.
    private let transcriptionHeldShortcuts: [String: () -> Void] = [
        "c": {
            TranscriptionManager.shared.copyLastTranscription(for: .keyboardShortcut)
        },
        "v": {
            TranscriptionManager.shared.pasteLastTranscription(for: .keyboardShortcut)
        },
        "e": {
            TranscriptionManager.shared.editLastTranscription()
        },
    ]

    private func handleKeyDown(event: CGEvent) -> Bool {
        guard KeyboardShortcutsManager.isToggleTranscriptionShortcutHeld,
              let baseCharacter = getBaseCharacter(from: event),
              let handler = transcriptionHeldShortcuts[baseCharacter]
        else {
            return false
        }

        handler()
        
        /// Returning `true` allows us to consume characters that match the cases for our custom shortcut callbacks (`transcriptionHeldShortcuts`/`handler()`).
        /// This prevents our callbacks from also typing the character into the user's current app, leading to more polished UX.
        return true
    }

    // MARK: - Private Functions: Get Base Character

    private func getBaseCharacter(from event: CGEvent) -> String? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        guard let keyboardLayoutPointer = getKeyboardLayoutPointer()
        else {
            return nil
        }

        let modifierKeyState: UInt32 = 0 /// 0 → base character as if no modifiers were held.
        var deadKeyState: UInt32 = 0
        var characterLength = 0
        let charactersMaxLength = 4
        var characters = [UniChar](repeating: 0, count: charactersMaxLength)

        let status = UCKeyTranslate(
            keyboardLayoutPointer,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            modifierKeyState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            charactersMaxLength,
            &characterLength,
            &characters
        )

        guard status == noErr,
              characterLength > 0
        else {
            return nil
        }

        return String(
            utf16CodeUnits: characters,
            count: characterLength
        )
    }
    
    private func getKeyboardLayoutPointer() -> UnsafePointer<UCKeyboardLayout>? {
        if let cached = cachedKeyboardLayoutPointer {
            return cached
        }

        /// Scan for ASCII-compatible keyboard layouts so that shortcuts like "c" (copy last transcription) and "v" (paste last transcription) resolve correctly when a non-Latin IME (Japanese/Korean/Chinese) or a non-Latin layout (Russian/Hindi) is active.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyboardLayoutPointer = extractKeyboardLayoutPointer(from: source)
        {
            cachedInputSourceForKeyboardLayoutPointer = source
            cachedKeyboardLayoutPointer = keyboardLayoutPointer
            return keyboardLayoutPointer
        }

        /// Some keyboard input sources (e.g. Japanese) result in an edge case where no keyboard layout data is returned.
        /// This fallback allows us to re-scan the currently-selected keyboard layout to account for this edge case.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyboardLayoutPointer = extractKeyboardLayoutPointer(from: source)
        {
            cachedInputSourceForKeyboardLayoutPointer = source
            cachedKeyboardLayoutPointer = keyboardLayoutPointer
            return keyboardLayoutPointer
        }

        return nil
    }

    private func extractKeyboardLayoutPointer(from source: TISInputSource) -> UnsafePointer<UCKeyboardLayout>? {
        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        
        let layoutData = unsafeBitCast(
            layoutDataPointer,
            to: CFData.self
        )
        
        return unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
    }
}
