// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingTranscriptionDemo.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

struct OnboardingTranscriptionDemo: View {
    // MARK: - Types

    private enum EditTarget {
        case list
        case backtracking
        case fillers
    }

    private struct SubStep {
        let title: String
        let caption: String
        let promptVerb: String
        let trySaying: String
        let editTarget: EditTarget?
        let showRawComparison: Bool
        var captionHighlights: [DemoHighlight] = []
        var trySayingHighlights: [DemoHighlight] = []
        /// Existing text around the dictation point (steps 5/6). Fed to the cleanup as preceding/following
        /// context so it merges intelligently, and shown as real text + ghost placeholder before dictation.
        var precedingText: String? = nil
        var followingText: String? = nil
    }

    // MARK: - Defaults

    @Default(.currentOnboardingStep) private var currentStep
    @Default(TranscriptionConfigKeys.shortcutType) private var shortcutType

    // MARK: - Observations

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared

    // MARK: - States

    @State private var subStepIndex: Int = 0
    @State private var cleanedResult: String = ""
    @State private var rawResult: String = ""
    @State private var showEditModal: Bool = false

    /// The "Without Smart Cleanup" comparison reveals ~400ms after the cleaned result, by design.
    @State private var rawComparisonVisible: Bool = false

    /// How many preceding chars the cleanup consumed (steps 5/6 merged-sentence reconstruction).
    @State private var deleteCount: Int = 0

    // MARK: - Private Variables

    private var shortcutSymbol: String {
        shortcutType.displayNameSymbol
    }

    private var current: SubStep {
        subSteps[subStepIndex]
    }

