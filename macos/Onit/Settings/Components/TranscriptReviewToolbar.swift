// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptReviewToolbar.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import SwiftUI

/// Bottom toolbar of the review modal: ← back, "X reviewed (Y%)" progress
/// counter, optional "+N today" pill, Delete, Skip/Next, and the dynamic
/// primary CTA group.
///
/// Five primary CTA renderings, derived from `(isDirty, currentStatus,
/// hasBeenUploaded)`:
///   - !dirty + .unreviewed                       → `[Mark as correct]`         (⌘↩)
///   - dirty (any status)                          → `[Save]` `[Save & request fix]`  (⌘↩ / ⌘⇧↩)
///   - !dirty + .reviewed                          → `[✓ Reviewed badge]` (revert)
///   - !dirty + .corrected + !hasBeenUploaded      → `[Request fix]` `[✓ Corrected badge]` (revert) - Request fix on ⌘⇧↩
///   - !dirty + .corrected + hasBeenUploaded       → `[✓ Corrected badge]` (revert)
///
/// Keyboard shortcuts are scoped to whichever CTA is currently rendered:
/// ⌘↩ for the safe local-save default (Mark as correct or Save), ⌘⇧↩ for
/// the share-with-Onit variant (Save & request fix or Request fix). Each
/// button surfaces its shortcut via the standard hover tooltip rather
/// than an inline label, to keep the buttons compact.
struct TranscriptReviewToolbar: View {
    // MARK: - Properties

    let canGoBack: Bool
    let canSkip: Bool
    let canSubmit: Bool
    let isDirty: Bool
    let currentStatus: TranscriptionHistory.ReviewStatus
    /// Whether the current row's correction has reached
    /// `everUploadedAt != nil`. Drives the `.corrected` toolbar split
    /// between "Request fix + Corrected" and "Corrected only".
    let hasBeenUploaded: Bool
    let reviewedCount: Int
    let totalCount: Int
    /// Number of reviews completed today, surfaced via the green
    /// "+N today" pill when greater than zero. Sourced from
    /// `TranscriptionHistoryManager.reviewedTodayCount` (DB-derived) so it
    /// stays consistent with reverts and survives a relaunch.
    let reviewedTodayCount: Int

    let onBack: () -> Void
    let onSkip: () -> Void
    let onDelete: () -> Void
    /// Tapped from the single `Mark as correct` button (no-edit save path).
    let onMarkAsCorrect: () -> Void
    /// Tapped from the local-only `Save` button (dirty path). The parent
    /// persists the edit and stamps the correction `excludedReason = optOut`.
    let onSave: () -> Void
    /// Tapped from `Save & request fix` (dirty path). The parent gates
    /// this on the consent modal when the user hasn't confirmed yet.
    let onSaveAndRequestFix: () -> Void
    /// Tapped from `Request fix` (corrected + not yet uploaded path).
    /// Same consent gating as `onSaveAndRequestFix`.
    let onRequestFix: () -> Void
    let onRevert: () -> Void

    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @State private var hoveredDeleteButton: Bool = false
    @State private var hoveredSkipButton: Bool = false
    @State private var hoveredMarkAsCorrect: Bool = false
    @State private var hoveredSave: Bool = false
    @State private var hoveredSaveAndRequestFix: Bool = false
    @State private var hoveredRequestFix: Bool = false
    @State private var hoveredStatusBadge: Bool = false

    // MARK: - Private Variables

    private let buttonHeight: CGFloat = 36
    private let cornerRadius: CGFloat = 9
    private let horizontalPadding: CGFloat = 12

    private var progressPercent: Int {
        guard totalCount > 0 else { return 0 }
        // Show 100% only when literally everything is reviewed - `rounded()`
        // would tip 199/200 to 100%, which is misleading.
        if reviewedCount >= totalCount { return 100 }
        return Int(floor(Double(reviewedCount) / Double(totalCount) * 100))
    }

