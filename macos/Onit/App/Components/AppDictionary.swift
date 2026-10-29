// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDictionary.swift
//  Onit
//
//  Dictionary page rendered inside `AppWindowPages`. Owns the term list,
//  search/sort affordances, add/edit/delete/calibration sheets, and the
//  advanced-settings sheet (model status, history scan, suggestions).
//
//  Mirrors the Transcripts page pattern: title rendered inline alongside
//  the action row, page state owned here, sheets stacked at the root.
//

import Defaults
import SwiftUI

struct AppDictionary: View {

    // MARK: - Types

    enum DictionarySortOrder: String, CaseIterable {
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

    @ObservedObject private var service = CustomDictionaryService.shared
    @ObservedObject private var localization = LocalizationManager.shared
    /// Observed so the model-nudge banner appears/disappears live with the
    /// selected ASR model (selectedASRModelId is @Published).
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared

    // MARK: - States

    @State private var sortOrder: DictionarySortOrder = .newest
    @State private var showingAdvancedSheet: Bool = false
    @State private var editingTerm: CustomDictionaryTerm?
    @State private var termPendingDelete: CustomDictionaryTerm?
    @State private var termPendingCalibration: CustomDictionaryTerm?
    @State private var showSortPopover = false
    /// Full ASR model picker (the same sheet Settings uses - download size,
    /// RAM requirements, install state) opened from the nudge banner.
    @State private var showModelsSheet = false

    // MARK: - Private Variables

    private var visibleTerms: [CustomDictionaryTerm] {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty
            ? service.terms
            : service.terms.filter { $0.textLowercased.contains(needle) }

        switch sortOrder {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .alphabetical:
            return filtered.sorted {
                $0.text.localizedStandardCompare($1.text) == .orderedAscending
            }
        }
    }
    
    private var termsCountText: String {
        if visibleTerms.count == 1 {
            return String.localized("1 term", table: "App")
        } else {
            return String.localized("\(visibleTerms.count) terms", table: "App")
        }
    }

    private var hasAnyTerms: Bool {
        return !service.terms.isEmpty
    }
    
