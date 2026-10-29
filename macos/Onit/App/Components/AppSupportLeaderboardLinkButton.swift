// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportLeaderboardLinkButton.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportLeaderboardLinkButton: View {
    // MARK: - Properties
    
    let referralLink: ReferralLink
    var inSheet: Bool = false
    let action: () -> Void
    
    // MARK: - Body

    var body: some View {
        AppSupportReferralLinkPlatformIcon(
            referralLinkPlatform: ReferralLinkPlatform(from: referralLink.url),
            sizeConfig: .init(
                buttonSize: inSheet ? 36 : 26,
                iconSize: inSheet ? 20 : 16
            )
        ) {
            action()
        }
    }
}
