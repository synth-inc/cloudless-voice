// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AvailableMicrophonesPopoverView.swift
//  Onit
//
//  Created by Loyd Kim on 3/31/26.
//

import Defaults
import SwiftUI

struct AvailableMicrophonesPopoverView: View {
    // MARK: - Defaults

    @Default(.transcriptionInputDevice) private var currentInputDevice
    @Default(.transcriptionAutoSwitchMicrophone) private var autoSwitchMicrophone

    // MARK: - Observations

    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared
    
    // MARK: - Properties
    
    @Binding var show: Bool
    var isOpaque: Bool = false

    // MARK: - Body

    var body: some View {
        if isOpaque {
            contentView
                .presentationBackground(.ultraThickMaterial)
        } else {
            contentView
        }
    }
    
    // MARK: - Child Components: Content View
    
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(microphoneInputManager.availableDevices, id: \.id) { inputDevice in
                let displayName: String = {
                    #if DEBUG || ONIT_BETA
                    let sourceLabel = inputDevice.source.map { "[\($0)]" } ?? "[nil]"
                    return "\(inputDevice.name) \(sourceLabel)"
                    #else
                    return inputDevice.name
                    #endif
                }()
                checkmarkButton(
                    text: displayName,
                    isSelected: inputDevice.id == currentInputDevice?.id
                ) {
                    Task {
                        await microphoneInputManager.setInputDevice(inputDevice.id)
                    }
                    show = false
                }
            }
            
            dividerView
            
            checkmarkButton(
                text: String.localized("Auto-Switch to New Mics", table: "MenuBar"),
                isSelected: autoSwitchMicrophone
            ) {
                autoSwitchMicrophone.toggle()
                show = false
            }
        }
        .padding(12)
    }
    
    private func checkmarkButton(
        text: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "checkmark")
                    .styleText(
                        size: 10
                    )
                    .opacity(isSelected ? 1 : 0)
                
                Text(text)
                    .styleText(
                        size: 13,
                        weight: .regular
                    )
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var dividerView: some View {
        Group {
            if isOpaque {
                Divider()
            } else {
                DividerHorizontal()
            }
        }
        .padding(.vertical, 2)
    }
}
