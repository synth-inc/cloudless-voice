// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptListItem.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import AppKit
import SwiftUI

/// A single transcript row in the new transcript list.
///
/// Idle state shows the diff text plus a tools row (timestamp, app icon,
/// hover-only More/Copy actions, and a "Review & teach Onit" CTA). Tapping the
/// CTA notifies the parent so it can present the review modal.
struct TranscriptListItem: View {
    // MARK: - Properties

    let historyItem: TranscriptionHistory
    let showEdits: Bool
    /// When `true`, the timestamp label includes the date in addition to the
    /// time. Use when the parent list does NOT group rows under date section
    /// headers (e.g. sort by audio duration or app name), so rows from
    /// different days remain distinguishable.
    let showFullDate: Bool
    let onRefresh: (TranscriptionHistory) -> Void
    let onDelete: (TranscriptionHistory) -> Void
    let onReviewRequest: (TranscriptionHistory) -> Void

    init(
        historyItem: TranscriptionHistory,
        showEdits: Bool,
        showFullDate: Bool = false,
        onRefresh: @escaping (TranscriptionHistory) -> Void,
        onDelete: @escaping (TranscriptionHistory) -> Void,
        onReviewRequest: @escaping (TranscriptionHistory) -> Void
    ) {
        self.historyItem = historyItem
        self.showEdits = showEdits
        self.showFullDate = showFullDate
        self.onRefresh = onRefresh
        self.onDelete = onDelete
        self.onReviewRequest = onReviewRequest
    }

    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false

    @State private var showDeleteConfirmation: Bool = false
    @State private var deleteFailedErrorMessage: String? = nil
    @State private var showMorePopover: Bool = false

    @State private var isReTranscribing: Bool = false
    @State private var reTranscribeFailedMessage: String? = nil

    @State private var downloadAudioFailedMessage: String? = nil

    @State private var isExpanded: Bool = false
    @State private var isTextTruncatable: Bool = false
    @State private var availableTextWidth: CGFloat = 0

    /// Matches Figma's `max-h-[144px]` on the transcript text (8 lines × 18pt).
    private let collapsedLineLimit: Int = 8

    /// Recompute whether the displayed transcript would overflow
    /// `collapsedLineLimit` lines at the current available width. Uses
    /// `NSLayoutManager` so it matches the real text-renderer's wrapping.
    private func recomputeTruncation() {
        guard availableTextWidth > 0 else {
            isTextTruncatable = false
            return
        }
        isTextTruncatable = truncationBlocks.contains { block in
            block.text.numberOfRenderedLines(
                font: NSFont.systemFont(ofSize: block.size, weight: .regular),
                width: availableTextWidth
            ) > collapsedLineLimit
        }
    }

    /// The text blocks `transcriptText` limits to `collapsedLineLimit` lines, with the
    /// font size each is drawn at. A rewritten row has two: the recognizer text (as
    /// corrected) and what was pasted.
    private var truncationBlocks: [(text: String, size: CGFloat)] {
        if let source = historyItem.rewriteSourceText {
            return [
                (historyItem.correctedTranscription ?? source, 13),
                (historyItem.cleanedTranscription, 14),
            ]
        }
        return [(displayText, 14)]
    }

    // MARK: - Private Variables

    private let actionIconSize: CGFloat = 14
    private let actionButtonSize: CGFloat = 28
    private let actionCornerRadius: CGFloat = 8

    /// The text the user currently sees: the manual correction takes precedence
    /// over the smart-cleanup output.
    private var displayText: String {
        historyItem.correctedTranscription ?? historyItem.cleanedTranscription
    }

    private var appIcon: NSImage? {
        guard let bundleId = historyItem.appBundleId else { return nil }
        return NSWorkspace.shared.icon(forBundleIdentifier: bundleId)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Localized "Apr 28 at 3:42 PM" style format. Used when the parent list
    /// does not group rows under date section headers and the row therefore
    /// needs to carry the date on its own.
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
        return formatter
    }()

    private var timestampLabel: String {
        let formatter = showFullDate ? Self.dateTimeFormatter : Self.timeFormatter
        return formatter.string(from: historyItem.timestamp)
    }
    
    struct MoreOption {
        let text: String
        var isDestructive: Bool = false
        var disabled: Bool = false
        var action: () -> Void
    }
    
