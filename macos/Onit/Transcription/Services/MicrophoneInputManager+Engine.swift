// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MicrophoneInputManager+Engine.swift
//  Onit
//
//  Created by Loyd Kim on 3/5/26.
//

/*
 * Functions: Configure Audio Unit
 * Private Functions: `configureAudioEngine()` Helpers
 * Functions: Clean Up Failed Audio Unit
 * Private Functions: Core Audio Input Audio Device Callback
 */

import AudioToolbox
import AVFAudio
import AVFoundation
import CoreAudio
import Defaults

extension MicrophoneInputManager {
    // MARK: - Functions: Configure Audio Unit

    /// Configures a Core Audio audio unit for input-only capture from the user's selected device.
    /// When audio ducking is enabled the unit is VoiceProcessingIO (which causes macOS to duck
    /// other apps' audio while recording); otherwise it uses the standard HALOutput unit.
    func configureAudioEngine() throws {
        let duckAudio = Defaults[.transcriptionDuckAudio]
        guard let outputAudioUnit = findOutputAudioUnit(ducking: duckAudio)
        else {
            throw MicrophoneError.outputAudioUnitNotAvailable
        }

        guard let inputAudioUnit = createInputAudioUnit(alongWith: outputAudioUnit)
        else {
            throw MicrophoneError.inputAudioUnitNotAvailable
        }
        
        try enableInputAudioUnitOnInputBus(
            for: inputAudioUnit
        )

        if duckAudio {
            // VPIO requires its output bus to remain active so it can build its
            // internal aggregate device. Disabling the bus causes the -10875 init
            // failure. Mute the output instead so no audio is played back.
            muteVPIOOutput(for: inputAudioUnit)
        } else {
            try disableOutputOnOutputBus(for: inputAudioUnit)
        }

        guard let selectedInputDeviceID = resolveSelectedInputDeviceID()
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.inputAudioDeviceNotFound
        }

        try assignSelectedInputDeviceToInputAudioUnit(
            for: inputAudioUnit,
            with: selectedInputDeviceID,
            isVPIO: duckAudio
        )

        /// Read the device's native stream format so we can configure our output format to match its sample rate.
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        try getInputAudioUnitStreamFormatAndSize(
            for: inputAudioUnit,
            deviceFormat: &deviceFormat,
            formatSize: &formatSize
        )

        /// Cache the sample rate so the realtime callback can use it without querying CoreAudio.
        inputAudioUnitCachedSampleRate = deviceFormat.mSampleRate

        try setOutputFormat(
            for: inputAudioUnit,
            with: deviceFormat
        )

        if duckAudio {
            // VPIO requires element 0 (output bus) format to match element 1 (input bus).
            try setVPIOOutputBusFormat(for: inputAudioUnit, with: deviceFormat)
        }
        
        try installInputAudioUnitCallback(
            for: inputAudioUnit
        )
        
