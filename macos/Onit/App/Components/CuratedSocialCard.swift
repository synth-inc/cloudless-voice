// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialCard.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

struct CuratedSocialCard: View {
    // MARK: - Types
    
    enum Variant: Equatable {
        case active
        case peek
        case thankYou
    }
    
    // MARK: - Properties

    let post: CuratedSocialMediaPost
    let variant: Variant
    let width: CGFloat
    let ctaAction: () -> Void
    let onClickAction: () -> Void
    
    // MARK: - States
    
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    
    @State private var showInfoPopover: Bool = false
    
    // MARK: - Private Variables
    
    private let cornerRadius: CGFloat = 26
    
    private var contributionIconName: String {
        guard let platform = post.platform else { return "heart" }
        
        switch platform {
        case .reddit:
            return "arrowshape.up"
        case .youtube:
            return "hand.thumbsup"
        case .x:
            return "heart"
        }
    }

    private var ctaButtonBackgroundColor: Color {
        switch variant {
        case .active, .peek:
            return Color.S_0
        case .thankYou:
            return Color.T_9
        }
    }

    private var ctaButtonTextColor: Color {
        switch variant {
        case .active, .peek:
            return Color.S_10
        case .thankYou:
            return Color.T_3
        }
    }
    
    private var ctaText: String {
        switch variant {
        case .active, .peek:
            return
                post.platform?.ctaLabel ??
                String.localized("Open", table: "App")
        case .thankYou:
            return String.localized("Thank you", table: "App")
        }
    }
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                headerSection
                bodyTextSection
            }
            
            if variant != .peek {
                footerSection
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, variant == .peek ? 18 : 12)
        .frame(width: width, alignment: .center)
        .addButtonEffects(
            background: Color.S_10,
            hoverBackground: Color.S_10.opacity(variant == .peek ? 1.0 : 0.7),
            cornerRadius: cornerRadius,
            disabled: variant == .thankYou,
            shouldFadeOnDisabled: false,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            onClickAction()
        }
        .addBorder(
            cornerRadius: cornerRadius,
            stroke: variant == .peek ? Color.clear : Color.T_8
        )
        .opacity(variant == .peek ? 0.6 : 1.0)
        .allowsHitTesting(variant != .thankYou)
    }

    // MARK: - Child Components: Header Section

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 10) {
            platformIconView

            VStack(alignment: .leading, spacing: 1) {
                Text(post.title)
                    .styleText(
                        size: 15,
                        weight: .regular
                    )
                    .truncateText()

                Text(post.subtitle)
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_2
                    )
                    .truncateText()
            }
        }
    }

    private var platformIconView: some View {
        Image(post.platform?.logoImage ?? .link)
            .resizable()
            .renderingMode(post.platform == .reddit ? nil : .template)
            .aspectRatio(contentMode: .fit)
            .frame(
                width: 24,
                height: 24,
                alignment: .center
            )
            .foregroundColor(
                post.platform == .reddit ? nil :
                post.platform == .youtube ? Color.red :
                Color.S_0
            )
    }
    
    // MARK: - Child Components: Body Text Section

    private var bodyTextSection: some View {
        Text(post.body)
            .styleText(
                size: 16,
                weight: .regular
            )
            .frame(
                maxHeight: variant != .peek ? .infinity : nil,
                alignment: .top
            )
            .truncateText(lineLimit: 2)
    }

    // MARK: - Child Components: Footer Section

    private var footerSection: some View {
        HStack(alignment: .center, spacing: 0) {
            infoButton
                .opacity(0)
                .allowsHitTesting(false)
            Spacer()
            ctaButton
            Spacer()
            infoButton
        }
    }
    
    @ViewBuilder
    private var contributionCountView: some View {
        if post.contributionCount > 0 {
            HStack(alignment: .center, spacing: 2) {
                Image(systemName: contributionIconName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.T_1)

                Text("\(post.contributionCount)")
                    .styleText(
                        size: 11,
                        weight: .regular,
                        color: Color.T_2
                    )
            }
        }
    }
    
    @ViewBuilder
    private var infoButton: some View {
        if let platform = post.platform,
           platform == .youtube
        {
            Button {
                AnalyticsManager.CuratedSocials.youtubeInfoClicked(postId: post.id)
                showInfoPopover = true
            } label: {
                Image(systemName: "info.circle")
                    .styleText(
                        size: 14,
                        color: Color.T_2
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: $showInfoPopover) {
                Text(String.localized(
                    "This comment is the \"Highlighted Comment\" at the top of the comments section.",
                    table: "App"
                ))
                .padding(8)
                .frame(width: 180)
                .styleText(
                    size: 12,
                    weight: .regular
                )
            }
        }
    }

    private var ctaButton: some View {
        TextButton(
            colorConfig: .init(
                background: ctaButtonBackgroundColor
            ),
            sizeConfig: .init(
                horizontalPadding: 15,
                height: 36,
                cornerRadius: 10
            ),
            statusConfig: .init(
                disabled: variant == .thankYou,
                shouldFadeOnDisabled: false
            )
        ) {
            HStack(alignment: .center, spacing: 0) {
                ctaButtonIcon.opacity(0)
                Spacer()
                Text(ctaText)
                    .styleText(
                        weight: .regular,
                        color: ctaButtonTextColor
                    )
                Spacer()
                ctaButtonIcon
            }
            .frame(width: 135, alignment: .center)
        } action: {
            AnalyticsManager.CuratedSocials.postOpened(
                postId: post.id,
                platform: post.platform?.rawValue
            )
            ctaAction()
        }
    }
    
    @ViewBuilder
    private var ctaButtonIcon: some View {
        if variant == .active {
            Image(systemName: "arrow.up.right")
                .styleText(
                    size: 10,
                    color: ctaButtonTextColor
                )
        }
    }
}
