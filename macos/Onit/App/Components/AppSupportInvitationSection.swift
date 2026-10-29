// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportInvitationSection.swift
//  Onit
//
//  Created by Loyd Kim on 6/2/26.
//

import Defaults
import SwiftUI

struct AppSupportInvitationSection: View {
    // MARK: - Observations
    
    @ObservedObject var referralManager = ReferralManager.shared
    
    // MARK: - States
    
    @State private var showTipsForSharingSheet: Bool = false
    
    // MARK: - Private Variables
    
    private let onitTwitterPostUrl = "https://x.com/intent/tweet"
    private let onitYouTubePageUrl = "https://www.youtube.com/@getonit-ai"

    // MARK: - Private Functions

    /// Sends the user to the Home "Keep dictation local" section to post a curated
    /// comment. That section can be hidden for today or removed entirely, so this
    /// reverses both dismissal states first, reloads so the carousel re-derives
    /// its view mode (otherwise a same-day `dismissedAt` would re-hide it), then
    /// navigates to the Home page.
    private func showCuratedSocialsSectionOnHome() {
        Defaults[.appHomeCuratedSocialsSectionDismissedForever] = false
        Defaults[.appHomeCuratedSocialsSectionDismissedAt] = nil
        CuratedSocialsManager.shared.loadInitialPosts()
        AppWindowManager.shared.setPage(page: .home)
    }

    // MARK: - Body
    
    var body: some View {
        Group {
            inviteSection
            socialContributionsSection
        }
        .sheet(isPresented: $showTipsForSharingSheet) {
            AppSupportTipsForSharingSheet(shouldShow: $showTipsForSharingSheet)
        }
    }
    
    // MARK: - Child Components: Invite Section
    
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 0) {
                inviteLinkHeader
                AppSupportCompletedInvitationsView(showTipsForSharingSheet: $showTipsForSharingSheet)
            }
            
            inviteLinkSection
            
            if referralManager.hasCheckedReferrer && referralManager.referrer == nil {
                AppSupportConnectReferrerFormView()
            }
            
            referredByView
        }
    }

    private var inviteLinkHeader: some View {
        Text(String.localized("Invite with your link!", table: "App"))
            .styleText(
                size: 15,
                weight: .regular
            )
    }

    @ViewBuilder
    private var inviteLinkSection: some View {
        if referralManager.failedToGenerateUniqueReferralCode {
            failedToGenerateUniqueReferralCodeView
        } else {
            LoadingContainer(
                isLoading: referralManager.isGeneratingUniqueReferralCode,
                loaderView: { Loader() },
                loadedView: { ReferralInviteCard() }
            )
        }
    }

    private var failedToGenerateUniqueReferralCodeView: some View {
        SettingsPageSection() {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized(
                        "We couldn't generate your unique referral code.",
                        table: "App"
                    ),
                    subtitle: String.localized(
                        "Please click on the retry button to try again.",
                        table: "App"
                    )
                )
            ) {
                IconButton(
                    systemName: "arrow.trianglehead.counterclockwise.rotate.90",
                    action: {
                        referralManager.findOrCreateReferral()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var referredByView: some View {
        if let referrer = referralManager.referrer {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "person.fill.checkmark")
                Text(String.localized("Referred by", table: "App") + " \(referrer.displayName)")
            }
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.T_1
            )
        }
    }
    
    // MARK: - Child Components: Social Contributions Section
    
    private var socialContributionsSection: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                redditContributionCard
                twitterContributionCard
                youTubeContributionCard
            }
        }
        .scrollIndicators(.hidden)
    }
    
    @ViewBuilder
    private var twitterContributionCard: some View {
        if let twitterUrl = URL(string: onitTwitterPostUrl) {
            AppSupportSocialContributionView(
                icon: .logoX,
                iconColor: Color.S_0,
                title: String.localized("Mention us on X", table: "App")
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Post about Cloudless Voice on X.", table: "App"))
                        .font(.system(size: 14))
                        .foregroundColor(Color.T_1)
                        .fontWeight(.regular)

                    Text(String.localized("Tip: Share your stats!", table: "App"))
                        .styleText(
                            weight: .regular,
                            color: Color.T_1
                        )
                }
            } action: {
                NSWorkspace.shared.open(twitterUrl)
            }
        }
    }
    
    @ViewBuilder
    private var youTubeContributionCard: some View {
        if let youtubeUrl = URL(string: onitYouTubePageUrl) {
            AppSupportSocialContributionView(
                icon: .logoYoutube,
                iconColor: Color.red500,
                title: String.localized("Feature us on YouTube", table: "App"),
                description: String.localized("Share your thoughts on Cloudless in your next video.", table: "App"),
                footerButton: .init(
                    text: String.localized("💡 Tips and ideas", table: "App"),
                    action: {
                        showTipsForSharingSheet = true
                    }
                )
            ) {
                NSWorkspace.shared.open(youtubeUrl)
            }
        }
    }
    
    private var redditContributionCard: some View {
        AppSupportSocialContributionView(
            icon: .logoRedditFilled,
            title: String.localized("Mention us on Reddit", table: "App"),
            description: String.localized("Post one of our pre-written comments!", table: "App")
        ) {
            showCuratedSocialsSectionOnHome()
        }
    }
}
