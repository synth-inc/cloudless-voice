// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailTermListSection.swift
//  Onit
//
//  A reusable "Customize" disclosure for one of the email-layout lists
//  (greetings, sign-offs, or the composer app / webmail allowlist). Shows the
//  full built-in list - each entry marked on or off - plus the user's own
//  additions, and lets them add new entries, turn built-ins off, and revert.
//
//  Mirrors `EmojiTriggersSection`'s disclosure + add-row + hover-action idiom,
//  adapted for a flat string list layered over built-in defaults
//  (`EmailLayoutTermsManager`). Meant to be dropped inside an existing
//  `SettingsPageSection`, so it renders only the DisclosureGroup, not its own card.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EmailTermListSection: View {
    // MARK: - Properties

    /// Disclosure label, e.g. "Customize greetings".
    let title: String
    /// Placeholder for the add field, e.g. "Add a greeting (e.g. \"sup\")".
    let addPlaceholder: String
    let list: EmailTermList
    /// Apps are identified by bundle id, which is unfriendly to type - offer a
    /// native app picker and show resolved app names.
    var usesAppPicker: Bool = false
    /// Optional explainer shown in a "?" popover next to the title.
    var help: String? = nil

    // MARK: - Observations

    @ObservedObject private var manager = EmailLayoutTermsManager.shared
    // Greeting / sign-off defaults follow `cleanupLocale`; observe so the list
    // refreshes if the dictation language changes.
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared

    // MARK: - State

    @State private var isExpanded = false
    @State private var newTerm = ""
    @State private var showHelp = false

    // MARK: - Private

    private let rowHeight: CGFloat = 28
    private let listMaxHeight: CGFloat = 220

    // MARK: - Body

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: { content },
            label: {
                HStack(spacing: 6) {
                    Button {
                        withAnimation { isExpanded.toggle() }
                    } label: {
                        Text(title).styleText(size: 12)
                    }
                    .buttonStyle(.plain)

                    if let help {
                        Button {
                            showHelp.toggle()
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(help)
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                            Text(help)
                                .styleText(size: 12, weight: .regular, color: .T_1)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 260, alignment: .leading)
                                .padding(12)
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            addRow
            DividerHorizontal()
            entryList

            if manager.hasCustomizations(for: list) {
                DividerHorizontal()
                HStack {
                    Spacer()
                    Button {
                        manager.restoreDefaults(for: list)
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
            TextField(addPlaceholder, text: $newTerm)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onSubmit(commitAdd)

            if usesAppPicker {
                Button(action: chooseApp) {
                    Text(String.localized("Choose App…", table: "Settings"))
                        .styleText(size: 12)
                }
                .buttonStyle(.plain)
            }

            Button(action: commitAdd) {
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
        !EmailLayoutTermsManager.normalize(newTerm).isEmpty
    }

    private func commitAdd() {
        if manager.add(newTerm, to: list) { newTerm = "" }
    }

    /// Native picker: pick a `.app` and resolve its bundle identifier.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String.localized("Choose", table: "Settings")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        manager.add(bundleId, to: list)
    }

    // MARK: - Entry List

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(manager.entries(for: list)) { entry in
                    EmailTermRow(
                        label: displayName(for: entry.term),
                        state: entry.state,
                        height: rowHeight,
                        onRemove: { manager.remove(entry.term, from: list) },
                        onRestore: { manager.restore(entry.term, in: list) }
                    )
                }
            }
        }
        .frame(maxHeight: listMaxHeight)
    }

    /// For the apps list, show the installed app's name when we can resolve the
    /// bundle id; otherwise (and for every other list) show the raw term.
    private func displayName(for term: String) -> String {
        guard usesAppPicker,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: term) else {
            return term
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: - Row

    private struct EmailTermRow: View {
        let label: String
        let state: EmailTermState
        let height: CGFloat
        let onRemove: () -> Void
        let onRestore: () -> Void

        @State private var isHovered = false

        var body: some View {
            HStack(spacing: 8) {
                Text(label)
                    .styleText(size: 12, weight: .regular, color: state == .removed ? .T_3 : .T_1)
                    .truncateText()

                switch state {
                case .added: tag(String.localized("Added", table: "Settings"))
                case .removed: tag(String.localized("Off", table: "Settings"))
                case .builtIn: EmptyView()
                }

                Spacer()

                if isHovered { action }
            }
            .frame(height: height)
            .padding(.horizontal, 6)
            .background(isHovered ? Color.S_0.opacity(0.06) : Color.clear)
            .cornerRadius(6)
            .onHover { isHovered = $0 }
        }

        @ViewBuilder
        private var action: some View {
            switch state {
            case .removed:
                Button(action: onRestore) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String.localized("Turn back on", table: "Settings"))
            case .added:
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String.localized("Remove", table: "Settings"))
            case .builtIn:
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String.localized("Turn off", table: "Settings"))
            }
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
