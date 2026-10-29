// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarLastTranscription.swift
//  Onit
//
//  Created by Loyd Kim on 4/27/26.
//

import AppKit

@MainActor
final class MenuBarLastTranscription: MenuBarItemBase {
    // MARK: - Initializer

    override func initializeProperties() {
        self.title = ""
        self.action = nil
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.title = String.localized("Last Transcript", table: "MenuBar")
        self.populateDropdownSubmenu()
    }

    // MARK: - States

    private var dropdownSubmenu = NSMenu()

    // MARK: - Private Functions

    private func populateDropdownSubmenu() {
        self.dropdownSubmenu.removeAllItems()

        self.dropdownSubmenu.addItem(self.lastTranscriptionPreviewItem())
        self.dropdownSubmenu.addItem(self.copyLastTranscriptionButtonItem())
        self.dropdownSubmenu.addItem(self.pasteLastTranscriptionButtonItem())
        self.dropdownSubmenu.addItem(self.editLastTranscriptionButtonItem())

        self.submenu = self.dropdownSubmenu
    }

    private func lastTranscriptionPreviewItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false

        let prefix = String.localized("Last: ", table: "MenuBar")
        let transcript = LastTranscriptionState.shared.previewText ?? ""
        item.view = MenuBarLastTranscriptionPreviewView(text: prefix + transcript)

        return item
    }

    private func copyLastTranscriptionButtonItem() -> NSMenuItem {
        let item = NSMenuItem()

        item.view = MenuBarItemTitleAndShortcutView(
            title: String.localized("Copy", table: "MenuBar"),
            shortcutText: LastTranscriptionState.shared.copyShortcutText,
            onClick: {
                TranscriptionManager.shared.copyLastTranscription(for: .menuBar)
            }
        )

        return item
    }

    private func pasteLastTranscriptionButtonItem() -> NSMenuItem {
        let item = NSMenuItem()

        item.view = MenuBarItemTitleAndShortcutView(
            title: String.localized("Paste", table: "MenuBar"),
            shortcutText: LastTranscriptionState.shared.pasteShortcutText,
            onClick: {
                TranscriptionManager.shared.pasteLastTranscription(for: .menuBar)
            }
        )

        return item
    }

    private func editLastTranscriptionButtonItem() -> NSMenuItem {
        let item = NSMenuItem()

        item.view = MenuBarItemTitleAndShortcutView(
            title: String.localized("Edit", table: "MenuBar"),
            shortcutText: LastTranscriptionState.shared.editShortcutText,
            onClick: {
                TranscriptionManager.shared.editLastTranscription()
            }
        )

        return item
    }
}

// MARK: - Last Transcription Preview View

private final class MenuBarLastTranscriptionPreviewView: NSView {
    private let label = NSTextField(labelWithString: "")

    private let menuItemWidth: CGFloat = 280
    private let menuItemHeight: CGFloat = 24
    private let leadingPadding: CGFloat = 16
    private let trailingPadding: CGFloat = -16

    init(text: String) {
        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: menuItemWidth,
                height: menuItemHeight
            )
        )

        configureView(text: text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureView(text: String) {
        wantsLayer = true

        label.stringValue = text
        label.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        label.textColor = .tertiaryLabelColor
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.cell?.wraps = false
        label.cell?.isScrollable = false

        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                equalToConstant: menuItemHeight
            ),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: leadingPadding
            ),
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: trailingPadding
            ),
            label.centerYAnchor.constraint(
                equalTo: centerYAnchor
            )
        ])
    }
}
