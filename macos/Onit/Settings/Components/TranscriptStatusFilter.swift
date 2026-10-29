// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptStatusFilter.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import SwiftUI

/// A pill-shaped dropdown that filters the transcript list by `ReviewStatus`.
/// `nil` represents the "All" option (no filtering).
///
/// When no status is selected, the pill shows "Review Status" with a chevron.
/// When a status IS selected, the pill takes a tinted blue background, shows
/// `Status: <Label>` and exposes a separate X button (right of a divider) to
/// clear the filter without opening the popover.
struct TranscriptStatusFilter: View {
    // MARK: - Properties
    
    @Binding var selection: TranscriptionHistory.ReviewStatus?
    
    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared
    
    // MARK: - States

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    @State private var showPopover: Bool = false
    
    // MARK: - Private variables

    private let height: CGFloat = 32
    private let cornerRadius: CGFloat = 9
    
    private let sortOptions: [(
        text: String,
        sortOrder: TranscriptionHistory.ReviewStatus
    )] = [
        (
            text: String.localized("Needs review", table: "Transcription"),
            sortOrder: .unreviewed
        ),
        (
            text: String.localized("Reviewed", table: "Transcription"),
            sortOrder: .reviewed
        ),
        (
            text: String.localized("Corrected", table: "Transcription"),
            sortOrder: .corrected
        )
    ]
    
    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.T_3)

            if let selection {
                Text(String.localized("Status:", table: "Transcription"))
                    .styleText(weight: .regular, color: Color.T_1)
                Text(selectedLabel(for: selection))
                    .styleText(weight: .regular, color: Color.S_0)
            } else {
                Text(String.localized("Review Status", table: "Transcription"))
                    .styleText(weight: .regular)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.T_2)
                .rotationEffect(.degrees(showPopover ? 180 : 0))
                .addAnimation(dependency: showPopover)

            if selection != nil {
                clearButton
            }
        }
        .padding(.leading, 10)
        // When the clear-button is present it absorbs its own right padding,
        // so the outer trailing pad collapses to keep the X hit zone flush
        // with the pill's right border.
        .padding(.trailing, selection == nil ? 8 : 0)
        .padding(.vertical, selection == nil ? 8 : 0)
        .frame(height: height, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(selection == nil ? Color.clear : Color.info500.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.T_8, lineWidth: 1)
        )
        .addButtonEffects(
            background: Color.clear,
            hoverBackground: selection == nil ? Color.T_9 : Color.info500.opacity(0.15),
            cornerRadius: cornerRadius,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            showPopover.toggle()
        }
        .id(localization.currentLanguage)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            PopoverButtonsView(
                items: sortOptions.map { sortOption in
                    PopoverButtonsView.ButtonItem(
                        text: sortOption.text,
                        statusConfig: PopoverButtonsView.buttonStatusConfig(
                            selected: selection == sortOption.sortOrder
                        )
                    ) {
                        selection = sortOption.sortOrder
                        showPopover = false
                    }
                }
            )
        }
    }
    
    // MARK: - Child Components: Clear Button

    /// The right-hand "clear filter" hit target. Spans from the separator to
    /// the pill's right border so any click in that strip clears the filter
    /// without triggering the popover.
    private var clearButton: some View {
        Button {
            selection = nil
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.T_8)
                    .frame(width: 1, height: 14)

                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.info500)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func selectedLabel(for status: TranscriptionHistory.ReviewStatus) -> String {
        switch status {
        case .unreviewed:
            return String.localized("Needs review", table: "Transcription")
        case .reviewed:
            return String.localized("Reviewed", table: "Transcription")
        case .corrected:
            return String.localized("Corrected", table: "Transcription")
        }
    }
}
