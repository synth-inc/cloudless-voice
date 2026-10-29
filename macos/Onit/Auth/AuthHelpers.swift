// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AuthHelpers.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/25.
//

import Defaults
import SwiftUI

// MARK: - Auth Helper Functions

@MainActor
enum AuthHelpers {
    static func createAnAccountButton(callback: (() -> Void)? = nil) -> some View {
        SimpleButton(
            iconSystem: "person.crop.circle",
            iconColor: Color.white,
            text: String.localized("Create an account"),
            textColor: Color.white,
            action: {
                AnalyticsManager.AccountEvents.createAccountPressed()
                Defaults[.authFlowStatus] = .showSignUp
                callback?()
            },
            background: Color.blue
        )
    }

    static func signInButton(callback: (() -> Void)? = nil) -> some View {
        SimpleButton(text: String.localized("Sign in")) {
            AnalyticsManager.AccountEvents.signInPressed()
            Defaults[.authFlowStatus] = .showSignIn
            callback?()
        }
    }

    static var logoutButton: some View {
        SimpleButton(
            text: String.localized("Log out"),
            action: {
                AnalyticsManager.AccountEvents.logoutPressed()
                AuthManager.shared.logout()
            }
        )
    }

    static func openPanel() {
        // No-op: the panel/sidebar feature has been removed (dictation-only build).
    }

    enum OpenAuthCategory {
        case signIn
        case signUp
    }
    
    enum OpenAuthSource {
        case panel
        case quickEdit
    }

    static func openAuth(
        for category: OpenAuthCategory = .signIn,
        from source: OpenAuthSource = .panel
    ) {
        if category == .signIn {
            AnalyticsManager.AccountEvents.signInPressed()
            Defaults[.authFlowStatus] = .showSignIn
        } else {
            AnalyticsManager.AccountEvents.signUpPressed()
            Defaults[.authFlowStatus] = .showSignUp
        }
        
        switch source {
        case .panel:
            openPanel()
        case .quickEdit:
            OnboardingWindowManager.shared.showAuthOnly()
        }
    }
}
