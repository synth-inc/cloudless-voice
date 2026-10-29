// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictionaryCalibrationSheet.swift
//  Onit
//
//  Multi-step calibration sheet for a newly added custom dictionary term.
//
//  Flow:
//    1. Confirm pronunciation (SherpaTokenizer preview, optional correction)
//    2. Sherpa KWS scan of transcription history
//    3. Accept/reject each match (positives feed proxy selection)
//    4. Auto-select proxy, user confirms - or type sentences if no history
//    5. Done
//

import SwiftUI

struct DictionaryCalibrationSheet: View {

    let term: CustomDictionaryTerm
    let onDismiss: () -> Void
    /// Called once calibration succeeds (after the user confirms a category).
    /// The dictionary page uses this to surface a "term added" toast.
    var onComplete: ((CustomDictionaryTerm) -> Void)? = nil

    @ObservedObject private var manager = CustomDictionaryCalibrationManager.shared
    @ObservedObject private var audioPlayer = AudioPlaybackService.shared
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    enum Step {
        case confirmPronunciation
        case scanning
        case reviewHistory
        case typeSentences
        case loadingCategories
        case chooseCategory(categories: [String], candidates: [String])
        case confirmProxy(candidates: [String])  // legacy, unused
        case done
    }

    @State private var step: Step = .scanning
    @State private var playingCandidateID: UUID?
    @State private var positives: [CalibrationExample] = []
    @State private var negatives: [CalibrationExample] = []
    @State private var currentCandidateIdx: Int = 0
    @State private var typedSentences: [String] = ["", "", ""]
    @State private var typedSentenceText: String = ""
    @State private var selectedProxy: String = ""
    @State private var customProxy: String = ""
    @State private var useCustomProxy = false
    @State private var selectedCategory: String? = nil
    @State private var customCategoryText: String = ""
    @State private var useCustomCategory: Bool = false
    @State private var isWorking = false
    @State private var correctionText: String = ""
    @State private var showCorrectionField: Bool = false

    private let historyPositiveTarget = 3
    private let historyCandidateCap = 10

    // MARK: - Body

    var body: some View {
        Group {
            switch step {
            case .scanning:
                scanningView
            case .reviewHistory:
                reviewHistoryView(candidates: manager.historyCandidates)
            case .typeSentences:
                useInSentenceView
            case .loadingCategories:
                loadingCategoriesView
            case .chooseCategory(let categories, let candidates):
                chooseCategoryView(categories: categories, candidates: candidates)
            case .confirmPronunciation, .confirmProxy, .done:
                legacyBody
            }
        }
        .onAppear {
            AnalyticsManager.AppDictionary.calibrationStarted(termId: term.id.uuidString)
            // Step 1 (the add-term sheet) hands off here. Kick off the
            // history scan immediately so the user lands on Step 2's
            // "loading from history" state without an extra click.
            startScan()
        }
        .onChange(of: audioPlayer.isPlaying) { isPlaying in
            if !isPlaying { playingCandidateID = nil }
        }
        .onChange(of: manager.isScanning) { scanning in
            // When the scan completes, jump to the appropriate workspace:
            // big-modal review if we have candidates, big-modal type-sentences if not.
            if !scanning, case .scanning = step {
                if manager.historyCandidates.isEmpty {
                    step = .typeSentences
                } else {
                    step = .reviewHistory
                    currentCandidateIdx = 0
                }
            }
        }
    }