    private var moreOptions: [MoreOption] {
        var options: [MoreOption] = []
        
        #if DEBUG
        options.append(.init(
            text: String.localized("Re-transcribe", table: "Transcription"),
            action: {
                guard !isReTranscribing else { return }
                isReTranscribing = true
                reTranscribeFailedMessage = nil

                Task {
                    do {
                        if let updated = try await TranscriptionManager.shared.reTranscribe(history: historyItem) {
                            onRefresh(updated)
                        }
                    } catch {
                        reTranscribeFailedMessage = error.localizedDescription
                    }
                    isReTranscribing = false
                }
            }
        ))
        #endif
        
        options.append(contentsOf: [
            .init(
                text: String.localized("Copy raw transcript", table: "Transcription"),
                action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.declareTypes([.string], owner: nil)
                    pasteboard.setString(historyItem.rawTranscription, forType: .string)
                }
            ),
            /// Disabled when the audio file is missing on disk:
            ///     * Older rows outliving their audio if the user manually cleared Application Support.
            ///     * Save failed.
            .init(
                text: String.localized("Download audio file", table: "Transcription"),
                disabled: TranscriptionHistoryManager.shared.audioFileURL(for: historyItem) == nil,
                action: downloadAudioFile
            ),
            .init(
                text: String.localized("Delete", table: "Transcription"),
                isDestructive: true,
                action: {
                    showDeleteConfirmation = true
                }
            )
        ])
        
