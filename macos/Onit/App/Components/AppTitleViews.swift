// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppTitleViews.swift
//  Onit
//
//  Created by Loyd Kim on 5/4/26.
//

import Defaults
import SwiftUI

@MainActor
struct AppTitleViews {
    // MARK: - Home Title
    
    struct Home: View {
        private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys
        @Default(TranscriptionConfigKeys.shortcutType) var transcriptionShortcutType
        /// These aren't explicitly read from in this file. They are used to allow `transcriptionShortcutType` to update in real time.
        @Default(TranscriptionConfigKeys.lastUsedCustomShortcutIndex) var transcriptionLastUsedCustomShortcutIndex
        @Default(TranscriptionConfigKeys.alternateSlotTypes) var transcriptionAlternateSlotTypes
        @Default(TranscriptionConfigKeys.customShortcutCount) var transcriptionCustomShortcutCount
        
        private let fontSize: CGFloat = 23
        
        var body: some View {
            HStack(alignment: .center, spacing: 9) {
                PageTitleView(
                    text: String.localized("Hold", table: "App"),
                    fontSize: fontSize
                )
                
                TextButton(
                    text: transcriptionShortcutType.displayNameSymbol,
                    colorConfig: .init(
                        background: Color.T_9,
                        hoverBackground: Color.T_8,
                        border: Color.T_9
                    ),
                    sizeConfig: .init(
                        text: 19,
                        textWeight: .regular,
                        horizontalPadding: 8,
                        height: 32
                    )
                ) {
                    Defaults[.settingsPage] = .transcriptionBehavior
                    AppWindowManager.shared.showSettingsSheet = true
                }
                
                PageTitleView(
                    text: String.localized("to dictate anywhere!", table: "App"),
                    fontSize: fontSize
                )
            }
        }
    }
    
    // MARK: - Page Title View
    
    struct PageTitleView: View {
        let text: String
        var fontSize: CGFloat = 19
        
        var body: some View {
            Text(text)
                .styleText(
                    fontFamily: .libreBaskerville,
                    size: fontSize,
                    weight: .regular
                )
        }
    }
}
