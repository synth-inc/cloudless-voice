// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MicrophoneInputManager.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreAudio
import Defaults
import Foundation

enum MicrophoneSource: Int, Codable, CustomStringConvertible {
    case builtIn
    case audioJack
    case usb
    case bluetooth
    case aggregate
    case virtual
    case airPlay
    case unknown

    var description: String {
        switch self {
        case .bluetooth: return "bluetooth"
        case .usb: return "usb"
        case .audioJack: return "audioJack"
        case .builtIn: return "builtIn"
        case .aggregate: return "aggregate"
        case .virtual: return "virtual"
        case .airPlay: return "airPlay"
        case .unknown: return "unknown"
        }
    }
}

struct MicrophoneInputDevice: Identifiable, Codable, Equatable, Defaults.Serializable {
    /// `MicrophoneInputManager` uses two types of IDs:
    ///     1. The input device ID returned by `CoreAudio`. Transient. Required for interacting with `CoreAudio` APIs.
    ///     2. The UID (unique ID) created with the input device ID. Persistent. Converted into the input device ID when configuring our audio engine.
    ///
    /// This `id` property stores the UID because it allows us to persist the reference to the user's preferred input device across sessions.
    let id: String
    var name: String
    var source: MicrophoneSource?
}

/// Manages microphone audio capture for real-time speech transcription.
/// Provides a stream of audio buffers for ASR processing.
final class MicrophoneInputManager: ObservableObject, @unchecked Sendable {

    // MARK: - Singleton

    @MainActor static let shared = MicrophoneInputManager()

    // MARK: - Published Properties

    @MainActor @Published private(set) var isRecording = false
    
    @MainActor @Published var audioLevel: Float = 0.0
    @MainActor @Published var hasPermission: Bool
    @MainActor @Published var availableDevices: [MicrophoneInputDevice] = []
    @MainActor @Published var error: MicrophoneError?

    // MARK: - Core Audio Properties

    var inputAudioUnit: AudioComponentInstance? = nil

    /// Sample rate cached during `configureAudioEngine()` so the realtime callback doesn't need to query CoreAudio on every invocation.
    var inputAudioUnitCachedSampleRate: Float64 = 0

    /// Latency of the last `configureAudioEngine()` call in milliseconds (set during startRecording).
    var lastConfigureAudioEngineMs: Double = 0
    /// Latency of the last `AudioOutputUnitStart()` call in milliseconds (set during startRecording).
    var lastAudioOutputUnitStartMs: Double = 0

    /// Lock that protects the async stream continuation from concurrent access.
    let continuationLock = NSLock()

    /// Continuation for the audio buffer async stream.
    var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation? = nil

    
    // MARK: - Timer Properties

    var permissionCheckTimer: Timer? = nil

    /// Device uniqueID to switch to after the current recording session ends.
    /// Set when auto-switch is requested while recording is active.
    @MainActor var pendingAutoSwitchDeviceID: String? = nil

    /// Transport type is immutable per device for the duration of a connection, so caching it eliminates redundant per-refresh `CoreAudio` queries. For example, in `menuWillOpen`.
    @MainActor var transportTypeCache: [String: UInt32] = [:]

    // MARK: - Initialization

