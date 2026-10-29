// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ReferralInviteCard.swift
//  Onit
//
//  Created by Loyd Kim on 3/30/26.
//

import SwiftUI

struct ReferralInviteCard: View {
    // MARK: - Properties
    
    var inOnboarding: Bool = false
    var showCopyCodeButton: Bool = true
    
    // MARK: - Observations
    
    @ObservedObject private var referralManager = ReferralManager.shared
    
    // MARK: - States

    @State private var showCopiedCodeConfirmation = false
    @State private var showCopiedUrlConfirmation = false
    
    // MARK: - Private Functions
    
    private func copyReferralCode(_ uniqueReferralCode: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(uniqueReferralCode, forType: .string)
        
        showCopiedCodeConfirmation = true
        
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showCopiedCodeConfirmation = false
        }
    }
    
    private func copyReferralLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(referralManager.referralURL, forType: .string)

        showCopiedUrlConfirmation = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            showCopiedUrlConfirmation = false
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        SettingsPageSection(
            size: .init(
                cornerRadius: 14,
                padding: 8
            ),
            color: .init(
                background: Color.special1,
                border: Color.T_8
            )
        ) {
            HStack(alignment: .center, spacing: 7) {
                Text(referralManager.referralURL)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .styleText(
                        weight: .regular,
                        color: Color.T_1
                    )
                    .truncateText()

                copyReferralCodeButton
                copyReferralUrlButton
            }
            .padding(.leading, 6)
        }
    }
    
    // MARK: - Child Components
    
    @ViewBuilder
    private var copyReferralCodeButton: some View {
        if let uniqueReferralCode = referralManager.uniqueReferralCode,
           showCopyCodeButton
        {
            pillButton(
                text: showCopiedCodeConfirmation
                    ? String.localized("Copied!", table: "Settings")
                    : String.localized("Copy Code", table: "Settings"),
                disabled: showCopiedCodeConfirmation,
                isPrimary: false
            ) {
                copyReferralCode(uniqueReferralCode)
            }
        }
    }
    
    private var copyReferralUrlButton: some View {
        pillButton(
            text: showCopiedUrlConfirmation
                ? String.localized("Copied!", table: "Settings")
                : inOnboarding ?
                    String.localized("Copy Invite Link", table: "Onboarding") :
                    String.localized("Copy Link", table: "Settings"),
            disabled: showCopiedUrlConfirmation,
            isPrimary: true
        ) {
            copyReferralLink()
        }
    }
    
    private func pillButton(
        text: String,
        disabled: Bool,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(
            text: text,
            colorConfig: .init(
                text: isPrimary ? Color.S_10 : Color.S_0,
                background: isPrimary ? Color.S_0 : Color.clear,
                border: isPrimary ? Color.clear : Color.T_7
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: 12,
                height: 32,
                cornerRadius: 9
            ),
            statusConfig: .init(
                disabled: disabled,
                shouldFadeOnDisabled: false
            )
        ) {
            action()
        }
    }
}