    private var hasResult: Bool {
        !cleanedResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isLastSubStep: Bool {
        subStepIndex == subSteps.count - 1
    }

    private var hasContext: Bool {
        current.precedingText != nil || current.followingText != nil
    }

    /// The full text shown after a context step's dictation - mirrors the real insertion exactly:
    /// preceding (minus the consumed chars) + the cleaned inserted text + following.
    private var displayedResult: String {
        guard hasContext else { return cleanedResult }
        let preceding = current.precedingText ?? ""
        let following = current.followingText ?? ""
        let keep = max(0, preceding.count - deleteCount)
        return String(preceding.prefix(keep)) + cleanedResult + following
    }

    /// The naïve "without Smart Cleanup" version for context steps - raw ASR dropped in, no merging.
    private var displayedRawComparison: String {
        guard hasContext else { return rawResult }
        let preceding = current.precedingText ?? ""
        let following = current.followingText ?? ""
        return preceding + rawResult + (following.isEmpty ? "" : " " + following)
    }

    /// Every step after the first shows off Smart Cleanup, so a fully open build
    /// (see `SmartCleanupAvailability`) only shows the first.
    private var subSteps: [SubStep] {
        SmartCleanupAvailability.isCompiledIn ? allSubSteps : Array(allSubSteps.prefix(1))
    }

    private var allSubSteps: [SubStep] {
        [
            SubStep(
                title: String.localized("Try dictating!", table: "Onboarding"),
                caption: String.localized("Press and hold %@ and speak your message.\n\nDouble-tap for hands-free mode.", table: "Onboarding", shortcutSymbol),
                promptVerb: String.localized("Try saying...", table: "Onboarding"),
                trySaying: String.localized("I'm throwing away my keyboard.", table: "Onboarding"),
                editTarget: nil,
                showRawComparison: false
            ),
            SubStep(
                title: String.localized("Dictate a list", table: "Onboarding"),
                caption: String.localized("Cloudless uses Smart Cleanup to format and polish your dictations.\n\nJust say a trigger phrase and Cloudless handles the rest.", table: "Onboarding"),
                promptVerb: String.localized("Try saying...", table: "Onboarding"),
                trySaying: String.localized("Shopping list. Number one, bananas. Number two, milk. Number three, bread.", table: "Onboarding"),
                editTarget: .list,
                showRawComparison: true,
                captionHighlights: [
                    DemoHighlight(
                        phrase: "trigger phrase",
                        color: Color.info500,
                        tooltip: String.localized("e.g. \"Number one\", \"Number two\", or \"bullet\"", table: "Onboarding")
                    )
                ],
                trySayingHighlights: ["Number one", "Number two", "Number three"].map {
                    DemoHighlight(
                        phrase: $0,
                        color: Color.T_3,
                        hoverColor: Color.info500,
                        tooltip: String.localized("Say this trigger to create a numbered lists item", table: "Onboarding")
                    )
                }
            ),
            SubStep(
                title: String.localized("Try backtracking", table: "Onboarding"),
                caption: String.localized("Cloudless uses Smart Cleanup to detect if you change your mind mid-dictation.\n\nSay things like: \"oh wait\", \"no sorry\", \"actually\", to trigger backtracking.", table: "Onboarding"),
                promptVerb: String.localized("Try saying...", table: "Onboarding"),
                trySaying: String.localized("Hi John, let's discuss this tomorrow at 8 AM, no sorry, 9 AM.", table: "Onboarding"),
                editTarget: .backtracking,
                showRawComparison: true,
                trySayingHighlights: [
                    DemoHighlight(
                        phrase: "no sorry",
                        color: Color.T_3,
                        hoverColor: Color.info500,
                        tooltip: String.localized("Say this trigger to backtrack a mistake.", table: "Onboarding")
                    )
                ]
            ),
            SubStep(
                title: String.localized("Auto-remove filler words", table: "Onboarding"),
                caption: String.localized("Cloudless uses Smart Cleanup to detect accidental filler words and remove them.", table: "Onboarding"),
                promptVerb: String.localized("Try saying...", table: "Onboarding"),
                trySaying: String.localized("I think that's, umm, correct", table: "Onboarding"),
                editTarget: .fillers,
                showRawComparison: true,
                trySayingHighlights: [
                    DemoHighlight(
                        phrase: "umm",
                        color: Color.T_3,
                        hoverColor: Color.info500,
                        tooltip: String.localized("Say this trigger to auto-remove a filler word.", table: "Onboarding")
                    )
                ]
            ),
            SubStep(
                title: String.localized("Continue a sentence...", table: "Onboarding"),
                caption: String.localized("Continue a sentence or start a new one. Cloudless adjusts punctuation and capitalization automatically.", table: "Onboarding"),
                promptVerb: String.localized("Try adding...", table: "Onboarding"),
                trySaying: String.localized("Now that our plans have changed.", table: "Onboarding"),
                editTarget: nil,
                showRawComparison: true,
                precedingText: String.localized("I'm wondering what's next.", table: "Onboarding") + " "
            ),
            SubStep(
                title: String.localized("or, insert mid-sentence", table: "Onboarding"),
                caption: String.localized("Dictate anywhere in your text, Cloudless will figure it out!", table: "Onboarding"),
                promptVerb: String.localized("Try inserting...", table: "Onboarding"),
                trySaying: String.localized("For this month.", table: "Onboarding"),
                editTarget: nil,
                showRawComparison: true,
                precedingText: String.localized("I'm wondering what's next now that our plans", table: "Onboarding") + " ",
                followingText: String.localized("have changed.", table: "Onboarding")
            )
        ]
    }

    // MARK: - Body

    var body: some View {
        OnboardingPage(
            footerConfig: .init(
                backButtonAction: { goBack() },
                showNextButton: false
            ),
            headerTitle: {
                EmptyView()
            },
            bodyContent: {
                demoBody
            },
            footerContent: {
                footer
            }
        )
        .onAppear {
            // Re-entered the demo (e.g. relaunch into a persisted `.transcriptionDemo`) before the
            // models finished? The demo needs dictation + the full Smart Cleanup stack loaded, so
            // bounce back to the Shortcut step rather than showing a non-functional demo. Skipped in
            // demo-only mode, which only ever opens once the stack is ready (and has no step to bounce
            // to, since the demo isn't in `steps` by then).
            if !ModelDownloadIndicator.demoModelsReady && !Defaults[.debugSimulateModelsDownloading]
                && !OnboardingWindowManager.shared.demoOnly {
                currentStep = OnboardingStep.transcriptionDemo.previousStep() ?? .transcriptionShortcut
                return
            }

            // Clear the last dictation's result before subscribing below: `@Published` replays its
            // current value to a new subscriber, and `insertedText` is only reset at the *start* of
            // the next dictation - so the demo would open pre-filled with the user's previous real
            // transcription (the "Try it now" / Settings → Setup path, where the process isn't fresh).
            transcriptionManager.state.insertedText = ""

            // Capture into the in-app demo only - never paste into other apps or save to history.
            transcriptionManager.isDemoCaptureMode = true
            syncDemoContext()
            AnalyticsManager.Transcription.Onboarding.demoShown()
            if transcriptionManager.needsInitialization {
                transcriptionManager.initializeModelsInBackground()
            }
        }
        .onDisappear {
            transcriptionManager.resetDemoCaptureState()
            if transcriptionManager.isTranscribing {
                transcriptionManager.cancelTranscription()
            }
        }
        .onReceive(transcriptionManager.state.$insertedText) { cleaned in
            // Subscribe to the published value directly. `state` is a *nested* ObservableObject, so a
            // plain `.onChange` on it doesn't reliably fire (the view only observes the manager).
            // The replayed value is empty (cleared in `.onAppear`), so the guard below absorbs it.
            // The pipeline finished - pull both the cleaned result and the raw (no-cleanup) text.
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            cleanedResult = cleaned
            rawResult = transcriptionManager.state.rawASRText
            deleteCount = transcriptionManager.state.deletePrecedingChars

            // Reveal the "Without Smart Cleanup" comparison ~400ms later, so the user's eyes land on the
            // cleaned result first, then get drawn to the raw version.
            rawComparisonVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard hasResult else { return } // user may have undone / advanced in the meantime
                withAnimation(.easeInOut(duration: 0.2)) {
                    rawComparisonVisible = true
                }
            }
        }
        .onChange(of: subStepIndex) { _, _ in
            syncDemoContext()
        }
    }

