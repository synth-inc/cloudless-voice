// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Hint+FeatureButtons.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Types
 * Variables: "Show" Booleans
 * Private Variables
 * Private Functions
 * Child Components: Public
 * Child Components: Private
 */

import Defaults
import SwiftUI

extension Hint {
    // MARK: - Types
    
    enum HoveredFeatureButton: Equatable {
        case editTranscript
        case transcription
        case update
    }
    
    enum TranscriptionButtonState {
        case idle           /// Display the default mic button.
        case listening      /// Display the recording waveform + stop button (recording audio).
        case processing     /// Display the loading indicator (transcribing audio to text).
    }
    
    // MARK: - Variables: "Show" Booleans
    
    private var showTranscriptionButton: Bool {
        transcriptionEnabled
    }

    var showUpdateButton: Bool {
        return appState.isUpdateAvailable
    }

    private var showEditUndoButtons: Bool {
        return
            transcriptionManager.hasLastTranscription &&
            !isTranscriptionActive
    }
    
    // MARK: - Private Variables
    
    private var currentTranscriptionButtonState: TranscriptionButtonState {
        if transcriptionIsRecording {
            return .listening
        } else if transcriptionIsProcessing {
            return .processing
        } else {
            return .idle
        }
    }
    
    private var shouldDisableTranscriptionButtonDuringOnboarding: Bool {
        return
            onboardingWindowManager.onboardingWindowIsVisible &&
            (
                microphonePermissionLost
                /// Commented out for now until non-AX becomes the default state.
//                screenRecordingPermissionLost
            )
            
    }
    
    private var shouldDisableTranscriptionButtonOutsideOnboarding: Bool {
        return
            !onboardingWindowManager.onboardingWindowIsVisible &&
            (
                microphonePermissionLost ||
                accessibilityPermissionLost
                /// Commented out for now until non-AX becomes the default state.
//                screenRecordingPermissionLost
            )
            
    }
    
    private var shouldDisableTranscriptionIdleView: Bool {
        return
            !transcriptionWarmedUp ||
            shouldDisableTranscriptionButtonDuringOnboarding ||
            shouldDisableTranscriptionButtonOutsideOnboarding
    }
    
    private var hasTranscriptionError: Bool {
        return
            transcriptionSetupIncomplete ||
            shouldDisableTranscriptionButtonDuringOnboarding ||
            shouldDisableTranscriptionButtonOutsideOnboarding
    }
    
    // MARK: - Public Functions
    
    func installUpdate() {
        guard !isDragging else { return }
        Defaults[.dismissedUpdateAlertVersion] = appState.availableUpdateVersion ?? ""
        hideMoreMenu()
        appState.checkForAvailableUpdateWithDownload()
    }
    
    // MARK: - Private Functions
    
    private func toggleTranscription() {
        guard !isDragging else { return }
        hideMoreMenu()
        
        if transcriptionSetupIncomplete {
            openTranscriptionOnboarding()
        } else {
            TranscriptionManager.shared.toggle()
        }
    }

    private func editLastTranscript() {
        hideMoreMenu()
        transcriptionManager.editLastTranscription()
    }

    // MARK: - Child Components: Public
    
    var logoButton: some View {
        FeatureButton(icon: .noodle) {}
            .allowsHitTesting(false)
    }