    @MainActor
    private init() {
        hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        setUpDeviceObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Variables

    /// Stream of audio buffers for processing.
    var audioBufferStream: AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            self.continuationLock.lock()
            self.bufferContinuation = continuation
            self.continuationLock.unlock()
        }
    }

    // MARK: - Public Functions: Configuration

    /// Starts a timer to periodically check microphone permission status.
    @MainActor
    func configure() {
        setUpPermissionCheckTimer()

        if Defaults[.transcriptionEnabled] {
            refreshAvailableDevicesAndAutoSelectIfNeeded(autoSelectInputDevice: false)
        }
    }
    
    // MARK: - Public Functions: Cleanup
    
    @MainActor
    func cleanup() {
        cleanUpPermissionCheckTimer()
    }

    // MARK: - Public Functions: Settings & Permissions

    /// Opens System Settings to the Microphone privacy section.
    @MainActor
    func openMicrophoneSettings() {
        let microphoneUrl: String

        if #available(macOS 26, *) {
            microphoneUrl = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        } else {
            microphoneUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }

        if let url = URL(string: microphoneUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Request microphone permission from the user.
    @MainActor
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            hasPermission = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            hasPermission = granted
            return granted
        case .denied, .restricted:
            hasPermission = false
            return false
        @unknown default:
            hasPermission = false
            return false
        }
    }

    /// Request microphone permission with native dialog, or open Settings if already denied.
    @MainActor
    func requestPermissionOrOpenSettings() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            hasPermission = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            hasPermission = granted
            if !granted {
                openMicrophoneSettings()
            }
        case .denied, .restricted:
            hasPermission = false
            openMicrophoneSettings()
        @unknown default:
            hasPermission = false
            openMicrophoneSettings()
        }
    }

    // MARK: - Public Functions: Start & Stop Recording

    @MainActor
    func startRecording() async throws {
        guard !isRecording else { return }

        if !hasPermission {
            let granted = await requestPermission()
            guard granted
            else {
                throw MicrophoneError.permissionDenied
            }
        }

        do {
            let configureStart = Date()
            try configureAudioEngine()
            lastConfigureAudioEngineMs = Date().timeIntervalSince(configureStart) * 1000
            log.info("[rec-startup] configureAudioEngine(): \(String(format: "%.1f", lastConfigureAudioEngineMs))ms")

            guard let inputAudioUnit = self.inputAudioUnit
            else {
                throw MicrophoneError.inputAudioUnitNotAvailable
            }

            let unitStartClock = Date()
            let startStatus = AudioOutputUnitStart(inputAudioUnit)
            lastAudioOutputUnitStartMs = Date().timeIntervalSince(unitStartClock) * 1000
            log.info("[rec-startup] AudioOutputUnitStart(): \(String(format: "%.1f", lastAudioOutputUnitStartMs))ms")
            guard startStatus == noErr
            else {
                throw MicrophoneError.engineStartFailed(
                    NSError(domain: NSOSStatusErrorDomain, code: Int(startStatus))
                )
            }

            isRecording = true
            error = nil
        } catch {
            cleanUpFailedInputAudioUnit()
            self.error = MicrophoneError.engineStartFailed(error)
            throw error
        }
    }

    @MainActor
    func stopRecording() {
        guard isRecording else { return }

        if let inputAudioUnit = self.inputAudioUnit {
            AudioOutputUnitStop(inputAudioUnit)
            AudioUnitUninitialize(inputAudioUnit)
            AudioComponentInstanceDispose(inputAudioUnit)
        }

        inputAudioUnit = nil

        continuationLock.lock()
        bufferContinuation?.finish()
        bufferContinuation = nil
        continuationLock.unlock()

        isRecording = false
        audioLevel = 0.0
        inputAudioUnitCachedSampleRate = 0

        if let pendingID = pendingAutoSwitchDeviceID {
            Task { await setInputDevice(pendingID) }
        }
    }

    // MARK: - Public Functions: Set Input Device
    
    @MainActor
    func setInputDevice(_ inputDeviceID: String) async {
        pendingAutoSwitchDeviceID = nil

        if let currentDevice = Defaults[.transcriptionInputDevice],
           inputDeviceID == currentDevice.id
        {
            return
        }

        guard let inputDevice = availableDevices.first(where: { $0.id == inputDeviceID })
        else {
            error = MicrophoneError.inputAudioDeviceNotFound
            
            // TODO: LOYD - We're surfacing `.inputDeviceFailed` here because it does a good job at surfacing issues related to microphone setup. But, in an ideal world, we would be creating new cases and a new Hint pop-up child component to individually handle this specific case. It's currently out-of-scope, so I've deferred to go the simpler route.
            HintManager.shared.showTranscriptionAlert(.inputDeviceFailed)
            return
        }

        Defaults[.transcriptionInputDevice] = inputDevice

        /// If currently recording, restart with the new device.
        if isRecording {
            stopRecording()
            try? await startRecording()
        }
    }
}

// MARK: - Error Types

enum MicrophoneError: Error, LocalizedError {
    case permissionDenied
    case outputAudioUnitNotAvailable
    case inputAudioUnitNotAvailable
    case inputAudioDeviceNotFound
    case invalidInputFormat
    case engineStartFailed(Error)
    case activeInputDeviceDisconnected

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return NSLocalizedString(
                "Microphone permission denied. Please enable microphone access in System Settings.",
                comment: "Error when microphone access is denied"
            )
            
        case .outputAudioUnitNotAvailable:
            return NSLocalizedString(
                "Output audio unit not available.",
                comment: "Error when output audio unit is unavailable"
            )

        case .inputAudioUnitNotAvailable:
            return NSLocalizedString(
                "Input audio unit not available.",
                comment: "Error when input audio unit is unavailable"
            )
            
        case .inputAudioDeviceNotFound:
            return NSLocalizedString(
                "Selected input audio device not found.",
                comment: "Error when selected microphone is unavailable"
            )

        case .invalidInputFormat:
            return NSLocalizedString(
                "Unable to get audio input format.",
                comment: "Error when audio format is invalid"
            )

        case .engineStartFailed(let error):
            return String(
                format: NSLocalizedString(
                    "Failed to start audio engine: %@",
                    comment: "Error when audio engine fails to start"
                ),
                error.localizedDescription
            )
            
        case .activeInputDeviceDisconnected:
            return NSLocalizedString(
                "The active microphone was disconnected during recording.",
                comment: "Error when the recording microphone is disconnected mid-session"
            )
        }
    }
}