    /// "Skip" on an unreviewed transcript reads as "ignore this one for now",
    /// but on an already-reviewed/corrected transcript that framing is wrong -
    /// the action just steps forward through the queue. Use "Next" in that case.
    private var skipLabel: String {
        switch currentStatus {
        case .unreviewed:
            return String.localized("Skip", table: "Transcription")
        case .reviewed, .corrected:
            return String.localized("Next", table: "Transcription")
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            backButton
            progressLabel

            Spacer()

            deleteButton
            skipButton
            primaryCTAs
        }
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components

    private var backButton: some View {
        IconButton(
            systemName: "arrow.left",
            iconSize: 14,
            buttonSize: buttonHeight,
            inactiveColor: Color.S_0,
            background: canGoBack ? Color.T_9 : Color.clear,
            hoverBackground: Color.T_8,
            cornerRadius: cornerRadius,
            disabled: !canGoBack,
            tooltipPrompt: String.localized("Previous transcription", table: "App")
        ) {
            onBack()
        }
    }

    private var progressLabel: some View {
        HStack(spacing: 8) {
            Text(
                String.localized(
                    "%lld reviewed (%lld%%)",
                    table: "Transcription",
                    reviewedCount,
                    progressPercent
                )
            )
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.T_1
            )
            if reviewedTodayCount > 0 {
                Text(
                    String.localized(
                        "+%lld today",
                        table: "Transcription",
                        reviewedTodayCount
                    )
                )
                .styleText(
                    size: 13,
                    weight: .medium,
                    color: Color.lime500
                )
            }
        }
        // Hold the label's intrinsic horizontal size so it can't wrap to
        // a second line when both Save / Save & request fix CTAs are
        // rendered. The trailing `Spacer()` in the toolbar absorbs the
        // squeeze instead.
        .fixedSize(horizontal: true, vertical: false)
    }

