// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSnippetsItemRow.swift
//  Onit
//
//  Created by Kévin Naudin on 17/06/2026.
//

import SwiftUI

struct AppSnippetsItemRow: View {
    // MARK: - Properties

    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    // MARK: - States

    @State private var isHovered = false
    @State private var isExpanded = false

    /// Heights of the replacement preview when clamped to `previewLineLimit`
    /// vs. rendered in full - used to decide whether to surface "See more".
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    // MARK: - Private Variables

    private let previewLineLimit = 3

    private var isTruncated: Bool {
        fullHeight > clampedHeight + 1
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                triggerLabel
                    .font(.system(size: 14))
                    .fontWeight(.regular)
                    .foregroundColor(Color.S_0)
                    .lineLimit(1)
                    .truncationMode(.tail)

                replacementPreview
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onEdit()
            }

            actionButtonsRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(isHovered ? Color.T_9 : Color.clear)
        .cornerRadius(14)
        .onHover { isHovered = $0 }
        .addAnimation(dependency: isHovered)
    }

    private var triggerLabel: Text {
        Text(verbatim: "\u{201C}\(snippet.name)\u{201D}")
    }

    // MARK: - Child Components: Replacement Preview

    private var replacementPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color.T_1)
                    .padding(.top, 2)

                visiblePreviewText
            }

            if isTruncated {
                Button {
                    isExpanded.toggle()
                } label: {
                    Text(
                        isExpanded
                            ? String.localized("See less", table: "App")
                            : String.localized("See more", table: "App")
                    )
                    .styleText(
                        size: 13,
                        weight: .medium,
                        color: Color.info500
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 18)
            }
        }
    }

    /// The visible, possibly-clamped preview. Two hidden copies (clamped + full)
    /// are measured behind it so `isTruncated` reflects real wrapping rather than
    /// a character-count guess.
    private var visiblePreviewText: some View {
        Text(snippet.replacement)
            .styleText(weight: .regular, color: Color.T_1)
            .lineLimit(isExpanded ? nil : previewLineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(measurementOverlay)
    }

    private var measurementOverlay: some View {
        ZStack {
            Text(snippet.replacement)
                .styleText(weight: .regular, color: Color.T_1)
                .lineLimit(previewLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ClampedHeightKey.self, value: proxy.size.height)
                })
                .hidden()

            Text(snippet.replacement)
                .styleText(weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FullHeightKey.self, value: proxy.size.height)
                })
                .hidden()
        }
        .onPreferenceChange(ClampedHeightKey.self) { clampedHeight = $0 }
        .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
    }

    // MARK: - Child Components: Action Buttons Row

    private var actionButtonsRow: some View {
        HStack(alignment: .center, spacing: 4) {
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

// MARK: - Height Preference Keys

private struct ClampedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
