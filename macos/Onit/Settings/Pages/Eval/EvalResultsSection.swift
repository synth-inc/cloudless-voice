// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalResultsSection.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import AVFoundation
import SwiftUI

/// Captured transcription result from an eval recording session.
struct EvalCapturedResult {
    var raw: String = ""
    var cleaned: String = ""
    var audioURL: URL? = nil
    var isExportingAudio: Bool = false

    var hasResults: Bool { !raw.isEmpty || !cleaned.isEmpty }

    mutating func clear() {
        raw = ""
        cleaned = ""
        audioURL = nil
        isExportingAudio = false
    }
}

/// Displays raw STT, cleaned output, expected text, audio playback, and scoring debug.
struct EvalResultsSection: View {

    @ObservedObject var manager: EvalRecordingManager
    let testCase: EvalTestCase
    let captured: EvalCapturedResult
    @Binding var isPlayingAudio: Bool
    var audioPlayer: Binding<AVAudioPlayer?>
    var onShowEasyFix: () -> Void
    var onTogglePlayback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsPageSection {
                VStack(alignment: .leading, spacing: 12) {
                    audioPlaybackRow
                    Divider()
                    resultBlock(label: "Raw STT", icon: "waveform", text: captured.raw, color: .orange)
                    Divider()
                    resultBlock(label: "Cleaned", icon: "sparkles", text: captured.cleaned, color: .blue)
                    Divider()
                    resultBlock(label: "Expected", icon: "checkmark.seal", text: testCase.expected, color: .green)
                }
            }
        }
    }

    // MARK: - Audio Playback

    private var audioPlaybackRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 10))
                .foregroundColor(Color.T_3)
            Text("Playback")
                .styleText(size: 10, weight: .semibold, color: Color.T_3)
            Spacer()

            easyFixButton

            if captured.audioURL != nil {
                Button {
                    onTogglePlayback()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isPlayingAudio ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(isPlayingAudio ? "Stop" : "Play")
                            .styleText(size: 12, weight: .medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.T_6)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else if captured.isExportingAudio {
                ProgressView().scaleEffect(0.6)
                Text("Exporting…")
                    .styleText(size: 11, color: Color.T_3)
            }
        }
    }

    private var easyFixButton: some View {
        let hasFix = manager.easyFixes[testCase.index] != nil
        return Button {
            onShowEasyFix()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wrench.adjustable.fill")
                    .font(.system(size: 10))
                Text(hasFix ? "Edit Fix" : "Easy Fix")
                    .styleText(size: 11, weight: .medium,
                               color: hasFix ? .white : Color.T_2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(hasFix ? Color.orange : Color.T_6)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .foregroundColor(hasFix ? .white : Color.T_2)
    }

    // MARK: - Result Block

    private func resultBlock(label: LocalizedStringKey, icon: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
                Text(label).styleText(size: 10, weight: .semibold, color: color)
            }
            if text.isEmpty {
                Text("(empty)")
                    .styleText(size: 13, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(verbatim: text)
                    .styleText(size: 13, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
