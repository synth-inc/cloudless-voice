// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MentionYourSubmissionsSheet.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import SwiftUI

struct MentionYourSubmissionsSheet: View {
    // MARK: - Properties

    @Binding var shouldShow: Bool

    // MARK: - Observations

    @ObservedObject private var curatedMentionsManager = CuratedMentionsManager.shared
    
    // MARK: States

    @State private var isHoveredLeaderboard: Bool = false
    @State private var pendingDeleteContribution: MyMentionContribution? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            contentView
            footerView
        }
        .frame(width: 600, height: 460)
        .onAppear {
            curatedMentionsManager.loadMyContributions()
        }
        .alert(
            String.localized("Delete this comment?", table: "App"),
            isPresented: .init(
                get: { pendingDeleteContribution != nil },
                set: { if !$0 { pendingDeleteContribution = nil } }
            )
        ) {
            Button(String.localized("Cancel", table: "App"), role: .cancel) {
                pendingDeleteContribution = nil
            }
            Button(String.localized("Delete", table: "App"), role: .destructive) {
                if let contribution = pendingDeleteContribution {
                    curatedMentionsManager.deleteMyContribution(contribution)
                }
                pendingDeleteContribution = nil
            }
        } message: {
            Text(String.localized(
                "This permanently removes your submitted link and can't be undone.",
                table: "App"
            ))
        }
    }

    // MARK: - Child Components: Header View

    private var headerView: some View {
        Text(String.localized("Your comments", table: "App"))
            .styleText(
                size: 15,
                weight: .regular
            )
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    // MARK: - Child Components: Content View

    private var contentView: some View {
        LoadingContainer(
            isLoading: curatedMentionsManager.isLoadingMyContributions,
            loaderView: {
                Loader()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .center)
            },
            loadedView: {
                if curatedMentionsManager.myContributions.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(curatedMentionsManager.myContributions) { contribution in
                                submissionRow(contribution)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyStateView: some View {
        Button {
            shouldShow = false
            AppWindowManager.shared.setPage(page: .support)
        } label: {
            (
                Text(String.localized(
                    "Post a comment and submit your link to climb the ",
                    table: "App"
                )) +

                Text(String.localized(
                    "leaderboard",
                    table: "App"
                ))
                .underline(true)
                .foregroundColor(isHoveredLeaderboard ? Color.S_0 : Color.T_1) +

                Text(String.localized(
                    " and get karma!",
                    table: "App"
                ))
            )
            .styleText(
                weight: .regular,
                color: Color.T_1,
                align: .center
            )
            .contentShape(Rectangle())
            .hoverPointerStyle(.link)
            .onHover { isHoveredLeaderboard = $0 }
            .addAnimation(dependency: isHoveredLeaderboard)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func submissionRow(_ contribution: MyMentionContribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                platformIconView(contribution.platform)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contribution.title)
                        .styleText(
                            size: 14,
                            weight: .regular
                        )
                        .truncateText()

                    if let subtitle = contribution.subtitle,
                       !subtitle.isEmpty
                    {
                        Text(subtitle)
                            .styleText(
                                size: 12,
                                weight: .regular,
                                color: Color.T_2
                            )
                            .truncateText()
                    }
                }
            }
            .padding(.leading, 8)

            if let body = contribution.body,
               !body.isEmpty
            {
                Text(body)
                    .styleText(
                        weight: .regular
                    )
                    .truncateText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 8) {
                Spacer()

                deleteContributionButton(contribution)
                viewContributionButton(contribution)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.S_10)
        .addBorder(
            cornerRadius: 28,
            stroke: Color.T_4,
            dotted: true
        )
    }

    private func platformIconView(_ platform: CuratedSocialMediaPostPlatform?) -> some View {
        Image(platform?.logoImage ?? .link)
            .resizable()
            .renderingMode(platform == .reddit ? nil : .template)
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24, alignment: .center)
            .foregroundColor(
                platform == .reddit ? nil :
                platform == .youtube ? Color.red :
                Color.S_0
            )
    }
    
    private func deleteContributionButton(_ contribution: MyMentionContribution) -> some View {
        AppIconButton(
            systemName: "trash",
            tooltip: String.localized("Delete submitted comment.", table: "App")
        ) {
            pendingDeleteContribution = contribution
        }
    }

    @ViewBuilder
    private func viewContributionButton(_ contribution: MyMentionContribution) -> some View {
        if let contributionUrl = URL(string: contribution.url) {
            TextButton(
                text: String.localized("View", table: "App"),
                iconConfig: .init(
                    leftIconName: "link"
                ),
                colorConfig: .init(
                    background: Color.T_9,
                    hoverBackground: Color.T_8
                ),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 32
                ),
                alignmentConfig: .init(
                    gap: 4
                )
            ) {
                NSWorkspace.shared.open(contributionUrl)
            }
        }
    }

    // MARK: - Child Components: Footer View

    private var footerView: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer()
            
            TextButton(
                type: .primary,
                text: String.localized("Done", table: "App"),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                )
            ) {
                shouldShow = false
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52, alignment: .center)
        .background(Color.surface3)
        .addBorder(
            sides: .top,
            cornerRadius: 0,
            stroke: Color.T_7
        )
    }
}
