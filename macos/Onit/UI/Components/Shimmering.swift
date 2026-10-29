// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Shimmering.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-08.
//

import SwiftUI

/// A shimmering loading effect: sweeps a soft highlight across the content.
private struct ShimmeringModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            Color.white.opacity(0.55),
                            .clear,
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .offset(x: phase * geometry.size.width * 2)
                    .mask(content)
                    .allowsHitTesting(false)
                }
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmeringModifier())
    }
}
