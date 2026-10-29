// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppHomeCuratedSocials.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import AppKit
import Defaults
import SwiftUI

struct AppHomeCuratedSocials: View {
    // MARK: - Defaults
    
    @Default(.appHomeCuratedSocialsSectionDismissedForever) private var sectionDismissedForever
    @Default(.appHomeCuratedSocialsSectionDismissedAt) private var sectionDismissedAt
    
    // MARK: - Observables

    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var curatedSocialsManager = CuratedSocialsManager.shared
    @ObservedObject private var curatedMentionsManager = CuratedMentionsManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var transcriptionHistoryManager = TranscriptionHistoryManager.shared
    
    // MARK: - States

    @State private var showHeaderPopover: Bool = false
    @State private var showYourSubmissionsSheet: Bool = false

    @State private var isHoveredYourCommentsButton: Bool = false
    @State private var isPressedYourCommentsButton: Bool = false
    
    // MARK: - Private Variables
    
    private var totalWords: Int {
        return transcriptionHistoryManager.lifetimeStats?.totalWords ?? 0
    }
    
    private var unlockedDictationStats: Bool {
        return totalWords >= LifetimeTranscriptionStats.wordCountUnlockThreshold
    }
    
    private var isDismissedForOneDay: Bool {
        return sectionDismissedAt != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            
            if !isDismissedForOneDay {
                // Only show the "Post a comment!" carousel when there are
                // missions to act on - otherwise hide it entirely (no empty
                // "all comments posted" placeholder card).
                if unlockedDictationStats, !curatedMentionsManager.missions.isEmpty {
                    AppHomeCommentMissionsCarousel(
                        showYourSubmissionsSheet: $showYourSubmissionsSheet
                    )
                }
                viewModeContent
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            curatedSocialsManager.loadInitialPosts()
            curatedMentionsManager.loadMyContributions()
            curatedMentionsManager.loadMissions()
        }
        .onChange(of: authManager.userLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                curatedSocialsManager.loadInitialPosts()
                curatedMentionsManager.loadMyContributions()
                curatedMentionsManager.loadMissions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task {
                await curatedSocialsManager.showThankYouFeedbackOnAppRefocusIfNeeded()
            }
        }
        .sheet(isPresented: $showYourSubmissionsSheet) {
            MentionYourSubmissionsSheet(shouldShow: $showYourSubmissionsSheet)
        }
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components: Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppHomeSectionHeader(
                iconSystemName: "heart",
                title: String.localized("Keep dictation local", table: "App"),
                isHidden: isDismissedForOneDay
            ) {
                HStack(alignment: .center, spacing: 2) {
                    yourCommentsButton
                    viewLeaderboardButton
                    headerViewMoreButton
                }
            }

            headerViewSubtitle
        }
    }

    private var yourCommentsButton: some View {
        HStack(alignment: .center, spacing: 3) {
            Text("\(curatedMentionsManager.myContributions.count)")
            Image(systemName: "text.bubble")
        }
        .styleText(
            size: 13,
            weight: .regular,
            color: isHoveredYourCommentsButton ? Color.S_0 : Color.T_2
        )
        .padding(.horizontal, 8)
        .frame(height: 32, alignment: .center)
        .addButtonEffects(
            background: Color.clear,
            hoverBackground: Color.T_9,
            cornerRadius: 8,
            isHovered: $isHoveredYourCommentsButton,
            isPressed: $isPressedYourCommentsButton,
            tooltipPrompt: String.localized("Your comments", table: "App")
        ) {
            AnalyticsManager.CuratedMentions.yourCommentsOpened()
            showYourSubmissionsSheet = true
        }
        .addAnimation(dependency: isHoveredYourCommentsButton)
        .onHover { isHoveredYourCommentsButton = $0 }
    }

    private var viewLeaderboardButton: some View {
        AppIconButton(
            systemName: "chart.bar",
            tooltip: String.localized("View leaderboard", table: "App")
        ) {
            AnalyticsManager.CuratedMentions.leaderboardPressed()
            AppWindowManager.shared.setPage(page: .support)
        }
    }

    private var headerViewMoreButton: some View {
        AppIconButton(
            systemName: "ellipsis",
            tooltip: isDismissedForOneDay ?
                String.localized("Show", table: "App") :
                String.localized("Hide", table: "App")
        ) {
            showHeaderPopover.toggle()
        }
        .popover(
            isPresented: $showHeaderPopover,
            arrowEdge: .bottom
        ) {
            headerViewMoreButtonPopover
        }
    }
    
    private var headerViewMoreButtonPopover: some View {
        PopoverButtonsView(
            items: [
                .init(
                    text: isDismissedForOneDay ?
                        String.localized("Unhide section", table: "App") :
                        String.localized("Hide for today", table: "App"),
                    action: {
                        if isDismissedForOneDay {
                            AnalyticsManager.CuratedSocials.sectionRestored()
                            sectionDismissedAt = nil
                            curatedSocialsManager.loadInitialPosts()
                        } else {
                            AnalyticsManager.CuratedSocials.sectionDismissed()
                            sectionDismissedAt = Date()
                            curatedSocialsManager.viewMode = .hidden
                        }
                        
                        showHeaderPopover = false
                    }
                ),
                .init(
                    text: String.localized("Remove section completely", table: "App"),
                    colorConfig: PopoverButtonsView.buttonColorConfig(
                        text: Color.red500,
                        hoverBackground: Color.red500.opacity(0.1)
                    ),
                    action: {
                        AnalyticsManager.CuratedSocials.sectionDismissedForever()
                        sectionDismissedForever = true
                        curatedSocialsManager.viewMode = .hidden
                        showHeaderPopover = false
                    }
                )
            ]
        )
    }
    
    @ViewBuilder
    private var headerViewSubtitle: some View {
        if !isDismissedForOneDay {
            Text(String.localized(
                "Post & upvote comments to help us spread the word! This way we can grow our community and keep building dictation that never leaves your Mac.",
                table: "App"
            ))
            .styleText(
                weight: .regular,
                color: Color.T_1
            )
        }
    }

    // MARK: - Child Components: View Mode Content

    @ViewBuilder
    private var viewModeContent: some View {
        switch curatedSocialsManager.viewMode {
        case .carousel:
            CuratedSocialsCarousel()
        case .dailyStackDone:
            CuratedSocialsDailyStackDone()
        case .stackDone:
            CuratedSocialsStackDone()
        case .stackDismissed:
            CuratedSocialsCollapsedLink()
        case .hidden:
            EmptyView()
        }
    }
}
