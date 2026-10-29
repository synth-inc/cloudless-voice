// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialsDailyStackDone.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

struct CuratedSocialsDailyStackDone: View {
    // MARK: - Observables
    
    @ObservedObject private var curatedSocialsManager = CuratedSocialsManager.shared
    
    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(String.localized("Daily stack completed!", table: "App"))
                .styleText(
                    size: 15,
                    weight: .regular
                )

            HStack(alignment: .center, spacing: 9) {
                if !curatedSocialsManager.openAllPostIds.isEmpty {
                    CuratedSocialsUndoOpenAllButton {
                        AnalyticsManager.CuratedSocials.undoOpenAllPressed()
                        curatedSocialsManager.undoContributeAllFetchedPosts()
                    }
                }

                CuratedSocialsLoadMoreButton(
                    isLoading: curatedSocialsManager.isLoadingPosts
                ) {
                    AnalyticsManager.CuratedSocials.loadMorePressed()
                    curatedSocialsManager.loadInitialPosts(isReloadingStack: true)
                }

                CloseDoneViewButton {
                    AnalyticsManager.CuratedSocials.dailyStackDoneDismissed()
                    curatedSocialsManager.dismissDailyStackDone()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.special2)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_8
        )
    }
}
