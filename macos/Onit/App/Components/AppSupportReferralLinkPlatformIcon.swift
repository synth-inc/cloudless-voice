// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportReferralLinkPlatformIcon.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportReferralLinkPlatformIcon: View {
    // MARK: - Types
    
    struct SizeConfig {
        let buttonSize: CGFloat
        let iconSize: CGFloat
    }
    
    // MARK: - Properties

    let referralLinkPlatform: ReferralLinkPlatform?
    var disabled: Bool = false
    let sizeConfig: SizeConfig
    let action: () -> Void
    
    // MARK: - States

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    
    // MARK: - Body

    var body: some View {
        referralLinkPlatformIcon
            .frame(
                width: sizeConfig.buttonSize,
                alignment: .center
            )
            .frame(
                height: sizeConfig.buttonSize,
                alignment: .center
            )
            .addButtonEffects(
                background: Color.T_9,
                hoverBackground: Color.T_9.opacity(0.7),
                cornerRadius: 999,
                disabled: disabled,
                isHovered: $isHovered,
                isPressed: $isPressed
            ) {
                action()
            }
            .addAnimation(dependency: isHovered)
    }
    
    // MARK: - Child Components: Referral Link Platform Icon

    private var referralLinkPlatformIcon: some View {
        Group {
            if let referralLinkPlatform {
                switch referralLinkPlatform {
                case .github:
                    Image(.logoGithub).resizable().renderingMode(.template)
                case .instagram:
                    Image(.logoInstagram).resizable().renderingMode(.template)
                case .tiktok:
                    Image(.logoTiktok).resizable().renderingMode(.template)
                case .x:
                    Image(.logoX).resizable().renderingMode(.template).padding(2)
                case .youtube:
                    Image(.logoYoutube).resizable().renderingMode(.template)
                }
            } else {
                Image(.link).resizable().renderingMode(.template).padding(1)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(
            width: sizeConfig.iconSize,
            height: sizeConfig.iconSize
        )
        .foregroundColor(
            Color.T_1
        )
    }
}
