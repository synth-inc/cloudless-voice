// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppHomeCommentMissionsCarousel.swift
//  Onit
//
//  Created by Loyd Kim on 6/1/26.
//

import AppKit
import SwiftUI

struct AppHomeCommentMissionsCarousel: View {
    // MARK: - Properties
    
    @Binding var showYourSubmissionsSheet: Bool
    
    // MARK: - Observations

    @ObservedObject private var curatedMentionsManager = CuratedMentionsManager.shared

    // MARK: - States

    @State private var currentIndex: Int = 0

    @State private var commentToSubmit: CuratedSocialMediaMention? = nil

    /// Set by the submit sheet on success so the sheet's `onDismiss` can open the
    /// "Your comments" sheet only after the submit sheet has fully dismissed.
    @State private var pendingOpenSubmissions: Bool = false

    @State private var isHoveredSampleCommentView: Bool = false
    @State private var isPressedSampleCommentView: Bool = false
    @State private var isCommentCopied: Bool = false
    @State private var isCommentCopiedTask: Task<Void, Error>? = nil

    // MARK: - Private Variables

    private var currentMission: CuratedSocialMediaMention? {
        guard currentIndex >= 0,
              currentIndex < curatedMentionsManager.missions.count
        else {
            return nil
        }
        
        return curatedMentionsManager.missions[currentIndex]
    }

    private var canGoPrevious: Bool {
        return currentIndex > 0
    }
    
    private var canGoNext: Bool {
        return currentIndex < curatedMentionsManager.missions.count - 1
    }

    // MARK: - Private Functions

    private func goToPrevious() {
        guard canGoPrevious else { return }
        AnalyticsManager.CuratedMentions.previousPressed()
        currentIndex -= 1
    }

    private func goToNext() {
        guard canGoNext else { return }
        AnalyticsManager.CuratedMentions.nextPressed()
        currentIndex += 1
    }

    private func prefetchMoreMissionsIfNeeded() {
        guard curatedMentionsManager.hasMoreMissions,
              currentIndex >= curatedMentionsManager.missions.count - 3
        else {
            return
        }

        curatedMentionsManager.loadMoreMissions()
    }

