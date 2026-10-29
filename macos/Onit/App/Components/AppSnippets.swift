// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSnippets.swift
//  Onit
//
//  Snippets page rendered inside `AppWindowPages`. Owns the snippet list,
//  search/sort affordances, and the add/edit/delete sheets. Mirrors the
//  Dictionary page pattern: title rendered in `AppSnippetsHeader`, page state
//  owned here, sheets stacked at the root.
//
//  Created by Kévin Naudin on 17/06/2026.
//

import Defaults
import SwiftUI

struct AppSnippets: View {

    // MARK: - Types

    enum SnippetSortOrder: String, CaseIterable {
        case newest
        case oldest
        case alphabetical

        @MainActor
        var label: String {
            switch self {
            case .newest:
                return String.localized("Newest first", table: "App")
            case .oldest:
                return String.localized("Oldest first", table: "App")
            case .alphabetical:
                return String.localized("Alphabetical", table: "App")
            }
        }
    }

    // MARK: - Properties

    @Binding var searchQuery: String
    @Binding var showAddSheet: Bool

    // MARK: - Observations

    @ObservedObject private var service = SnippetsService.shared
    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - Defaults

    /// The global trigger keyword. Single source of truth: editing it retroactively
    /// re-targets every snippet whose `appendsKeyword` is true.
    @Default(.snippetKeyword) private var snippetKeyword

    // MARK: - States

    @State private var sortOrder: SnippetSortOrder = .newest
    @State private var editingSnippet: Snippet?
    @State private var snippetPendingDelete: Snippet?
    @State private var showSortPopover = false

    @FocusState private var keywordFieldFocused: Bool

    // MARK: - Private Variables

    private var visibleSnippets: [Snippet] {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty
            ? service.snippets
            : service.snippets.filter { $0.nameLowercased.contains(needle) }

        switch sortOrder {
        case .newest:
            return filtered.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .oldest:
            return filtered.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .alphabetical:
            return filtered.sorted { lhs, rhs in
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    private var snippetsCountText: String {
        if visibleSnippets.count == 1 {
            return String.localized("1 snippet", table: "App")
        } else {
            return String.localized("\(visibleSnippets.count) snippets", table: "App")
        }
    }

    private var hasAnySnippets: Bool {
        !service.snippets.isEmpty
    }

    /// Bridges the optional `snippetPendingDelete` to the `Bool` binding the
    /// `.alert(_:isPresented:presenting:)` modifier expects.
    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { snippetPendingDelete != nil },
            set: { if !$0 { snippetPendingDelete = nil } }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listToolsRow

            TranscriptSectionCard {
                if hasAnySnippets {
                    itemsContainer
                } else {
                    emptyStateBanner
                }
            }
            .frame(maxHeight: .infinity)
        }
        .id(localization.currentLanguage)
        .onAppear {
            AnalyticsManager.AppSnippets.pageOpened()
        }
        .onChange(of: searchQuery) { _, newValue in
            AnalyticsManager.AppSnippets.searched(queryLength: newValue.count)
        }
        .onChange(of: sortOrder) { _, newValue in
            AnalyticsManager.AppSnippets.sortOrderChanged(sortOrder: newValue.rawValue)
        }
        .sheet(isPresented: $showAddSheet) {
            AppSnippetsSheet(
                mode: .add,
                onSubmitAdd: { name, replacement, appendsKeyword in
                    if let newSnippet = service.addSnippet(
                        name: name,
                        replacement: replacement,
                        appendsKeyword: appendsKeyword
                    ) {
                        AnalyticsManager.AppSnippets.snippetAdded(
                            snippetId: newSnippet.id.uuidString,
                            nameLength: newSnippet.name.count,
                            replacementLength: newSnippet.replacement.count
                        )
                    }
                }
            )
        }
        .sheet(item: $editingSnippet) { snippet in
            AppSnippetsSheet(
                mode: .edit(snippet: snippet),
                onSubmitAdd: { _, _, _ in /* unused in edit mode */ },
                onSubmitEdit: { updated in
                    service.updateSnippet(updated)
                    AnalyticsManager.AppSnippets.snippetEdited(snippetId: updated.id.uuidString)
                }
            )
        }
        .alert(
            String.localized("Delete snippet?", table: "App"),
            isPresented: deleteConfirmationPresented,
            presenting: snippetPendingDelete
        ) { snippet in
            Button(
                String.localized("Cancel", table: "App"),
                role: .cancel
            ) {}
            Button(
                String.localized("Delete", table: "App"),
                role: .destructive
            ) {
                AnalyticsManager.AppSnippets.snippetDeleted(snippetId: snippet.id.uuidString)
                service.removeSnippet(id: snippet.id)
            }
        } message: { _ in
            Text(String.localized(
                "Your snippet will be permanently deleted.",
                table: "App"
            ))
        }
    }

    // MARK: - Child Components: Add New Button

    struct AddNewButton: View {
        @Binding var showAddSheet: Bool
        var type: TextButton<EmptyView>.ButtonType = .custom

        var body: some View {
            TextButton(
                type: type,
                text: String.localized("Add new", table: "App"),
                iconConfig: .init(
                    leftIconName: "plus"
                ),
                sizeConfig: .init(
                    leftIcon: 12,
                    horizontalPadding: 8,
                    height: 32,
                    cornerRadius: 9
                ),
                alignmentConfig: .init(
                    gap: 4
                )
            ) {
                showAddSheet = true
            }
        }
    }

    // MARK: - Child Components: List Tools Row

    private var listToolsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(snippetsCountText)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.T_2
                )

