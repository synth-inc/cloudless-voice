// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingDemoShortcutInstruction.swift
//  Onit
//
//  Created by Loyd Kim on 8/11/25.
//

import SwiftUI

struct OnboardingDemoShortcutInstruction: View {
    // MARK: - Properties
    
    private let shortcutText: String
    
    init(shortcutText: String) {
        self.shortcutText = shortcutText
    }
    
    // MARK: - Body
    
    var body: some View {
        Text(self.shortcutText)
            .styleText(
                size: 20,
                weight: .regular
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 55, minHeight: 55)
            .background(Color.T_9)
            .addBorder(
                cornerRadius: 8,
                stroke: Color.T_5
            )
    }
}
