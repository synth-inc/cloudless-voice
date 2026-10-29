// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsAbout.swift
//  Onit
//
//  Created by Loyd Kim on 9/2/25.
//

import SwiftUI

struct SettingsAbout: View {
    // MARK: - Private Variables
    
    private var versionText: String {
        let version = Bundle.main.appVersion
        let build = Bundle.main.appBuild

        #if ONIT_BETA
        return String(format: String.localized("Version %@ (%@) - BETA", table: "Settings"), version, build)
        #else
        return String(format: String.localized("Version %@", table: "Settings"), version)
        #endif
    }
    
    /// The notices file the build copies into the app. Nil in a build made without that copy.
    private var licensesURL: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
    }

    private func openLicenses(_ url: URL) {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: url) != nil {
            workspace.open(url)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Body
    
    var body: some View {
        SettingsPageSection() {
            header
            buttons
        }
    }
    
    // MARK: - Child Components
    
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(.logo)
                .resizable()
                .frame(width: 41, height: 41)
                .padding(4)
            
            VStack(alignment: .leading, spacing: 0) {
                Text("Cloudless")
                    .styleText(weight: .regular)
                
                Text(versionText)
                    .styleText(
                        size: 12,
                        weight: .regular,
                        color: Color.T_2
                    )
            }
        }
    }
    
    private var buttons: some View {
        HStack(alignment: .center, spacing: 8) {
            SimpleButton(text: String.localized("Visit Website", table: "Settings")) {
                if let url = URL(string: "https://www.cloudless.so") {
                    NSWorkspace.shared.open(url)
                }
            }

            SimpleButton(text: String.localized("Contact Us", table: "Settings")) {
                if let url = URL(string: "mailto:contact@cloudless.so") {
                    NSWorkspace.shared.open(url)
                }
            }

            SimpleButton(text: String.localized("Send Feedback", table: "Settings")) {
                if let url = URL(string: "mailto:contact@cloudless.so") {
                    NSWorkspace.shared.open(url)
                }
            }

            if let licensesURL {
                SimpleButton(text: String.localized("Open-source licenses", table: "Settings")) {
                    openLicenses(licensesURL)
                }
            }
        }
    }
}
