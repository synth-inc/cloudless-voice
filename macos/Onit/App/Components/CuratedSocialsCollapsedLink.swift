// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialsCollapsedLink.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

struct CuratedSocialsCollapsedLink: View {
    // MARK: - Observables

    @ObservedObject private var curatedSocialsManager = CuratedSocialsManager.shared
    
    // MARK: - Body

    var body: some View {
        Button {
            AnalyticsManager.CuratedSocials.collapsedLinkPressed()
            AppWindowManager.shared.setPage(page: .support)
        } label: {
            (
                Text(
                    curatedSocialsManager.hasMore ?
                        String.localized("Daily stack completed, ", table: "App") :
                        String.localized("Stack completed, ", table: "App")
                )
                .font(.system(size: 14))
                .italic()
                .fontWeight(.regular)
                .foregroundColor(Color.T_1)
                +
                Text(String.localized("see more ways to spread the word →", table: "App"))
                    .font(.system(size: 14))
                    .italic()
                    .fontWeight(.regular)
                    .foregroundColor(Color.info500)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
