// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarMicrophone.swift
//  Onit
//
//  Created by Loyd Kim on 3/12/26.
//

import AppKit
import Defaults

@MainActor
final class MenuBarMicrophone: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.action = nil
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = String.localized("Microphone", table: "MenuBar")
        self.populateDropdownSubmenu()
    }

    // MARK: - States

    private var dropdownSubmenu = NSMenu()

    // MARK: - Private Variables

    private let microphoneInputManager = MicrophoneInputManager.shared

    private var currentInputDevice: MicrophoneInputDevice? {
        return Defaults[.transcriptionInputDevice]
    }

    // MARK: - Private Functions

    private func populateDropdownSubmenu() {
        self.dropdownSubmenu.removeAllItems()

        if self.microphoneInputManager.hasPermission {
            self.populateWithAvailableDevices()
        } else {
            self.populateWithGrantPermissionItem()
        }

        self.submenu = self.dropdownSubmenu
    }

    private func populateWithAvailableDevices() {
        guard !self.microphoneInputManager.availableDevices.isEmpty
        else {
            let noDevicesItem = NSMenuItem(
                title: String.localized("No microphones found", table: "MenuBar"),
                action: nil,
                keyEquivalent: ""
            )
            noDevicesItem.isEnabled = false
            self.dropdownSubmenu.addItem(noDevicesItem)
            return
        }

        for inputDevice in self.microphoneInputManager.availableDevices {
            #if DEBUG || ONIT_BETA
            let title = "\(inputDevice.name) [\(inputDevice.source?.description ?? "nil")]"
            #else
            let title = inputDevice.name
            #endif
            let item = NSMenuItem(
                title: title,
                action: #selector(self.selectInputDevice(_:)),
                keyEquivalent: ""
            )

            item.target = self
            item.representedObject = inputDevice.id
            item.state = inputDevice.id == self.currentInputDevice?.id ? .on : .off

            self.dropdownSubmenu.addItem(item)
        }

        self.dropdownSubmenu.addItem(.separator())

        let autoSwitchItem = NSMenuItem(
            title: String.localized("Auto-Switch to New Mics", table: "MenuBar"),
            action: #selector(self.toggleAutoSwitchMicrophone),
            keyEquivalent: ""
        )
        autoSwitchItem.target = self
        autoSwitchItem.state = Defaults[.transcriptionAutoSwitchMicrophone] ? .on : .off
        self.dropdownSubmenu.addItem(autoSwitchItem)
    }

    private func populateWithGrantPermissionItem() {
        let item = NSMenuItem(
            title: String.localized("Grant Microphone Permission...", table: "MenuBar"),
            action: #selector(self.grantMicrophonePermission),
            keyEquivalent: ""
        )

        item.target = self

        self.dropdownSubmenu.addItem(item)
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let inputDeviceID = sender.representedObject as? String else { return }

        Task {
            await self.microphoneInputManager.setInputDevice(inputDeviceID)
        }
    }

    @objc private func toggleAutoSwitchMicrophone() {
        Defaults[.transcriptionAutoSwitchMicrophone].toggle()
    }

    @objc private func grantMicrophonePermission() {
        Task {
            await self.microphoneInputManager.requestPermissionOrOpenSettings()
        }
    }
}