    // MARK: - Child Components: Demo Body

    private var demoBody: some View {
        HStack(alignment: .top, spacing: 33) {
            leftColumn
            resultCard
        }
        .padding(.vertical, 18)
        .padding(.leading, 36)
        .padding(.trailing, 27)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            paginator

            VStack(alignment: .leading, spacing: 11) {
                Text(current.title)
                    .styleText(
                        fontFamily: .libreBaskerville,
                        size: 28,
                        weight: .regular
                    )

                DemoRichText(
                    text: current.caption,
                    highlights: current.captionHighlights,
                    size: 17,
                    color: Color.S_1
                )
            }

            if current.editTarget != nil {
                editTriggersButton
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paginator: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(0..<subSteps.count, id: \.self) { index in
                Capsule()
                    .fill(index <= subStepIndex ? Color.sky : Color.T_8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 4)
                    .addAnimation(dependency: subStepIndex)
            }
        }
        .frame(width: 193)
    }

    // MARK: - Child Components: Edit Triggers Button

    private var editTriggersButton: some View {
        TextButton(
            text: editButtonText,
            colorConfig: .init(
                text: Color.S_0,
                background: Color.T_8
            ),
            sizeConfig: .init(
                horizontalPadding: 6,
                height: 28,
                cornerRadius: 8
            )
        ) {
            showEditModal = true
        }
        .popover(isPresented: $showEditModal, arrowEdge: .bottom) {
            editModal
                .background(Color.surface3)
        }
    }

