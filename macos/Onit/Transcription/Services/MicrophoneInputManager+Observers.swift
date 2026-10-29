// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MicrophoneInputManager+Observers.swift
//  Onit
//
//  Created by Loyd Kim on 3/5/26.
//

/*
 * Device Observers
 * Permission Check Timer Observer
 */

import AVFoundation
import Defaults
import Foundation

extension MicrophoneInputManager {
    // MARK: - Device Observers

    func setUpDeviceObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceWasConnected),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceWasDisconnected),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
    }

    @objc private func handleDeviceWasConnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.audio)
        else {
            return
        }

        let uniqueID = device.uniqueID
        Task { @MainActor in
            // Check before reloading: if this device is already in the known list it isn't
            // truly new. AVAudioEngine startup (e.g. audio playback in the correction UI)
            // can spuriously fire AVCaptureDeviceWasConnected for existing devices.
            let isActuallyNew = !availableDevices.contains(where: { $0.id == uniqueID })

            let autoSwitchEnabled = Defaults[.transcriptionAutoSwitchMicrophone]

            refreshAvailableDevicesAndAutoSelectIfNeeded(
                autoSelectInputDevice: false,
                skipAutoSelect: autoSwitchEnabled
            )

            if autoSwitchEnabled,
               let newConnectedInputDevice = availableDevices.first(where: { $0.id == uniqueID })
            {
                let hasHighPriorityDevice = !availableDevices
                    .filter { !isLowPriorityInputDevice($0.source) }
                    .isEmpty
                
                let newConnectedInputDeviceIsHighPriority = !isLowPriorityInputDevice(newConnectedInputDevice.source)
                
                let canSwitchToHighPriorityDevice = hasHighPriorityDevice && newConnectedInputDeviceIsHighPriority
                let canSwitchToLowPriorityDevice = !hasHighPriorityDevice && !newConnectedInputDeviceIsHighPriority
                
                if canSwitchToHighPriorityDevice || canSwitchToLowPriorityDevice {
                    if isRecording {
                        // Queue the switch - apply it after the current recording session ends.
                        pendingAutoSwitchDeviceID = uniqueID
                    } else {
                        await setInputDevice(uniqueID)
                    }
                }
            }

            if isActuallyNew {
                HintManager.shared.showTranscriptionAlert(.detectedNewInputDevice)
            }
        }
    }

    @objc private func handleDeviceWasDisconnected(_ notification: Notification) {
        let disconnectedDevice = notification.object as? AVCaptureDevice
        let currentDevice = Defaults[.transcriptionInputDevice]

        let disconnectedUniqueID = disconnectedDevice?.uniqueID
        let wasCurrentDeviceDisconnected = disconnectedUniqueID == currentDevice?.id

        Task { @MainActor in
            /// If the disconnected device was queued for an auto-switch, cancel it.
            if disconnectedUniqueID == pendingAutoSwitchDeviceID {
                pendingAutoSwitchDeviceID = nil
            }

            if wasCurrentDeviceDisconnected {
                Defaults[.transcriptionInputDevice] = nil
                
                if isRecording {
                    stopRecording()
                    error = MicrophoneError.activeInputDeviceDisconnected
                }
            }

            refreshAvailableDevicesAndAutoSelectIfNeeded(
                autoSelectInputDevice: wasCurrentDeviceDisconnected,
                excludingDeviceID: disconnectedUniqueID
            )
        }
    }
    
    // MARK: - Permission Check Timer Observer
    
    func setUpPermissionCheckTimer() {
        cleanUpPermissionCheckTimer()

        permissionCheckTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkPermissionFromTimer),
            userInfo: nil,
            repeats: true
        )
    }
    
    @MainActor
    @objc private func checkPermissionFromTimer() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let isAuthorized = status == .authorized

        if hasPermission != isAuthorized {
            hasPermission = isAuthorized
        }
    }
    
    func cleanUpPermissionCheckTimer() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }
}