        return options
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    transcriptText
                    .background(
                        // Capture the actual text-rendering width so the
                        // truncation check matches what NSLayoutManager wraps to.
                        // Ignore tiny width changes (~16pt scrollbar appearance
                        // / disappearance) - when those flip `isTextTruncatable`
                        // they change row height → total content height →
                        // scrollbar visibility → width again, producing an
                        // infinite render loop that pegs CPU at 100%. Only
                        // real container resizes (>30pt) warrant re-evaluating.
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    availableTextWidth = proxy.size.width
                                    recomputeTruncation()
                                }
                                .onChange(of: proxy.size.width) { _, new in
                                    guard abs(new - availableTextWidth) > 30 else { return }
                                    availableTextWidth = new
                                    recomputeTruncation()
                                }
                        }
                    )

                    if isTextTruncatable {
                        seeMoreLessButton
                    }
                }
                .onChange(of: truncationBlocks.map(\.text)) { _, _ in recomputeTruncation() }

                toolsRow
            }
            .opacity(isReTranscribing ? 0.4 : 1)

            if isReTranscribing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .addButtonEffects(
            hoverBackground: Color.T_10,
            cornerRadius: 16,
            allowsHitTesting: !isReTranscribing,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            onReviewRequest(historyItem)
        }
        .alert(
            String.localized("Delete Transcript?", table: "Transcription"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(String.localized("No, Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Delete", table: "Transcription"), role: .destructive) {
                deleteTranscription()
            }
        } message: {
            Text(String.localized("Deleting a transcript is permanent. Are you sure?", table: "Transcription"))
        }
        .alert(
            String.localized("Delete failed", table: "Transcription"),
            isPresented: .init(
                get: { deleteFailedErrorMessage != nil },
                set: { if !$0 { deleteFailedErrorMessage = nil } }
            )
        ) {
            Button(String.localized("Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Try again", table: "Transcription"), role: .destructive) {
                deleteTranscription()
            }
        } message: {
            if let errorMessage = deleteFailedErrorMessage {
                Text(errorMessage)
            }
        }
        .alert(
            String.localized("Re-transcribe failed", table: "Transcription"),
            isPresented: .init(
                get: { reTranscribeFailedMessage != nil },
                set: { if !$0 { reTranscribeFailedMessage = nil } }
            )
        ) {
            Button(String.localized("OK", table: "Transcription"), role: .cancel) {}
        } message: {
            if let message = reTranscribeFailedMessage {
                Text(message)
            }
        }
        .alert(
            String.localized("Could not save audio file", table: "Transcription"),
            isPresented: .init(
                get: { downloadAudioFailedMessage != nil },
                set: { if !$0 { downloadAudioFailedMessage = nil } }
            )
        ) {
            Button(String.localized("OK", table: "Transcription"), role: .cancel) {}
        } message: {
            if let message = downloadAudioFailedMessage {
                Text(message)
            }
        }
        .id(localization.currentLanguage)
    }

    // MARK: - Tools Row (idle state)

    /// Toggle between truncated (8 lines) and full-height transcript display.
    /// Only shown when the transcript actually overflows the collapsed limit.
    private var seeMoreLessButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded
                 ? String.localized("See less", table: "Transcription")
                 : String.localized("See more", table: "Transcription"))
                .styleText(
                    size: 12,
                    weight: .medium,
                    color: Color.info500
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var toolsRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(timestampLabel)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: Color.T_2
                )
                .animation(.easeInOut(duration: 0.12), value: isHovered)

            if let sourceFilename = historyItem.sourceFilename {
                fileBadge(sourceFilename)
            }

            // A rewrite announces itself in the text ("Rewritten by"), so the badge is
            // Smart Cleanup's alone. A row rewritten before v14 has no source to show
            // that rule with, so it keeps a badge.
            if let route = historyItem.cleanupRoute,
               route != .yourModel || historyItem.rewriteSourceText == nil {
                cleanupBadge(route)
            }

            appIconView
                .opacity(isHovered ? 1 : 0)

            Spacer()

            // Always render to preserve the popover anchor; visibility flips on hover.
            // Without this, hovering away from the row removes the more-button view and
            // the popover collapses on any pointer movement.
            HStack(spacing: 4) {
                moreButton
                copyButton
            }
            .opacity(secondaryActionsVisible ? 1 : 0)
            .allowsHitTesting(secondaryActionsVisible)

            statusTrailingView
        }
        .frame(height: 28)
    }

    private var secondaryActionsVisible: Bool {
        isHovered || showMorePopover
    }

    /// The transcript. A rewritten row (Settings > Rewrite) shows what the
    /// recognizer produced first, smaller and in the secondary colour with the
    /// cleanup diff, then a thin "Rewritten by" rule, then what was pasted. A word
    /// diff of a rewrite is noise (every word changes when the model translates
    /// or rephrases), so the rewrite itself is never diffed.
    @ViewBuilder
    private var transcriptText: some View {
        if let source = historyItem.rewriteSourceText {
            VStack(alignment: .leading, spacing: 10) {
                TranscriptDiffText(
                    rawText: historyItem.rawTranscription,
                    cleanedText: source,
                    correctedText: historyItem.correctedTranscription,
                    showEdits: showEdits,
                    lineLimit: isExpanded ? nil : collapsedLineLimit,
                    size: 13,
                    color: Color.T_2
                )
                rewriteRule
                Text(historyItem.cleanedTranscription)
                    .styleText(weight: .regular)
                    .lineLimit(isExpanded ? nil : collapsedLineLimit)
            }
        } else {
            TranscriptDiffText(
                rawText: historyItem.rawTranscription,
                cleanedText: historyItem.cleanedTranscription,
                correctedText: historyItem.correctedTranscription,
                showEdits: showEdits,
                lineLimit: isExpanded ? nil : collapsedLineLimit
            )
        }
    }

    private var rewriteRule: some View {
        let label = if let model = historyItem.rewriteModel, !model.isEmpty {
            String.localized("Rewritten by %@", table: "Transcription", model)
        } else {
            String.localized("Rewritten", table: "Transcription")
        }
        return HStack(alignment: .center, spacing: 8) {
            DividerHorizontal()
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color.T_2)
                Text(label)
                    .styleText(size: 11, weight: .medium, color: Color.T_2)
                    .lineLimit(1)
            }
            .fixedSize()
            DividerHorizontal()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// Trailing item in the tools row whose visual depends on the workflow state.
    /// - unreviewed → "Review & teach Onit" CTA pill
    /// - reviewed   → small green checkmark badge (no label)
    /// - corrected  → green "Corrected" pill (icon + label)
    @ViewBuilder
    private var statusTrailingView: some View {
        switch historyItem.reviewStatus {
        case .unreviewed:
            reviewButton
        case .reviewed:
            reviewedBadge
        case .corrected:
            correctedBadge
        }
    }

    private var reviewedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(Color.lime500)
            .padding(.horizontal, 6)
            .frame(minWidth: 28, minHeight: 28, alignment: .center)
            .background(Color.lime500.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var correctedBadge: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.lime500)

            Text(String.localized("Corrected", table: "Transcription"))
                .styleText(
                    weight: .regular,
                    color: Color.lime500
                )
        }
        .padding(.horizontal, 6)
        .frame(height: 28, alignment: .center)
        .background(Color.lime500.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Marks a transcript made from an audio file rather than dictated. Always visible,
    /// unlike the hover-only app icon. Same geometry as `correctedBadge`; truncates
    /// before the trailing actions do.
    /// "Cleaned up": Smart Cleanup changed the text. "Rewritten" only marks a row
    /// rewritten before the source was stored; newer rewrites show it in `transcriptText`.
    private func cleanupBadge(_ route: TranscriptionHistory.CleanupRoute) -> some View {
        let label = switch route {
        case .smartCleanup, .smartCleanupAndYourModel: String.localized("Cleaned up", table: "Transcription")
        case .yourModel: String.localized("Rewritten", table: "Transcription")
        }

        return HStack(alignment: .center, spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Color.T_2)

            Text(label)
                .styleText(size: 12, weight: .regular, color: Color.T_2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: actionButtonSize, alignment: .center)
        .background(Color.T_9)
        .clipShape(RoundedRectangle(cornerRadius: actionCornerRadius))
        .layoutPriority(-1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func fileBadge(_ filename: String) -> some View {
        let label = String.localized("Transcribed from an audio file", table: "Transcription")

        return HStack(alignment: .center, spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.T_2)

            Text(filename)
                .styleText(weight: .regular, color: Color.T_2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(height: actionButtonSize, alignment: .center)
        .background(Color.T_9)
        .clipShape(RoundedRectangle(cornerRadius: actionCornerRadius))
        .layoutPriority(-1)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(filename)
    }

    @ViewBuilder
    private var appIconView: some View {
        if let appIcon = self.appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 18, height: 18)
                .cornerRadius(6)
        }
    }

    private var moreButton: some View {
        IconButton(
            systemName: "ellipsis",
            iconSize: actionIconSize,
            buttonSize: actionButtonSize,
            cornerRadius: actionCornerRadius,
            tooltipPrompt: String.localized("More options", table: "App")
        ) {
            showMorePopover = true
        }
        .popover(isPresented: $showMorePopover, arrowEdge: .bottom) {
            PopoverButtonsView(
                items: moreOptions.map { moreOption in
                    PopoverButtonsView.ButtonItem(
                        text: moreOption.text,
                        colorConfig: PopoverButtonsView.buttonColorConfig(
                            text: moreOption.isDestructive ? Color.red500 : Color.S_0,
                            hoverBackground: moreOption.isDestructive ? Color.red500.opacity(0.1) : Color.T_9
                        ),
                        statusConfig: PopoverButtonsView.buttonStatusConfig(
                            disabled: moreOption.disabled
                        )
                    ) {
                        showMorePopover = false
                        moreOption.action()
                    }
                }
            )
        }
    }

    private var copyButton: some View {
        CopyButton(
            text: historyItem.pastedText,
            iconSize: actionIconSize,
            buttonSize: actionButtonSize,
            inactiveColor: Color.T_3,
            cornerRadius: actionCornerRadius
        )
    }

    private var reviewButton: some View {
        TextButton(
            text: String.localized("Review & teach Cloudless", table: "Transcription"),
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                textWeight: .regular,
                horizontalPadding: 6,
                height: actionButtonSize,
                cornerRadius: actionCornerRadius
            )
        ) {
            onReviewRequest(historyItem)
        }
    }

    // MARK: - Actions

    private func deleteTranscription() {
        deleteFailedErrorMessage = nil
        Task {
            do {
                if let id = historyItem.id {
                    try await TranscriptionHistoryManager.shared.delete(id: id)
                    onDelete(historyItem)
                }
            } catch {
                deleteFailedErrorMessage = error.localizedDescription
            }
        }
    }

    /// Presents an `NSSavePanel` so the user picks where to copy the original
    /// recording. The default filename embeds a sortable timestamp so multiple
    /// downloads from the same session don't trample each other in the
    /// destination directory.
    private func downloadAudioFile() {
        guard let sourceURL = TranscriptionHistoryManager.shared.audioFileURL(for: historyItem) else {
            downloadAudioFailedMessage = String.localized(
                "The original audio recording is no longer available on this device.",
                table: "Transcription"
            )
            return
        }

        let timestampSuffix: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return formatter.string(from: historyItem.timestamp)
        }()

        let panel = NSSavePanel()
        panel.title = String.localized("Save audio file", table: "Transcription")
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "onit_dictation_\(timestampSuffix).wav"
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else { return }

        do {
            // Overwrite a pre-existing file at the chosen path. NSSavePanel
            // already prompts the user for confirmation in that case, so by
            // the time we're here they've explicitly accepted the replace.
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            downloadAudioFailedMessage = error.localizedDescription
        }
    }
}
