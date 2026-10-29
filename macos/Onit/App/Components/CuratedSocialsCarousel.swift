// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialsCarousel.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

struct CuratedSocialsCarousel: View {
    // MARK: - Observations

    @ObservedObject private var curatedSocialsManager = CuratedSocialsManager.shared

    // MARK: - States

    @State private var carouselWidth: CGFloat = 0

    // MARK: - Private Variables

    private let cardWidth: CGFloat = 310
    
    private var centeringPadding: CGFloat {
        return max(0, (carouselWidth - cardWidth) / 2)
    }

    // MARK: - Private Functions

    private func settleCuratedSocialCardVariant(postId: Int) -> CuratedSocialCard.Variant {
        if curatedSocialsManager.thankYouFeedbackPostId == postId {
            return .thankYou
        } else if curatedSocialsManager.centeredPostId == postId {
            return .active
        } else {
            return .peek
        }
    }

    private func snapPostToCenter(using postId: Int) {
        guard curatedSocialsManager.centeredPostId != postId else { return }
        AnalyticsManager.CuratedSocials.carouselCardCentered(postId: postId)
        withAnimation {
            curatedSocialsManager.centeredPostId = postId
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            headerView
            cardsCarousel
            carouselControls
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.special2)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_8
        )
    }
    
    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(String.localized(
                "Comments Spotlight",
                table: "App"
            ))
            .styleText(
                size: 16,
                weight: .regular
            )

            Text(String.localized(
                "Upvote to support the community! Post a comment to get it featured.",
                table: "App"
            ))
            .styleText(
                weight: .regular,
                color: Color.T_1
            )
        }
    }

    // MARK: - Cards Carousel

    private var cardsCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 0) {
                cardsCarouselCenteringPaddingView

                HStack(alignment: .center, spacing: 16) {
                    ForEach(curatedSocialsManager.loadedPosts) { post in
                        let variant = settleCuratedSocialCardVariant(postId: post.id)
                        
                        CuratedSocialCard(
                            post: post,
                            variant: variant,
                            width: cardWidth,
                            ctaAction: {
                                curatedSocialsManager.contribute(to: post)
                            },
                            onClickAction: {
                                if variant == .peek {
                                    snapPostToCenter(using: post.id)
                                } else if variant == .active {
                                    AnalyticsManager.CuratedSocials.postOpened(
                                        postId: post.id,
                                        platform: post.platform?.rawValue
                                    )
                                    curatedSocialsManager.contribute(to: post)
                                }
                            }
                        )
                        .id(post.id)
                    }

                    if curatedSocialsManager.hasMore {
                        loadMorePostsButton
                            .id("loadMorePostsButton")
                    } else if curatedSocialsManager.hasThanksCard {
                        thanksForSupportCard
                            .id(CuratedSocialsManager.thanksCardCenterId)
                    }
                }

                cardsCarouselCenteringPaddingView
            }
        }
        // TODO: LOYD - Bring back manual scroll after adding scroll-based card "snap" handler. Also, bring in drag-to-snap functionality with same helper.
        .scrollDisabled(true)
        .scrollPosition(
            id: $curatedSocialsManager.centeredPostId,
            anchor: .center
        )
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        carouselWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        carouselWidth = newWidth
                    }
            }
        )
        .frame(height: 170)
    }
    
    private var cardsCarouselCenteringPaddingView: some View {
        Color.clear
            .frame(width: centeringPadding)
    }

    private var loadMorePostsButton: some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9
            ),
            sizeConfig: .init(
                horizontalPadding: 12,
                height: 36,
                cornerRadius: 10
            ),
            statusConfig: .init(
                disabled: curatedSocialsManager.isLoadingPosts
            )
        ) {
            HStack(alignment: .center, spacing: 4) {
                if curatedSocialsManager.isLoadingPosts {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.S_0)
                }

                Text(String.localized("More", table: "App"))
                    .styleText(
                        size: 14
                    )
            }
        } action: {
            guard !curatedSocialsManager.isLoadingPosts else { return }
            AnalyticsManager.CuratedSocials.morePressed()
            curatedSocialsManager.loadMorePosts()
        }
    }

    // MARK: - Thanks For Support Card

    private var thanksForSupportCard: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(Color.info500)

            Text(String.localized("Thanks for your support!", table: "App"))
                .styleText(
                    size: 16,
                    weight: .regular
                )

            Text(String.localized("More comments coming soon", table: "App"))
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
        }
        .frame(width: cardWidth, alignment: .center)
    }

    // MARK: - Carousel Controls

    private var carouselControls: some View {
        HStack(alignment: .center, spacing: 16) {
            chevronButton(
                systemName: "chevron.left",
                disabled: !curatedSocialsManager.canGoPrevious,
                tooltip: String.localized("Go to previous post", table: "App")
            ) {
                withAnimation {
                    curatedSocialsManager.goToPreviousPostItem()
                }
            }

            openAllButton

            chevronButton(
                systemName: "chevron.right",
                disabled: !curatedSocialsManager.canGoNext,
                tooltip: String.localized("Go to next post", table: "App")
            ) {
                withAnimation {
                    curatedSocialsManager.goToNextPostItem()
                }
            }
        }
    }

    private func chevronButton(
        systemName: String,
        disabled: Bool,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        IconButton(
            systemName: systemName,
            iconSize: 13,
            buttonSize: 32,
            inactiveColor: Color.S_0,
            cornerRadius: 999,
            disabled: disabled,
            tooltipPrompt: tooltip
        ) {
            action()
        }
    }

    private var openAllButton: some View {
        TextButton(
            text: String(
                format: String.localized("Open all (%d)", table: "App"),
                curatedSocialsManager.loadedPosts.count
            ),
            colorConfig: .init(
                background: Color.T_9
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: 12,
                height: 36,
                cornerRadius: 10
            ),
            statusConfig: .init(
                disabled: curatedSocialsManager.isLoadingPosts
            )
        ) {
            AnalyticsManager.CuratedSocials.openAllPressed(
                postCount: curatedSocialsManager.loadedPosts.count
            )
            curatedSocialsManager.contributeAllFetchedPosts()
        }
    }
}
