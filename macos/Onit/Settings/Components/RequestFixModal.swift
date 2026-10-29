// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  RequestFixModal.swift
//  Onit
//
//  Created by Loyd Kim on 5/19/26.
//

import SwiftUI

struct RequestFixModal: View {
    // MARK: - Properties

    let showAgreeAndSend: Bool
    let onCancel: () -> Void
    let onAgreeAndSend: () -> Void

    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - Layout constants

    private let buttonHeight: CGFloat = 36
    private let buttonCornerRadius: CGFloat = 9

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            textBlock
            infoCard
            actionsRow
        }
        .padding(16)
        .frame(width: 443, alignment: .leading)
        .background(Color.surface3)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_9
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.T_9, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 2)
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components: Text Block

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                String.localized(
                    "Share this correction to improve Cloudless.",
                    table: "Transcription"
                )
            )
            .styleText(
                size: 15,
                weight: .regular
            )

            Text(
                String.localized(
                    "If you agree, this transcript and its audio clip are sent to the Cloudless team and stored in Google Firebase under your account. They are used to improve dictation accuracy.",
                    table: "Transcription"
                )
            )
            .styleText(
                weight: .regular,
                color: Color.T_1
            )
//            .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    // MARK: - Child Components: Info Card
    
    private struct Subtitle {
        let text: String
        var weight: Font.Weight = Font.Weight.regular
        var color: Color = Color.T_1
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(
                systemName: "shield",
                title: String.localized("Optional and revocable", table: "Transcription"),
                subtitles: [
                    .init(text: String.localized(
                        "Nothing is sent unless you agree. Delete the transcript from your transcription history to have the copy we stored deleted.",
                        table: "Transcription"
                    ))
                ]
            )
            
            DividerHorizontal(foregroundColor: Color.T_7)

            infoRow(
                systemName: "square.and.arrow.up",
                title: String.localized("What gets sent", table: "Transcription"),
                subtitles: [
                    .init(
                        text: String.localized(
                            "The audio clip, the original and corrected text, your account identifier and the name of the app you dictated into.",
                            table: "Transcription"
                        )
                    ),
                    .init(
                        text: String.localized("Ensure your transcript doesn't contain sensitive info.", table: "Transcription"),
                        weight: .medium,
                        color: Color.orange500
                    )
                ]
            )
        }
        .padding(6)
        .background(Color.T_9)
        .cornerRadius(14)
    }

    private func infoRow(
        systemName: String,
        title: String,
        subtitles: [Subtitle]
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemName)
                .styleText(
                    size: 16,
                    color: Color.T_1
                )
                .frame(width: 22, height: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .styleText(
                        weight: .regular
                    )
                
                ForEach(Array(subtitles.enumerated()), id: \.offset) { _, subtitle in
                    Text(subtitle.text)
                        .styleText(
                            size: 13,
                            weight: subtitle.weight,
                            color: subtitle.color
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
    }
    
    // MARK: - Child Components: Actions Row

    private var actionsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            cancelButton

            if showAgreeAndSend {
                agreeAndSendButton
            }
        }
    }

    private var cancelButton: some View {
        actionButton(
            text: String.localized("Cancel", table: "Transcription")
        ) {
            onCancel()
        }
    }

    private var agreeAndSendButton: some View {
        actionButton(
            isPrimary: true,
            text: String.localized("Agree & send", table: "Transcription")
        ) {
            onAgreeAndSend()
        }
    }
    
    private func actionButton(
        isPrimary: Bool = false,
        text: String,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(
            type: isPrimary ? .primary : .custom,
            text: text,
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                textWeight: .regular,
                height: 36
            ),
            statusConfig: .init(
                fillContainer: true
            )
        ) {
            action()
        }
    }
}