    /// Legacy 400-wide layout used by steps not yet ported to the new design.
    @ViewBuilder
    private var legacyBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch step {
            case .confirmPronunciation:
                confirmPronunciationView
            case .confirmProxy(let candidates):
                confirmProxyView(candidates: candidates)
            case .done:
                doneView
            case .scanning, .reviewHistory, .typeSentences,
                 .loadingCategories, .chooseCategory:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: - Step 2 - small modal "loading from history"

    private var scanningView: some View {
        VStack(spacing: 0) {
            // Modal top - title + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a term")
                    .styleText(size: 15, weight: .medium, color: Color.S_0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Add a word you want Cloudless to recognize.")
                    .styleText(size: 14, weight: .regular, color: Color.T_1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            // Content - disabled-looking term field + scan-progress helper
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(term.text)
                        .styleText(size: 14, weight: .regular, color: Color.S_0)
                        .opacity(0.4)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Color.special1)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .addBorder(cornerRadius: 12, stroke: Color.T_8)
                .opacity(0.8)

                HStack(alignment: .top, spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(manager.historyCandidates.count) transcript matches")
                            .styleText(size: 14, weight: .regular, color: Color.T_1)
                        Text("Searching locally, please wait\u{2026}")
                            .styleText(size: 14, weight: .regular, color: Color.T_1)
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Toolbar
            HStack(spacing: 8) {
                Spacer()

                Button(action: cancelFlow) {
                    Text("Cancel")
                        .styleText(size: 14, weight: .medium, color: Color.S_0)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.T_9)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                // Add button is visible-but-disabled during scan; the term is
                // already added - this just signals "scan in progress".
                Text("Add")
                    .styleText(size: 14, weight: .medium, color: Color.black)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.sky)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .opacity(0.3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.T_7)
                    .frame(height: 1)
            }
        }
        .frame(width: 345)
    }

    private func cancelFlow() {
        dismiss()
        onDismiss()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Configure \u{201C}\(term.text)\u{201D}")
                .styleText(size: 17, weight: .semibold)
            Text("Help Cloudless recognise this word more accurately.")
                .styleText(size: 12, weight: .regular, color: Color.T_2)
        }
    }

    // MARK: - Processing

    private func processingView(label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .styleText(size: 13, weight: .regular, color: Color.T_2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    // MARK: - Confirm Pronunciation

    private var confirmPronunciationView: some View {
        let primaryKeyword = SherpaTokenizer.load()?.keywordString(for: term.text)
        let primaryDisplay = primaryKeyword.map { tokenDisplay($0) }

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("This is how Cloudless will listen for \u{201C}\(term.text)\u{201D}:")
                    .styleText(size: 13, weight: .regular, color: Color.T_1)
            }

            // Primary pronunciation pill
            if let display = primaryDisplay {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .styleText(size: 12, color: Color.blue)
                    Text(display)
                        .styleText(size: 15, weight: .semibold, color: Color.T_1)
                        .tracking(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.T_9)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Could not determine pronunciation.")
                    .styleText(size: 12, weight: .regular, color: Color.orange)
            }

            // Correction flow
            if showCorrectionField {
                correctionFieldView
            } else {
                Button("That doesn\u{2019}t look right") {
                    showCorrectionField = true
                }
                .styleText(size: 12, weight: .regular, color: Color.T_2)
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextButton(
                    type: .primary,
                    text: "Looks right \u{2014} scan history",
                    sizeConfig: .init(text: 13, horizontalPadding: 14, height: 32, cornerRadius: 8),
                    action: { startScan() }
                )

                Button("Skip") {
                    dismiss()
                    onDismiss()
                }
                .styleText(size: 13, weight: .regular, color: Color.T_2)
                .buttonStyle(.plain)
            }
        }
    }

    private var correctionFieldView: some View {
        let correctionKeyword = correctionText.isEmpty
            ? nil
            : SherpaTokenizer.load()?.keywordString(for: correctionText)
        let correctionDisplay = correctionKeyword.map { tokenDisplay($0) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Type a phonetic spelling (e.g. \u{201C}audit\u{201D}, \u{201C}own it\u{201D}):")
                .styleText(size: 12, weight: .regular, color: Color.T_2)

            HStack(spacing: 8) {
                TextField("e.g. own it, audit\u{2026}", text: $correctionText)
                    .textFieldStyle(.plain)
                    .styleText(size: 13, weight: .regular)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.T_9)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if let display = correctionDisplay {
                    Text(display)
                        .styleText(size: 12, weight: .semibold, color: Color.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                }
            }

            if correctionDisplay != nil {
                Button("Use this pronunciation") {
                    startScan()
                }
                .styleText(size: 12, weight: .regular, color: Color.blue)
                .buttonStyle(.plain)
            } else if !correctionText.isEmpty {
                Text("No pronunciation found for that spelling.")
                    .styleText(size: 11, weight: .regular, color: Color.orange)
            }
        }
        .padding(12)
        .background(Color.T_9.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Converts a raw Sherpa keyword string (e.g. `"▁ON IT"`) to a display string (`"ON · IT"`).
    private func tokenDisplay(_ keyword: String) -> String {
        keyword
            .components(separatedBy: " ")
            .map { $0.hasPrefix("▁") ? String($0.dropFirst()) : $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func highlightedText(sentence: String, span: String) -> some View {
        let parts = sentence.components(separatedBy: span)
        if parts.count >= 2 {
            (Text(parts[0])
             + Text(span).bold().foregroundColor(.accentColor)
             + Text(parts[1...].joined(separator: span)))
        } else {
            Text(sentence)
        }
    }

    // MARK: - Review History (Step 3 - big modal)

    private func reviewHistoryView(
        candidates: [CustomDictionaryCalibrationManager.CalibrationCandidate]
    ) -> some View {
        let total = min(candidates.count, historyCandidateCap)
        let idx = currentCandidateIdx
        let candidate: CustomDictionaryCalibrationManager.CalibrationCandidate? =
            idx < candidates.count ? candidates[idx] : nil

        return VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                tickerPill(current: idx + 1, total: total)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Should this be \u{201C}\(term.text)\u{201D}?")
                        .styleText(size: 15, weight: .medium, color: Color.S_0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(transcriptSubtitle(for: candidate))
                        .styleText(size: 14, weight: .regular, color: Color.T_1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            // Content - sentence textbox + answer buttons
            VStack(spacing: 8) {
                if let candidate {
                    Text(highlightedSentence(
                        sentence: candidate.sentence,
                        span: candidate.matchedSpan
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .background(Color.special1)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .addBorder(cornerRadius: 14, stroke: Color.T_8)
                }

                VStack(spacing: 8) {
                    answerChoiceButton(
                        attributed: yesChoiceText(),
                        action: {
                            guard let c = candidate else { return }
                            positives.append(CalibrationExample(sentence: c.sentence, span: c.matchedSpan))
                            // Promote the matched span to a deterministic
                            // substring trigger so future dictations catch it
                            // even when KWS audio scoring misses.
                            CustomDictionaryService.shared.addCommonMistake(
                                termID: term.id, span: c.matchedSpan
                            )
                            advance(candidates: candidates)
                        }
                    )
                    answerChoiceButton(
                        attributed: noChoiceText(span: candidate?.matchedSpan),
                        action: {
                            guard let c = candidate else { return }
                            negatives.append(CalibrationExample(sentence: c.sentence, span: c.matchedSpan))
                            advance(candidates: candidates)
                        }
                    )
                    Button {
                        advance(candidates: candidates)
                    } label: {
                        Text("Not sure")
                            .styleText(size: 14, weight: .regular, color: Color.S_0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)

            // Toolbar
            HStack(spacing: 16) {
                Text("Each confirmation helps Cloudless learn your new term")
                    .styleText(size: 13, weight: .medium, color: Color.T_2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    proceedToProxy()
                } label: {
                    Text("Skip this step")
                        .styleText(size: 13, weight: .medium, color: Color.info500)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .background(Color.special2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.T_9).frame(height: 1)
            }
        }
        .frame(width: 600, height: 460)
    }

    // MARK: - Review helpers

    private func tickerPill(current: Int, total: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(current)")
                .frame(maxWidth: .infinity)
            Text("of")
            Text("\(total)")
                .frame(maxWidth: .infinity)
        }
        .styleText(size: 13, weight: .medium, color: Color.T_1)
        .frame(width: 68, height: 24)
        .background(Color.T_9)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func transcriptSubtitle(
        for candidate: CustomDictionaryCalibrationManager.CalibrationCandidate?
    ) -> String {
        guard let candidate else { return "From your transcript" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "From your transcript \u{2022} \(formatter.string(from: candidate.transcriptTimestamp))"
    }

    /// AttributedString with the matched span shown in medium weight + orange highlight.
    private func highlightedSentence(sentence: String, span: String) -> AttributedString {
        var attributed = AttributedString(sentence)
        attributed.font = .system(size: 14, weight: .regular)
        attributed.foregroundColor = Color.S_0
        if let range = attributed.range(of: span, options: .caseInsensitive) {
            attributed[range].font = .system(size: 14, weight: .medium)
            attributed[range].backgroundColor = Color.orange500.opacity(0.2)
        }
        return attributed
    }

    private func yesChoiceText() -> AttributedString {
        var prefix = AttributedString("Yes, this should be ")
        prefix.font = .system(size: 14, weight: .regular)
        prefix.foregroundColor = Color.S_0

        var quote = AttributedString("\u{201C}\(term.text)\u{201D}")
        quote.font = .system(size: 14, weight: .medium)
        quote.foregroundColor = Color.S_0

        return prefix + quote
    }

    private func noChoiceText(span: String?) -> AttributedString {
        var prefix = AttributedString("No, ")
        prefix.font = .system(size: 14, weight: .regular)
        prefix.foregroundColor = Color.S_0

        var quote = AttributedString("\u{201C}\(span ?? "")\u{201D} ")
        quote.font = .system(size: 14, weight: .medium)
        quote.foregroundColor = Color.S_0

        var suffix = AttributedString("is correct")
        suffix.font = .system(size: 14, weight: .regular)
        suffix.foregroundColor = Color.S_0

        return prefix + quote + suffix
    }

    private func answerChoiceButton(
        attributed: AttributedString,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(attributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\u{2192}")
                    .styleText(size: 14, weight: .medium, color: Color.T_2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 19)
            .background(Color.T_10)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .addBorder(cornerRadius: 14, stroke: Color.T_7)
        }
        .buttonStyle(.plain)
    }

    private func candidateCard(candidate: CustomDictionaryCalibrationManager.CalibrationCandidate) -> some View {
        let sentence = candidate.sentence
        let span = candidate.matchedSpan
        let isThisPlaying = playingCandidateID == candidate.id && audioPlayer.isPlaying

        return VStack(alignment: .leading, spacing: 8) {
            highlightedText(sentence: sentence, span: span)
                .styleText(size: 13, weight: .regular)

            Text(String(format: "Detection: %.2fs – %.2fs", candidate.detectionStartSec, candidate.detectionEndSec))
                .styleText(size: 10, weight: .semibold, color: Color.T_2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.T_9)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                if isThisPlaying {
                    audioPlayer.pause()
                    playingCandidateID = nil
                } else {
                    audioPlayer.loadAudio(samples: candidate.spanAudioSamples)
                    audioPlayer.play()
                    playingCandidateID = candidate.id
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isThisPlaying ? "stop.fill" : "waveform")
                        .styleText(size: 11, color: Color.blue)
                    Text(isThisPlaying ? "Stop" : "Hear identified span")
                        .styleText(size: 12, weight: .regular, color: Color.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(candidate.spanAudioSamples.isEmpty)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.T_9)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func advance(candidates: [CustomDictionaryCalibrationManager.CalibrationCandidate]) {
        let next = currentCandidateIdx + 1
        let reachedTarget = positives.count >= historyPositiveTarget
        let hitCap = next >= historyCandidateCap
        let scanExhausted = !manager.isScanning && next >= candidates.count

        if reachedTarget || hitCap || scanExhausted {
            if positives.isEmpty {
                step = .typeSentences
            } else {
                proceedToProxy()
            }
        } else if next < candidates.count {
            currentCandidateIdx = next
        }
        // else: scan still running, more candidates will arrive via onChange
    }

    // MARK: - Step 3 (not found) - "Use term in a sentence"

    private var canSubmitTypedSentence: Bool {
        !typedSentenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var useInSentenceView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Use \u{201C}\(term.text)\u{201D} in a sentence")
                    .styleText(size: 15, weight: .medium, color: Color.S_0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("We couldn\u{2019}t match your term to any of your existing transcripts. Help Cloudless learn by using this term in a sentence instead.")
                    .styleText(size: 14, weight: .regular, color: Color.T_1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            // Content - multi-line text editor + helper
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if typedSentenceText.isEmpty {
                        Text("Type / dictate one or more short sentences with \u{201C}\(term.text)\u{201D}\u{2026}")
                            .styleText(size: 14, weight: .regular, color: Color.S_0)
                            .opacity(0.4)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $typedSentenceText)
                        .styleText(size: 14, weight: .regular, color: Color.S_0)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(Color.special1)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .addBorder(cornerRadius: 14, stroke: Color.T_8)

                Text("E.g. if your term is a name, like \u{201C}Sarah\u{201D} you can write \u{201C}My name is Sarah\u{201D}")
                    .styleText(size: 13, weight: .regular, color: Color.T_1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity)

            // Toolbar
            HStack(spacing: 8) {
                Spacer()
                Button(action: submitTypedSentences) {
                    Text("Continue")
                        .styleText(size: 14, weight: .medium, color: Color.black)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.sky)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .opacity(canSubmitTypedSentence ? 1.0 : 0.3)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitTypedSentence)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.T_7).frame(height: 1)
            }
        }
        .frame(width: 600, height: 460)
    }

    private func submitTypedSentences() {
        let lines = typedSentenceText
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let sentences = lines.isEmpty
            ? [typedSentenceText.trimmingCharacters(in: .whitespacesAndNewlines)]
            : lines
        for s in sentences where !s.isEmpty {
            positives.append(CalibrationExample(sentence: s, span: term.text))
        }
        proceedToProxy()
    }

    // MARK: - Step 4 (loading categories)

    private var loadingCategoriesView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Adding \u{201C}\(term.text)\u{201D} to your dictionary")
                    .styleText(size: 15, weight: .medium, color: Color.S_0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Finalising calibration\u{2026}")
                    .styleText(size: 14, weight: .regular, color: Color.T_1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving\u{2026}")
                        .styleText(size: 14, weight: .regular, color: Color.T_2)
                        .italic()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 19)
                .background(Color.T_10)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .addBorder(cornerRadius: 14, stroke: Color.T_7)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 600, height: 460)
    }

    // MARK: - Step 4 (choose category)

    private func chooseCategoryView(categories: [String], candidates: [String]) -> some View {
        VStack(spacing: 0) {
            categoryHeader

            VStack(alignment: .leading, spacing: 8) {
                ForEach(categories, id: \.self) { cat in
                    categoryOption(label: cat, isSelected: selectedCategory == cat && !useCustomCategory) {
                        selectedCategory = cat
                        useCustomCategory = false
                    }
                }
                customCategoryRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            categoryToolbar(canConfirm: canConfirmCategory && !isWorking) {
                Task { await confirmCategory(candidates: candidates) }
            }
        }
        .frame(width: 600, height: 460)
    }

    private var canConfirmCategory: Bool {
        if useCustomCategory {
            return !customCategoryText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return selectedCategory != nil
    }

    private var categoryHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose a category for \u{201C}\(term.text)\u{201D}")
                .styleText(size: 15, weight: .medium, color: Color.S_0)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Select the most accurate category")
                .styleText(size: 14, weight: .regular, color: Color.T_1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
    }

    private func categoryOption(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                radioCircle(isSelected: isSelected)
                Text(label)
                    .styleText(size: 14, weight: .regular, color: Color.S_0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 19)
            .background(Color.T_10)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .addBorder(cornerRadius: 14, stroke: Color.T_7)
        }
        .buttonStyle(.plain)
    }

    private var customCategoryRow: some View {
        HStack(spacing: 8) {
            radioCircle(isSelected: useCustomCategory)
            TextField(
                "",
                text: $customCategoryText,
                prompt: Text("Something else\u{2026}")
                    .foregroundColor(Color.S_0.opacity(0.4))
                    .italic()
            )
            .textFieldStyle(.plain)
            .styleText(size: 14, weight: .regular, color: Color.S_0)
            .onChange(of: customCategoryText) { newValue in
                useCustomCategory = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                if useCustomCategory {
                    selectedCategory = nil
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 19)
        .background(Color.T_10)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .addBorder(cornerRadius: 14, stroke: Color.T_7)
        .contentShape(Rectangle())
        .onTapGesture {
            if !customCategoryText.trimmingCharacters(in: .whitespaces).isEmpty {
                useCustomCategory = true
                selectedCategory = nil
            }
        }
    }

    private func radioCircle(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(Color.T_2.opacity(0.4), lineWidth: 1)
                .frame(width: 16, height: 16)
            if isSelected {
                Circle()
                    .fill(Color.info500)
                    .frame(width: 16, height: 16)
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func categoryToolbar(
        canConfirm: Bool,
        onConfirm: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: backFromCategory) {
                Text("\u{2190}")
                    .styleText(size: 14, weight: .medium, color: Color.S_0)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.T_10)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onConfirm) {
                Text(isWorking ? "Calibrating\u{2026}" : "Confirm and finish")
                    .styleText(size: 14, weight: .medium, color: Color.black)
                    .frame(width: 168, height: 36)
                    .background(Color.sky)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .opacity(canConfirm ? 1.0 : 0.3)
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.T_7).frame(height: 1)
        }
    }

    private func backFromCategory() {
        // Per design annotation: "goes back to first match".
        if !manager.historyCandidates.isEmpty {
            currentCandidateIdx = 0
            step = .reviewHistory
        } else {
            step = .typeSentences
        }
    }

    private func confirmCategory(candidates: [String]) async {
        let category = useCustomCategory
            ? customCategoryText.trimmingCharacters(in: .whitespaces)
            : (selectedCategory ?? "")
        guard !category.isEmpty else { return }

        isWorking = true
        defer { isWorking = false }

        let proxy: String?
        if candidates.isEmpty {
            proxy = nil
        } else {
            proxy = (try? await CustomDictionaryProxySelector.shared
                .pickProxyForCategory(candidates: candidates, category: category))
                ?? candidates.first
        }

        var finalNegatives = negatives
        if finalNegatives.count < 2, !positives.isEmpty {
            let confusionSpan = positives.first?.span ?? term.text
            let generated = await manager.generateNegativeExamples(confusionSpan: confusionSpan, count: 3)
            finalNegatives.append(contentsOf: generated)
        }

        await manager.finishCalibration(
            term: term,
            positives: positives,
            negatives: finalNegatives,
            proxyWord: proxy
        )
        AnalyticsManager.AppDictionary.calibrationCompleted(
            termId: term.id.uuidString,
            category: category
        )
        onComplete?(term)
        dismiss()
        onDismiss()
    }

    // MARK: - Type Sentences (legacy, unused)

    private var typeSentencesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("No matches found in history.")
                    .styleText(size: 13, weight: .regular, color: Color.T_1)
                Text("Type a few example sentences that use \u{201C}\(term.text)\u{201D}.")
                    .styleText(size: 12, weight: .regular, color: Color.T_2)
            }

            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    TextField("Sentence \(i + 1)\u{2026}", text: $typedSentences[i])
                        .textFieldStyle(.plain)
                        .styleText(size: 13, weight: .regular)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Color.T_9)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack {
                Spacer()
                TextButton(
                    type: .primary,
                    text: "Continue",
                    sizeConfig: .init(text: 13, horizontalPadding: 14, height: 32, cornerRadius: 8),
                    statusConfig: .init(disabled: typedSentences.filter {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }.count < 1),
                    action: {
                        let filled = typedSentences
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        for s in filled {
                            positives.append(CalibrationExample(sentence: s, span: term.text))
                        }
                        proceedToProxy()
                    }
                )
            }

            skipLink
        }
    }

    // MARK: - Confirm Proxy

    private func confirmProxyView(candidates: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a reference word.")
                    .styleText(size: 13, weight: .regular, color: Color.T_1)
                if candidates.isEmpty {
                    Text("Type a common word that sounds similar to \u{201C}\(term.text)\u{201D} (e.g. \u{201C}Unit\u{201D}, \u{201C}Audit\u{201D}). This helps Cloudless verify context.")
                        .styleText(size: 12, weight: .regular, color: Color.T_2)
                } else {
                    Text("To verify \u{201C}\(term.text)\u{201D} in context, Cloudless compares it against a similar common word. Which fits best?")
                        .styleText(size: 12, weight: .regular, color: Color.T_2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates, id: \.self) { proxy in
                    proxyOption(label: proxy, isSelected: selectedProxy == proxy && !useCustomProxy) {
                        selectedProxy = proxy
                        useCustomProxy = false
                    }
                }

                // Custom proxy row
                HStack(spacing: 8) {
                    Image(systemName: useCustomProxy ? "circle.fill" : "circle")
                        .styleText(size: 13, color: useCustomProxy ? Color.blue : Color.T_2)

                    TextField("Something else\u{2026}", text: $customProxy)
                        .textFieldStyle(.plain)
                        .styleText(size: 13, weight: .regular)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Color.T_9)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: customProxy) { _ in useCustomProxy = !customProxy.isEmpty }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Calibrating\u{2026}")
                        .styleText(size: 13, weight: .regular, color: Color.T_2)
                }
            } else {
                HStack(spacing: 8) {
                    TextButton(
                        type: .primary,
                        text: "Confirm",
                        sizeConfig: .init(text: 13, horizontalPadding: 14, height: 32, cornerRadius: 8),
                        statusConfig: .init(disabled: selectedProxy.isEmpty && customProxy.trimmingCharacters(in: .whitespaces).isEmpty),
                        action: { Task { await finishWithProxy() } }
                    )

                    Button("Skip") { finishWithoutProxy() }
                        .styleText(size: 13, weight: .regular, color: Color.T_2)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func proxyOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .styleText(size: 13, color: isSelected ? Color.blue : Color.T_2)
                Text(label)
                    .styleText(size: 13, weight: .regular, color: Color.T_1)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .styleText(size: 40, color: Color.green)

            VStack(spacing: 4) {
                Text("\u{201C}\(term.text)\u{201D} is configured")
                    .styleText(size: 15, weight: .semibold)
                Text("Cloudless will now recognise \u{201C}\(term.text)\u{201D} more accurately.")
                    .styleText(size: 12, weight: .regular, color: Color.T_2, align: .center)
            }

            TextButton(
                type: .primary,
                text: "Done",
                sizeConfig: .init(text: 13, horizontalPadding: 20, height: 32, cornerRadius: 8),
                action: {
                    dismiss()
                    onDismiss()
                }
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Shared Links

    private var skipLink: some View {
        HStack {
            Spacer()
            Button("Skip for now") {
                dismiss()
                onDismiss()
            }
            .styleText(size: 12, weight: .regular, color: Color.T_2)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func startScan() {
        step = .scanning
        Task { await manager.scanHistory(for: term) }
    }

    /// Generate the proxy directly from the existing filters + collected
    /// positive sentences and finish calibration. Category-picker UI is
    /// commented out below - it tested worse than picking top-1 of the
    /// `selectProxy` ranked list, so we skip it for now.
    private func proceedToProxy() {
        step = .loadingCategories  // reuses the loading screen as a generic "saving" state
        Task {
            let candidates = await manager.selectProxy(for: term, positives: positives)
            let proxy = candidates.first

            var finalNegatives = negatives
            if finalNegatives.count < 2, !positives.isEmpty {
                let confusionSpan = positives.first?.span ?? term.text
                let generated = await manager.generateNegativeExamples(confusionSpan: confusionSpan, count: 3)
                finalNegatives.append(contentsOf: generated)
            }

            await manager.finishCalibration(
                term: term,
                positives: positives,
                negatives: finalNegatives,
                proxyWord: proxy
            )
            AnalyticsManager.AppDictionary.calibrationCompleted(
                termId: term.id.uuidString,
                category: nil
            )
            onComplete?(term)
            dismiss()
            onDismiss()
        }
    }

    // MARK: - Category step (disabled)
    //
    // Earlier prototype routed through `.loadingCategories` → `.chooseCategory`
    // with NLEmbedding-ranked categories + Llama zero-shot proxy picking.
    // Tim tested this and found it produced worse proxies than just taking
    // top-1 of `CustomDictionaryProxySelector.selectProxy`. Keeping the views
    // and helpers below in case we revisit; they're unreachable now.

    /* DISABLED - left for future re-enable.
    private func proceedToProxyWithCategoryPicker() {
        step = .loadingCategories
        Task {
            let referenceSentences = positives.map(\.sentence)
            let categories = CustomDictionaryCategoryRanker.relevantCategories(
                positives: referenceSentences,
                topN: 4
            )
            let candidates = await manager.selectProxy(for: term, positives: positives)
            step = .chooseCategory(categories: categories, candidates: candidates)
            selectedCategory = categories.first
            useCustomCategory = false
        }
    }
    */

    private func finishWithoutProxy() {
        Task {
            await manager.finishCalibration(term: term, positives: positives, negatives: negatives, proxyWord: nil)
            step = .done
        }
    }

    private func finishWithProxy() async {
        isWorking = true
        let proxy = useCustomProxy
            ? customProxy.trimmingCharacters(in: .whitespaces)
            : selectedProxy

        var finalNegatives = negatives
        if finalNegatives.count < 2, !positives.isEmpty {
            let confusionSpan = positives.first?.span ?? term.text
            let generated = await manager.generateNegativeExamples(confusionSpan: confusionSpan, count: 3)
            finalNegatives.append(contentsOf: generated)
        }

        await manager.finishCalibration(
            term: term,
            positives: positives,
            negatives: finalNegatives,
            proxyWord: proxy.isEmpty ? nil : proxy
        )
        isWorking = false
        step = .done
    }
}
