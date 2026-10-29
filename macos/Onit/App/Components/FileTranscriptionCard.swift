// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FileTranscriptionCard.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-09-15.
//
//  Card above the Transcripts list to transcribe an audio file. Visuals match
//  `CorrectionBacktestBanner` (special2 bg, T_8 stroke, T_9 button).
//

import AppKit
import Defaults
import SwiftUI

struct FileTranscriptionCard: View {

    @ObservedObject private var service = FileTranscriptionService.shared
    @Default(.transcriptionHistoryEnabled) private var historyEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            switch service.phase {
            case .running(let filename, let fraction):
                runningContent(filename: filename, fraction: fraction)
            case .failed(let message):
                idleContent(subtitle: message, subtitleColor: Color.red500)
            case .idle:
                idleContent(
                    subtitle: String.localized("WAV, M4A, MP3, AIFF, CAF or FLAC, up to 30 minutes. Transcribed on this Mac.", table: "App"),
                    subtitleColor: Color.T_2
                )
            }
        }
        .padding(16)
        .background(Color.special2)
        .addBorder(cornerRadius: 14, stroke: Color.T_8)
        // An error is about the last attempt, not something to find days later.
        .onDisappear { service.clearError() }
    }

    // MARK: - States

    @ViewBuilder
    private func idleContent(subtitle: String, subtitleColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String.localized("Transcribe an audio file", table: "App"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(historyEnabled ? Color.S_0 : Color.T_2)

            if historyEnabled {
                Text(subtitle)
                    .styleText(size: 13, weight: .regular, color: subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String.localized("File transcripts are saved to your history. Turn on “Save Transcripts to History” to use this.", table: "App"))
                    .styleText(size: 13, weight: .regular, color: Color.T_2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    AppWindowManager.shared.showWindow(settingsPage: .transcriptionBehavior)
                } label: {
                    Text(String.localized("Open Settings", table: "App"))
                        .styleText(size: 12, weight: .medium, color: Color.info500)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .hoverPointerStyle(.link)
            }
        }
        Spacer()
        cardButton(text: String.localized("Open file", table: "App"), disabled: !historyEnabled) {
            openFile()
        }
    }

    @ViewBuilder
    private func runningContent(filename: String, fraction: Double?) -> some View {
        let title = String.localized("Transcribing: %@", table: "App", filename)

        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.S_0)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(Color.info500)
                        .accessibilityLabel(title)
                    Text(String.localized("%d%%", table: "Transcription", Int((fraction * 100).rounded())))
                        .styleText(size: 12, weight: .regular, color: Color.T_2)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.info500)
                        .accessibilityLabel(title)
                }
            }
        }
        Spacer()
        // Stays disabled once pressed: the job stops at the next segment boundary.
        cardButton(text: String.localized("Cancel", table: "App"), disabled: service.isCancelling) {
            service.cancel()
        }
    }

    private func cardButton(text: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        TextButton(
            text: text,
            colorConfig: .init(background: Color.T_9, hoverBackground: Color.T_8),
            sizeConfig: .init(horizontalPadding: 12, height: 32, cornerRadius: 9),
            statusConfig: .init(disabled: disabled),
            action: action
        )
    }

    // MARK: - Actions

    private func openFile() {
        guard historyEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = String.localized("Choose an audio file", table: "App")
        panel.allowedContentTypes = FileTranscriptionService.supportedTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.start(url: url)
    }
}
