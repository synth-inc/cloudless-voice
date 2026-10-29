// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmojiTriggersSection.swift
//  Onit
//
//  Settings section for the "Insert Emoji" feature: an enable toggle plus a
//  collapsible "Customize Triggers" disclosure that shows the full spoken
//  name -> glyph dictionary and lets users add or override entries.
//
//  Mirrors `SmartFormattingCategorySection` (toggle + DisclosureGroup +
//  manager), adapted for the emoji map which is a single glyph per name.
//

import Defaults
import SwiftUI

private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

struct EmojiTriggersSection: View {
    // MARK: - Properties

    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool

    // MARK: - Observations

    @ObservedObject private var manager = EmojiTriggersManager.shared
    // Observed so the shown list refreshes when the dictation language changes:
    // the defaults follow `cleanupLocale`, see EmojiTriggers.defaults(for:).
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared
    @Default(ConfigKeys.emojiSemanticMatchingEnabled) private var semanticMatchingEnabled

    // MARK: - States

    @State private var isExpanded = false
    @State private var searchText = ""
    @State private var newName = ""
    @State private var newGlyph = ""

    // MARK: - Private Variables

    private let rowHeight: CGFloat = 30
    private let listMaxHeight: CGFloat = 260

    // MARK: - Body

    var body: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(title: title, subtitle: subtitle),
                isOn: $isEnabled
            )

            if isEnabled {
                DividerHorizontal()

                DisclosureGroup(
                    isExpanded: $isExpanded,
                    content: { triggerContent },
                    label: {
                        Button {
                            withAnimation { isExpanded.toggle() }
                        } label: {
                            Text(String.localized("Customize Triggers", table: "Settings"))
                                .styleText(size: 12)
                        }
                        .buttonStyle(.plain)
                    }
                )
            }
        }
    }

    // MARK: - Trigger Content

    private var sortedNames: [String] {
        let all = manager.effectiveGlyphs
        let query = EmojiTriggersManager.normalize(searchText)
        let names = query.isEmpty
            ? Array(all.keys)
            : all.keys.filter { $0.contains(query) || (all[$0] ?? "") == searchText }
        return names.sorted()
    }

    @ViewBuilder
    private var triggerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $semanticMatchingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Semantic matching (beta)", table: "Settings"))
                        .styleText(size: 12, weight: .regular, color: .S_0)
                    Text(String.localized("Match approximate names too: say \"crying emoji\" and we pick the closest glyph.", table: "Settings"))
                        .styleText(size: 11, weight: .regular, color: .T_3)
                }
            }
            .toggleStyle(.switch)

            DividerHorizontal()

            addRow

            DividerHorizontal()

            searchRow

            mappingList

            if manager.hasCustomizations {
                DividerHorizontal()
                HStack {
                    Text(String.localized("%d custom trigger(s)", table: "Settings", manager.customGlyphs.count))
                        .styleText(size: 11, weight: .regular, color: .T_3)
                    Spacer()
                    Button {
                        manager.restoreDefaults()
                    } label: {
                        Text(String.localized("Restore Defaults", table: "Settings"))
                            .styleText(size: 11)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(10)
        .background(Color.S_7.opacity(0.7))
        .cornerRadius(16)
        .padding(.top, 12)
    }

    // MARK: - Add Row

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField(String.localized("Spoken name (e.g. \"ship it\")", table: "Settings"), text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Text("→").styleText(size: 12, weight: .regular, color: .T_3)

            TextField("🚀", text: $newGlyph)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)

            Button {
                if manager.setTrigger(name: newName, glyph: newGlyph) {
                    newName = ""
                    newGlyph = ""
                }
            } label: {
                Text(String.localized("Add", table: "Settings"))
                    .styleText(size: 12, weight: .regular, color: .white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(canAdd ? Color.accentsBlue : Color.gray.opacity(0.4))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
        }
    }

    private var canAdd: Bool {
        !EmojiTriggersManager.normalize(newName).isEmpty
            && !newGlyph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Search Row

    private var searchRow: some View {
        TextField(String.localized("Search %d emoji triggers…", table: "Settings", manager.effectiveGlyphs.count), text: $searchText)
            .textFieldStyle(.roundedBorder)
    }

    // MARK: - Mapping List

    private var mappingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedNames, id: \.self) { name in
                    EmojiTriggerRow(
                        name: name,
                        glyph: manager.effectiveGlyphs[name] ?? "",
                        isCustom: manager.isCustomAddition(name),
                        isOverridden: manager.isOverriddenDefault(name),
                        height: rowHeight,
                        onRemove: { manager.removeCustom(name: name) }
                    )
                }
            }
        }
        .frame(maxHeight: listMaxHeight)
    }

    // MARK: - Row

    private struct EmojiTriggerRow: View {
        let name: String
        let glyph: String
        let isCustom: Bool
        let isOverridden: Bool
        let height: CGFloat
        let onRemove: () -> Void

        @State private var isHovered = false

        var body: some View {
            HStack(spacing: 8) {
                Text(glyph).font(.system(size: 15))
                    .frame(width: 24, alignment: .center)

                Text(name)
                    .styleText(size: 12, weight: .regular, color: .T_1)
                    .truncateText()

                if isCustom {
                    tag(String.localized("Custom", table: "Settings"))
                } else if isOverridden {
                    tag(String.localized("Overridden", table: "Settings"))
                }

                Spacer()

                if (isCustom || isOverridden) && isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isCustom
                        ? String.localized("Remove custom trigger", table: "Settings")
                        : String.localized("Revert to default", table: "Settings"))
                }
            }
            .frame(height: height)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.S_0.opacity(0.06) : Color.clear)
            .cornerRadius(6)
            .onHover { isHovered = $0 }
        }

        private func tag(_ text: String) -> some View {
            Text(text)
                .styleText(size: 9, weight: .regular, color: .T_3)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.S_0.opacity(0.08))
                .cornerRadius(4)
        }
    }
}
