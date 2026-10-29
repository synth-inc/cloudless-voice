// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsWindowSidebar.swift
//  Onit
//
//  Created by Loyd Kim on 2/23/26.
//

import Defaults
import SwiftUI

struct SettingsWindowSidebar: View {
    // MARK: - Defaults

    @Default(.settingsPage) private var settingsPage

    // MARK: - Environments

    @Environment(\.appState) var appState

    // MARK: - Observations

    @ObservedObject private var keyboardPermissionManager = KeyboardPermissionManager.shared

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            closeButton
            ScrollView {
                rootOptions
                dictationOptions
            }
            .padding(.bottom, 16)
        }
        .frame(width: 224)
        .background(Backgrounds.BrushedGlass())
        .background(Color.T_6)
        .overlay(
            Rectangle()
                .fill(Color.T_6)
                .frame(width: 1)
                .frame(maxHeight: .infinity),
            alignment: .trailing
        )
        .onAppear {
            handlePollingMacKeyboardSuggestionsDisabledState()
        }
        .onChange(of: settingsPage) { _, _ in
            handlePollingMacKeyboardSuggestionsDisabledState()
        }
        .onDisappear {
            keyboardPermissionManager.stopPollingIsMacKeyboardSuggestionsDisabledState()
        }
    }

    // MARK: - Child Components: Close Button

    private var closeButton: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                AppWindowManager.shared.showSettingsSheet = false
            } label: {
                Circle()
                    .fill(Color.systemRed)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38, alignment: .center)
    }

    // MARK: - Child Components

    private var rootOptions: some View {
        sidebarSection(
            pages: SettingsPage.rootCases,
            showDivider: false
        )
    }

    /// Dictation is the app's only product, so its settings are always available.
    private var dictationOptions: some View {
        sidebarSection(
            title: String.localized("Voice Dictation", table: "Settings"),
            pages: SettingsPage.transcriptionCases
        )
    }

    private func sidebarSection(
        title: String? = nil,
        pages: [SettingsPage],
        showDivider: Bool = true
    ) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            if showDivider {
                DividerHorizontal()
            }

            if let title = title {
                Text(title)
                    .styleText(
                        size: 13,
                        weight: .semibold,
                        color: Color.S_0
                    )
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
            }

            if !pages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pages, id: \.self) { page in
                        sidebarButton(for: page)
                    }
                }
                .padding([.horizontal, .bottom], 8)
            }
        }
    }

    private func sidebarButton(for page: SettingsPage) -> some View {
        TextButton(
            type: .clear,
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: 8,
                height: 32
            ),
            statusConfig: .init(
                selected: settingsPage == page
            )
        ) {
            HStack(alignment: .center, spacing: 10) {
                sidebarIcon(for: page)

                Text(page.name)
                    .styleText(size: 13)

                Spacer()

                if let notificationCount = getNotificationCount(for: page) {
                    Text("\(notificationCount)")
                        .frame(width: 18, height: 18)
                        .background(Color.red500)
                        .cornerRadius(999)
                        .styleText(
                            size: 11,
                            weight: .regular,
                            color: Color.white
                        )
                }
            }
        } action: {
            settingsPage = page
        }
    }

    private func sidebarIcon(for page: SettingsPage) -> some View {
        Image(systemName: page.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color.white)
            .frame(
                width: 20,
                alignment: .center
            )
            .frame(
                height: 20,
                alignment: .center
            )
            .background(page.iconBackgroundColor)
            .cornerRadius(5)
    }

    // MARK: - Private Functions

    private func handlePollingMacKeyboardSuggestionsDisabledState() {
        switch settingsPage {
        case .setup:
            keyboardPermissionManager.startPollingIsMacKeyboardSuggestionsDisabledState()
        default:
            keyboardPermissionManager.stopPollingIsMacKeyboardSuggestionsDisabledState()
        }
    }

    private func getNotificationCount(for settingsPage: SettingsPage) -> Int? {
        switch settingsPage {
        case .setup:
            return appState.setupBadgeCount
        default:
            return nil
        }
    }
}
