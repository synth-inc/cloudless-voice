// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptShowEditsToggle.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import SwiftUI

/// Pill-shaped toggle that controls whether the transcript list shows the inline
/// word-level diff between the raw ASR output and the displayed text.
///
/// The entire pill - not just the inner switch - is the hit target. This
/// matches the sibling `TranscriptStatusFilter` button so the two controls
/// feel consistent, and lets the user click anywhere on the chip to flip
/// the toggle. The native `Toggle` is kept as a visual indicator only
/// (`.allowsHitTesting(false)`) so it never competes with the outer
/// `addButtonEffects` drag-gesture for taps.
struct TranscriptShowEditsToggle: View {
    @Binding var isOn: Bool

    @ObservedObject private var localization = LocalizationManager.shared

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    private let height: CGFloat = 32
    private let cornerRadius: CGFloat = 9

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "plusminus")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.T_3)

            Text(String.localized("Show edits", table: "Transcription"))
                .styleText(weight: .regular)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                // Default switch tint is the system accent (blue) - override
                // to the design-system lime so the "Show edits" affordance
                // visually pairs with the green diff highlights it controls.
                .tint(Color.lime500)
                // Pure indicator: the parent pill owns the tap-to-toggle.
                .allowsHitTesting(false)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: height, alignment: .center)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.T_8, lineWidth: 1)
        )
        .addButtonEffects(
            background: Color.clear,
            hoverBackground: Color.T_9,
            cornerRadius: cornerRadius,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            // Mirror the sibling search/sort buttons: the click can leave the
            // hover state stuck if anything reshuffles the cursor target on
            // toggle. Clear the tooltip explicitly so it never lingers.
            TooltipManager.shared.setTooltip(nil)
            isOn.toggle()
        }
        // Custom in-app tooltip (matches the search & sort affordances on the
        // same row) - not SwiftUI's native `.help`, which would render a
        // system tooltip that visually clashes with the design system.
        .onChange(of: isHovered) { _, hovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: hovering,
                tooltipPrompt: String.localized("Display changes", table: "Transcription")
            )
        }
        .id(localization.currentLanguage)
    }
}