            Spacer()

            keywordField

            sortButton
        }
    }

    // MARK: - Child Components: Trigger Keyword Field

    /// Global trigger-keyword editor. Bound to `Defaults[.snippetKeyword]`, it is
    /// the single source of truth for the suffix appended to every snippet whose
    /// `appendsKeyword` is true, so editing it retroactively re-targets all of them.
    private var keywordField: some View {
        HStack(spacing: 6) {
            Text(String.localized("Trigger keyword", table: "App"))
                .styleText(size: 12, weight: .regular, color: Color.T_2)

            TextField(
                String.localized("Trigger keyword", table: "App"),
                text: $snippetKeyword
            )
            .textFieldStyle(PlainTextFieldStyle())
            .styleText(size: 12, weight: .regular)
            .frame(width: 110)
            .focused($keywordFieldFocused)
            .onSubmit { sanitizeKeyword() }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.special1)
            .addBorder(cornerRadius: 8, stroke: Color.T_8)
        }
        // The field binds straight to Defaults, so every keystroke persists the
        // raw value. Sanitize on blur too (not only on Return) so clicking away
        // or closing the page never leaves an empty / space-padded keyword.
        .onChange(of: keywordFieldFocused) { _, focused in
            if !focused { sanitizeKeyword() }
        }
    }

    /// Normalizes the keyword on commit: trim edges, collapse internal whitespace,
    /// and fall back to "snippet" when the field is left empty. Guarantees the
    /// stored keyword never yields a trailing-space trigger.
    private func sanitizeKeyword() {
        let collapsed = snippetKeyword
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        snippetKeyword = collapsed.isEmpty ? "snippet" : collapsed
    }

    private var sortButton: some View {
        AppIconButton(
            systemName: "arrow.up.arrow.down",
            tooltip: String.localized("Sort by", table: "Transcription")
        ) {
            showSortPopover.toggle()
        }
        .popover(isPresented: $showSortPopover, arrowEdge: .bottom) {
            PopoverButtonsView(
                items: AppSnippets.SnippetSortOrder.allCases.map { snippetSortOrder in
                    PopoverButtonsView.ButtonItem(
                        text: snippetSortOrder.label,
                        statusConfig: PopoverButtonsView.buttonStatusConfig(
                            selected: sortOrder == snippetSortOrder
                        )
                    ) {
                        sortOrder = snippetSortOrder
                        showSortPopover = false
                    }
                }
            )
        }
    }

    // MARK: - Child Components: Items Container

    private var itemsContainer: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleSnippets.isEmpty {
                    AppEmptyResultsView(
                        iconSystemName: "magnifyingglass",
                        title: String.localized("No matches", table: "App"),
                        subtitle: String.localized("No snippet matches your search.", table: "App")
                    ) {
                        Self.AddNewButton(showAddSheet: $showAddSheet)
                    }
                } else {
                    ForEach(Array(visibleSnippets.enumerated()), id: \.element.id) { index, snippet in
                        AppSnippetsItemRow(
                            snippet: snippet,
                            onEdit: { editingSnippet = snippet },
                            onDelete: { snippetPendingDelete = snippet }
                        )
                        if index < visibleSnippets.count - 1 {
                            DividerHorizontal(foregroundColor: Color.T_9)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Child Components: Empty State Banner

    private var exampleCategories: [String] {
        ["Emails", "Addresses", "Links", "Replies", "Signatures", "File paths", "Code"]
    }

    private var emptyStateBanner: some View {
        VStack(alignment: .center, spacing: 10) {
            VStack(alignment: .center, spacing: 8) {
                Text(String.localized("Add your first snippet!", table: "App"))
                    .styleText(
                        fontFamily: .libreBaskerville,
                        size: 19,
                        weight: .regular,
                        align: .center
                    )

                Text(String.localized(
                    "Save things you say often as snippets, and insert them instantly while dictating.",
                    table: "App"
                ))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.S_1,
                    align: .center
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            FlowLayout(spacing: 10, rowAlignment: .center) {
                ForEach(exampleCategories, id: \.self) { category in
                    exampleCategoryTag(category)
                }
            }
            .frame(width: 302)

            Self.AddNewButton(
                showAddSheet: $showAddSheet,
                type: .primary
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.special2)
        .cornerRadius(15)
        .addBorder(cornerRadius: 15, stroke: Color.T_9)
    }

    private func exampleCategoryTag(_ text: String) -> some View {
        Text(String.localized(text, table: "App"))
            .styleText(size: 13, weight: .regular, color: Color.S_0)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .addBorder(cornerRadius: 16, stroke: Color.T_4, dotted: true)
    }
}
