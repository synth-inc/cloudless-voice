// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportLeaderboardSection.swift
//  Onit
//
//  Created by Loyd Kim on 6/2/26.
//

import SwiftUI

struct AppSupportLeaderboardSection: View {
    // MARK: - Observations
    
    @ObservedObject var authManager = AuthManager.shared
    @ObservedObject var referralManager = ReferralManager.shared
    
    // MARK: - States
    
    @State private var viewInLeaderboardTrigger: Int = 0
    
    // MARK: - Body
    
    var body: some View {
        Group {
            leaderboardHeaderView
            AppSupportLeaderboardList(
                viewInLeaderboardTrigger: $viewInLeaderboardTrigger
            )
        }
    }
    
    // MARK: - Child Components: Leaderboard Header View

    private var leaderboardHeaderView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(String.localized("Our supporters, thank you!", table: "App"))
                    .styleText(
                        size: 15,
                        weight: .regular
                    )

                Spacer()
                
                LoadingContainer(
                    isLoading: referralManager.isFetchingLeaderboardRanking,
                    loaderView: {
                        Text(String.localized("Fetching your rank...", table: "App"))
                            .styleText(
                                size: 13,
                                weight: .regular,
                                color: Color.T_1
                            )
                    },
                    loadedView: {
                        if referralManager.leaderboardRankErrorMessage != nil {
                            Text(String.localized("Couldn't fetch rank.", table: "App"))
                                .styleText(
                                    weight: .regular,
                                    color: Color.red500
                                )
                        } else if !authManager.userLoggedIn {
                            loginCtaButton
                        } else if let rank = referralManager.leaderboardRank?.rank {
                            ViewInLeaderboardCtaButton(rank: rank) {
                                viewInLeaderboardTrigger += 1
                            }
                        } else {
                            leaderboardRankInviteCTATextView
                        }
                    }
                )
            }
            
            Text(String.localized("Climb our supporters list by inviting more.", table: "App"))
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
        }
    }
    
    private var loginCtaButton: some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                horizontalPadding: 6,
                height: 28
            )
        ) {
            HStack(alignment: .center, spacing: 3) {
                Text(String.localized("Log in to view & edit", table: "App"))
                .styleText(
                    size: 14,
                    weight: .regular
                )
                
                Image(systemName: "arrow.right")
                    .styleText(
                        size: 10,
                        weight: .regular
                    )
            }
        } action: {
            OnboardingWindowManager.shared.showAuthOnly()
        }
    }

    private struct ViewInLeaderboardCtaButton: View {
        let rank: Int
        let action: () -> Void

        @State private var isHovered: Bool = false

        var body: some View {
            Button {
                action()
            } label: {
                (
                    Text(String(format: String.localized("You are #%d - View & Edit ", table: "App"), rank)) +
                    Text(Image(systemName: "arrow.down"))
                )
                .styleText(
                    weight: .regular,
                    color: Color.T_1,
                    underline: isHovered
                )
                .addAnimation(dependency: isHovered)
            }
            .buttonStyle(PlainButtonStyle())
            .onHover { hovering in
                isHovered = hovering
            }
            .hoverPointerStyle(.link)
        }
    }

    private var leaderboardRankInviteCTATextView: some View {
        Text(String.localized("Invite to join the list", table: "App"))
            .styleText(
                italic: true,
                weight: .regular,
                color: Color.T_1
            )
    }
}