    private func openPost(_ mission: CuratedSocialMediaMention) {
        guard let urlString = mission.url,
              let url = URL(string: urlString)
        else {
            return
        }
        
        NSWorkspace.shared.open(url)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            headerView
            content
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.special1)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_8
        )
        .onAppear {
            curatedMentionsManager.loadMissions()
        }
        .onChange(of: curatedMentionsManager.missions.count) { _, newCount in
            if currentIndex >= newCount {
                currentIndex = max(0, newCount - 1)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            /// Reset the per-card "Copied!" state so it doesn't carry to the next mission.
            isCommentCopiedTask?.cancel()
            isCommentCopied = false
            prefetchMoreMissionsIfNeeded()
        }
        .sheet(
            item: $commentToSubmit,
            onDismiss: {
                /// Defer opening "Your comments" until the submit sheet has fully
                /// dismissed - presenting both in one runloop can drop the second.
                if pendingOpenSubmissions {
                    pendingOpenSubmissions = false
                    showYourSubmissionsSheet = true
                }
            }
        ) { mission in
            MentionSubmitLinkSheet(
                pendingOpenSubmissions: $pendingOpenSubmissions,
                mention: mission
            )
        }
    }

    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(String.localized(
                "Post a comment!", 
                table: "App"
            ))
            .styleText(
                size: 16,
                weight: .regular
            )

            Text(String.localized(
                "Comment to support us, climb the leaderboard and gain karma.",
                table: "App"
            ))
            .styleText(
                weight: .regular,
                color: Color.T_1
            )
        }
    }

    // MARK: - Child Components: Content

    @ViewBuilder
    private var content: some View {
        LoadingContainer(
            isLoading: curatedMentionsManager.isLoadingMissions,
            loaderView: {
                Loader()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            },
            loadedView: {
                if let currentMission {
                    HStack(alignment: .center, spacing: 16) {
                        contentNavigationButton(
                            systemName: "arrow.left",
                            disabled: !canGoPrevious,
                            tooltip: String.localized("Previous comment", table: "App")
                        ) {
                            goToPrevious()
                        }
                        
                        missionCard(currentMission)

                        if currentIndex == curatedMentionsManager.missions.count - 1,
                           curatedMentionsManager.isLoadingMoreMissions
                        {
                            Loader()
                                .frame(width: 32, alignment: .center)
                                .frame(height: 32, alignment: .center)
                        } else {
                            contentNavigationButton(
                                systemName: "arrow.forward",
                                disabled: !canGoNext,
                                tooltip: String.localized("Next comment", table: "App")
                            ) {
                                goToNext()
                            }
                        }
                    }
                } else {
                    // No missions to show - render nothing. The whole carousel
                    // is also gated out by the parent when missions are empty.
                    EmptyView()
                }
            }
        )
    }

    private func contentNavigationButton(
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
            hoverBackground: Color.T_9,
            cornerRadius: 8,
            disabled: disabled,
            tooltipPrompt: tooltip
        ) {
            action()
        }
    }

    // MARK: - Child Components: Mission Card

    private func missionCard(_ mission: CuratedSocialMediaMention) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                platformIconView(mission.platform)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mission.title)
                        .styleText(
                            weight: .regular
                        )
                        .truncateText()

                    if let subtitle = mission.subtitle,
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

            sampleCommentView(mission)

            HStack(alignment: .center, spacing: 8) {
                commentNowButton(mission)
                submitLinkButton(mission)
            }
            .padding(.horizontal, 56)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.T_9)
        .addBorder(
            cornerRadius: 28,
            stroke: Color.T_8,
            dotted: true
        )
    }
    
    private func platformIconView(
        _ platform: CuratedSocialMediaPostPlatform?
    ) -> some View {
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

    @ViewBuilder
    private func sampleCommentView(_ mission: CuratedSocialMediaMention) -> some View {
        if let body = mission.body,
           !body.isEmpty
        {
            VStack(alignment: .leading, spacing: 2) {
                Text(String.localized("Sample comment:", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_2
                    )
                    .frame(height: 24, alignment: .center)

                Text(body)
                    .styleText(
                        italic: true,
                        weight: .light
                    )
                    .truncateText(lineLimit: 3)
                    .padding(.bottom, 2)
                
                CopyCommentTextView(
                    isHovered: $isHoveredSampleCommentView,
                    isCopied: $isCommentCopied
                )
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.special1)
            .addBorder(
                cornerRadius: 20,
                stroke:
                    isCommentCopied ? Color.T_4 :
                    isHoveredSampleCommentView ? Color.info500 :
                    Color.T_4,
                dotted: true
            )
            .addButtonEffects(
                hoverBackground: Color.clear,
                cornerRadius: 20,
                isHovered: $isHoveredSampleCommentView,
                isPressed: $isPressedSampleCommentView
            ) {
                isCommentCopiedTask?.cancel()

                isCommentCopied = false
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(body, forType: .string)
                isCommentCopied = true

                isCommentCopiedTask = Task { @MainActor in
                    try await Task.sleep(for: .seconds(2))
                    isCommentCopied = false
                }
            }
            .addAnimation(dependency: [isHoveredSampleCommentView, isCommentCopied])
        }
    }
    
    private struct CopyCommentTextView: View {
        @Binding var isHovered: Bool
        @Binding var isCopied: Bool
        
        var body: some View {
            TextButton(
                text:
                    isCopied ? String.localized("Copied!", table: "App") :
                    isHovered ? String.localized("Copy comment", table: "App") :
                    "",
                iconConfig: .init(
                    leftIconName: isCopied ? "checkmark.circle.fill" : nil,
                    leftIconImage: isCopied ? nil : .copy
                ),
                colorConfig: .init(
                    text: Color.info500,
                    leftIcon: isHovered || isCopied ? Color.info500 : Color.T_2,
                    background: Color.clear,
                    hoverBackground: Color.clear
                ),
                sizeConfig: .init(
                    horizontalPadding: 6,
                    height: 28,
                    cornerRadius: 8
                ),
                alignmentConfig: .init(
                    gap: 4
                )
            ) {
            }
            .allowsHitTesting(false)
        }
    }

    private func commentNowButton(_ mission: CuratedSocialMediaMention) -> some View {
        TextButton(
            text: String.localized("Comment now!", table: "App"),
            colorConfig: .init(
                text: Color.S_10,
                background: Color.S_0
            ),
            sizeConfig: .init(
                horizontalPadding: 12,
                height: 36
            ),
            statusConfig: .init(
                fillContainer: true
            )
        ) {
            AnalyticsManager.CuratedMentions.commentNowPressed()
            openPost(mission)
        }
    }

    private func submitLinkButton(_ mission: CuratedSocialMediaMention) -> some View {
        TextButton(
            text: String.localized("Submit your link", table: "App"),
            iconConfig: .init(
                leftIconName: "link"
            ),
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                horizontalPadding: 12,
                height: 36
            ),
            alignmentConfig: .init(
                gap: 4
            ),
            statusConfig: .init(
                fillContainer: true
            )
        ) {
            AnalyticsManager.CuratedMentions.submitLinkPressed()
            commentToSubmit = mission
        }
    }
}