        try initializeInputAudioUnit(
            for: inputAudioUnit
        )
    }
    
    // MARK: - Private Functions: `configureAudioEngine()` Helpers
    
    /// Returns the audio component to use for capture.
    /// - When `ducking` is true: VoiceProcessingIO, which causes macOS to automatically
    ///   lower other apps' audio volume while recording (following the teardown fix -
    ///   the unit is stopped/uninitialized/disposed in `stopRecording()` so ducking doesn't
    ///   persist after the session ends).
    /// - When `ducking` is false: standard HALOutput (default).
    private func findOutputAudioUnit(ducking: Bool) -> AudioComponent? {
        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: ducking ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        return AudioComponentFindNext(nil, &componentDescription)
    }
    
    private func createInputAudioUnit(alongWith outputAudioUnit: AudioComponent) -> AudioComponentInstance? {
        var inputAudioUnit: AudioComponentInstance?
        let instanceStatus = AudioComponentInstanceNew(outputAudioUnit, &inputAudioUnit)

        guard instanceStatus == noErr,
              let inputUnit = inputAudioUnit
        else {
            return nil
        }
        
        return inputUnit
    }
    
    /// Enable input on element 1 (input bus).
    private func enableInputAudioUnitOnInputBus(for inputAudioUnit: AudioComponentInstance) throws {
        var enableInput: UInt32 = 1
        let enableInputStatus = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        guard enableInputStatus == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(enableInputStatus)
                )
            )
        }
    }
    
    /// Disable output on element 0 (output bus). We only need input capture.
    private func disableOutputOnOutputBus(for inputAudioUnit: AudioComponentInstance) throws {
        var disableOutput: UInt32 = 0
        let disableOutputStatus = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        
        guard disableOutputStatus == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(disableOutputStatus)
                )
            )
        }
    }

    /// Mutes VPIO's output bus so no audio is played back through speakers.
    /// Unlike HALOutput, VPIO needs its output bus active to build its aggregate
    /// device, so we mute rather than disable.
    private func muteVPIOOutput(for inputAudioUnit: AudioComponentInstance) {
        var mute: UInt32 = 1
        // kAUVoiceIOProperty_MuteOutput = 2305
        AudioUnitSetProperty(
            inputAudioUnit,
            2305,
            kAudioUnitScope_Global,
            0,
            &mute,
            UInt32(MemoryLayout<UInt32>.size)
        )
        // Non-fatal: if the property isn't supported on this OS version the
        // output bus will be active but silent (no render callback is installed).
    }

    /// Resolves the CoreAudio device ID for the user's selected input device.
    private func resolveSelectedInputDeviceID() -> AudioDeviceID? {
        if let selectedInputDevice = Defaults[.transcriptionInputDevice],
           let deviceID = getDeviceID(fromUID: selectedInputDevice.id)
        {
            return deviceID
        }

        return nil
    }

    private func assignSelectedInputDeviceToInputAudioUnit(
        for inputAudioUnit: AudioComponentInstance,
        with selectedInputDeviceID: AudioDeviceID,
        isVPIO: Bool = false
    ) throws {
        var mutableDeviceID = selectedInputDeviceID
        // HALOutput uses element 0 (global device); VPIO uses element 1 (input bus).
        let element: UInt32 = isVPIO ? 1 : 0
        let setDeviceStatus = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            element,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard setDeviceStatus == noErr else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(setDeviceStatus)
                )
            )
        }
    }
    
    private func getInputAudioUnitStreamFormatAndSize(
        for inputAudioUnit: AudioComponentInstance,
        deviceFormat: UnsafeMutableRawPointer,
        formatSize: UnsafeMutablePointer<UInt32>
    ) throws {
        let status = AudioUnitGetProperty(
            inputAudioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            deviceFormat,
            formatSize
        )

        guard status == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.invalidInputFormat
        }
    }
    
    /// Set the output format on element 1 (what the callback receives).
    /// Match the device's sample rate, but request 32-bit float mono for the ASR pipeline.
    private func setOutputFormat(
        for inputAudioUnit: AudioComponentInstance,
        with deviceFormat: AudioStreamBasicDescription
    ) throws {
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let setFormatStatus = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &outputFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        guard setFormatStatus == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.invalidInputFormat
        }
    }
    
    /// Sets the stream format on VPIO's output bus (element 0) to match the input bus.
    /// VPIO refuses to initialize if these formats differ.
    private func setVPIOOutputBusFormat(
        for inputAudioUnit: AudioComponentInstance,
        with deviceFormat: AudioStreamBasicDescription
    ) throws {
        var outputBusFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let status = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &outputBusFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            )
        }
    }

    /// Install the input callback. Core Audio invokes this each time a buffer of audio is available.
    private func installInputAudioUnitCallback(for inputAudioUnit: AudioComponentInstance) throws {
        var callbackStruct = AURenderCallbackStruct(
            inputProc: auhalInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let callbackStatus = AudioUnitSetProperty(
            inputAudioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard callbackStatus == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(callbackStatus)
                )
            )
        }
    }
    
    /// Initialize the audio unit. This finalizes the configuration.
    private func initializeInputAudioUnit(for inputAudioUnit: AudioComponentInstance) throws {
        let initStatus = AudioUnitInitialize(inputAudioUnit)

        guard initStatus == noErr
        else {
            AudioComponentInstanceDispose(inputAudioUnit)
            throw MicrophoneError.engineStartFailed(
                NSError(domain: NSOSStatusErrorDomain, code: Int(initStatus))
            )
        }

        self.inputAudioUnit = inputAudioUnit
    }

    // MARK: - Functions: Clean Up Failed Audio Unit

    /// Disposes of the audio unit after a failed setup or start attempt.
    func cleanUpFailedInputAudioUnit() {
        if let inputAudioUnit = self.inputAudioUnit {
            AudioUnitUninitialize(inputAudioUnit)
            AudioComponentInstanceDispose(inputAudioUnit)
        }
        inputAudioUnit = nil
    }
}