    private var editButtonText: String {
        switch current.editTarget {
        case .list?:
            return String.localized("Edit list triggers", table: "Onboarding")
        case .backtracking?:
            return String.localized("Edit backtracking triggers", table: "Onboarding")
        case .fillers?:
            return String.localized("Edit filler words", table: "Onboarding")
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var editModal: some View {
        switch current.editTarget {
        case .list?:
            // Formatting triggers are keyed by their *replacement* string (see PunctuationConstants /
            // SmartFormattingDefaults.invertFormattingTriggers), so the numbered-list marker is "\n1. ",
            // NOT "1.". Passing the wrong key yields an empty modal.
            SmartFormattingEditModal(category: .formatting, symbol: "\n1. ", isPresented: $showEditModal)
        case .backtracking?:
            BacktrackingEditModal(isPresented: $showEditModal)
        case .fillers?:
            SmartFormattingEditModal(category: .fillers, symbol: "", isPresented: $showEditModal)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Child Components: Result Card

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 16) {
                if hasResult {
                    Text(displayedResult)
                        .styleText(size: 17, weight: .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if current.showRawComparison && rawComparisonVisible {
                        rawComparison
                            .transition(.opacity)
                    }
                } else {
                    promptPill
                    if hasContext {
                        contextPlaceholderText
                    } else {
                        DemoRichText(
                            text: current.trySaying,
                            highlights: current.trySayingHighlights,
                            size: 17,
                            color: Color.T_3
                        )
                    }
                    Spacer()
                }
            }
            
            AppIconButton(
                systemName: "arrow.uturn.backward",
                disabled: !hasResult,
                tooltip: String.localized("Reset", table: "Onboarding")
            ) {
                undoResult()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.special1)
        .addBorder(
            cornerRadius: 22,
            stroke: Color.T_7
        )
    }

    private var promptPill: some View {
        Text(current.promptVerb)
            .styleText(weight: .regular, color: Color.black)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.sky)
            .cornerRadius(999)
    }

    /// Steps 5/6 placeholder: existing text (real) + the ghost dictation placeholder + trailing existing text.
    private var contextPlaceholderText: some View {
        let preceding = current.precedingText ?? ""
        let following = current.followingText ?? ""
        return (
            Text(preceding).foregroundColor(Color.S_0)
            + Text(current.trySaying).foregroundColor(Color.T_3)
            + Text(following.isEmpty ? "" : " " + following).foregroundColor(Color.S_0)
        )
        .font(FontFamily.system.font(size: 17))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rawComparison: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                subStepIndex < 3
                    ? String.localized("Without Smart Cleanup (e.g. Apple Dictation)", table: "Onboarding")
                    : String.localized("Without Smart Cleanup", table: "Onboarding")
            )
                .styleText(size: 12, weight: .regular, color: Color.T_1)

            Text(displayedRawComparison)
                .styleText(size: 15, weight: .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.T_10)
        .cornerRadius(14)
    }

    // MARK: - Child Components: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Spacer()

            if !hasResult {
                Button {
                    skipDemo()
                } label: {
                    Text(String.localized("Skip", table: "Onboarding"))
                        .styleText(size: 13, weight: .medium, color: Color.T_2)
                }
                .buttonStyle(PlainButtonStyle())
            }

            TextButton(
                type: .primary,
                text: String.localized("Next", table: "Onboarding"),
                statusConfig: .init(disabled: !hasResult)
            ) {
                goNext()
            }
        }
    }

    // MARK: - Private Functions: Navigation

    private func goNext() {
        if isLastSubStep {
            completeDemo()
        } else {
            advanceSubStep()
        }
    }

    private func advanceSubStep() {
        cancelActiveDictation()
        subStepIndex += 1
        resetSubStepResult()
    }

    private func goBack() {
        cancelActiveDictation()
        if subStepIndex > 0 {
            subStepIndex -= 1
            resetSubStepResult()
        } else if OnboardingWindowManager.shared.demoOnly {
            // Standalone demo: backing out of the first sub-step exits the demo.
            OnboardingWindowManager.shared.closeWindow()
        } else if let previous = currentStep?.previousStep() {
            currentStep = previous
        }
    }

    /// Finished the last sub-step with a real dictation result.
    private func completeDemo() {
        AnalyticsManager.Transcription.Onboarding.demoCompleted(
            textLength: cleanedResult.count,
            shortcutType: shortcutType.rawValue
        )
        finishDemo()
    }

    /// Bailed out via the Skip button - distinct analytics event so skips don't inflate the
    /// completion metric, but the same exit path (skipping still marks the demo done so the user
    /// isn't re-prompted from Home).
    private func skipDemo() {
        AnalyticsManager.Transcription.Onboarding.demoSkipped(
            subStepIndex: subStepIndex,
            source: "onboarding_demo"
        )
        finishDemo()
    }

    /// Shared exit path for completing or skipping the demo.
    private func finishDemo() {
        cancelActiveDictation()
        Defaults[.dictationDemoCompleted] = true
        if OnboardingWindowManager.shared.demoOnly {
            // Standalone demo: nothing to advance to - finishing closes the window.
            OnboardingWindowManager.shared.closeWindow()
        } else if let next = currentStep?.nextStep() {
            currentStep = next
        }
    }

    private func resetSubStepResult() {
        cleanedResult = ""
        rawResult = ""
        showEditModal = false
        rawComparisonVisible = false
    }

    /// Undo button - bring the current sub-step back to its placeholder state.
    private func undoResult() {
        cancelActiveDictation()
        cleanedResult = ""
        rawResult = ""
        rawComparisonVisible = false
    }

    /// Feed the current sub-step's preceding/following context to the cleanup pipeline (steps 5/6).
    private func syncDemoContext() {
        transcriptionManager.demoPrecedingText = current.precedingText
        transcriptionManager.demoFollowingText = current.followingText
    }

    private func cancelActiveDictation() {
        if transcriptionManager.isTranscribing {
            transcriptionManager.cancelTranscription()
        }
    }
}

// MARK: - Demo Rich Text (inline highlighted, hoverable phrases)

/// A highlighted phrase within demo copy: dotted-underlined, optionally recolored, with a hover tooltip.
private struct DemoHighlight {
    let phrase: String
    var color: Color? = nil
    /// Color shown while hovered (e.g. result-card triggers go T_3 → info500). Nil = no change on hover.
    var hoverColor: Color? = nil
    var tooltip: String? = nil
}

