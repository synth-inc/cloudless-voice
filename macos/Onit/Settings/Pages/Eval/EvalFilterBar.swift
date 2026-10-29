// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalFilterBar.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import SwiftUI

/// Category and tag filter chips for the eval UI.
struct EvalFilterBar: View {

    @ObservedObject var manager: EvalRecordingManager
    @Binding var selectedCategory: String?
    var currentCase: EvalTestCase?
    var onApplyTag: (String, EvalTestCase) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryChip(label: "All", category: nil)
                    ForEach(manager.categories, id: \.self) { cat in
                        categoryChip(label: LocalizedStringKey(cat), category: cat)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if !manager.allTags.isEmpty, let testCase = currentCase {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                            .foregroundColor(Color.T_3)
                        ForEach(manager.allTags, id: \.self) { tag in
                            tagQuickAddChip(label: tag, testCase: testCase)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Chips

    private func categoryChip(label: LocalizedStringKey, category: String?) -> some View {
        let isSelected = selectedCategory == category
        let recorded = manager.recordedCount(for: category)
        let total = manager.totalCount(for: category)
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .styleText(size: 11, weight: isSelected ? .semibold : .regular,
                               color: isSelected ? .white : Color.T_1)
                if total > 0 {
                    Text("\(recorded)/\(total)")
                        .styleText(size: 10, color: isSelected ? .white.opacity(0.75) : Color.T_3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.blue : Color.T_6)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }

    private func tagQuickAddChip(label: String, testCase: EvalTestCase) -> some View {
        let alreadyApplied = manager.tags(for: testCase.index).contains(label)
        return Button {
            onApplyTag(label, testCase)
        } label: {
            Text(label)
                .styleText(size: 11, weight: alreadyApplied ? .semibold : .regular,
                           color: alreadyApplied ? .white : Color.T_1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(alreadyApplied ? Color.purple : Color.T_6)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}