// MARK: - Private Functions: Core Audio Input Audio Device Callback

/// C-function callback invoked by Core Audio each time audio data is available from the input device.
/// Renders the audio into a buffer, calculates the audio level, and forwards it through the async stream.
private func auhalInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<MicrophoneInputManager>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let unit = manager.inputAudioUnit
    else {
        return noErr
    }

    /// Allocate a buffer list for mono float32 audio.
    let bufferList = AudioBufferList.allocate(maximumBuffers: 1)
    bufferList[0].mNumberChannels = 1
    bufferList[0].mDataByteSize = inNumberFrames * 4
    bufferList[0].mData = UnsafeMutableRawPointer.allocate(
        byteCount: Int(inNumberFrames * 4),
        alignment: MemoryLayout<Float>.alignment
    )

    /// Pull audio data from the input device into our buffer.
    let renderStatus = AudioUnitRender(
        unit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        bufferList.unsafeMutablePointer
    )

    guard renderStatus == noErr
    else {
        bufferList[0].mData?.deallocate()
        free(bufferList.unsafeMutablePointer)
        return renderStatus
    }

    /// Wrap the raw audio data in an AVAudioPCMBuffer for compatibility with the existing ASR pipeline.
    /// Uses the sample rate cached during `configureAudioEngine()` to avoid querying CoreAudio on the realtime thread.
    guard let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: manager.inputAudioUnitCachedSampleRate,
        channels: 1,
        interleaved: false
    ) else {
        bufferList[0].mData?.deallocate()
        free(bufferList.unsafeMutablePointer)
        return noErr
    }

    guard let pcmBuffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat,
        frameCapacity: inNumberFrames
    ) else {
        bufferList[0].mData?.deallocate()
        free(bufferList.unsafeMutablePointer)
        return noErr
    }

    pcmBuffer.frameLength = inNumberFrames

    /// Copy rendered audio into the PCM buffer.
    if let source = bufferList[0].mData,
       let destination = pcmBuffer.floatChannelData?[0]
    {
        memcpy(destination, source, Int(inNumberFrames * 4))
    }

    /// Calculate audio level for UI feedback.
    let level = calculateAudioLevelFromBuffer(pcmBuffer)
    Task { @MainActor in
        guard manager.isRecording else { return }
        manager.audioLevel = level
    }

    /// Forward the buffer through the async stream.
    /// `nonisolated(unsafe)` is required because AVAudioPCMBuffer is not Sendable,
    /// but we know this is safe - the buffer is fully populated before being yielded
    /// and is not accessed again after this point.
    nonisolated(unsafe) let sendableBuffer = pcmBuffer
    manager.continuationLock.lock()
    manager.bufferContinuation?.yield(sendableBuffer)
    manager.continuationLock.unlock()

    bufferList[0].mData?.deallocate()
    free(bufferList.unsafeMutablePointer)

    return noErr
}

/// Calculates the RMS audio level from a PCM buffer, normalized to 0.0–1.0.
private func calculateAudioLevelFromBuffer(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channelData = buffer.floatChannelData?[0] else { return 0 }

    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return 0 }

    var sumOfSquares: Float = 0
    for i in 0..<frameLength {
        let sample = channelData[i]
        sumOfSquares += sample * sample
    }

    let rms = sqrt(sumOfSquares / Float(frameLength))

    let minDb: Float = -60.0
    let db = 20 * log10(max(rms, 0.000001))
    let normalizedDb = max(0, (db - minDb) / (-minDb))

    let curved = pow(normalizedDb, 0.5)

    return min(1.0, curved)
}
