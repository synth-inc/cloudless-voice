// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarCheckForPermissions.swift
//  Onit
//
//  Created by Loyd Kim on 9/25/25.
//

import AppKit
import Defaults

final class MenuBarCheckForPermissions: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.image = self.statusDot
        self.action = #selector(openPermissionSettings)
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = String.localized(" Allow access...", table: "MenuBar")
    }

    // MARK: - Private Variables

    private lazy var statusDot = self.drawStatusDot(NSColor.red500)

    // MARK: - Private Functions

    @MainActor
    @objc private func openPermissionSettings() {
        // Priority order: Accessibility > Screen Recording > Microphone
        if AccessibilityPermissionManager.shared.accessibilityPermissionStatus != .granted {
            AccessibilityPermissionManager.shared.requestPermission()
        }
        /// Commented out for now until non-AX becomes the default state.
//        else if Defaults[.quickEditConfig].isEnabled && !ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled {
//            Task {
//                _ = await ScreenRecordingPermissionManager.shared.requestScreenRecordingPermission()
//            }
//        }
        else if Defaults[.transcriptionEnabled] && !MicrophoneInputManager.shared.hasPermission {
            Task {
                await MicrophoneInputManager.shared.requestPermissionOrOpenSettings()
            }
        }
    }
}