    /// Collapsed-pill model-preparation indicator: shown in place of the logo while any required
    /// model (dictation or the Smart Cleanup stack) is being prepared. During the **download** phase
    /// it shows "X% ⟳"; during the **warmup** phase (no determinate progress) it shows an
    /// indeterminate spinner. Read-only - it reports status, it isn't a button. Re-renders are driven
    /// by `hintManager`'s published progress (the poll timer), so the phase read here stays current.
    @ViewBuilder
    var downloadProgressPill: some View {
        Group {
            // A stalled transfer (no bytes for a few seconds, a Range-resume retry pending) shows the
            // indeterminate spinner rather than a frozen "4% ⟳" that reads as a dead progress bar.
            if let progress = ModelDownloadIndicator.current?.progress, !hintManager.modelDownloadStalled {
                HStack(spacing: 5) {
                    Text("\(Int((progress * 100).rounded()))%")
                        .styleText(
                            size: 12,
                            weight: .medium,
                            color: Color.T_1
                        )

                    DownloadProgressRing(progress: progress)
                        .frame(width: 14, height: 14)
                }
            } else {
                // Full scale (~16pt) so the warmup spinner matches the logo / download-ring size.
                Loader(size: 16, scaleEffect: 1.0, controlSize: .small)
            }
        }
        .frame(height: Hint.featureButtonSize)
        .padding(.horizontal, 6)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    var moreMenuButton: some View {
        if !isTranscriptionActive {
            FeatureButton(
                icon: .dots,
                width: nil
            ) {
                toggleMoreMenu()
            }
            .padding(.horizontal, Self.moreMenuButtonHorizontalPadding)
        }
    }

    @ViewBuilder
    var transcriptionButton: some View {
        if showTranscriptionButton {
            switch currentTranscriptionButtonState {
            case .idle:
                transcriptionIdleView
            case .listening:
                transcriptionListeningView
            case .processing:
                transcriptionProcessingView
            }
        }
    }

    @ViewBuilder
    var updateButton: some View {
        if showUpdateButton && !isTranscriptionActive {
            FeatureButton(
                icon: .update,
                shouldShowProminence: true,
                hoveredButton: .update,
                currentHoveredButton: $hoveredFeatureButton
            ) {
                installUpdate()
            }
        }
    }

    @ViewBuilder
    var editLastTranscriptButton: some View {
        if showEditUndoButtons {
            FeatureButton(
                icon: .edit,
                hoveredButton: .editTranscript,
                currentHoveredButton: $hoveredFeatureButton
            ) {
                editLastTranscript()
            }
        }
    }

    // MARK: - Child Components: Private
    
    private var transcriptionIdleView: some View {
        FeatureButton(
            icon: .transcription,
            hasError: hasTranscriptionError,
            disabled: shouldDisableTranscriptionIdleView,
            hoveredButton: .transcription,
            currentHoveredButton: $hoveredFeatureButton
        ) {
            if transcriptionSetupIncomplete {
                hintManager.hideMoreMenu()
                openTranscriptionOnboarding()
            } else if transcriptionWarmedUp {
                toggleTranscription()
            }
        }
    }

    private var transcriptionListeningView: some View {
        HStack(spacing: 6) {
            Button {
                TranscriptionManager.shared.cancelTranscription(reason: .recordingCancelled)
            } label: {
                Image(.recordingCancel)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundColor(Color.T_1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.leading, 4)

            AudioVisualizer(
                audioLevel: transcriptionState.audioLevel,
                isProcessing: false
            )

            Button {
                TranscriptionManager.shared.stopTranscription()
            } label: {
                Image(.stop)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundColor(Color.red500)
                    .background(Color.white)
                    .contentShape(Rectangle())
                    .cornerRadius(999)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(height: Self.featureButtonSize)
    }

    private var transcriptionProcessingView: some View {
        Loader(
            size: Self.featureButtonSize,
            scaleEffect: 1.0,
            controlSize: .small
        )
        .frame(height: Self.featureButtonSize)
    }
    
    private struct DownloadProgressRing: View {
        /// Download fraction (0.0–1.0).
        let progress: Double

        var body: some View {
            ZStack {
                Circle()
                    .stroke(Color.T_5, lineWidth: 2)

                Circle()
                    /// Floor the trim so there's always a visible arc, even at 0%.
                    .trim(from: 0, to: max(0.03, min(1, progress)))
                    .stroke(
                        Color.S_0,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private struct FeatureButton: View {
        var icon: ImageResource? = nil
        var systemName: String? = nil
        var width: CGFloat? = Hint.featureButtonSize
        var height: CGFloat? = Hint.featureButtonSize
        var hasError: Bool = false
        var shouldShowProminence: Bool = false
        var disabled: Bool = false
        var hoveredButton: HoveredFeatureButton? = nil
        var currentHoveredButton: Binding<HoveredFeatureButton?> = .constant(nil)
        let action: () -> Void

        @State private var isHovering: Bool = false

        var foregroundColor: Color {
            if hasError {
                return Color.S_0
            } else if shouldShowProminence {
                return Color.lime400
            } else {
                return isHovering ? Color.S_1 : Color.T_1
            }
        }

        var backgroundColor: Color {
            if hasError {
                if isHovering {
                    return Color.red500.opacity(0.3)
                } else {
                    return Color.red500.opacity(0.15)
                }
            } else if shouldShowProminence {
                if isHovering {
                    return Color.lime400.opacity(0.3)
                } else {
                    return Color.lime400.opacity(0.15)
                }
            } else {
                if isHovering {
                    return Color.T_9
                } else {
                    return Color.clear
                }
            }
        }

        var borderColor: Color {
            if hasError {
                return Color.red500
            } else if shouldShowProminence {
                return Color.lime400
            } else {
                return Color.clear
            }
        }

        var body: some View {
            Button {
                if !disabled {
                    action()
                }
            } label: {
                iconView
                    .foregroundColor(foregroundColor)
                    .frame(
                        width: width,
                        height: height
                    )
                    .contentShape(Rectangle())
                    .opacity(disabled ? 0.5 : 1.0)
            }
            .buttonStyle(PlainButtonStyle())
            .background(disabled ? Color.clear : backgroundColor)
            .addBorder(
                cornerRadius: 999,
                stroke: borderColor
            )
            .onHover { isHovering in
                self.isHovering = isHovering

                if isHovering {
                    currentHoveredButton.wrappedValue = hoveredButton
                } else if currentHoveredButton.wrappedValue == hoveredButton {
                    currentHoveredButton.wrappedValue = nil
                }
            }
        }
        
        @ViewBuilder
        private var iconView: some View {
            if let systemName = systemName {
                Image(systemName: systemName)
                    .font(.system(size: Hint.featureButtonIconSize, weight: .medium))
                    .frame(
                        width: Hint.featureButtonIconSize,
                        height: Hint.featureButtonIconSize
                    )
            } else if let icon = icon {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: Hint.featureButtonIconSize,
                        height: Hint.featureButtonIconSize
                    )
            }
        }
    }
}
