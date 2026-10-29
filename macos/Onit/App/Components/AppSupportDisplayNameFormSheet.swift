// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportDisplayNameFormSheet.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportDisplayNameFormSheet: View {
    // MARK: - Properties
    
    @Binding var shouldShow: Bool
    @Binding var displayName: String
    
    // MARK: - Observations

    @ObservedObject private var referralManager = ReferralManager.shared
    @ObservedObject private var referralLinkManager = ReferralLinkManager.shared
    @ObservedObject private var authManager = AuthManager.shared
    
    // MARK: - States

    @State private var editingReferralLink: ReferralLink? = nil
    @State private var showAddLinkSheet: Bool = false
    @State private var linkWasModified: Bool = false
    
    // MARK: - Private Variables

    private var cannotSave: Bool {
        let nameUnchanged = displayName == referralManager.leaderboardRank?.displayName
        return
            referralManager.isUpdatingDisplayName ||
            displayName.isEmpty ||
            displayName.count > 30 ||
            (nameUnchanged && !linkWasModified)
    }
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                headerSection
                displayNameForm
            }
            DividerHorizontal()
            addLinksSection
            footerButtons
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            if let existingDisplayName = referralManager.leaderboardRank?.displayName {
                displayName = existingDisplayName
            }
        }
        .onDisappear {
            referralManager.isUpdatingDisplayName = false
            referralManager.displayNameErrorMessage = nil
            displayName = ""
        }
        .sheet(isPresented: $showAddLinkSheet) {
            AppSupportAddLinkSheet(
                shouldShow: $showAddLinkSheet,
                referralLink: $editingReferralLink
            )
        }
        .onChange(of: referralLinkManager.isAddingLink) { _, isAdding in
            if !isAdding && showAddLinkSheet && referralLinkManager.addLinkErrorMessage == nil {
                showAddLinkSheet = false
                linkWasModified = true
            }
        }
        .onChange(of: referralLinkManager.isUpdatingLink) { _, isUpdating in
            if !isUpdating && showAddLinkSheet && referralLinkManager.updateLinkErrorMessage == nil {
                showAddLinkSheet = false
                linkWasModified = true
            }
        }
        .onChange(of: referralLinkManager.isDeletingLink) { _, isDeleting in
            if !isDeleting && showAddLinkSheet && referralLinkManager.deleteLinkErrorMessage == nil {
                showAddLinkSheet = false
                linkWasModified = true
            }
        }
    }
    
    // MARK: - Child Components: Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String.localized("Choose a Display Name", table: "App"))
                .styleText(size: 16)
            Text(String.localized("This is how others will see you in the list.", table: "App"))
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
        }
    }
    
    // MARK: - Child Components: Display Name Form

    private var displayNameForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            InputField(
                text: $displayName,
                placeholder: String.localized("Display name", table: "App"),
                errorMessage: referralManager.displayNameErrorMessage,
                sizeConfig: .init(
                    height: 36,
                    cornerRadius: 12
                )
            )

            Text(String.localized("Max 30 char", table: "App"))
                .padding(.leading, 12)
                .styleText(
                    size: 11,
                    weight: .regular,
                    color: displayName.count > 30 ? Color.red500 : Color.T_2
                )
        }
    }
    
    // MARK: - Child Components: Add Links Section

    private var addLinksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String.localized("Add Links", table: "App"))
                .styleText(
                    weight: .regular
                )
            Text(String.localized("Feel free to display your socials & sites.", table: "App"))
                .styleText(
                    weight: .light,
                    color: Color.T_1
                )
                .padding(.bottom, 2)

            if authManager.userLoggedIn {
                HStack(alignment: .center, spacing: 6) {
                    TextButton(
                        type: .iosBlue,
                        text: String.localized("+ Add", table: "App"),
                        sizeConfig: .init(
                            text: 13,
                            horizontalPadding: 12,
                            height: 36,
                            cornerRadius: 12
                        ),
                        statusConfig: .init(
                            disabled: referralLinkManager.hasReachedMaxLinks
                        )
                    ) {
                        editingReferralLink = nil
                        showAddLinkSheet = true
                    }

                    ForEach(referralLinkManager.links) { referralLink in
                        AppSupportLeaderboardLinkButton(
                            referralLink: referralLink,
                            inSheet: true
                        ) {
                            editingReferralLink = referralLink
                            showAddLinkSheet = true
                        }
                    }
                }
            } else {
                Text(String.localized("Log in to add links.", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_2
                    )
            }

            if referralLinkManager.hasReachedMaxLinks {
                Text(String.localized("Link limit reached", table: "App"))
                    .styleText(
                        size: 11,
                        weight: .regular,
                        color: Color.T_2
                    )
                    .padding(.top, 4)
                    .padding(.horizontal, 12)
            }
        }
    }
    
    // MARK: - Child Components: Footer Buttons

    private var footerButtons: some View {
        HStack(alignment: .center, spacing: 10) {
            Spacer()

            SimpleButton(
                text: String.localized("Cancel", table: "App"),
                cornerRadius: 6,
                action: {
                    shouldShow = false
                }
            )

            SimpleButton(
                disabled: cannotSave,
                text: String.localized("Save", table: "App"),
                textColor: Color.white,
                cornerRadius: 6,
                action: {
                    if displayName == referralManager.leaderboardRank?.displayName {
                        shouldShow = false
                    } else {
                        referralManager.updateReferralDisplayName(to: displayName) {
                            shouldShow = false
                        }
                    }
                },
                background: Color.blue
            )
        }
    }
}
