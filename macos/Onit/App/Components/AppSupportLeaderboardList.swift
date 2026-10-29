// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportLeaderboardList.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportLeaderboardList: View {
    // MARK: - Properties

    @Binding var viewInLeaderboardTrigger: Int

    // MARK: - Observations

    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var referralManager = ReferralManager.shared
    @ObservedObject private var referralLinkManager = ReferralLinkManager.shared

    // MARK: - States

    @State private var pendingScrollToUserReferralEntryInLeaderboard = false
    
    @State private var displayName = ""
    @State private var editingReferralLink: ReferralLink? = nil
    
    @State private var showDisplayNameFormSheet = false
    @State private var showAddLinkSheet = false

    // MARK: - Private Variables

    private let tableSpacing: CGFloat = 2
    private let leaderboardEntryRowHeight: CGFloat = 40
    
    private var leaderboardEntriesListViewMaxHeight: CGFloat {
        let maxLeaderboardEntriesInViewCount = 10
        
        let totalTableSpacingHeight = Int(tableSpacing) * (maxLeaderboardEntriesInViewCount - 1)
        let totalLeaderboardEntryHeight = Int(leaderboardEntryRowHeight) * maxLeaderboardEntriesInViewCount
        
        let totalHeight = totalTableSpacingHeight + totalLeaderboardEntryHeight
        return CGFloat(totalHeight)
    }

    private var isUserReferralLoadedInLeaderboard: Bool {
        guard let referralId = referralManager.referralId
        else {
            return false
        }
        
        return referralManager.leaderboardEntries.contains(where: {
            $0.id == referralId
        })
    }

    private var shouldShowPinnedLeaderboardEntry: Bool {
        guard referralManager.leaderboardRank?.rank != nil
        else {
            return false
        }
        
        return !isUserReferralLoadedInLeaderboard
    }
    
    // MARK: - Private Functions

    private func openDisplayNameFormSheetIfNeeded() {
        guard referralManager.referralId != nil else { return }

        if authManager.userLoggedIn {
            showDisplayNameFormSheet = true
        } else {
            OnboardingWindowManager.shared.showAuthOnly()
        }
    }

    private func handleReferralLinkClickIfNeeded(_ link: ReferralLink) {
        guard referralManager.referralId != nil else { return }

        /// Populate the edit sheet with the link details and then open the edit sheet.
        editingReferralLink = link
        showAddLinkSheet = true
    }

    private func processPendingScrollToUserReferralEntryInLeaderboard(with proxy: ScrollViewProxy) {
        guard pendingScrollToUserReferralEntryInLeaderboard else { return }

        if let referralId = referralManager.referralId,
           referralManager.leaderboardEntries.contains(where: { $0.id == referralId })
        {
            withAnimation {
                proxy.scrollTo(referralId, anchor: .center)
            }
        }

        pendingScrollToUserReferralEntryInLeaderboard = false
    }

    // MARK: - Body

    var body: some View {
        LoadingContainer(
            isLoading: referralManager.isFetchingFirstPage,
            loaderView: { loadingShimmers },
            loadedView: {
                if let errorMessage = referralManager.leaderboardErrorMessage {
                    Text(errorMessage)
                        .styleText(
                            weight: .regular,
                            color: Color.red500
                        )
                } else {
                    VStack(alignment: .leading, spacing: tableSpacing) {
                        leaderboardEntriesListView
                        pinnedLeaderboardEntryView
                        loadMoreLeaderboardEntriesButton
                    }
                    .padding(4)
                    .background(Color.special1)
                    .addBorder(
                        cornerRadius: 14,
                        stroke: Color.T_7
                    )
                }
            }
        )
        .onAppear {
            AnalyticsManager.Referral.leaderboardViewed()
            referralManager.resetAndFetchLeaderboard()
        }
        .onChange(of: referralManager.uniqueReferralCode) { _, uniqueReferralCode in
            guard uniqueReferralCode != nil else { return }
            referralManager.resetAndFetchLeaderboard()
        }
        .sheet(isPresented: $showDisplayNameFormSheet) {
            AppSupportDisplayNameFormSheet(
                shouldShow: $showDisplayNameFormSheet,
                displayName: $displayName
            )
        }
        .sheet(isPresented: $showAddLinkSheet) {
            AppSupportAddLinkSheet(
                shouldShow: $showAddLinkSheet,
                referralLink: $editingReferralLink
            )
        }
    }

    // MARK: - Child Components: Loading Shimmers

    private var loadingShimmers: some View {
        VStack(alignment: .leading, spacing: tableSpacing) {
            loadingShimmer
            loadingShimmer
            loadingShimmer
        }
    }

    private var loadingShimmer: some View {
        Shimmer(
            height: 32,
            cornerRadius: 8
        )
    }

    // MARK: - Child Components: Leaderboard Entries List View
    
    private var leaderboardEntriesListView: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: tableSpacing) {
                    if referralManager.leaderboardEntries.isEmpty {
                        dummyLeaderboardEntryRow
                    } else {
                        leaderboardEntriesView
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: leaderboardEntriesListViewMaxHeight)
            .onChange(of: viewInLeaderboardTrigger) { _, _ in
                /// Fast-path: If the user's row is already in the loaded entries, scroll directly. No fetch needed.
                if let referralId = referralManager.referralId,
                   referralManager.leaderboardEntries.contains(where: { $0.id == referralId })
                {
                    withAnimation {
                        scrollViewProxy.scrollTo(referralId, anchor: .center)
                    }
                    return
                }
                /// Otherwise, bulk-load every entry from rank 1 through to the page that contains the user's leaderboard entry.
                /// Once the response returns and populates `referralManager.leaderboardEntries`, `processPendingScrollToUserReferralEntryInLeaderboard` will perform the scroll.
                pendingScrollToUserReferralEntryInLeaderboard = true
                referralManager.loadLeaderboardUpToUserLeaderboardEntry()
            }
            .onChange(of: referralManager.leaderboardEntries.count) { _, _ in
                processPendingScrollToUserReferralEntryInLeaderboard(with: scrollViewProxy)
            }
        }
    }
    
    private var dummyLeaderboardEntryRow: some View {
        leaderboardEntryRow(
            leaderboardRank: 1,
            displayName: "Anonymous",
            completedInvitations: 1,
            mentions: 0,
            isUser: false,
            links: []
        )
    }
    
    private var leaderboardEntriesView: some View {
        ForEach(
            Array(referralManager.leaderboardEntries.enumerated()),
            id: \.element.id
        ) { index, entry in
            let leaderboardRank = index + 1
            let isUser = entry.id == referralManager.referralId
            
            leaderboardEntryRow(
                leaderboardRank: leaderboardRank,
                displayName: isUser
                    ? (referralManager.leaderboardRank?.displayName ?? entry.displayName)
                    : entry.displayName,
                completedInvitations: entry.completedInvitations,
                mentions: entry.mentions,
                isUser: isUser,
                links: entry.links.map { $0.url }
            )
            .id(entry.id)
        }
    }
    
    // MARK: - Child Components: Pinned Leaderboard Entry View
    
    @ViewBuilder
    private var pinnedLeaderboardEntryView: some View {
        if shouldShowPinnedLeaderboardEntry,
           let leaderboardRank = referralManager.leaderboardRank?.rank,
           let displayName = referralManager.leaderboardRank?.displayName,
           let completedInvitations = referralManager.leaderboardRank?.completedInvitations
        {
            leaderboardEntryRow(
                leaderboardRank: leaderboardRank,
                displayName: displayName,
                completedInvitations: completedInvitations,
                mentions: referralManager.leaderboardRank?.mentions ?? 0,
                isUser: true,
                links: []
            )
            .id("user-pinned-leaderboard-entry")
        }
    }

    // MARK: - Child Components: Load More Leaderboard Entries Footer

    @ViewBuilder
    private var loadMoreLeaderboardEntriesButton: some View {
        Group {
            if referralManager.isFetchingNextPage {
                Loader()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if referralManager.hasMorePages {
                Button {
                    referralManager.loadNextPage()
                } label: {
                    Text(String.localized("Load more", table: "App"))
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: Color.info500
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .hoverPointerStyle(.link)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    // MARK: - Child Components: Leaderboard Entry Row

    /// Builds the per-entry stats string, e.g. "30 invites · 1 comment".
    private func statsText(invites: Int, mentions: Int) -> String {
        var parts: [String] = []

        if invites > 0 {
            parts.append(
                invites == 1
                    ? String.localized("1 invite", table: "App")
                    : String(format: String.localized("%d invites", table: "App"), invites)
            )
        }

        if mentions > 0 {
            parts.append(
                mentions == 1
                    ? String.localized("1 comment", table: "App")
                    : String(format: String.localized("%d comments", table: "App"), mentions)
            )
        }

        if parts.isEmpty {
            parts.append(String.localized("1 invite", table: "App"))
        }

        return parts.joined(separator: " · ")
    }

    private func leaderboardEntryRow(
        leaderboardRank: Int,
        displayName: String,
        completedInvitations: Int,
        mentions: Int,
        isUser: Bool,
        links: [String]
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(String("\(leaderboardRank)."))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: isUser ? Color.S_0 : Color.T_1
                )

            Text(displayName)
                .styleText(
                    size: 13,
                    weight: .regular
                )
                .truncateText()

            if isUser {
                userIndicatorView
                userLinksView
                Spacer()
                openDisplayNameFormSheetButton
            } else {
                linksView(links)
                Spacer()
            }

            Text(statsText(invites: completedInvitations, mentions: mentions))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: isUser ? Color.S_0 : Color.T_1
                )
        }
        .padding(.horizontal, 10)
        .frame(height: leaderboardEntryRowHeight, alignment: .center)
        .background(isUser ? Color.info500.opacity(0.1) : Color.clear)
        .cornerRadius(10)
    }

    private var userIndicatorView: some View {
        Text(String.localized("You", table: "App"))
            .styleText(
                size: 11,
                color: Color.white
            )
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(Color.info500)
            .cornerRadius(5)
    }

    @ViewBuilder
    private var userLinksView: some View {
        if referralLinkManager.links.isEmpty {
            AddLinkButton {
                openDisplayNameFormSheetIfNeeded()
            }
        } else {
            HStack(alignment: .center, spacing: 2) {
                ForEach(referralLinkManager.links) { link in
                    AppSupportLeaderboardLinkButton(referralLink: link) {
                        handleReferralLinkClickIfNeeded(link)
                    }
                }
            }
        }
    }
    
    private struct AddLinkButton: View {
        let action: () -> Void

        @State private var isHovered: Bool = false
        @State private var isPressed: Bool = false

        var body: some View {
            Image(systemName: "plus")
                .styleText(
                    size: 14,
                    weight: .regular
                )
                .frame(width: 26, alignment: .center)
                .frame(height: 26, alignment: .center)
                .addButtonEffects(
                    background: Color.T_9,
                    hoverBackground: Color.T_9.opacity(0.7),
                    cornerRadius: 999,
                    isHovered: $isHovered,
                    isPressed: $isPressed
                ) {
                    action()
                }
                .onChange(of: isHovered) { _, hovering in
                    TooltipHelpers.setTooltipOnHover(
                        isHovering: hovering,
                        tooltipPrompt: String.localized("Add link", table: "App")
                    )
                }
        }
    }

    @ViewBuilder
    private func linksView(_ links: [String]) -> some View {
        if !links.isEmpty {
            HStack(alignment: .center, spacing: 2) {
                ForEach(links.indices, id: \.self) { index in
                    AppSupportLeaderboardEntryLinkButton(
                        referralLinkUrl: links[index]
                    )
                }
            }
        }
    }

    private var openDisplayNameFormSheetButton: some View {
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
                Text(authManager.userLoggedIn ?
                        String.localized("Edit", table: "App") :
                        String.localized("Log in to view & edit", table: "App")
                )
                .styleText(
                    size: 13,
                    weight: .regular
                )
                
                Image(systemName: authManager.userLoggedIn ? "pencil" : "arrow.right")
                    .styleText(
                        size: 10,
                        weight: .regular
                    )
            }
        } action: {
            openDisplayNameFormSheetIfNeeded()
        }
    }
}
