// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalActionButtons.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import SwiftUI

/// Save & Next / Clear & Retry action buttons for the eval UI.
struct EvalActionButtons: View {

    let testCase: EvalTestCase
    let hasCapturedResults: Bool
    let isRecorded: Bool
    var onClearRetry: () -> Void
    var onSaveAndAdvance: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            clearRetryButton
            saveNextButton
        }
        .background {
            Button("") { onSaveAndAdvance() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        }
    }

    private var clearRetryButton: some View {
        Button {
            onClearRetry()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                Text(isRecorded ? "Delete & Retry" : "Clear & Retry")
                    .styleText(size: 13, weight: .medium,
                               color: isRecorded ? .red : Color.T_1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.T_6)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!hasCapturedResults && !isRecorded)
    }

    private var saveNextButton: some View {
        Button {
            onSaveAndAdvance()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text("Save & Next")
                    .styleText(size: 13, weight: .semibold, color: .white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(hasCapturedResults ? Color.green : Color.green.opacity(0.35))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!hasCapturedResults)
    }
}
