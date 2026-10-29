// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Hint+MoreMenu.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Private Variables: Microphone Selection
 * Private Variables: Snooze
 * Functions: Click Outside Monitor
 * Functions: Visibility Toggles
 * Private Functions
 * Child Components
 */

import Defaults
import SwiftUI

extension Hint {
    // MARK: - Private Variables: Microphone Selection

    private var shouldShowMicrophoneSelection: Bool {
        return
            transcriptionEnabled &&
            microphoneInputManager.hasPermission
    }
    
    // MARK: - Private Variables: Snooze

    /// Mirrors `HintManager.isHintSnoozed`. Evaluated once per open: the more menu is injected by
    ///     value into its own window (`HintManager.showMoreMenu`), so it is a snapshot rather than a
    ///     live view, and a snooze that lapses while it is open won't flip the row.
    private var isHintSnoozed: Bool {
        guard let hintSnoozedUntil = hintSnoozedUntil else { return false }

        return hintSnoozedUntil > .now
    }

    // MARK: - Functions: Click Outside Monitor
    
    private func setupClickOutsideMonitor() {
        removeClickOutsideMonitor()
        
        /// Monitor for clicks within our own app.
        clickOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [self] event in
            let screenLocation = NSEvent.mouseLocation
            if !hintManager.isClickInsideWindows(screenLocation) {
                DispatchQueue.main.async {
                    self.hideMoreMenu()
                }
            }
            return event
        }
                                                                                                                                
