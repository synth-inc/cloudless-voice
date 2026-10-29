// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingMicrophoneDropdown.swift
//  Onit
//
//  Created by Loyd Kim on 1/21/26.
//

import AVFoundation
import Defaults
import SwiftUI

struct OnboardingMicrophoneDropdown: View {
    // MARK: - Defaults

    @Default(.transcriptionInputDevice) private var currentInputDevice

    // MARK: - Observations

    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared

    // MARK: - States

    @State private var showAvailableDevices: Bool = false

    // MARK: - Private Variables

    private var noMicrophonesDetected: Bool {
        return microphoneInputManager.availableDevices.isEmpty
    }

    private var pillText: String {
        if noMicrophonesDetected {
            return String.localized("No microphones found. Click to retry.", table: "Onboarding")
        } else {
            return currentInputDevice?.name ?? ""
        }
    }

    // MARK: - Body

    var body: some View {
        OnboardingTitlePill(
            textConfig: .init(
                text: pillText,
                size: 12
            ),
            leftIconConfig: .init(
                systemName: "mic.fill"
            ),
            rightIconConfig:
                noMicrophonesDetected ? nil :
                .init(
                    systemName: "chevron.down",
                    size: 10
                ),
            colorConfig: .init(
                backgroundColor: Color.T_9,
                border: Color.clear
            ),
            statusConfig: .init(
                isDotted: false
            )
        ) {
            if noMicrophonesDetected {
                microphoneInputManager.refreshAvailableDevicesAndAutoSelectIfNeeded(
                    autoSelectInputDevice: currentInputDevice == nil
                )
            } else {
                showAvailableDevices.toggle()
            }
        }
        .popover(
            isPresented: $showAvailableDevices,
            arrowEdge: .bottom
        ) {
            AvailableMicrophonesPopoverView(show: $showAvailableDevices)
        }
    }
}
