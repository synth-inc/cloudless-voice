// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsWindowPages.swift
//  Onit
//
//  Created by Loyd Kim on 2/23/26.
//

import Defaults
import SwiftUI

struct SettingsWindowPages: View {
    // MARK: - Defaults
    
    @Default(.settingsPage) private var settingsPage
    
    // MARK: - Body
    
    var body: some View {
        if settingsPage.hasCustomScrolling {
            contentView
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                contentView
            }
        }
    }
    
    // MARK: - Child Components
    
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !settingsPage.rendersOwnHeader {
                pageViewHeaderView
            }
            pageContentView
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pageViewHeaderView: some View {
        pageViewHeaderTitleView()
    }
    
    private func pageViewHeaderTitleView(text: String? = nil) -> some View {
        Text(text ?? settingsPage.name)
            .styleText(
                size: 22,
                weight: .bold
            )
    }
    
    @ViewBuilder
    private var pageContentView: some View {
        switch self.settingsPage {

        /// Root Pages
        case .general:
            SettingsGeneral()
        case .accountAndBilling:
            SettingsAccountAndBilling()
        case .setup:
            SettingsSetup()
        case .about:
            SettingsAbout()

        /// Dictation Pages
        case .transcriptionBehavior:
            SettingsTranscriptionBehavior()
        case .transcriptionSmartFormatting:
            SettingsSmartFormatting()
        case .transcriptionRewrite:
            SettingsRewrite()
        case .transcriptionHistory:
            // History lives in the new App window; no Settings page yet.
            EmptyView()
        case .transcriptionNotifications:
            SettingsTranscriptionNotifications()
        #if DEBUG || ONIT_BETA
        case .transcriptionTraining:
            // Smart Cleanup training data; not listed without the library.
            #if canImport(TranscriptionCleanup)
            SettingsTranscriptionTraining()
            #else
            EmptyView()
            #endif
        case .transcriptionEval:
            SettingsTranscriptionEval()
        #endif
        }
    }
}
