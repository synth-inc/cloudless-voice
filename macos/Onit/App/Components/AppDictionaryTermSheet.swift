// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDictionaryTermSheet.swift
//  Onit
//
//  Created by Loyd Kim on 5/13/26.
//

import SwiftUI

struct AppDictionaryTermSheet: View {
    // MARK: - Types
    
    enum Mode {
        case add
        case edit(term: CustomDictionaryTerm)
    }
    
    // MARK: - Properties

    let mode: Mode
    var customDictionaryTerms: [CustomDictionaryTerm]
    
    /// Called for `.add` mode submissions. Receives the trimmed text.
    let onSubmit: (String) -> Void
    
    /// Called for `.edit` mode submissions. Receives the fully updated term
    /// (text, proxyWord, commonMistakes). Optional so call sites in `.add`
    /// mode can omit it.
    var onSubmitEdit: ((CustomDictionaryTerm) -> Void)? = nil
    
    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Observations
    
    @ObservedObject private var localization = LocalizationManager.shared
    
    // MARK: - States

    @State private var text: String = ""
    @State private var proxyWord: String = ""
    @State private var nllThresholdText: String = ""
    @State private var commonMistakesList: [String] = []
    @State private var confusionInputText: String = ""
    @State private var showAdvancedSection: Bool = false
    
    // MARK: - Private Variables

    private var isEditing: Bool {
        if case .edit = mode {
            return true
        }
        
        return false
    }
    
    private var customDictionaryTermsTexts: [String] {
        return customDictionaryTerms.map { term in
            return term.text
        }
    }

    private var trimmedText: String {
        return text.trimmingCharacters(in: .whitespaces)
    }

    private var wordCount: Int {
        return
            trimmedText.isEmpty ? 0 :
            trimmedText.split(separator: " ").count
    }

    private var isTooManyWords: Bool {
        return wordCount > 3
    }
    
    private var canSubmitAdd: Bool {
        return
            !trimmedText.isEmpty &&
            !isTooManyWords
    }
    
    private var canSaveEdit: Bool {
        return
            !trimmedText.isEmpty &&
            !isTooManyWords
    }
    
    // MARK: - Private Functions

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        // Flush any unsubmitted chip text before saving.
        let trimmedConfusionInputText = confusionInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !trimmedConfusionInputText.isEmpty {
            let trimmedConfusionInputTextSafe = trimmedConfusionInputText.lowercased()
            if !commonMistakesList.contains(where: {
                $0.lowercased() == trimmedConfusionInputTextSafe
            }) {
                commonMistakesList.append(trimmedConfusionInputText)
            }
            
            confusionInputText = ""
        }
        
        switch mode {
        case .add:
            onSubmit(trimmedText)
        case .edit(let term):
            var updated = term
            updated.text = trimmedText
            let trimmedProxy = proxyWord.trimmingCharacters(in: .whitespaces)
            updated.proxyWord = trimmedProxy.isEmpty ? nil : trimmedProxy
            updated.commonMistakes = commonMistakesList
            // Threshold: empty → clear override (use default); parseable Double → persist;
            // unparseable → keep prior value rather than silently nulling.
            let trimmedThreshold = nllThresholdText.trimmingCharacters(in: .whitespaces)
            if trimmedThreshold.isEmpty {
                updated.nllThreshold = nil
            } else if let value = Double(trimmedThreshold) {
                updated.nllThreshold = value
            }
            onSubmitEdit?(updated)
        }
        
