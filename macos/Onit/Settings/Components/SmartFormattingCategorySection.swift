// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartFormattingCategorySection.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-24.
//

import SwiftUI

/// A settings section for a smart formatting category with toggle, trigger preview, and edit access.
struct SmartFormattingCategorySection: View {
    // MARK: - Types
    
    struct Verbal: Hashable {
        let triggerTexts: [String]
        let editingSymbol: String
    }
    
    // MARK: - Properties
    
    let title: String
    let subtitle: String
    let category: SmartFormattingCategory
    @Binding var isEnabled: Bool
    
    // MARK: - Observations

    @ObservedObject private var triggersManager = SmartFormattingTriggersManager.shared
    
    // MARK: - States

    @State private var isExpanded = false
    @State private var editingSymbol: String?
    @State private var showEditModal = false
    
    // MARK: - Private Variables
    
    private let triggerListHorizontalSpacing: CGFloat = 8
    private let triggerRowHeight: CGFloat = 32
    
    // MARK: - Body

    var body: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: title,
                    subtitle: subtitle
                ),
                isOn: $isEnabled
            )

            if isEnabled {
                DividerHorizontal()

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
        }
        .sheet(isPresented: $showEditModal) {
            if let symbol = editingSymbol {
                SmartFormattingEditModal(
                    category: category,
                    symbol: symbol,
                    isPresented: $showEditModal
                )
            }
        }
    }
    
    // MARK: - Child Components: Trigger Content

    private var hasCustomTriggers: Bool {
        guard let custom = triggersManager.customTriggers else { return false }
        switch category {
        case .punctuation: return custom.punctuation != nil
        case .formatting: return custom.formatting != nil
        case .fillers: return custom.fillers != nil
        }
    }

    @ViewBuilder
    private var triggerContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch category {
            case .punctuation:
                punctuationTriggerList
            case .formatting:
                formattingTriggerList
            case .fillers:
                fillersTriggerList
            }

            if hasCustomTriggers {
                Divider()

                HStack {
                    Spacer()
                    Button {
                        triggersManager.restoreDefaults(for: category)
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

    // MARK: - Child Components: Punctuation Trigger List

    @ViewBuilder
    private var punctuationTriggerList: some View {
        let triggersDictionary = triggersManager.effectivePunctuation() ?? [:]
        let sortedTriggerNames = triggersDictionary.keys.sorted()
        
        var verbals: [Verbal] {
            return sortedTriggerNames.map { triggerName in
                let triggerTexts = triggersDictionary[triggerName] ?? []
                return Verbal(
                    triggerTexts: triggerTexts,
                    editingSymbol: triggerName
                )
            }
        }
        
        triggerListView(
            triggerNames: sortedTriggerNames,
            verbals: verbals
        )
    }

    // MARK: - Child Components: Formatting Trigger List

    @ViewBuilder
    private var formattingTriggerList: some View {
        let triggersDictionary = triggersManager.effectiveFormatting() ?? [:]
        let sortedTriggerNames = triggersDictionary.keys.sorted()
        
        var triggerNames: [String] {
            return sortedTriggerNames.map { key in
                formatTriggerKeyDisplayName(for: key)
            }
        }
        
        var verbals: [Verbal] {
            return sortedTriggerNames.map { triggerName in
                let triggerTexts = triggersDictionary[triggerName] ?? []
                return Verbal(
                    triggerTexts: triggerTexts,
                    editingSymbol: triggerName
                )
            }
        }
        
        triggerListView(
            triggerNames: triggerNames,
            verbals: verbals
        )
    }

    // MARK: - Child Components: Fillers Trigger List

    @ViewBuilder
    private var fillersTriggerList: some View {
        let fillers = triggersManager.effectiveFillers() ?? []
        
        triggerListView(
            triggerNames: [String.localized("[Removed]", table: "Settings")],
            verbals: [Verbal(
                triggerTexts: fillers,
                editingSymbol: String.localized("__fillers__", table: "Settings")
            )]
        )
    }

    // MARK: - Child Components: Trigger List View
    
    private func triggerListView(
        triggerNames: [String],
        verbals: [Verbal]
    ) -> some View {
        HStack(alignment: .center, spacing: triggerListHorizontalSpacing) {
            triggerNamesColumnView(triggerNames)
            triggerVerbalsColumnView(verbals)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
    
    private func triggerNamesColumnView(_ triggerNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(triggerNames, id: \.self) { triggerName in
                Text(triggerName)
                    .styleText(
                        size: 12,
                        weight: .regular
                    )
                    .frame(
                        height: triggerRowHeight,
                        alignment: .center
                    )
            }
        }
    }
    
    private func triggerVerbalsColumnView(_ verbals: [Verbal]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(verbals, id: \.self) { verbal in
                TriggerVerbalsColumnRow(
                    verbal: verbal,
                    horizontalSpacing: triggerListHorizontalSpacing,
                    height: triggerRowHeight,
                    editingSymbol: $editingSymbol,
                    showEditModal: $showEditModal
                )
            }
        }
    }
    
    private struct TriggerVerbalsColumnRow: View {
        var verbal: Verbal
        var horizontalSpacing: CGFloat
        var height: CGFloat
        
        @Binding var editingSymbol: String?
        @Binding var showEditModal: Bool
        
        @State var isHovered: Bool = false
        
        private var triggerTexts: String {
            return verbal.triggerTexts.map { "\"\($0)\"" }.joined(separator: " / ")
        }
        
        private var triggerTextsIsEmpty: Bool {
            return triggerTexts.trimmingCharacters(in: .whitespaces).isEmpty
        }
        
        var body: some View {
            HStack(alignment: .center, spacing: horizontalSpacing) {
                Text(triggerTextsIsEmpty ? String.localized("No Triggers", table: "Settings") : triggerTexts)
                    .styleText(
                        size: 12,
                        italic: triggerTextsIsEmpty,
                        weight: .regular,
                        color: triggerTextsIsEmpty ? Color.T_3 : Color.T_1
                    )
                    .truncateText()
                
                Spacer()
                
                if isHovered {
                    SimpleButton(
                        text: triggerTextsIsEmpty ? String.localized("Add Trigger...", table: "Settings") : String.localized("Edit...", table: "Settings"),
                        cornerRadius: 6,
                        action: {
                            editingSymbol = verbal.editingSymbol
                            showEditModal = true
                        }
                    )
                }
            }
            .frame(
                height: height,
                alignment: .center
            )
            .onHover { isHovered in
                self.isHovered = isHovered
            }
        }
    }
    
    // MARK: - Private Functions
    
    private func formatTriggerKeyDisplayName(for triggerKey: String) -> String {
        if triggerKey == "\t" {
            return String.localized("Tab", table: "Settings")
        }

        let containsNewlines = triggerKey.contains("\n")
        let isOnlyNewLines = !triggerKey.isEmpty && triggerKey.allSatisfy({ $0 == "\n" })
        let isPureNewlineString = containsNewlines && isOnlyNewLines

        /// Pure newline strings:
        ///     * "\n" → "New Line"
        ///     * "\n\n" → "New Paragraph"
        if isPureNewlineString {
            switch triggerKey.count {
            case 1: return String.localized("New Line", table: "Settings")
            case 2: return String.localized("New Paragraph", table: "Settings")
            default: return String.localized("New Line x\(triggerKey.count)", table: "Settings")
            }
        }
        /// If contains newline string(s) + other content, strip leading newlines and trailing whitespace.
        else if containsNewlines {
            let formattedTriggerKey = triggerKey
                .drop(while: { $0 == "\n" })
                .trimmingCharacters(in: .whitespaces)
            return formattedTriggerKey.isEmpty ? triggerKey : formattedTriggerKey
        }

        /// No formatting required. Just return the trigger key as-is.
        return triggerKey
    }
}
