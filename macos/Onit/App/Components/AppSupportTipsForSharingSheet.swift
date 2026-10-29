// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportTipsForSharingSheet.swift
//  Onit
//
//  Created by Loyd Kim on 5/7/26.
//

import SwiftUI

struct AppSupportTipsForSharingSheet: View {
    // MARK: - Properties
    
    @Binding var shouldShow: Bool
    
    // MARK: - Private Variables

    private let talkingPoints: [String] = [
        String.localized("Wispr Flow costs $15 a month; Cloudless Pro is $5.99, less than half the price.", table: "App"),
        String.localized("Wispr Flow sends all your audio to the cloud; Cloudless works entirely on-device.", table: "App"),
        String.localized("Cloudless is the local version of Wispr Flow: same workflow, but your voice never leaves your Mac.", table: "App"),
        String.localized("Mention your invite link: downloads through it count toward your spot on our referral leaderboard (I'll give you a link).", table: "App"),
        String.localized("Cloudless works offline and without Wi-Fi.", table: "App"),
        String.localized("Cloudless is much better than Apple's built-in dictation (has a custom-built cleanup model).", table: "App")
    ]

    private let worthSharingPoints: [(
        title: String,
        body: String
    )] = [
        (
            String.localized("SEO purposes:", table: "App"),
            String.localized(
                "If you cover us now and rank around terms like \u{201C}local Wispr Flow alternative\u{201D} or \u{201C}private Wispr Flow,\u{201D} your video will be the top result. We predict a high volume of searches for these terms in the near future!",
                table: "App"
            )
        ),
        (
            String.localized("Get featured:", table: "App"),
            String.localized(
                "We'll promote your content in our app, and we have a referral leaderboard that tracks downloads through your invite link. Climb the list and every new user who opens Cloudless will see your channel. That's ongoing visibility long after your video goes up!",
                table: "App"
            )
        ),
        (
            String.localized("Share a great product:", table: "App"),
            String.localized(
                "An increasing number of people are looking for local, private alternatives to popular AI tools. AI dictation is no exception. Treat your audience to a genuinely great local app at half the price!",
                table: "App"
            )
        )
    ]
    
    private let germanGuyReviewerYouTubeVideoLink = "https://www.youtube.com/watch?v=XZzyZMO4_ys"
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            talkingPointsView
            worthSharingView
        }
        .padding(16)
        .frame(width: 600, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            closeButtonView
        }
    }
    
    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleTextView
            subtextView
        }
    }
    
    private var titleTextView: some View {
        Text(String.localized("Tips for sharing", table: "App"))
            .styleText(
                fontFamily: .libreBaskerville,
                size: 19,
                weight: .regular
            )
    }
    
    private var subtextView: some View {
        Text(String.localized(
            "Cloudless is a small, local-first product that relies on growth through word of mouth. By featuring us in your next YouTube video (or on other platforms), you help us keep building dictation that never leaves your Mac.",
            table: "App")
        )
        .styleText(
            weight: .regular
        )
    }
    
    // MARK: - Child Components: Talking Points View

    private var talkingPointsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            talkingPointsTitleTextView
            talkingPointsSubtextView
            talkingPointsBulletPointsView
            watchReviewVideoButton
        }
    }
    
    private var talkingPointsTitleTextView: some View {
        HStack(alignment: .center, spacing: 3) {
            Text("💬")
                .styleText(
                    size: 12
                )
            Text(String.localized("Talking points that work", table: "App"))
                .styleText(
                    size: 15
                )
        }
    }
    
    private var talkingPointsSubtextView: some View {
        Text(String.localized("We value your honest thoughts, but here is some inspiration if you need it:", table: "App"))
            .styleText(
                weight: .regular
            )
    }
    
    private var talkingPointsBulletPointsView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(talkingPoints, id: \.self) { point in
                bulletRow(text: Text(point))
            }
        }
    }
    
    @ViewBuilder
    private var watchReviewVideoButton: some View {
        if let youtubeReviewUrl = URL(string: germanGuyReviewerYouTubeVideoLink) {
            TextButton(
                text: String.localized("Watch this video to get an idea", table: "App"),
                iconConfig: .init(
                    leftIconName: "play.circle",
                    rightIconName: "arrow.up.right"
                ),
                colorConfig: .init(
                    rightIcon: Color.T_3,
                    background: Color.T_9
                ),
                sizeConfig: .init(
                    horizontalPadding: 6,
                    height: 32,
                    cornerRadius: 9
                ),
                alignmentConfig: .init(
                    gap: 4
                )
            ) {
                NSWorkspace.shared.open(youtubeReviewUrl)
            }
        }
    }
    
    // MARK: - Child Components: Worth Sharing View

    private var worthSharingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            worthSharingTitleTextView
            worthSharingBulletPointsView
        }
    }
    
    private var worthSharingTitleTextView: some View {
        HStack(alignment: .center, spacing: 3) {
            Text("❤️")
                .styleText(
                    size: 12
                )
            Text(String.localized("Why it's worth sharing", table: "App"))
                .styleText(
                    size: 15
                )
        }
    }
    
    private var worthSharingBulletPointsView: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(worthSharingPoints, id: \.title) { point in
                bulletRow(
                    text: Text(point.title).fontWeight(.bold) + Text(point.body)
                )
            }
        }
    }
    
    // MARK: - Child Components: Shared Views

    private func bulletRow(text: Text) -> some View {
        HStack(alignment: .top, spacing: 0) {
            bulletPointView
            
            text
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 14))
        .fontWeight(.regular)
        .foregroundColor(Color.S_0)
        .padding(.leading, 8)
    }
    
    private var bulletPointView: some View {
        Text("•")
            .font(.system(size: 14))
            .fontWeight(.regular)
            .frame(width: 13, alignment: .leading)
    }

    // MARK: - Child Components: Close Button View

    private var closeButtonView: some View {
        Button {
            shouldShow = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.T_3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 11)
        .padding(.trailing, 16)
    }
}