    private var skipButton: some View {
        Button(action: onSkip) {
            Text(skipLabel)
                .styleText(
                    weight: .medium,
                    color: hoveredSkipButton ? Color.S_0 : Color.T_1
                )
                .padding(.horizontal, horizontalPadding)
                .frame(height: buttonHeight)
                .background(hoveredSkipButton ? Color.T_8 : Color.clear)
                .cornerRadius(cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canSkip)
        .opacity(canSkip ? 1 : 0.3)
        .onHover { isHovered in
            hoveredSkipButton = isHovered
        }
    }

    /// Permanently removes the current transcript (history row + correction +
    /// audio file + cloud copy) via the parent's confirmation flow. Disabled
    /// when no item is on screen - same gating as Skip.
    private var deleteButton: some View {
        Button {
            TooltipManager.shared.setTooltip(nil)
            onDelete()
        } label: {
            Image(systemName: "trash")
                .styleText(
                    size: 16,
                    color: hoveredDeleteButton ? Color.red500 : Color.T_1
                )
                .frame(width: buttonHeight, alignment: .center)
                .frame(height: buttonHeight, alignment: .center)
                .background(hoveredDeleteButton ? Color.red500.opacity(0.1) : Color.clear)
                .cornerRadius(cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hoveredDeleteButton = $0 }
        .onChange(of: hoveredDeleteButton) { _, isHovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: isHovering,
                tooltipPrompt: String.localized("Delete", table: "Transcription")
            )
        }
        .disabled(!canSkip)
    }

    @ViewBuilder
    private var primaryCTAs: some View {
        if isDirty {
            saveButton
            // Requesting a fix uploads to Firebase, which only official builds configure.
            if FirebaseSetup.isAvailable {
                saveAndRequestFixButton
            }
        } else {
            switch currentStatus {
            case .unreviewed:
                markAsCorrectButton
            case .reviewed:
                statusBadge(label: String.localized("Reviewed", table: "Transcription"))
            case .corrected:
                if !hasBeenUploaded && FirebaseSetup.isAvailable {
                    requestFixButton
                }
                statusBadge(label: String.localized("Corrected", table: "Transcription"))
            }
        }
    }

    /// Shown when the current transcript is already `.reviewed` or `.corrected`.
    /// Tapping it calls `onRevert` to clear the workflow state and return the
    /// transcript to `.unreviewed`.
    private func statusBadge(label: String) -> some View {
        Button(action: onRevert) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color.lime500)
                Text(label)
                    .styleText(
                        weight: .regular,
                        color: Color.lime500
                    )
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: buttonHeight)
            .background(hoveredStatusBadge ? Color.lime500.opacity(0.30) : Color.lime500.opacity(0.10))
            .cornerRadius(cornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hoveredStatusBadge = $0 }
    }

    private var saveButton: some View {
        Button(action: onSave) {
            Text(String.localized("Save", table: "Transcription"))
                .styleText(
                    weight: .medium,
                    color: Color.black
                )
                .padding(.horizontal, horizontalPadding)
                .frame(height: buttonHeight)
                .background(hoveredSave ? Color.sky.opacity(0.7) : Color.sky)
                .cornerRadius(cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.4)
        .onHover { hoveredSave = $0 }
        .onChange(of: hoveredSave) { _, isHovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: isHovering,
                tooltipPrompt: tooltipText(
                    label: String.localized("Save", table: "Transcription"),
                    shortcut: "⌘↩"
                )
            )
        }
    }

    private var saveAndRequestFixButton: some View {
        Button(action: onSaveAndRequestFix) {
            Text(String.localized("Save & request fix", table: "Transcription"))
                .styleText(
                    weight: .medium,
                    color: Color.black
                )
                .padding(.horizontal, horizontalPadding)
                .frame(height: buttonHeight)
                .background(hoveredSaveAndRequestFix ? Color.sky.opacity(0.7) : Color.sky)
                .cornerRadius(cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.4)
        .onHover { hoveredSaveAndRequestFix = $0 }
        .onChange(of: hoveredSaveAndRequestFix) { _, isHovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: isHovering,
                tooltipPrompt: tooltipText(
                    label: String.localized("Save & request fix", table: "Transcription"),
                    shortcut: "⌘⇧↩"
                )
            )
        }
    }

    private var requestFixButton: some View {
        Button(action: onRequestFix) {
            Text(String.localized("Request fix", table: "Transcription"))
                .styleText(
                    weight: .regular
                )
                .padding(.horizontal, horizontalPadding)
                .frame(height: buttonHeight)
                .background(hoveredRequestFix ? Color.T_8 : Color.T_9)
                .cornerRadius(cornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .onHover { hoveredRequestFix = $0 }
        .onChange(of: hoveredRequestFix) { _, isHovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: isHovering,
                tooltipPrompt: tooltipText(
                    label: String.localized("Request fix", table: "Transcription"),
                    shortcut: "⌘⇧↩"
                )
            )
        }
    }

    private var markAsCorrectButton: some View {
        Button(action: onMarkAsCorrect) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color.S_0)
                Text(String.localized("Mark as correct", table: "Transcription"))
                    .styleText(
                        weight: .medium
                    )
            }
            .padding(.horizontal, horizontalPadding)
            .frame(height: buttonHeight)
            .background(hoveredMarkAsCorrect ? Color.T_8 : Color.T_9)
            .cornerRadius(cornerRadius)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.4)
        .onHover { hoveredMarkAsCorrect = $0 }
        .onChange(of: hoveredMarkAsCorrect) { _, isHovering in
            TooltipHelpers.setTooltipOnHover(
                isHovering: isHovering,
                tooltipPrompt: tooltipText(
                    label: String.localized("Mark as correct", table: "Transcription"),
                    shortcut: "⌘↩"
                )
            )
        }
    }

    /// Builds the tooltip prompt that pairs the action name with its key combo.
    /// The shortcut glyphs are language-neutral so we suffix them after the
    /// localized label rather than baking them into a localization key.
    private func tooltipText(label: String, shortcut: String) -> String {
        "\(label)  \(shortcut)"
    }
}
