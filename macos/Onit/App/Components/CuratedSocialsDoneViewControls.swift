// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CuratedSocialsDoneViewControls.swift
//  Onit
//
//  Created by Loyd Kim on 4/30/26.
//

import SwiftUI

private let pillHorizontalPadding: CGFloat = 12
private let pillHeight: CGFloat = 36
private let pillCornerRadius: CGFloat = 10

struct CuratedSocialsUndoOpenAllButton: View {
    let action: () -> Void

    var body: some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: pillHorizontalPadding,
                height: pillHeight,
                cornerRadius: pillCornerRadius
            )
        ) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.S_0)

                Text(String.localized("Undo \"Open all\"", table: "App"))
                    .styleText(
                        size: 14
                    )
            }
        } action: {
            action()
        }
    }
}

struct CuratedSocialsLoadMoreButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: pillHorizontalPadding,
                height: pillHeight,
                cornerRadius: pillCornerRadius
            ),
            statusConfig: .init(
                disabled: isLoading
            )
        ) {
            HStack(alignment: .center, spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.S_0)
                }

                Text(String.localized("Load more", table: "App"))
                    .styleText(
                        size: 14,
                        weight: .medium
                    )
            }
        } action: {
            guard !isLoading else { return }
            action()
        }
    }
}

struct CloseDoneViewButton: View {
    let action: () -> Void

    var body: some View {
        IconButton(
            systemName: "xmark",
            iconSize: 12,
            buttonSize: 28,
            inactiveColor: Color.T_2,
            hoverBackground: Color.T_9,
            cornerRadius: 8,
            tooltipPrompt: String.localized("Hide", table: "App")
        ) {
            action()
        }
    }
}