/// Renders demo copy with inline highlighted phrases. SwiftUI can't hover a substring of a `Text`, so
/// each highlighted phrase is laid out as its own view in a `FlowLayout`. Non-highlighted paragraphs
/// render as a native `Text` to preserve kerning; only paragraphs containing a highlight flow word-by-word.
private struct DemoRichText: View {
    let text: String
    let highlights: [DemoHighlight]
    var size: CGFloat
    var color: Color
    var paragraphSpacing: CGFloat = 17
    var wordSpacing: CGFloat = 4

    private enum Token {
        case word(String)
        /// `suffix` is trailing punctuation (no leading space) rendered un-underlined so it stays snug.
        case highlight(phrase: String, suffix: String, highlight: DemoHighlight)
    }

    var body: some View {
        if highlights.isEmpty {
            Text(text)
                .styleText(size: size, weight: .regular, color: color)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: paragraphSpacing) {
                ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                    paragraphView(paragraph)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: String) -> some View {
        let active = highlights.filter { paragraph.contains($0.phrase) }
        if active.isEmpty {
            Text(paragraph)
                .styleText(size: size, weight: .regular, color: color)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            FlowLayout(spacing: wordSpacing) {
                ForEach(Array(tokens(for: paragraph, highlights: active).enumerated()), id: \.offset) { _, token in
                    tokenView(token)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func tokenView(_ token: Token) -> some View {
        switch token {
        case .word(let word):
            Text(word)
                .styleText(size: size, weight: .regular, color: color)
        case let .highlight(phrase, suffix, highlight):
            HighlightToken(
                phrase: phrase,
                suffix: suffix,
                highlight: highlight,
                baseColor: color,
                size: size
            )
        }
    }

    private func tokens(for paragraph: String, highlights: [DemoHighlight]) -> [Token] {
        var ranges: [(range: Range<String.Index>, highlight: DemoHighlight)] = []
        for highlight in highlights {
            var searchStart = paragraph.startIndex
            while searchStart < paragraph.endIndex,
                  let found = paragraph.range(of: highlight.phrase, range: searchStart..<paragraph.endIndex) {
                ranges.append((found, highlight))
                searchStart = found.upperBound
            }
        }
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }

        var tokens: [Token] = []
        var cursor = paragraph.startIndex

        for entry in ranges {
            guard entry.range.lowerBound >= cursor else { continue } // skip overlaps

            if cursor < entry.range.lowerBound {
                tokens.append(contentsOf: words(in: String(paragraph[cursor..<entry.range.lowerBound])))
            }

            // Absorb trailing punctuation (no leading space) so e.g. "Number one," stays together.
            var suffixEnd = entry.range.upperBound
            while suffixEnd < paragraph.endIndex, !paragraph[suffixEnd].isWhitespace {
                suffixEnd = paragraph.index(after: suffixEnd)
            }

            tokens.append(.highlight(
                phrase: String(paragraph[entry.range]),
                suffix: String(paragraph[entry.range.upperBound..<suffixEnd]),
                highlight: entry.highlight
            ))
            cursor = suffixEnd
        }

        if cursor < paragraph.endIndex {
            tokens.append(contentsOf: words(in: String(paragraph[cursor..<paragraph.endIndex])))
        }

        return tokens
    }

    private func words(in segment: String) -> [Token] {
        segment.split(separator: " ", omittingEmptySubsequences: true).map { .word(String($0)) }
    }
}

/// A single highlighted phrase: dotted-underlined, recolors on hover (e.g. T_3 → info500), with a tooltip.
/// Its own `@State` so each phrase hovers independently. Trailing punctuation (`suffix`) stays un-underlined.
private struct HighlightToken: View {
    let phrase: String
    let suffix: String
    let highlight: DemoHighlight
    let baseColor: Color
    let size: CGFloat

    @State private var isHovered = false

    private var displayColor: Color {
        if isHovered, let hoverColor = highlight.hoverColor {
            return hoverColor
        }
        return highlight.color ?? baseColor
    }

    var body: some View {
        (Text(phrase).underline(true, pattern: .dot, color: displayColor) + Text(suffix))
            .font(FontFamily.system.font(size: size))
            .fontWeight(.regular)
            .foregroundColor(displayColor)
            .addAnimation(dependency: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    TooltipHelpers.setTooltipOnHover(isHovering: hovering, tooltipPrompt: highlight.tooltip)
                } else {
                    TooltipManager.shared.setTooltip(nil)
                }
            }
    }
}
