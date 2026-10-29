// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportAddLinkSheet.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportAddLinkSheet: View {
    // MARK: - Properties
    
    @Binding var shouldShow: Bool
    @Binding var referralLink: ReferralLink?
    
    // MARK: - Observations

    @ObservedObject private var referralLinkManager = ReferralLinkManager.shared
    
    // MARK: - States

    @State private var linkText: String = ""
    @State private var selectedPlatform: ReferralLinkPlatform? = nil
    @State private var showPlatformPopover: Bool = false
    
    // MARK: - Private Variables

    private var isEditing: Bool {
        return referralLink != nil
    }

    private var placeholderText: String {
        if let placeholderText = selectedPlatform?.formPlaceholderText {
            return placeholderText
        } else {
            return String.localized("Paste a link", table: "App")
        }
    }

    private var platformIcon: ImageResource {
        if let selectedPlatform {
            switch selectedPlatform {
            case .github: return .logoGithub
            case .instagram: return .logoInstagram
            case .tiktok: return .logoTiktok
            case .x: return .logoX
            case .youtube: return .logoYoutube
            }
        } else {
            return .link
        }
    }

    private var isLoading: Bool {
        return
            referralLinkManager.isAddingLink ||
            referralLinkManager.isUpdatingLink ||
            referralLinkManager.isDeletingLink
    }

    private var errorMessage: String? {
        if isEditing {
            return
                referralLinkManager.updateLinkErrorMessage ??
                referralLinkManager.deleteLinkErrorMessage
        } else {
            return referralLinkManager.addLinkErrorMessage
        }
    }
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            formView
            errorMessageView
            footerButtonsView
        }
        .padding(16)
        .frame(width: 345)
        .onAppear {
            if let referralLink {
                linkText = referralLink.url
                selectedPlatform = ReferralLinkPlatform(from: referralLink.url)
            }
        }
        .onChange(of: linkText) { _, currentLinkText in
            selectedPlatform = ReferralLinkPlatform(from: currentLinkText)
        }
        .onDisappear {
            referralLinkManager.addLinkErrorMessage = nil
            referralLinkManager.updateLinkErrorMessage = nil
            referralLinkManager.deleteLinkErrorMessage = nil
        }
    }
    
    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String.localized("Add Link", table: "App"))
                .styleText(
                    weight: .regular
                )
        }
    }
    
    // MARK: - Child Components: Form View

    private var formView: some View {
        VStack(alignment: .leading, spacing: 6) {
            platformDropdown
            InputField(
                text: $linkText,
                placeholder: placeholderText,
                sizeConfig: .init(
                    height: 36,
                    cornerRadius: 12
                )
            )
        }
    }

    private var platformDropdown: some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9
            ),
            sizeConfig: .init(
                horizontalPadding: 12,
                height: 36,
                cornerRadius: 12
            )
        ) {
            HStack(alignment: .center, spacing: 6) {
                Image(platformIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14)
                    .foregroundColor(Color.S_0)
                Text(selectedPlatform?.displayName ?? String.localized("Link", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular
                    )
                Spacer()
                Image(systemName: "chevron.down")
                    .styleText(
                        size: 10,
                        weight: .regular
                    )
            }
        } action: {
            showPlatformPopover.toggle()
        }
        .frame(width: 150)
        .popover(
            isPresented: $showPlatformPopover,
            arrowEdge: .bottom
        ) {
            platformDropdownPopover
        }
    }

    private var platformDropdownPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            platformDropdownPopoverOption(nil, text: String.localized("Link", table: "App"))
            platformDropdownPopoverOption(.instagram, text: "Instagram")
            platformDropdownPopoverOption(.youtube, text: "YouTube")
            platformDropdownPopoverOption(.github, text: "GitHub")
            platformDropdownPopoverOption(.x, text: "X")
            platformDropdownPopoverOption(.tiktok, text: "TikTok")
        }
        .padding(8)
        .frame(
            width: 227,
            alignment: .leading
        )
    }

    private func platformDropdownPopoverOption(
        _ platform: ReferralLinkPlatform?,
        text: String
    ) -> some View {
        Button {
            if linkText.isEmpty {
                selectedPlatform = platform
            } else {
                selectedPlatform = ReferralLinkPlatform(from: linkText)
            }
            showPlatformPopover = false
        } label: {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "checkmark")
                    .styleText(
                        size: 10
                    )
                    .opacity(platform == selectedPlatform ? 1 : 0)
                Text(text)
                    .styleText(
                        size: 13,
                        weight: .regular
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 2)
    }
    
    // MARK: - Child Components: Error Message View

    @ViewBuilder
    private var errorMessageView: some View {
        if let errorMessage {
            Text(errorMessage)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.red500
                )
        }
    }
    
    // MARK: - Child Components: Form Buttons View

    private var footerButtonsView: some View {
        HStack(alignment: .center, spacing: 8) {
            if isEditing {
                SimpleButton(
                    text: String.localized("Remove", table: "App"),
                    textColor: Color.redDelete,
                    cornerRadius: 6,
                    action: {
                        guard let linkId = referralLink?.id else { return }
                        referralLinkManager.deleteLink(linkId: linkId) {
                            shouldShow = false
                        }
                    },
                    background: Color.redDelete.opacity(0.25)
                )
                .disabled(isLoading)
                .opacity(isLoading ? 0.5 : 1)
            }

            Spacer()

            SimpleButton(
                text: String.localized("Cancel", table: "App"),
                cornerRadius: 6,
                action: {
                    shouldShow = false
                }
            )
            .disabled(isLoading)

            SimpleButton(
                disabled: linkText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading,
                text: isEditing
                    ? String.localized("Save", table: "App")
                    : String.localized("Add", table: "App"),
                textColor: Color.white,
                cornerRadius: 6,
                action: {
                    let trimmed = linkText.trimmingCharacters(in: .whitespaces)
                    let lower = trimmed.lowercased()
                    let normalizedUrl = (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
                        ? trimmed
                        : "https://\(trimmed)"
                    if isEditing,
                       let linkId = referralLink?.id
                    {
                        referralLinkManager.updateLink(
                            linkId: linkId,
                            url: normalizedUrl
                        )
                    } else {
                        referralLinkManager.addLink(
                            url: normalizedUrl
                        )
                    }
                },
                background: Color.blue
            )
        }
    }
}
