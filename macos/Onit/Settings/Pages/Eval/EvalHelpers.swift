// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalHelpers.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import SwiftUI

// MARK: - Category Colors

enum EvalCategoryColor {
    private static let palette: [Color] = [
        .blue, .purple, .orange, .red, .teal,
        .indigo, .mint, .pink, .brown, .cyan, .green, .yellow,
    ]

    /// Returns a stable color for any category name using its hash.
    static func color(for category: String) -> Color {
        let index = abs(category.hashValue) % palette.count
        return palette[index]
    }
}

// MARK: - Pulse Animation

struct EvalPulseAnimation: ViewModifier {
    @State private var pulsing = false
    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
