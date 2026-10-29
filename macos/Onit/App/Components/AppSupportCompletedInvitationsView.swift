// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportCompletedInvitationsView.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportCompletedInvitationsView: View {
    // MARK: - Properties
    
    @Binding var showTipsForSharingSheet: Bool
    
    // MARK: - Observations
    
    @ObservedObject private var referralManager = ReferralManager.shared
    
    // MARK: - States

    @State private var hasFetched = false
    @State private var infoPopoverOpen: Bool = false
    
    // MARK: - Body

    var body: some View {
        Group {
            if let errorMessage = referralManager.completedInvitationsErrorMessage {
                Text(errorMessage)
                    .styleText(
                        size: 13,
                        color: Color.red500
                    )
            } else {
                LoadingContainer(
                    isLoading: referralManager.isFetchingCompletedInvitationsCount,
                    loaderView: {
                        Text(String.localized(
                            "Fetching your completed invitations count...",
                            table: "App"
                        ))
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: Color.T_1
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    },
                    loadedView: {
                        if let completedInvitationsCount = referralManager.completedInvitations?.count {
                            completedInvitationsButton(completedInvitationsCount)
                        } else {
                            noSharedInvitationsView
                        }
                    },
                )
            }
        }
        .onAppear {
            guard !hasFetched else { return }
            hasFetched = true
            referralManager.fetchCompletedInvitationsCount()
        }
        .onChange(of: referralManager.uniqueReferralCode) { _, code in
            guard code != nil else { return }
            referralManager.fetchCompletedInvitationsCount()
        }
    }
    
    // MARK: - Child Components: Completed Invitations Button

    private func completedInvitationsButton(_ count: Int) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Button {
                showTipsForSharingSheet = true
            } label: {
                Text(
                    count == 1
                        ? String.localized("%d Completed Invitation", table: "App", count)
                        : String.localized("%d Completed Invitations", table: "App", count)
                )
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.T_1
                )
            }
            .buttonStyle(PlainButtonStyle())
            .hoverPointerStyle(.link)

            showTipsForSharingSheetButton(
                text: String.localized(
                    "Your invitation counts as completed once your invitees sign up.",
                    table: "App")
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    // MARK: - Child Components: No Shared Invitations View

    private var noSharedInvitationsView: some View {
        HStack(alignment: .center, spacing: 4) {
            Spacer()
            showTipsForSharingSheetButton(
                text: String.localized(
                    "Invite others to sign up to see your completed invitation counts here!",
                    table: "App")
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    // MARK: - Child Components: Show Tips For Sharing Sheet Button

    private func showTipsForSharingSheetButton(text: String) -> some View {
        Button {
            infoPopoverOpen = true
        } label: {
            Image(systemName: "questionmark.circle")
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.T_1
                )
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $infoPopoverOpen) {
            Text(text)
                .padding(8)
                .frame(width: 240)
        }
        .hoverPointerStyle(.link)
    }
}
