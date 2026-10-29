// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartFormattingEditModal.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-24.
//

import SwiftUI

/// Modal for editing trigger words for a specific symbol in a smart formatting category.
struct SmartFormattingEditModal: View {
    // MARK: - Properties
    
    let category: SmartFormattingCategory
    let symbol: String
    @Binding var isPresented: Bool
    
    // MARK: - Observations

    @ObservedObject private var triggersManager = SmartFormattingTriggersManager.shared
    
    // MARK: - States
    
    @State private var newTrigger = ""
    @State private var conflictSymbol: String?

    // MARK: - Private Variables
    
    private var displayTitle: String {
        if category == .fillers {
            return String.localized("Manage Filler Words", table: "Settings")
        }
        return String.localized("Manage triggers for \"%@\"", table: "Settings", symbol)
    }

    private var currentTriggers: [String] {
        switch category {
        case .punctuation:
            let all = triggersManager.effectivePunctuation() ?? [:]
            return all[symbol] ?? []
        case .formatting:
            let all = triggersManager.effectiveFormatting() ?? [:]
            return all[symbol] ?? []
        case .fillers:
            return triggersManager.effectiveFillers() ?? []
        }
    }
    
    private var addTriggerButtonDisabled: Bool {
        return newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || conflictSymbol != nil
    }
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleView
            addTriggerFormView
            triggersListView
            footerView
        }
        .padding(20)
        .frame(
            width: 345,
            height: 272
        )
    }
    
    // MARK: - Child Components: Title View
    
    private var titleView: some View {
        Text(displayTitle)
            .styleText(
                size: 14,
                weight: .regular
            )
    }
    
    // MARK: - Child Components: Add Trigger Form View
    
    private var addTriggerFormView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                addTriggerInputFieldView
                addTriggerButton
            }
            if let conflictSymbol {
                Text(String.localized("Already used by \"%@\"", table: "Settings", conflictSymbol))
                    .styleText(
                        size: 11,
                        weight: .regular,
                        color: Color.red
                    )
            }
        }
    }
    
    private var addTriggerInputFieldView: some View {
        InputField(
            text: $newTrigger,
            placeholder: category == .fillers ?
                String.localized("filler word", table: "Settings") :
                String.localized("trigger word / phrase", table: "Settings"),
            sizeConfig: .init(
                height: 36,
                cornerRadius: 12
            )
        ) {
            addTrigger()
        }
        .onChange(of: newTrigger) { _, _ in
            checkConflict()
        }
    }
    
    private var addTriggerButton: some View {
        Button {
            addTrigger()
        } label: {
            Image(systemName: "plus")
                .frame(
                    width: 46,
                    height: 36,
                    alignment: .center
                )
                .styleText(color: Color.white)
                .background(Color.blue)
                .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(addTriggerButtonDisabled)
        .addAnimation(dependency: addTriggerButtonDisabled)
    }
    
    // MARK: - Child Components: Triggers List View
    
    private var triggersListView: some View {
        ScrollView {
            if currentTriggers.isEmpty {
                triggersListEmptyView
            } else {
                triggersList
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Color.T_9)
        .cornerRadius(16)
    }
    
    private var triggersListEmptyView: some View {
        Text(String.localized("no triggers added yet", table: "Settings"))
            .padding(8)
            .frame(
                maxWidth: .infinity,
                alignment: .center
            )
            .styleText(
                size: 13,
                italic: true,
                weight: .regular,
                color: Color.T_2,
            )
    }
    
    private var triggersList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(currentTriggers, id: \.self) { trigger in
                triggersListRow(trigger)
            }
        }
        .padding(4)
    }
    
    private func triggersListRow(_ trigger: String) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(trigger)
                .styleText(
                    size: 13,
                    weight: .regular
                )
                .truncateText()
            
            Spacer()
            
            Button {
                removeTrigger(trigger)
            } label: {
                Image(systemName: "minus.circle")
                    .styleText(
                        size: 13,
                        color: Color.T_2
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(8)
    }
    
    // MARK: - Child Components: Footer View
    
    private var footerView: some View {
        HStack(alignment: .center, spacing: 0) {
            footerRestoreDefaultsButton
            Spacer()
            footerDoneButton
        }
    }
    
    private var footerRestoreDefaultsButton: some View {
        SimpleButton(
            text: String.localized("Restore Defaults", table: "Settings"),
            cornerRadius: 6,
            action: {
                triggersManager.restoreDefaults(for: category)
            }
        )
    }
    
    private var footerDoneButton: some View {
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

    // MARK: - Private Functions

    private func addTrigger() {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard conflictSymbol == nil else { return }

        switch category {
        case .punctuation:
            triggersManager.addPunctuationTrigger(symbol: symbol, trigger: trimmed)
        case .formatting:
            triggersManager.addFormattingTrigger(symbol: symbol, trigger: trimmed)
        case .fillers:
            triggersManager.addFiller(trimmed)
        }

        newTrigger = ""
        conflictSymbol = nil
    }

    private func checkConflict() {
        let trimmed = newTrigger.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, category != .fillers else {
            conflictSymbol = nil
            return
        }
        conflictSymbol = triggersManager.symbolUsingTrigger(trimmed, in: category, excluding: symbol)
    }

    private func removeTrigger(_ trigger: String) {
        switch category {
        case .punctuation:
            triggersManager.removePunctuationTrigger(symbol: symbol, trigger: trigger)
        case .formatting:
            triggersManager.removeFormattingTrigger(symbol: symbol, trigger: trigger)
        case .fillers:
            triggersManager.removeFiller(trigger)
        }
    }
}
