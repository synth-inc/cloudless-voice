// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BacktrackingEditModal.swift
//  Onit
//

import SwiftUI

/// Modal for editing the user's backtracking marker list.
/// Mirrors `SmartFormattingEditModal` for the flat-list (fillers-style) case.
struct BacktrackingEditModal: View {
    // MARK: - Properties

    @Binding var isPresented: Bool

    // MARK: - Observations

    @ObservedObject private var manager = BacktrackingMarkersManager.shared

    // MARK: - States

    @State private var newMarker = ""

    // MARK: - Private Variables

    private var currentMarkers: [String] {
        manager.effectiveMarkers()
    }

    private var addButtonDisabled: Bool {
        newMarker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleView
            addMarkerFormView
            markersListView
            footerView
        }
        .padding(20)
        .frame(width: 345, height: 272)
    }

    // MARK: - Child Components

    private var titleView: some View {
        Text(String.localized("Manage Backtracking Triggers", table: "Settings"))
            .styleText(size: 14, weight: .regular)
    }

    private var addMarkerFormView: some View {
        HStack(alignment: .center, spacing: 6) {
            InputField(
                text: $newMarker,
                placeholder: String.localized("trigger word / phrase", table: "Settings"),
                sizeConfig: .init(height: 36, cornerRadius: 12)
            ) {
                addMarker()
            }

            Button {
                addMarker()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 46, height: 36, alignment: .center)
                    .styleText(color: Color.white)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(addButtonDisabled)
            .addAnimation(dependency: addButtonDisabled)
        }
    }

    private var markersListView: some View {
        ScrollView {
            if currentMarkers.isEmpty {
                markersEmptyView
            } else {
                markersList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.T_9)
        .cornerRadius(16)
    }

    private var markersEmptyView: some View {
        Text(String.localized("no triggers added yet", table: "Settings"))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .center)
            .styleText(size: 13, italic: true, weight: .regular, color: Color.T_2)
    }

    private var markersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(currentMarkers, id: \.self) { marker in
                markerRow(marker)
            }
        }
        .padding(4)
    }

    private func markerRow(_ marker: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(marker)
                .styleText(size: 13, weight: .regular)
                .truncateText()

            Spacer()

            Button {
                manager.removeMarker(marker)
            } label: {
                Image(systemName: "minus.circle")
                    .styleText(size: 13, color: Color.T_2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(8)
    }

    private var footerView: some View {
        HStack(alignment: .center, spacing: 0) {
            SimpleButton(
                text: String.localized("Restore Defaults", table: "Settings"),
                cornerRadius: 6,
                action: {
                    manager.restoreDefaults()
                }
            )
            Spacer()
            SimpleButton(
                text: String.localized("Done", table: "Settings"),
                textColor: Color.white,
                cornerRadius: 6,
                action: {
                    isPresented = false
                },
                background: Color.blue
            )
        }
    }

    // MARK: - Private Functions

    private func addMarker() {
        let trimmed = newMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.addMarker(trimmed)
        newMarker = ""
    }
}
