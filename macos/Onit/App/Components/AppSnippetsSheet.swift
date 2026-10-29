// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSnippetsSheet.swift
//  Onit
//
//  Add / edit modal for a snippet. Two fields - name (the dictation trigger +
//  search target) and replacement (the inserted text). Validation guards the
//  empty name, the self-referential loop (name appearing inside its own
//  replacement), and an over-long replacement.
//
//  Created by Kévin Naudin on 17/06/2026.
//

import Defaults
import SwiftUI

struct AppSnippetsSheet: View {
    // MARK: - Types

    enum Mode {
        case add
        case edit(snippet: Snippet)
    }

    // MARK: - Properties

    let mode: Mode

    /// Called for `.add` submissions with the trimmed base name, replacement, and
    /// whether the global keyword should be appended to form the trigger.
    let onSubmitAdd: (_ name: String, _ replacement: String, _ appendsKeyword: Bool) -> Void

    /// Called for `.edit` submissions with the fully updated snippet. Optional so
    /// `.add` call sites can omit it.
    var onSubmitEdit: ((Snippet) -> Void)? = nil

    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss

    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @State private var name: String = ""
    @State private var replacement: String = ""

    @FocusState private var nameFieldFocused: Bool

    @State private var appendSnippetSuffix: Bool = true

    // MARK: - Private Variables

    /// The global trigger keyword, displayed as a fixed suffix after the phrase
    /// ("my email" → "my email snippet"). Reflects `Defaults.snippetKeyword` live,
    /// so it is never welded into the stored name.
    private var nameSuffix: String {
        " " + Defaults[.snippetKeyword]
    }

    private let maxReplacementLength = 5000

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The user-typed base name. The keyword is no longer stored on the name, so
    /// the base is exactly what gets persisted.
    private var trimmedBase: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReplacementTooLong: Bool {
        replacement.count > maxReplacementLength
    }

    // Note: no "name must not appear in its replacement" guard is needed - the
    // matcher (`SnippetsService.expand`) is single-pass and never re-scans
    // spliced replacements, so a self-referential replacement can't cascade.
    private var replacementError: String? {
        isReplacementTooLong
            ? String.localized(
                "Replacement is too long (max %lld characters).",
                table: "App",
                maxReplacementLength
            )
            : nil
    }

    private var canSubmit: Bool {
        !trimmedBase.isEmpty && !trimmedReplacement.isEmpty && !isReplacementTooLong
    }

    // MARK: - Private Functions

    private func submit() {
        guard canSubmit else { return }
        switch mode {
        case .add:
            onSubmitAdd(trimmedBase, replacement, appendSnippetSuffix)
        case .edit(let snippet):
            var updated = snippet
            updated.name = trimmedBase
            updated.replacement = replacement
            updated.appendsKeyword = appendSnippetSuffix
            onSubmitEdit?(updated)
        }
        dismiss()
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headerView
                nameField
                replacementField
                suffixToggleRow
            }
            .padding(16)

            toolbarView
        }
        .frame(width: 460)
        .id(localization.currentLanguage)
        .onAppear {
            if case .edit(let snippet) = mode {
                name = snippet.name
                appendSnippetSuffix = snippet.appendsKeyword
                replacement = snippet.replacement
            } else {
                nameFieldFocused = true
            }
        }
    }

    // MARK: - Child Components: Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                isEditing
                    ? String.localized("Edit snippet", table: "App")
                    : String.localized("Add a snippet", table: "App")
            )
            .styleText(
                size: 15,
                weight: .regular,
                color: Color.S_0
            )

            Text(String.localized(
                "Save text you reuse often. Say your phrase while dictating to insert your replacement.",
                table: "App"
            ))
            .styleText(
                size: 14,
                weight: .regular,
                color: Color.T_1
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Child Components: Phrase Field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String.localized("Phrase", table: "App"))
                .styleText(size: 12, weight: .regular)

            HStack(spacing: 0) {
                TextField(
                    String.localized("e.g. my email %@", table: "App", Defaults[.snippetKeyword]),
                    text: $name
                )
                .textFieldStyle(PlainTextFieldStyle())
                .styleText(size: 14, weight: .regular)
                .focused($nameFieldFocused)
                .onSubmit { submit() }

                if appendSnippetSuffix {
                    Text(nameSuffix)
                        .styleText(size: 14, weight: .regular, color: Color.T_2)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.special1)
            .addBorder(cornerRadius: 12, stroke: Color.T_8)
        }
    }

    // MARK: - Child Components: Replacement Field

    private var replacementField: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String.localized("Replacement", table: "App"))
                .styleText(size: 12, weight: .regular)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $replacement)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
                    .foregroundColor(Color.S_0)
                    .frame(height: 120)
                    .padding(8)
                    .background(Color.special1)

                if replacement.isEmpty {
                    Text(String.localized("e.g. example@email.com", table: "App"))
                        .font(.system(size: 14))
                        .foregroundColor(Color.T_2)
                        .padding(.top, 8)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
            }
            .addBorder(
                cornerRadius: 12,
                stroke: replacementError != nil ? Color.red500 : Color.T_8
            )

            if let replacementError {
                Text(replacementError)
                    .styleText(size: 12, weight: .regular, color: Color.red500)
                    .addAnimation(dependency: replacementError)
            }
        }
    }

    // MARK: - Child Components: Suffix Toggle Row

    private var suffixToggleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle("", isOn: $appendSnippetSuffix)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

            Text(String.localized(
                "Append \u{201C}%@\u{201D} to the phrase to avoid accidental triggers.",
                table: "App",
                Defaults[.snippetKeyword]
            ))
            .styleText(size: 13, weight: .regular, color: Color.T_1)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Child Components: Toolbar

    private var toolbarView: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer()

            TextButton(
                text: String.localized("Cancel", table: "App"),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                )
            ) {
                dismiss()
            }

            TextButton(
                type: .primary,
                text: isEditing
                    ? String.localized("Save", table: "App")
                    : String.localized("Add", table: "App"),
                sizeConfig: .init(
                    horizontalPadding: 22,
                    height: 36
                ),
                statusConfig: .init(
                    disabled: !canSubmit
                )
            ) {
                submit()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .addBorder(
            sides: .top,
            stroke: Color.T_7
        )
    }
}

