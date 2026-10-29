// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptSectionCard.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import SwiftUI

/// White, rounded container that groups a date section's transcript items.
/// The caller is responsible for placing `DividerHorizontal` between items.
struct TranscriptSectionCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.special1)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_8
        )
    }
}
