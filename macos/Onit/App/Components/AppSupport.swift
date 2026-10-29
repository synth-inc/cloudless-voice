// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupport.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

struct AppSupport: View {
    // MARK: - Observations

    @ObservedObject var authManager = AuthManager.shared
    @ObservedObject var referralManager = ReferralManager.shared
    @ObservedObject var referralLinkManager = ReferralLinkManager.shared

    // MARK: - States

    @State private var hasFetchedReferrer = false

    // MARK: - Private Functions

    private func fetchLeaderboardDependents() {
        guard referralManager.uniqueReferralCode != nil else { return }
        referralLinkManager.fetchLinks()
        referralManager.fetchLeaderboardRank()
    }

    private func fetchReferrerIfNeeded() {
        if !hasFetchedReferrer {
            hasFetchedReferrer = true
            referralManager.fetchMyReferrer()
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageHeaderSection

            DividerHorizontal()

            AppSupportInvitationSection()

            DividerHorizontal()

            AppSupportLeaderboardSection()
        }
        .onAppear {
            referralManager.findOrCreateReferral()
            fetchLeaderboardDependents()
            fetchReferrerIfNeeded()
        }
        .onChange(of: referralManager.uniqueReferralCode) { _, _ in
            fetchLeaderboardDependents()
        }
        .onChange(of: authManager.userLoggedIn) { _, userLoggedIn in
            if userLoggedIn {
                hasFetchedReferrer = false
                fetchReferrerIfNeeded()
            }
        }
    }

    // MARK: - Child Components: Page Header Section

    private var pageHeaderSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                String.localized(
                    "Hi, We're a small team committed to keeping dictation local and private. Please support us by inviting and spreading the word to help grow our community.",
                    table: "App"
                )
            )
            .styleText(
                weight: .regular,
                color: Color.S_0
            )

            Text(String.localized("- Tim (CEO) & the Cloudless team", table: "App"))
                .styleText(
                    italic: true,
                    weight: .regular,
                    color: Color.T_2
                )
        }
    }
}
