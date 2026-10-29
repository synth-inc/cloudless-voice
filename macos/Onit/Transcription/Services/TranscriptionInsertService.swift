// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionInsertService.swift
//  Onit
//
//  Created by Kévin Naudin on 08/06/2026.
//

import AppKit
import ApplicationServices
import Defaults
import Foundation

@MainActor
class TranscriptionInsertService {

    /// Bundle identifier of the macOS Spotlight search panel. The AX insertion workaround is
    /// gated on EXACT equality with this string - never a category like "panel" or "non-activating".
    static let spotlightBundleId = "com.apple.Spotlight"

    /// AX messaging timeout (seconds) for the focus probe, so a hung foreground app cannot stall
    /// insertion. On timeout / any AX error we fall through to the paste path.
    private static let axMessagingTimeout: Float = 0.2

    // MARK: - Public Functions

    /// Inserts the transcribed text at the current cursor position.
    ///
    /// Normally this synthesizes a ⌘V paste. As a Spotlight-only workaround, when the true focused
    /// element is the Spotlight search field (see `shouldUseSpotlightAXInsert`), the text is written
    /// directly via the Accessibility API - because Spotlight is a non-activating panel and the
    /// paste would otherwise land on the process underneath it.
    ///
    /// - Parameters:
    ///   - text: The text to insert.
    ///   - targetPid: If provided, posts the paste event directly to this process.
    /// - Returns: `true` when the Spotlight Accessibility path handled the insertion (the caller
    ///   should then skip undo / correction / phantom-space follow-ups that assume a persistent
    ///   `targetPid`). `false` when the normal paste path was used (behavior identical to before).
    @discardableResult
    func insertText(_ text: String, targetPid: pid_t? = nil) async -> Bool {
        guard !text.isEmpty else {
            return false
        }

        // Spotlight-only pre-check. Strictly gated and fully fail-safe: any miss falls through
        // to the unchanged paste path below.
        if Defaults[.spotlightAXInsertEnabled], insertViaSpotlightAXIfFocused(text) {
            return true
        }

        // Use PasteboardManager for reliable insertion
        await PasteboardManager.shared.insertViaPaste(text, targetPid: targetPid)
        return false
    }

    // MARK: - Spotlight Accessibility Insertion

    /// Pure decision function for the Spotlight AX insertion workaround.
    ///
    /// Returns `true` ONLY when the currently focused element is the Spotlight search field:
    /// exact bundle-id equality with `com.apple.Spotlight`, an AX text-field role, and a settable
    /// `kAXSelectedText` attribute. Every other app (Safari, Chrome, Terminal, Electron, …) and any
    /// nil/false input returns `false`, so the workaround can never affect a non-Spotlight insertion.
    static func shouldUseSpotlightAXInsert(
        bundleId: String?,
        axRole: String?,
        selectedTextSettable: Bool
    ) -> Bool {
        return bundleId == spotlightBundleId
            && axRole == (kAXTextFieldRole as String)
            && selectedTextSettable
    }

    /// Resolves the true system-wide AX focus and, if it is the Spotlight search field, writes the
    /// text at the cursor via `kAXSelectedText`. Returns `false` (falling through to paste) on any
    /// AX error, timeout, nil value, or a focused element that fails the strict Spotlight gate.
    private func insertViaSpotlightAXIfFocused(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axMessagingTimeout)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
                  systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedObj = focusedRef,
              CFGetTypeID(focusedObj) == AXUIElementGetTypeID()
        else { return false }
        let focused = focusedObj as! AXUIElement

        // Cap messaging on the focused element too, so reads/writes below can't hang.
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        // Owning pid -> bundle identifier. Short-circuit on the EXACT Spotlight bundle id
        // before any further AX round-trips, so the common (non-Spotlight) insertion - which
        // is every normal paste - costs a single AX call and can't stall on the role/settable
        // reads. Anything but Spotlight falls straight through to the paste path.
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Self.spotlightBundleId
        else { return false }

        // Confirmed Spotlight: verify it's a settable text field before writing.
        var roleRef: AnyObject?
        let axRole: String? = AXUIElementCopyAttributeValue(
            focused, kAXRoleAttribute as CFString, &roleRef) == .success ? roleRef as? String : nil
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)

        guard Self.shouldUseSpotlightAXInsert(
            bundleId: Self.spotlightBundleId,
            axRole: axRole,
            selectedTextSettable: settable.boolValue
        ) else {
            return false
        }

        let setResult = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString)
        guard setResult == .success else {
            log.warning("[SpotlightAX] set kAXSelectedText failed (code \(setResult.rawValue)); falling back to paste")
            return false
        }

        log.info("[SpotlightAX] inserted \(text.count) chars into Spotlight via Accessibility")
        AnalyticsManager.Transcription.spotlightAXInsertUsed(textLength: text.count)
        return true
    }
}