        dismiss()
    }
    
    private func addConfusionTag() {
        let separatedInputTexts = confusionInputText.split(
            whereSeparator: { $0 == "," || $0.isNewline }
        )
        
        for inputText in separatedInputTexts {
            let trimmedInputText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInputText.isEmpty else { continue }
            
            let trimmedInputTextSafe = trimmedInputText.lowercased()
            
            if !commonMistakesList.contains(where: {
                $0.lowercased() == trimmedInputTextSafe
            }) {
                commonMistakesList.append(trimmedInputText)
            }
        }
        
        confusionInputText = ""
    }
    
    // MARK: - Body

    var body: some View {
        Group {
            if isEditing {
                editExistingDictionaryTermView
            } else {
                addNewDictionaryTermView
            }
        }
        .id(localization.currentLanguage)
        .onAppear {
            if case .edit(let term) = mode {
                text = term.text
                proxyWord = term.proxyWord ?? ""
                commonMistakesList = term.commonMistakes
                nllThresholdText = term.nllThreshold.map { String(format: "%.3f", $0) } ?? ""
                // Always start collapsed; user can expand to reveal proxy.
                // Don't auto-focus the term field - it's read-only in edit mode.
            }
        }
    }

    // MARK: - Child Components: Add New Dictionary Term View

    private var addNewDictionaryTermView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                addNewTermHeaderView
                addNewTermInputField
            }
            .padding(16)
            
            toolbarView(
                cancelButton: .init(
                    text: String.localized("Cancel", table: "App"),
                    action: {
                        dismiss()
                    }
                ),
                primaryButton: .init(
                    text: String.localized("Add", table: "App"),
                    disabled: !canSubmitAdd,
                    action: {
                        submit()
                    }
                )
            )
        }
        .frame(width: 345)
    }
    
    private var addNewTermHeaderView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String.localized("Add a term", table: "App"))
                .styleText(
                    size: 15,
                    weight: .regular,
                    color: Color.S_0
                )
            
            Text(String.localized(
                "Add a word you want Cloudless to recognize.",
                table: "App"
            ))
            .styleText(
                size: 14,
                weight: .regular,
                color: Color.T_1
            )
        }
    }
    
    private var addNewTermInputField: some View {
        InputField(
            text: $text,
            placeholder: String.localized("Enter a new term", table: "App"),
            errorMessage: customDictionaryTermsTexts.contains(text) ?
                String.localized(
                    "Term already in dictionary", 
                    table: "App"
                ) :
                isTooManyWords ?
                String.localized(
                    "Terms longer than 3 words won't be recognized. Try splitting into separate shorter terms.",
                    table: "App"
                ) : nil,
            colorConfig: .init(
                background: Color.special1,
                border: Color.T_8
            ),
            sizeConfig: .init(
                cornerRadius: 12
            )
        ) {
            submit()
        }
    }

    // MARK: - Child Components: Edit Existing Dictionary Term View

    private var editExistingDictionaryTermView: some View {
        VStack(alignment: .leading, spacing: 0) {
            editExistingTermHeaderView

            VStack(alignment: .leading, spacing: 8) {
                editExistingTermConfusionsView
                editExistingTermAdvancedSettingsToggleButtonView
                editExistingTermAdvancedSettingsView
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            
            toolbarView(
                cancelButton: .init(
                    text: String.localized("Cancel", table: "App"),
                    action: {
                        dismiss()
                    }
                ),
                primaryButton: .init(
                    text: String.localized("Save", table: "App"),
                    disabled: !canSaveEdit,
                    action: {
                        submit()
                    }
                )
            )
        }
        .frame(width: 460)
    }
    
    // MARK: - Child Components: Edit Existing Term Header View
    
    private var editExistingTermHeaderView: some View {
        Text(text)
            .styleText(size: 15, weight: .medium, color: Color.S_0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.horizontal, 16)
    }
    
    // MARK: - Child Components: Edit Existing Term Confusions View
    
    private var editExistingTermConfusionsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String.localized(
                "Known confusions",
                table: "App")
            )
            .styleText(
                size: 12,
                weight: .regular
            )
            
            confusionsTagsField
            
            Text(String.localized(
                "Cloudless will correct these confusions in the future.",
                table: "App"
            ))
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.T_1
            )
        }
    }

    private var confusionsTagsField: some View {
        FlowLayout(spacing: 4) {
            ForEach(commonMistakesList.indices, id: \.self) { index in
                confusionTag(
                    text: commonMistakesList[index]
                ) {
                    commonMistakesList.remove(at: index)
                }
            }
            
            confusionsTextField
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.special1)
        .addBorder(
            cornerRadius: 12,
            stroke: Color.T_8
        )
    }

    private func confusionTag(
        text: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(text)
                .styleText(
                    weight: .regular
                )
            
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(Color.T_1)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .frame(height: 26, alignment: .center)
        .background(Color.T_9)
        .addBorder(
            cornerRadius: 999,
            stroke: Color.T_8
        )
    }

    private var confusionsTextField: some View {
        TextField(
            String.localized("Separate with comma (,)", table: "App"),
            text: $confusionInputText
        )
        .textFieldStyle(PlainTextFieldStyle())
        .styleText(
            size: 14,
            weight: .regular
        )
        .frame(minWidth: 140, alignment: .leading)
        .frame(height: 26, alignment: .center)
        .onChange(of: confusionInputText) { _, inputText in
            if inputText.contains(",") || inputText.contains("\n") {
                addConfusionTag()
            }
        }
        .onSubmit(addConfusionTag)
    }
    
    // MARK: - Child Components: Edit Existing Term Advanced Settings Toggle Button View
    
    private var editExistingTermAdvancedSettingsToggleButtonView: some View {
        Button {
            showAdvancedSection.toggle()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(String.localized("Advanced settings", table: "App"))
                    .styleText(
                        weight: .regular
                    )
                
                Image(systemName: showAdvancedSection ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(Color.S_0)
                
                Spacer(minLength: 0)
            }
            .frame(height: 34, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Child Components: Edit Existing Term Advanced Settings View
    
    /// Advanced section: proxy word + replacement threshold (instant insert/remove).
    /// Always reserves layout space so the modal height doesn't change when toggled - keeps the rows above pinned in place.
    @ViewBuilder
    private var editExistingTermAdvancedSettingsView: some View {
        if showAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Proxy word", table: "App"))
                        .styleText(
                            size: 12,
                            weight: .regular
                        )

                    InputField(
                        text: $proxyWord,
                        placeholder: "Sarah",
                        colorConfig: .init(
                            background: Color.special1,
                            border: Color.T_8
                        ),
                        sizeConfig: .init(
                            cornerRadius: 12
                        )
                    )

                    Text(String.localized(
                        "We auto-generate a common word with similar meaning to help Cloudless understand your term. You can replace this with a better word. Removing it completely will turn off this feature and likely reduce accuracy.",
                        table: "App"
                    ))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Replacement threshold", table: "App"))
                        .styleText(
                            size: 12,
                            weight: .regular
                        )

                    InputField(
                        text: $nllThresholdText,
                        placeholder: "-0.126",
                        colorConfig: .init(
                            background: Color.special1,
                            border: Color.T_8
                        ),
                        sizeConfig: .init(
                            cornerRadius: 12
                        )
                    )

                    Text(String.localized(
                        "Typical range is -0.20 to 0.0; default is -0.126. Lower values accept more replacements; higher values are stricter. Clear to use the default.",
                        table: "App"
                    ))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_1
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    
    // MARK: - Child Components: Toolbar View
    
    struct ToolbarButton {
        let text: String
        var disabled: Bool = false
        let action: () -> Void
    }
    
    private func toolbarView(
        cancelButton: ToolbarButton,
        primaryButton: ToolbarButton
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer()
            
            TextButton(
                text: cancelButton.text,
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 36
                )
            ) {
                cancelButton.action()
            }
            
            TextButton(
                type: .primary,
                text: primaryButton.text,
                sizeConfig: .init(
                    horizontalPadding: 22,
                    height: 36
                ),
                statusConfig: .init(
                    disabled: primaryButton.disabled
                )
            ) {
                primaryButton.action()
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
