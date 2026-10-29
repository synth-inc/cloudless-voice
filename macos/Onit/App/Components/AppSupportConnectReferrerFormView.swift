// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportConnectReferrerFormView.swift
//  Onit
//
//  Created by Loyd Kim on 4/14/26.
//

import SwiftUI

struct AppSupportConnectReferrerFormView: View {
    // MARK: - Observations
    
    @ObservedObject private var referralManager = ReferralManager.shared

    // MARK: - States
    
    @State private var referralInput: String = ""

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
            VStack(alignment: .leading, spacing: 8) {
                Text(String.localized("Were you referred by someone?", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_1
                    )

                HStack(alignment: .center, spacing: 7) {
                    InputField(
                        text: $referralInput,
                        placeholder: String.localized("Paste their code or link", table: "App"),
                        colorConfig: .init(
                            background: Color.T_9,
                            border: Color.clear
                        ),
                        sizeConfig: .init(
                            height: 32,
                            cornerRadius: 9
                        )
                    )

                    TextButton(
                        text: String.localized("Apply", table: "App"),
                        colorConfig: .init(
                            text: Color.S_10,
                            background: Color.S_0
                        ),
                        sizeConfig: .init(
                            textWeight: .regular,
                            horizontalPadding: 12,
                            height: 32,
                            cornerRadius: 9
                        ),
                        statusConfig: .init(
                            disabled: referralInput.isEmpty || referralManager.isApplyingReferrer
                        )
                    ) {
                        referralManager.applyReferrer(code: referralInput) {
                            referralInput = ""
                        }
                    }
                }

                if let error = referralManager.applyReferrerErrorMessage {
                    Text(error)
                        .styleText(
                            size: 12,
                            weight: .regular,
                            color: Color.red500
                        )
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 6)
        }
        .onDisappear {
            referralManager.applyReferrerErrorMessage = nil
        }
    }
}
