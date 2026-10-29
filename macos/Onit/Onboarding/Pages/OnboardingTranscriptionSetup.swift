// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingTranscriptionSetup.swift
//  Onit
//
//  Created by Loyd Kim on 1/21/26.
//

import AVFoundation
import Defaults
import SwiftUI

struct OnboardingTranscriptionSetup: View {
    // MARK: - Defaults

    @Default(.currentOnboardingStep) var currentStep
    @Default(.transcriptionInputDevice) private var currentInputDevice

    // MARK: - Observations

    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared
    
    // MARK: - States

    @State private var microphonePermissionStatus: AVAuthorizationStatus = .notDetermined
    @State private var isCheckingPermission: Bool = false
    @State private var hasDetectedAudio: Bool = false

    // MARK: - Private Variables
    
    private let permissionButtonHeight: CGFloat = 37
    private let permissionButtonHorizontalPadding: CGFloat = 12

    private var hasMicrophonePermission: Bool {
        return microphonePermissionStatus == .authorized
    }
    
    private var defaultMicrophoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? String.localized("Default Microphone", table: "Onboarding")
    }
    
    private var isMicrophoneWorking: Bool {
        return hasDetectedAudio
    }
    
    // MARK: - Body

    var body: some View {
        OnboardingPage(
            footerConfig: .init(
                nextButtonDisabled: Binding(
                    get: { !(hasMicrophonePermission && isMicrophoneWorking) },
                    set: { _ in }
                )
            ),
            bodyContent: {
                VStack(alignment: .center, spacing: 0) {
                    microphoneIcon
                        
                    permissionButton
                        .padding(.top, 27)

                    if hasMicrophonePermission {
                        VStack(alignment: .center, spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                OnboardingMicrophoneDropdown()
                                audioLevelIndicator
                            }

                            captionView
                        }
                        .padding(.top, 56)
                    }
                }
                .padding(.top, 43)
            },
            footerContent: {
                Spacer()
            }
        )
        .onAppear {
            AnalyticsManager.Transcription.Onboarding.setupShown()
            checkMicrophonePermissionStatus()
            openMicrophonePermissionDialogueIfNeeded()
            microphoneInputManager.refreshAvailableDevicesAndAutoSelectIfNeeded(
                autoSelectInputDevice: currentInputDevice == nil
            )
        }
        .onChange(of: hasMicrophonePermission) { oldValue, grantedMicrophonePermission in
            if !oldValue && grantedMicrophonePermission {
                AnalyticsManager.Transcription.Onboarding.setupMicrophoneGranted()
            }
            if grantedMicrophonePermission {
                Task {
                    try? await microphoneInputManager.startRecording()
                }
            } else {
                microphoneInputManager.stopRecording()
            }
        }
        .onChange(of: microphoneInputManager.audioLevel) { _, audioLevel in
            let acceptableAudioThreshold: Float = 0.2
            let hasAcceptableAudio = audioLevel > acceptableAudioThreshold

            if hasAcceptableAudio && !hasDetectedAudio {
                hasDetectedAudio = true
                // User has mic permission and detected audio - setup is complete
                if hasMicrophonePermission {
                    AnalyticsManager.Transcription.Onboarding.setupCompleted()
                }
            }
        }
        .onDisappear {
            microphoneInputManager.stopRecording()
        }
    }

    // MARK: - Child Components: Microphone Icon

    private var microphoneIcon: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 32))
            .foregroundColor(Color.S_1.opacity(0.6))
    }
    
    // MARK: - Child Components: Permission Button

    @ViewBuilder
    private var permissionButton: some View {
        switch microphonePermissionStatus {
        case .authorized:
            grantedButton
        case .denied, .restricted:
            openSettingsButton
        case .notDetermined:
            grantAccessButton
        @unknown default:
            grantAccessButton
        }
    }
    
    private var grantedButton: some View {
        TextButton(
            text: String.localized("Microphone ready to use", table: "Onboarding"),
            iconConfig: .init(
                rightIconName: "checkmark"
            ),
            colorConfig: .init(
                text: Color.S_0,
                background: Color.clear,
                border: Color.T_4
            ),
            sizeConfig: .init(
                horizontalPadding: permissionButtonHorizontalPadding,
                height: permissionButtonHeight
            ),
            statusConfig: .init(
                disabled: true,
                shouldFadeOnDisabled: false,
                borderDotted: true
            )
        ) {}
    }
    
    private var openSettingsButton: some View {
        TextButton(
            type: .primary,
            text: String.localized("Open Settings to grant access", table: "Onboarding"),
            sizeConfig: .init(
                horizontalPadding: permissionButtonHorizontalPadding,
                height: permissionButtonHeight
            )
        ) {
            microphoneInputManager.openMicrophoneSettings()
        }
    }

    private var grantAccessButton: some View {
        TextButton(
            type: .primary,
            text: String.localized("Grant access", table: "Onboarding"),
            sizeConfig: .init(
                horizontalPadding: permissionButtonHorizontalPadding,
                height: permissionButtonHeight
            ),
            statusConfig: .init(
                disabled: isCheckingPermission
            )
        ) {
            requestMicrophonePermission()
        }
    }
    
    // MARK: - Child Components: Audio Level Indicator

    private var audioLevelIndicator: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 999)
                    .fill(getAudioBarColor(for: index))
                    .frame(
                        width: 6,
                        height: 12
                    )
            }
        }
    }
    
    // MARK: - Child Components: Caption View

    private var captionView: some View {
        // TODO: LOYD - Change text back to this when adding adding multi-mic input.
//        Text("Check your microphone (built-in is recommended)")
        Text(String.localized("Speak to test your microphone", table: "Onboarding"))
            .styleText(
                size: 12,
                weight: .regular,
                color: Color.S_0.opacity(0.7)
            )
    }

    // MARK: - Private Functions
    
    private func checkMicrophonePermissionStatus() {
        microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    private func requestMicrophonePermission() {
        isCheckingPermission = true

        Task { @MainActor in
            let granted = await microphoneInputManager.requestPermission()
            microphonePermissionStatus = granted ? .authorized : .denied
            isCheckingPermission = false
        }
    }
    
    private func openMicrophonePermissionDialogueIfNeeded() {
        if microphonePermissionStatus == .notDetermined {
            requestMicrophonePermission()
        }
    }
    
    private func getAudioBarColor(for index: Int) -> Color {
        guard hasMicrophonePermission else {
            return Color.S_0.opacity(0.2)
        }

        let normalizedLevel = microphoneInputManager.audioLevel
        let threshold = Float(index + 1) / 6.0

        if normalizedLevel >= threshold {
            return Color.sky
        } else {
            return Color.T_6
        }
    }
}
