// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MicrophoneInputManager+Detection.swift
//  Onit
//
//  Created by Loyd Kim on 3/5/26.
//

/*
 * Functions: Get Device ID/UID/Name
 * Functions: Load Available Devices
 */

import AVFoundation
import CoreAudio
import Defaults

extension MicrophoneInputManager {
    // MARK: - Functions: Get Device ID/UID/Name

    /// Converts an AVFoundation UID string to a CoreAudio `AudioDeviceID`.
    func getDeviceID(fromUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr
        else {
            return nil
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        /// There is an edge case where devices can connect or disconnect between our two calls (size query + data query), which would leave `propertySize` stale.
        /// `CoreAudio` writes the real size used into `actualSize`, which leads to the accurate `validCount`.
        
        var actualSize = propertySize

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &actualSize,
            &deviceIDs
        ) == noErr
        else {
            return nil
        }

        let actualCount = Int(actualSize) / MemoryLayout<AudioDeviceID>.size
        let validCount = min(actualCount, deviceCount)

        return deviceIDs.prefix(validCount).first { getDeviceUID(for: $0) == uid }
    }
    
    /// Returns the UID (unique ID) string for a CoreAudio device ID.
    func getDeviceUID(for coreAudioDeviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(coreAudioDeviceID, &address, 0, nil, &size, &uid) == noErr
        else {
            return nil
        }

        return uid as String
    }

    // MARK: - Functions: Load Available Devices
    
    @MainActor
    func refreshAvailableDevicesAndAutoSelectIfNeeded(
        autoSelectInputDevice: Bool,
        skipAutoSelect: Bool = false,
        excludingDeviceID: String? = nil
    ) {
        refreshAvailableDevices(excludingDeviceID: excludingDeviceID)

        /// `skipAutoSelect` is for callers that will set `transcriptionInputDevice` themselves.
        /// Useful in `handleDeviceWasConnected()` to prevent double-writing to `Defaults[.transcriptionInputDevice]`.
        guard !skipAutoSelect else { return }

        let (
            shouldCaptureMacOsDefaultInputDevice,
            shouldAutoSelectInputDevice
        ) = determineShouldAutoSelectInputDevice(autoSelectInputDevice)

        guard shouldAutoSelectInputDevice else { return }

        if shouldCaptureMacOsDefaultInputDevice,
           let detectedDefaultDevice = AVCaptureDevice.default(for: .audio),
           let defaultInputDevice = availableDevices.first(where: { $0.id == detectedDefaultDevice.uniqueID }),
           !isLowPriorityInputDevice(defaultInputDevice.source)
        {
            Defaults[.transcriptionInputDevice] = defaultInputDevice
        } else if let fallback = selectHighestPriorityInputDevice() {
            Defaults[.transcriptionInputDevice] = fallback
        }
    }

    @MainActor
    private func refreshAvailableDevices(excludingDeviceID: String? = nil) {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let discoveredDevices = discoverySession.devices

        availableDevices = discoveredDevices.compactMap { device in
            /// `AVCaptureDevice.DiscoverySession` can briefly continue to report a just-disconnected device, so the disconnect handler (`handleDeviceWasDisconnected()` passes its UID here to suppress it from `availableDevices`.
            if device.uniqueID == excludingDeviceID {
                return nil
            }

            let inputDeviceSource = resolveInputDeviceSource(for: device.uniqueID)

            return MicrophoneInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                source: inputDeviceSource
            )
        }

        let activeDeviceUIDs = Set(discoveredDevices.map { $0.uniqueID })