    /// Bridges the optional `termPendingDelete` to the `Bool` binding the
    /// `.alert(_:isPresented:presenting:)` modifier expects.
    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { termPendingDelete != nil },
            set: { if !$0 { termPendingDelete = nil } }
        )
    }
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listToolsRow

            modelNudgeBanner

            TranscriptSectionCard {
                if hasAnyTerms {
                    itemsContainer
                } else {
                    emptyStateBanner
                }
            }
            .frame(maxHeight: .infinity)
        }
        .id(localization.currentLanguage)
        .onAppear {
            AnalyticsManager.AppDictionary.pageOpened()
        }
        .onChange(of: searchQuery) { _, newValue in
            AnalyticsManager.AppDictionary.searched(queryLength: newValue.count)
        }
        .onChange(of: sortOrder) { _, newValue in
            AnalyticsManager.AppDictionary.sortOrderChanged(sortOrder: newValue.rawValue)
        }
        .sheet(isPresented: $showAddSheet) {
            AppDictionaryTermSheet(
                mode: .add,
                customDictionaryTerms: service.terms,
                onSubmit: { text in
                    if let newTerm = service.addTerm(text) {
                        AnalyticsManager.AppDictionary.termAdded(
                            termId: newTerm.id.uuidString,
                            textLength: newTerm.text.count
                        )
                        termPendingCalibration = newTerm
                    }
                }
            )
        }
        .sheet(item: $termPendingCalibration) { term in
            DictionaryCalibrationSheet(
                term: term,
                onDismiss: { termPendingCalibration = nil },
                onComplete: { completedTerm in
                    ToastPanelController.shared.show(
                        message: String.localized(
                            "\u{201C}%@\u{201D} added to dictionary",
                            table: "App",
                            completedTerm.text
                        )
                    )
                }
            )
        }
        .sheet(item: $editingTerm) { term in
            AppDictionaryTermSheet(
                mode: .edit(term: term),
                customDictionaryTerms: service.terms,
                onSubmit: { _ in /* unused in edit mode */ },
                onSubmitEdit: { updated in
                    service.updateTerm(updated)
                    AnalyticsManager.AppDictionary.termEdited(termId: updated.id.uuidString)
                }
            )
        }
        .sheet(isPresented: $showingAdvancedSheet) {
            AppDictionaryAdvancedSheet()
        }
        .sheet(isPresented: $showModelsSheet) {
            SettingsASRModelsPickerSheet()
        }
        .alert(
            String.localized("Delete this term?", table: "App"),
            isPresented: deleteConfirmationPresented,
            presenting: termPendingDelete
        ) { term in
            Button(
                String.localized("Cancel", table: "App"),
                role: .cancel
            ) {}
            Button(
                String.localized("Delete", table: "App"),
                role: .destructive
            ) {
                AnalyticsManager.AppDictionary.termDeleted(termId: term.id.uuidString)
                service.removeTerm(id: term.id)
            }
        } message: { term in
            Text(String.localized(
                "\u{201C}%@\u{201D} will be removed from your dictionary.",
                table: "App",
                term.text
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

    /// Model-recommendation nudge: dictionary biasing (glossary prompt +
    /// on-screen mining) only runs on the MLX backend (Qwen3/Granite). Styled
    /// after the curated-socials card (special2 bg, T_8 stroke, T_9 button).
    @ViewBuilder
    private var modelNudgeBanner: some View {
        if transcriptionConfig.selectedASRModel.backend != .mlx {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Dictionary requires Qwen or Granite models", table: "App"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.S_0)
                    Text(String.localized("The dictionary only works with certain models. Switch to a Qwen or Granite model to use this feature!", table: "App"))
                        .font(.system(size: 11))
                        .foregroundColor(Color.T_2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                modelNudgeChooseButton
            }
            .padding(12)
            .background(Color.special2)
            .addBorder(cornerRadius: 12, stroke: Color.T_8)
        }
    }

    /// Opens the full ASR model picker (same sheet as Settings) so the user
    /// sees download size, RAM requirements, and install state before
    /// switching. Button visuals match the curated-socials carousel button.
    private var modelNudgeChooseButton: some View {
        Button {
            showModelsSheet = true
            AnalyticsManager.AsrModel.pickerOpened()
        } label: {
            Text(String.localized("Choose model", table: "App"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.S_0)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.T_9)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .help(String.localized("Browse dictation models (size and memory requirements)", table: "App"))
    }

    private var listToolsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(termsCountText)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.T_2
                )
            
            Spacer()
            
            HStack(alignment: .center, spacing: 12) {
                sortButton
                advancedButton
            }
        }
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
                items: AppDictionary.DictionarySortOrder.allCases.map { dictionarySortOrder in
                    PopoverButtonsView.ButtonItem(
                        text: dictionarySortOrder.label,
                        statusConfig: PopoverButtonsView.buttonStatusConfig(
                            selected: sortOrder == dictionarySortOrder
                        )
                    ) {
                        sortOrder = dictionarySortOrder
                        showSortPopover = false
                    }
                }
            )
        }
    }

    private var advancedButton: some View {
        AppIconButton(
            systemName: "gearshape",
            tooltip: String.localized("Advanced settings", table: "App")
        ) {
            showingAdvancedSheet = true
        }
    }

    // MARK: - Child Components: Items Container

    private var itemsContainer: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visibleTerms.isEmpty {
                    AppEmptyResultsView(
                        iconSystemName: "magnifyingglass",
                        title: String.localized("No matches", table: "App"),
                        subtitle: String.localized("Missing a term? Add it to the dictionary.", table: "App")
                    ) {
                        Self.AddNewButton(showAddSheet: $showAddSheet)
                    }
                } else {
                    ForEach(visibleTerms) { term in
                        AppDictionaryItemRow(
                            term: term,
                            onEdit: { editingTerm = term },
                            onDelete: { termPendingDelete = term },
                            onRescan: { termPendingCalibration = term }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Child Components: Empty State Banner

    private var emptyStateBanner: some View {
        VStack(alignment: .center, spacing: 10) {
            Text(String.localized(
                "Add a term to the Dictionary!",
                table: "App")
            )
            .styleText(
                fontFamily: .libreBaskerville,
                size: 19,
                weight: .regular,
                align: .center
            )
            
            Text(String.localized(
                "Add words you want Cloudless to recognize. It can be particular spellings, names, and slang that you often use.",
                table: "App"
            ))
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.S_1,
                align: .center
            )
            
            Self.AddNewButton(
                showAddSheet: $showAddSheet,
                type: .primary
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.special2)
        .cornerRadius(14)
    }
    
}
