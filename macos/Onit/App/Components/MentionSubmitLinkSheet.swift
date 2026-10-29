// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MentionSubmitLinkSheet.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import SwiftUI

struct MentionSubmitLinkSheet: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// Set to `true` on a successful submit. The presenting carousel reads this
    /// in its sheet `onDismiss` to open the "Your comments" sheet only *after*
    /// this sheet has fully dismissed - presenting both in the same runloop can
    /// drop the second presentation on macOS.
    @Binding var pendingOpenSubmissions: Bool

    /// The mission being submitted for, or `nil` for a free-form submission.
    let mention: CuratedSocialMediaMention?

    // MARK: - States

    @State private var linkText: String = ""
    @State private var isSubmittingMention: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: - Private Variables

    private var platform: CuratedSocialMediaPostPlatform? {
        return mention?.platform
    }

    private var titleText: String {
        switch platform {
        case .reddit:
            return String.localized("Paste your Reddit comment link", table: "App")
        case .youtube:
            return String.localized("Paste your YouTube comment link", table: "App")
        case .x:
            return String.localized("Paste your X post link", table: "App")
        case nil:
            return String.localized("Submit your link", table: "App")
        }
    }

    private var instructionsText: String {
        switch platform {
        case .reddit:
            return String.localized(
                "On your comment, click 􀉐 Share, then 􀉣Copy link and paste it below.",
                table: "App"
            )
        case .youtube:
            return String.localized(
                "On your comment, click the timestamp next to your username (this makes your comment a Highlighted comment). Next, copy the link in the browser address bar and paste it below.",
                table: "App"
            )
        case .x:
            return String.localized(
                "Copy the link to your post and paste it below.",
                table: "App"
            )
        case nil:
            return String.localized(
                "Paste the link to the post or comment where you mentioned Cloudless.",
                table: "App"
            )
        }
    }

    private var placeholderText: String {
        switch platform {
        case .reddit:
            return "https://www.reddit.com/r/..."
        case .youtube:
            return "https://www.youtube.com/watch?v=..."
        case .x:
            return "https://x.com/..."
        case nil:
            return String.localized("Paste a link", table: "App")
        }
    }

    private var canSubmit: Bool {
        return
            !linkText.trimmingCharacters(in: .whitespaces).isEmpty &&
            !isSubmittingMention
    }

    // MARK: - Private Functions

    private func submit() {
        let trimmedLinkText = linkText.trimmingCharacters(in: .whitespaces)
        
        guard !trimmedLinkText.isEmpty,
              !isSubmittingMention
        else {
            return
        }

        let trimmedLinkTextSafe = trimmedLinkText.lowercased()
        
        let normalizedUrl =
            (trimmedLinkTextSafe.hasPrefix("http://") || trimmedLinkTextSafe.hasPrefix("https://")) ? trimmedLinkText :
            "https://\(trimmedLinkText)"

        isSubmittingMention = true
        errorMessage = nil

        Task {
            do {
                _ = try await CuratedMentionsManager.shared.submitContribution(
                    mentionId: mention?.id,
                    url: normalizedUrl
                )

                AnalyticsManager.CuratedMentions.submitSheetSubmitted()

                isSubmittingMention = false
                /// Flag first, then dismiss - the carousel opens the submissions
                /// sheet from this sheet's `onDismiss`, after it has fully closed.
                pendingOpenSubmissions = true
                dismiss()
            } catch {
                isSubmittingMention = false
                print("[MentionSubmitLinkSheet] Failed to submit social contribution mention: \(error.localizedDescription)")
                errorMessage = String.localized("Link has already been submitted", table: "App")
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                headerView
                InputField(
                    text: $linkText,
                    placeholder: placeholderText,
                    errorMessage: errorMessage,
                    colorConfig: .init(
                        background: Color.clear
                    ),
                    sizeConfig: .init(
                        height: 36,
                        cornerRadius: 12
                    )
                )
            }
            .padding(16)

            footerButtonsView
        }
        .frame(width: 345)
        .background(Color.surface3)
    }

    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText)
                .styleText(
                    size: 15,
                    weight: .medium
                )
            
            Text(instructionsText)
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
        }
    }

    // MARK: - Child Components: Footer Buttons View

    private var footerButtonsView: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer()
            
            TextButton(
                text: String.localized("Cancel", table: "App"),
                colorConfig: .init(
                    background: Color.T_9,
                    hoverBackground: Color.T_8
                ),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                ),
                statusConfig: .init(
                    disabled: isSubmittingMention
                )
            ) {
                AnalyticsManager.CuratedMentions.submitSheetCancelled()
                dismiss()
            }
            
            TextButton(
                type: .primary,
                text: String.localized("Submit", table: "App"),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                ),
                statusConfig: .init(
                    disabled: !canSubmit
                )
            ) {
                submit()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52, alignment: .center)
        .addBorder(
            sides: .top,
            cornerRadius: 0,
            stroke: Color.T_7
        )
    }
}
