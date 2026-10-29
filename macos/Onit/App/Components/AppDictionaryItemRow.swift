// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDictionaryItemRow.swift
//  Onit
//
//  Created by Loyd Kim on 5/13/26.
//

import SwiftUI

struct AppDictionaryItemRow: View {
    // MARK: - Properties

    let term: CustomDictionaryTerm
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRescan: () -> Void

    // MARK: - States

    @State private var isHovered = false
    @State private var isPressed = false
    
    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            Text(term.text)
                .styleText(
                    weight: .regular
                )
                .truncateText()
                .frame(maxWidth: .infinity, alignment: .leading)
            
            actionButtonsRow
        }
        .padding(.horizontal, 10)
        .frame(height: 40, alignment: .center)
        .addButtonEffects(
            background: Color.clear,
            hoverBackground: Color.T_9,
            cornerRadius: 14,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            onEdit()
        }
    }

    // MARK: - Child Components: Action Buttons Row
    
    private var actionButtonsRow: some View {
        HStack(alignment: .center, spacing: 4) {
            /// Re-scan history button - hidden for now; uncomment to bring back.
//             iconButtonView(
//                 systemName: "waveform.badge.magnifyingglass",
//                 tooltip: String.localized("Re-scan history", table: "App")
//             ) {
//                 onRescan()
//             }
            
            iconButtonView(
                systemName: "pencil",
                tooltip: String.localized("Edit", table: "App")
            ) {
                onEdit()
            }
            
            iconButtonView(
                systemName: "trash",
                tooltip: String.localized("Delete", table: "App")
            ) {
                onDelete()
            }
        }
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .addAnimation(dependency: isHovered)
    }
    
    private func iconButtonView(
        systemName: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        IconButton(
            systemName: systemName,
            iconSize: 14,
            buttonSize: 28,
            hoverBackground: Color.T_9,
            cornerRadius: 8,
            tooltipPrompt: tooltip
        ) {
            action()
        }
    }
}