        /// Filter ensures we don't maintain stale UID caches.
        transportTypeCache = transportTypeCache.filter { activeDeviceUIDs.contains($0.key) }
    }

    @MainActor
    private func resolveInputDeviceSource(for deviceUID: String) -> MicrophoneSource? {
        let deviceTransportType: UInt32

        if let cachedTransportType = transportTypeCache[deviceUID] {
            deviceTransportType = cachedTransportType
        } else {
            guard let coreAudioDeviceID = getDeviceID(fromUID: deviceUID),
                  let resolvedTransportType = getInputDeviceTransportType(for: coreAudioDeviceID)
            else {
                return nil
            }
            deviceTransportType = resolvedTransportType
            transportTypeCache[deviceUID] = resolvedTransportType
        }

        let source = mapTransportTypeToMicrophoneSource(deviceTransportType)

        if source == .builtIn,
           let coreAudioDeviceID = getDeviceID(fromUID: deviceUID),
           isExternalMicDataSource(for: coreAudioDeviceID)
        {
            return .audioJack
        }

        return source
    }

    /// `CoreAudio` cannot tell the difference between the actual built-in mic and an audio jack mic.
    ///     * This is because they both read as internal hardware audio devices.
    ///     * Therefore, they both resolve as "built in" transport types.
    /// This function digs deep into a `CoreAudio` device to find its `dataSource` binary and compare that against the `emic` (external mic) binary signature.
    /// If they're equal, then we've found an external mic. Otherwise, it's the built-in mic.
    private func isExternalMicDataSource(for coreAudioDeviceID: AudioDeviceID) -> Bool {
        var dataSource: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            coreAudioDeviceID,
            &address,
            0,
            nil,
            &size,
            &dataSource
        ) == noErr
        else {
            return false
        }

        /// `CoreAudio` `FourCC` for the audio-jack data source.
        let externalMicDataSource: UInt32 = 0x656D6963
        
        return dataSource == externalMicDataSource
    }
    
    private func getInputDeviceTransportType(for coreAudioDeviceID: AudioDeviceID) -> UInt32? {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            coreAudioDeviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        ) == noErr
        else {
            return nil
        }

        return transportType
    }
    
    private func mapTransportTypeToMicrophoneSource(_ transportType: UInt32) -> MicrophoneSource {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
            
        case kAudioDeviceTransportTypeUSB:
            return .usb
            
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
            
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return .aggregate
            
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
            
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
            
        default:
            return .unknown
        }
    }
    
    @MainActor
    private func determineShouldAutoSelectInputDevice(_ autoSelectInputDevice: Bool) -> (
        shouldCaptureMacOsDefaultInputDevice: Bool,
        shouldAutoSelectInputDevice: Bool
    ) {
        let shouldCaptureMacOsDefaultInputDevice = Defaults[.transcriptionInputDevice] == nil

        let savedDeviceIsStale: Bool = {
            guard let savedDevice = Defaults[.transcriptionInputDevice]
            else {
                return false
            }

            return !availableDevices.contains(where: { $0.id == savedDevice.id })
        }()
        
        let shouldAutoSelectInputDevice =
            shouldCaptureMacOsDefaultInputDevice ||
            savedDeviceIsStale ||
            autoSelectInputDevice
        
        return (
            shouldCaptureMacOsDefaultInputDevice,
            shouldAutoSelectInputDevice
        )
    }
    
    func isLowPriorityInputDevice(_ source: MicrophoneSource?) -> Bool {
        switch source {
        case .virtual, .unknown, .none:
            return true
        case .builtIn, .audioJack, .usb, .bluetooth, .aggregate, .airPlay:
            return false
        }
    }

    @MainActor
    private func selectHighestPriorityInputDevice() -> MicrophoneInputDevice? {
        let highPriorityDevice = availableDevices
            .filter { !isLowPriorityInputDevice($0.source) }
            .min { ($0.source?.rawValue ?? Int.max) < ($1.source?.rawValue ?? Int.max) }

        if let highPriorityDevice {
            return highPriorityDevice
        }
        
        /// A high priority device was not found. Return a low-priority device so that the user can still transcribe, or return `nil` if no devices are detected.
        return availableDevices.min {
            ($0.source?.rawValue ?? Int.max) < ($1.source?.rawValue ?? Int.max)
        }
    }
}
