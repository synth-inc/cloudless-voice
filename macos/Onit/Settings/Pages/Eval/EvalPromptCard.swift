// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalPromptCard.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import SwiftUI

/// Displays the current test case prompt with category badge, recorded status,
/// easy fix badge, and tags with autocomplete.
struct EvalPromptCard: View {

    @ObservedObject var manager: EvalRecordingManager
    let testCase: EvalTestCase
    let isRecorded: Bool
    @Binding var newTagInput: String
    @FocusState.Binding var isTagFieldFocused: Bool
    @Binding var tagSuggestions: [String]
    var onShowEasyFix: () -> Void
    var onApplyTag: (String, EvalTestCase) -> Void

    var body: some View {
        SettingsPageSection {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                Text(testCase.input)
                    .styleText(size: 16, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                tagRow
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(testCase.category)
                .styleText(size: 9, weight: .semibold, color: .white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(EvalCategoryColor.color(for: testCase.category))
                .cornerRadius(4)

            if isRecorded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("Recorded")
                        .styleText(size: 10, color: .green)
                }
            }

            if manager.easyFixes[testCase.index] != nil {
                easyFixBadge
            }

            Spacer()

            Text("#\(testCase.index + 1)")
                .styleText(size: 10, color: Color.T_3)
        }
    }

    private var easyFixBadge: some View {
        Button {
            onShowEasyFix()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "wrench.adjustable.fill")
                    .font(.system(size: 9))
                Text("Easy Fix")
                    .styleText(size: 9, weight: .semibold, color: .white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tags

    private var tagRow: some View {
        let tags = manager.tags(for: testCase.index).sorted()
        return HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 10))
                .foregroundColor(Color.T_3)

            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag)
                        .styleText(size: 11, color: Color.T_1)
                    Button {
                        manager.removeTag(tag, from: testCase.index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color.T_3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(4)
            }

            tagInputField
        }
    }

    private var tagInputField: some View {
        ZStack(alignment: .topLeading) {
            TextField("Add tag…", text: $newTagInput)
                .font(.system(size: 11))
                .textFieldStyle(.plain)
                .frame(width: 90)
                .focused($isTagFieldFocused)
                .onChange(of: newTagInput) { _, text in
                    let existing = manager.tags(for: testCase.index)
                    tagSuggestions = text.isEmpty ? [] : manager.allTags
                        .filter { !existing.contains($0) && $0.localizedCaseInsensitiveContains(text) }
                        .sorted()
                }
                .onSubmit {
                    onApplyTag(newTagInput, testCase)
                }

            if !tagSuggestions.isEmpty && isTagFieldFocused {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tagSuggestions.prefix(6), id: \.self) { suggestion in
                        Button {
                            onApplyTag(suggestion, testCase)
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 11))
                                .foregroundColor(Color.T_1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.clear)
                        if suggestion != tagSuggestions.prefix(6).last {
                            Divider().padding(.horizontal, 4)
                        }
                    }
                }
                .frame(width: 160)
                .background(.regularMaterial)
                .cornerRadius(7)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .offset(y: 20)
                .zIndex(100)
            }
        }
    }
}
