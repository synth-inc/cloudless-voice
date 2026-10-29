// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktrackingSection.swift
//  Onit
//

import SwiftUI

/// Settings section for the user-editable backtracking marker list.
/// Sits between the Cleanup model and the other Smart Cleanup categories.
struct BacktrackingSection: View {
    // MARK: - Properties

    @Binding var isEnabled: Bool

    // MARK: - Observations

    @ObservedObject private var manager = BacktrackingMarkersManager.shared
    @ObservedObject private var warmupProvider = ImprovementLLMWarmupProvider.shared

    // MARK: - States

    @State private var isExpanded = false
    @State private var showEditModal = false

    // MARK: - Private Variables

    private let triggerRowHeight: CGFloat = 32
    private let triggerListHorizontalSpacing: CGFloat = 8

    private var markersText: String {
        manager.effectiveMarkers()
            .map { "\"\($0)\"" }
            .joined(separator: " / ")
    }

    private var markersIsEmpty: Bool {
        manager.effectiveMarkers().isEmpty
    }

    // MARK: - Body

    var body: some View {
        SettingsPageSection {
            headerView

            if isEnabled {
                DividerHorizontal()
                modelStatusView
                DividerHorizontal()
                disclosureView
            }
        }
        .sheet(isPresented: $showEditModal) {
            BacktrackingEditModal(isPresented: $showEditModal)
        }
    }

    // MARK: - Child Components

    private var headerView: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text(String.localized("Detect Backtracking", table: "Settings"))
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text(String.localized(
                    "Detects when you change your mind. If you say \u{201C}let\u{2019}s sync at 9, no 10\u{201D}, Cloudless will backtrack and write the correct version only.",
                    table: "Settings"
                ))
                .styleText(size: 12, weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var modelStatusView: some View {
        SettingsPageSubsection(
            horizontal: .init(spacing: 8),
            header: .init(
                title: String.localized("Backtracking Model", table: "Settings"),
                subtitle: "Llama 3.2 1B (Cloudless fine-tune)"
            )
        ) {
            if warmupProvider.isWarmedUp {
                Text(String.localized("Ready", table: "Settings"))
                    .styleText(size: 12)
                    .foregroundStyle(.green)
            } else if let error = warmupProvider.errorMessage {
                HStack(spacing: 6) {
                    Text(error)
                        .styleText(size: 11)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Button {
                        WarmupCoordinator.shared.retryWarmup(for: warmupProvider.identifier)
                    } label: {
                        Text(String.localized("Retry", table: "Settings"))
                            .styleText(size: 11)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var disclosureView: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: { triggerContent },
            label: {
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(String.localized("Customize Triggers", table: "Settings"))
                        .styleText(size: 12)
                }
                .buttonStyle(PlainButtonStyle())
            }
        )
    }

    @ViewBuilder
    private var triggerContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            triggerRow

            if manager.hasCustomMarkers {
                Divider()

                HStack {
                    Spacer()
                    Button {
                        manager.restoreDefaults()
                    } label: {
                        Text(String.localized("Restore Defaults", table: "Settings"))
                            .styleText(size: 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color.S_7.opacity(0.7))
        .cornerRadius(16)
        .padding(.top, 12)
    }

    private var triggerRow: some View {
        HStack(alignment: .center, spacing: triggerListHorizontalSpacing) {
            Text(String.localized("Backtracking", table: "Settings"))
                .styleText(size: 12, weight: .regular)
                .frame(height: triggerRowHeight, alignment: .center)

            TriggerRowHover(
                text: markersText,
                isEmpty: markersIsEmpty,
                height: triggerRowHeight,
                horizontalSpacing: triggerListHorizontalSpacing,
                onEdit: { showEditModal = true }
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hover Row

private struct TriggerRowHover: View {
    let text: String
    let isEmpty: Bool
    let height: CGFloat
    let horizontalSpacing: CGFloat
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: horizontalSpacing) {
            Text(isEmpty ? String.localized("No Triggers", table: "Settings") : text)
                .styleText(
                    size: 12,
                    italic: isEmpty,
                    weight: .regular,
                    color: isEmpty ? Color.T_3 : Color.T_1
                )
                .truncateText()

            Spacer()

            if isHovered {
                SimpleButton(
                    text: isEmpty
                        ? String.localized("Add Trigger...", table: "Settings")
                        : String.localized("Edit...", table: "Settings"),
                    cornerRadius: 6,
                    action: onEdit
                )
            }
        }
        .frame(height: height, alignment: .center)
        .onHover { hovered in
            isHovered = hovered
        }
    }
}
