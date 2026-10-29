// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppIconButton.swift
//  Onit
//
//  Created by Loyd Kim on 5/13/26.
//

import SwiftUI

struct AppIconButton: View {
    let systemName: String
    var disabled: Bool = false
    let tooltip: String
    let action: () -> Void

    var body: some View {
        IconButton(
            systemName: systemName,
            iconSize: 16,
            buttonSize: 32,
            hoverBackground: Color.T_9,
            cornerRadius: 8,
            disabled: disabled,
            tooltipPrompt: tooltip
        ) {
            action()
        }
    }
}
