// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportLeaderboardEntryLinkButton.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportLeaderboardEntryLinkButton: View {
    // MARK: - Properties
    
    let referralLinkUrl: String
    
    // MARK: - Body

    var body: some View {
        AppSupportReferralLinkPlatformIcon(
            referralLinkPlatform: ReferralLinkPlatform(from: referralLinkUrl),
            sizeConfig: .init(
                buttonSize: 26,
                iconSize: 16
            )
        ) {
            if let referralLinkUrl = URL(string: referralLinkUrl) {
                NSWorkspace.shared.open(referralLinkUrl)
            }
        }
    }
}