        /// Monitor for clicks outside our app.
        clickOutsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [self] _ in
            DispatchQueue.main.async {
                self.hideMoreMenu()
            }
        }
    }

    func removeClickOutsideMonitor() {
        if let monitor = clickOutsideLocalMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideLocalMonitor = nil
        }
        
        if let monitor = clickOutsideGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideGlobalMonitor = nil
        }
    }
    
    // MARK: - Functions: Visibility Toggles
    
    func toggleMoreMenu() {
        if shouldShowMoreMenu {
            hideMoreMenu()
        } else {
            showMoreMenu()
        }
    }

    private func showMoreMenu() {
        guard !isDragging else { return }

        if shouldShowMicrophoneSelection {
            microphoneInputManager.refreshAvailableDevicesAndAutoSelectIfNeeded(
                autoSelectInputDevice: transcriptionInputDevice == nil
            )
        }

        shouldShowMoreMenu = true
        setupClickOutsideMonitor()
        hintManager.hideTranscriptionOverlayIfNeeded()
        hintManager.showMoreMenu(swiftUIView: moreMenuView)
    }

    func hideMoreMenu() {
        shouldShowMoreMenu = false
        removeClickOutsideMonitor()
        hintManager.hideMoreMenu()

        /// Re-evaluate popup after a brief delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let popUpMessageType = activePopUpMessageType {
                showPopUpMessage(type: popUpMessageType)
            }
        }
    }

    // MARK: - Private Functions
    
    private func openApp() {
        hideMoreMenu()
        AppWindowManager.shared.showWindow()
    }

    private func openSettings() {
        hideMoreMenu()
        AppWindowManager.shared.showWindow(settingsPage: .general)
    }
    
    // MARK: - Child Components
    
    var moreMenuView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                moreMenuOpenAppButtonView
                moreMenuOpenSettingsButtonView
            }

            moreMenuSnoozeSectionView

            moreMenuLastTranscriptSectionView

            if shouldShowMicrophoneSelection {
                DividerHorizontal()
                moreMenuMicrophoneSelectionView
            }
        }
        .padding(8)
        .background(Color.S_10.opacity(0.65))
        .background(Backgrounds.BrushedGlass())
        .addBorder(
            cornerRadius: 15,
            stroke: Color.T_8
        )
        .fixedSize()
        .addAnimation(dependency: shouldShowMoreMenu)
    }
    
    @ViewBuilder
    private var moreMenuLastTranscriptSectionView: some View {
        if lastTranscriptionState.isActive {
            DividerHorizontal()
            
            VStack(alignment: .leading, spacing: 0) {
                moreMenuLastTranscriptPreviewView
                moreMenuCopyLastTranscriptButtonView
                moreMenuPasteLastTranscriptButtonView
                moreMenuEditLastTranscriptButtonView
                moreMenuCorrectAndTeachOnit
            }
            .frame(
                width: 227,
                alignment: .leading
            )
        }
    }
    
    @ViewBuilder
    private var moreMenuLastTranscriptPreviewView: some View {
        if let previewText = lastTranscriptionState.previewText,
           !previewText.isEmpty
        {
            Text(String.localized("Last: ", table: "MenuBar") + previewText)
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.T_3
                )
                .truncateText()
                .padding(.horizontal, 10)
                .frame(height: 22, alignment: .center)
        }
    }
    
    private var moreMenuCopyLastTranscriptButtonView: some View {
        MoreMenuItemButtonView(
            text: String.localized("Copy", table: "MenuBar"),
            shortcut: lastTranscriptionState.copyShortcutText
        ) {
            hideMoreMenu()
            TranscriptionManager.shared.copyLastTranscription(for: .hintMoreMenu)
        }
    }
    
    private var moreMenuPasteLastTranscriptButtonView: some View {
        MoreMenuItemButtonView(
            text: String.localized("Paste", table: "MenuBar"),
            shortcut: lastTranscriptionState.pasteShortcutText
        ) {
            hideMoreMenu()
            TranscriptionManager.shared.pasteLastTranscription(for: .hintMoreMenu)
        }
    }

    private var moreMenuEditLastTranscriptButtonView: some View {
        MoreMenuItemButtonView(
            text: String.localized("Edit", table: "MenuBar"),
            shortcut: lastTranscriptionState.editShortcutText
        ) {
            hideMoreMenu()
            TranscriptionManager.shared.editLastTranscription()
        }
    }

    private var moreMenuCorrectAndTeachOnit: some View {
        let label = String.localized("Correct", table: "MenuBar")

        return MoreMenuItemButtonView(text: label) {
            hideMoreMenu()
            TranscriptionManager.shared.correctAndTeachLastTranscription(for: .hintMoreMenu)
        }
    }
    
    /// Hidden while `alwaysHideHint` is on: the Hint is already hidden, so a snooze would be a no-op.
    ///     Carries a leading divider like every other section below it; none of them carries a
    ///     trailing one, which would hang under the last row when nothing follows.
    ///
    ///     The durations unfold inline rather than in a SwiftUI `Menu`: a `Menu` label gets the
    ///     control's own text treatment (dimmed, and inset to leave room for the indicator) no
    ///     matter what is applied to it, so it could never match the Home / Settings rows. Building
    ///     every row from `MoreMenuItemButtonView` makes them identical by construction, and mirrors
    ///     how the Windows more-menu expands the same list.
    @ViewBuilder
    private var moreMenuSnoozeSectionView: some View {
        if !alwaysHideHint {
            DividerHorizontal()

            if isHintSnoozed {
                MoreMenuItemButtonView(
                    text: String.localized("Show hint", table: "MenuBar")
                ) {
                    hideMoreMenu()
                    hintManager.cancelHintSnooze()
                }
            } else {
                MoreMenuSnoozeView { duration in
                    hideMoreMenu()
                    hintManager.snoozeHint(duration)
                }
            }
        }
    }

    private var moreMenuMicrophoneSelectionView: some View {
        MoreMenuMicrophoneView(
            availableDevices: microphoneInputManager.availableDevices,
            currentInputDeviceID: transcriptionInputDevice?.id
        ) { deviceID in
            Task {
                await microphoneInputManager.setInputDevice(deviceID)
            }
            DispatchQueue.main.async {
                hideMoreMenu()
            }
        }
    }

    private var moreMenuOpenAppButtonView: some View {
        MoreMenuItemButtonView(
            text: String.localized("Home", table: "MenuBar")
        ) {
            openApp()
        }
    }

    private var moreMenuOpenSettingsButtonView: some View {
        MoreMenuItemButtonView(
            text: String.localized("Settings", table: "MenuBar")
        ) {
            openSettings()
        }
    }
    
    private struct MoreMenuItemButtonView: View {
        let text: String
        var disabled: Bool = false
        var shortcut: String? = nil
        /// SF Symbol drawn at the trailing edge, for rows that unfold (see `MoreMenuSnoozeView`).
        ///     An `Image` rather than a text glyph: arrowhead characters sit low in their line box,
        ///     while SF Symbols are cut to align with the text they sit next to.
        var trailingSystemName: String? = nil
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button {
                action()
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text(text)
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: disabled ? Color.T_3 : Color.S_0
                        )
                        .truncateText()

                    Spacer()

                    if let shortcut = shortcut {
                        Text(shortcut)
                            .styleText(
                                size: 13,
                                weight: .regular,
                                color: Color.T_2
                            )
                    }

                    if let trailingSystemName = trailingSystemName {
                        Image(systemName: trailingSystemName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.T_2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 10)
            .frame(height: 22, alignment: .center)
            .background(
                isHovered && !disabled ? Color.T_8 : Color.clear
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
            .disabled(disabled)
            .onHover { isHovered in
                self.isHovered = isHovered
            }
            .addAnimation(dependency: isHovered)
        }
    }
    
    // MARK: - More Menu Microphone View

    /// Same construction as `MoreMenuSnoozeView`: a plain row plus a real `NSMenu` pop-up.
    private struct MoreMenuMicrophoneView: View {
        let availableDevices: [MicrophoneInputDevice]
        let currentInputDeviceID: String?
        let onSelectDevice: (String) -> Void

        var body: some View {
            MoreMenuItemButtonView(
                text: String.localized("Microphone", table: "MenuBar"),
                trailingSystemName: "chevron.right"
            ) {
                showDevicesPopUp()
            }
        }

        @MainActor
        private func showDevicesPopUp() {
            let menu = NSMenu()

            guard !availableDevices.isEmpty else {
                /// No target and no action, so `autoenablesItems` greys it out on its own.
                menu.addItem(
                    withTitle: String.localized("No microphones found", table: "MenuBar"),
                    action: nil,
                    keyEquivalent: ""
                )
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }

            for device in availableDevices {
                let displayName: String = {
                    #if DEBUG || ONIT_BETA
                    return "\(device.name) [\(device.source?.description ?? "nil")]"
                    #else
                    return device.name
                    #endif
                }()

                menu.addPopUpItem(
                    title: displayName,
                    isOn: device.id == currentInputDeviceID
                ) {
                    onSelectDevice(device.id)
                }
            }

            menu.addItem(.separator())

            menu.addPopUpItem(
                title: String.localized("Auto-Switch to New Mics", table: "MenuBar"),
                isOn: Defaults[.transcriptionAutoSwitchMicrophone]
            ) {
                Defaults[.transcriptionAutoSwitchMicrophone].toggle()
            }

            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: - More Menu Snooze View

    /// The row itself is a plain `MoreMenuItemButtonView`, so it matches Home / Settings by
    ///     construction, and the durations open in a real `NSMenu` pop-up like the microphone row.
    ///     Not a SwiftUI `Menu`: that draws its label with the control's own text treatment (dimmed
    ///     and inset to leave room for the indicator), which no modifier overrides, so the row could
    ///     never line up with the ones above it.
    private struct MoreMenuSnoozeView: View {
        let onSelectDuration: (HintSnoozeDuration) -> Void

        var body: some View {
            MoreMenuItemButtonView(
                text: String.localized("Hide for", table: "MenuBar"),
                trailingSystemName: "chevron.right"
            ) {
                showDurationsPopUp()
            }
        }

        @MainActor
        private func showDurationsPopUp() {
            let menu = NSMenu()

            for duration in HintSnoozeDuration.allCases {
                menu.addPopUpItem(title: duration.title(table: "MenuBar")) {
                    onSelectDuration(duration)
                }
            }

            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// The action a pop-up row runs. `NSMenuItem` has no closure slot, but `representedObject` takes
///     any object, so each row carries its own instead of routing through one selector per menu.
private final class MoreMenuPopUpAction: NSObject {
    let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
    }
}

/// Shared target for every more-menu pop-up. `NSMenuItem.target` is **weak**, and AppKit does not
///     document whether an item's action is dispatched before `popUp` returns: a per-call target
///     could be deallocated first, leaving the weak reference nil, the action re-routed up the
///     responder chain, and the row silently doing nothing. This one is stateless and lives for the
///     process, so that can't happen.
@MainActor
private let moreMenuPopUpTarget = MoreMenuPopUpTarget()

/// Runs whatever action the clicked row carries. A top-level class because `@objc` members can't
///     live on a type nested inside a struct.
private final class MoreMenuPopUpTarget: NSObject {
    @MainActor
    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? MoreMenuPopUpAction)?.run()
    }
}

extension NSMenu {
    /// Appends a row that carries its own action, with `isOn` drawing the checkmark.
    @MainActor
    fileprivate func addPopUpItem(
        title: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(MoreMenuPopUpTarget.run(_:)),
            keyEquivalent: ""
        )

        item.target = moreMenuPopUpTarget
        item.representedObject = MoreMenuPopUpAction(run: action)
        item.state = isOn ? .on : .off

        addItem(item)
    }
}
