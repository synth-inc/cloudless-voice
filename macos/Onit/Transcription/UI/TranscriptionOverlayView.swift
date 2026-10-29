// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionOverlayView.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import Defaults
import SwiftUI

// MARK: - Audio Playback Control View

/// Compact audio playback controls for listening back to recordings
private struct AudioPlaybackControlView: View {
    @ObservedObject private var playbackService = AudioPlaybackService.shared
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            // Play/Pause button
            Button(action: {
                if playbackService.isPlaying {
                    playbackService.pause()
                } else {
                    playbackService.play()
                }
            }) {
                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.S_0)
                    .frame(width: 24, height: 24)
                    .background(Color.S_0.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Current time
            Text(formatTime(playbackService.currentTime))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Color.T_2)
                .frame(width: 32, alignment: .trailing)

            // Progress bar with scrubbing (wrapped in TimelineView for continuous updates during gestures)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playbackService.isPlaying)) { _ in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.S_0.opacity(0.15))
                            .frame(height: 4)

                        // Progress fill
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.S_0.opacity(0.6))
                            .frame(width: progressWidth(for: geometry.size.width), height: 4)

                        // Scrubber handle
                        Circle()
                            .fill(Color.S_0)
                            .frame(width: 10, height: 10)
                            .offset(x: scrubberOffset(for: geometry.size.width))
                    }
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingProgress = true
                                let progress = max(0, min(1, value.location.x / geometry.size.width))
                                dragProgress = progress
                            }
                            .onEnded { value in
                                isDraggingProgress = false
                                let progress = max(0, min(1, value.location.x / geometry.size.width))
                                playbackService.seek(to: progress * playbackService.duration)
                            }
                    )
                }
            }
            .frame(height: 10)

            // Total duration
            Text(formatTime(playbackService.duration))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(Color.T_2)
                .frame(width: 32, alignment: .leading)

            // Volume boost control
            HStack(spacing: 4) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 11))
                    .foregroundColor(Color.T_2)
                    .frame(width: 16)  // Fixed width to prevent layout shifts

                // Gain slider (0x to 6x trim around normalized level)
                Slider(value: $playbackService.gain, in: 0.0...6.0, step: 0.5)
                    .frame(width: 50)
                    .tint(Color.S_0.opacity(0.6))

                Text("\(String(format: "%.1f", playbackService.gain))x")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(Color.T_2)
                    .frame(width: 28, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.S_0.opacity(0.05))
        .cornerRadius(8)
    }

    private func progressWidth(for totalWidth: CGFloat) -> CGFloat {
        let progress = isDraggingProgress ? dragProgress : (playbackService.duration > 0 ? playbackService.currentTime / playbackService.duration : 0)
        return CGFloat(progress) * totalWidth
    }

    private func scrubberOffset(for totalWidth: CGFloat) -> CGFloat {
        let progress = isDraggingProgress ? dragProgress : (playbackService.duration > 0 ? playbackService.currentTime / playbackService.duration : 0)
        return CGFloat(progress) * totalWidth - 5 // -5 to center the 10px handle
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var volumeIcon: String {
        if playbackService.gain <= 0 {
            return "speaker.slash.fill"
        } else if playbackService.gain >= 4.0 {
            return "speaker.wave.3.fill"
        } else if playbackService.gain >= 2.0 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.1.fill"
        }
    }
}

// MARK: - Tag Row View (Debug/Beta)

#if DEBUG || ONIT_BETA
/// Horizontally scrollable row of toggleable tag chips for labelling a correction.
/// Recently-used tags appear first; predefined cleanup and eval tags follow.
private struct TranscriptionTagRowView: View {
    @ObservedObject var state: TranscriptionState
    @Default(.transcriptionRecentTags) private var recentTags

    @State private var isAddingTag = false
    @State private var newTagText = ""
    @FocusState private var addFieldFocused: Bool

    private static let cleanupTags = [
        "fillers", "stutters", "email-url", "acronyms",
        "paired-brackets", "numbers", "punctuation", "formatting"
    ]
    private static let evalTags = [
        "bad-caps", "keyword-boosting", "phonetic-match"
    ]

    /// Display order: recently-used first, then remaining predefined in canonical order.
    private var orderedTags: [String] {
        let recentSet = Set(recentTags)
        let remaining = (Self.cleanupTags + Self.evalTags).filter { !recentSet.contains($0) }
        return recentTags + remaining
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 10))
                .foregroundColor(Color.T_3)
                .padding(.leading, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if isAddingTag {
                        TextField("tag", text: $newTagText)
                            .font(.system(size: 11))
                            .foregroundColor(Color.T_1)
                            .frame(width: 80)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(4)
                            .focused($addFieldFocused)
                            .onSubmit { commitNewTag() }
                            .onExitCommand { cancelAddTag() }
                    } else {
                        Button {
                            isAddingTag = true
                            addFieldFocused = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color.T_3)
                                .frame(width: 20, height: 20)
                                .background(Color.S_0.opacity(0.07))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Add custom tag")
                    }

                    ForEach(orderedTags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.S_0.opacity(0.05))
        .cornerRadius(8)
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = state.selectedTags.contains(tag)
        return Button {
            toggleTag(tag)
        } label: {
            Text(tag)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .purple : Color.T_1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isSelected ? Color.purple.opacity(0.15) : Color.S_0.opacity(0.07))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }

    private func toggleTag(_ tag: String) {
        if state.selectedTags.contains(tag) {
            state.selectedTags.remove(tag)
        } else {
            state.selectedTags.insert(tag)
            // Promote to front of recently-used list
            var recent = recentTags
            recent.removeAll { $0 == tag }
            recent.insert(tag, at: 0)
            recentTags = Array(recent.prefix(50))
        }
    }

    private func commitNewTag() {
        let tag = newTagText.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty {
            toggleTag(tag)
        }
        cancelAddTag()
    }

    private func cancelAddTag() {
        newTagText = ""
        isAddingTag = false
        addFieldFocused = false
    }
}
#endif

// MARK: - Transcription Overlay View

/// Compact overlay view displayed after transcription completes.
/// Shows either the completion prompt ("Not right?") or the correction editor.
/// Note: The recording waveform is displayed in ExternalTetheredButton, not here.
struct TranscriptionOverlayView: View {
    @ObservedObject var state: TranscriptionState
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        Group {
            if state.isShowingCorrection {
                TranscriptionCorrectionView(state: state)
            } else {
                TranscriptionCompletedView(state: state)
            }
        }
        .id(localization.currentLanguage)
    }
}


// MARK: - Completed View

/// Correction prompt shown after editing signals are detected post-paste.
private struct TranscriptionCompletedView: View {
    @ObservedObject var state: TranscriptionState
    @State private var autoDismissTask: Task<Void, Never>?

    @State private var isHovered = false
    @State private var isFixHovered = false
    @State private var isFixPressed = false

    private let buttonVerticalPadding: CGFloat = 2
    private let buttonHorizontalPadding: CGFloat = 4
    private let buttonHoverBackground: Color = Color.T_8
    private let buttonCornerRadius: CGFloat = 6

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Image(.logo)
                .resizable()
                .frame(width: 18, height: 18)
                .cornerRadius(6)

            correctionButton
        }
        .padding(.leading, 5)
        .padding([.vertical, .trailing], 3)
        .fixedSize()
        .background(Color.S_10.opacity(0.4))
        .background(Backgrounds.BrushedGlass())
        .addBorder(
            cornerRadius: 9,
            stroke: Color.T_7
        )
        .opacity(state.isHighlighted || isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.15), value: state.isHighlighted)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                // Pause the dismiss timer while the user is hovering.
                autoDismissTask?.cancel()
                autoDismissTask = nil
            } else {
                // Restart the timer when the cursor leaves.
                scheduleAutoDismiss()
            }
        }
        .onAppear {
            HintManager.shared.updateTranscriptionOverlaySize()
            scheduleAutoDismiss()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            TranscriptionManager.shared.dismissOverlay()
        }
    }

    /// "Not quite right? Fix & teach Onit." - plain prefix + underlined action link.
    private var correctionButton: some View {
        HStack(spacing: 0) {
            Text(String.localized("Not quite right? ", table: "Transcription"))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.S_0.opacity(0.66)
                )
            Text(String.localized("Fix & teach Cloudless.", table: "Transcription"))
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.S_0.opacity(0.66),
                    underline: true
                )
                .padding(.vertical, buttonVerticalPadding)
                .padding(.horizontal, buttonHorizontalPadding)
                .addButtonEffects(
                    hoverBackground: buttonHoverBackground,
                    cornerRadius: buttonCornerRadius,
                    isHovered: $isFixHovered,
                    isPressed: $isFixPressed
                ) {
                    autoDismissTask?.cancel()
                    state.enterCorrectionMode()
                    HintManager.shared.enableTranscriptionOverlayEditMode()
                }
        }
        .padding(.leading, 4)
    }
}

// MARK: - Correction View

/// View displayed for correcting the transcription
private struct TranscriptionCorrectionView: View {
    @ObservedObject var state: TranscriptionState
    @ObservedObject private var config = TranscriptionConfig.shared
    @FocusState private var isTextFieldFocused: Bool

    /// Debug ⇄ production preview of this overlay: hides the context row, tag
    /// row, and scoring-debug button so the popup renders as release users see
    /// it. Flipped by the bottom-right ladybug; persists across dictations.
    @Default(Defaults.Keys.TranscriptionConfigKeys.transcriptionOverlayDebugUI) private var overlayDebugUI

    /// "Add to dictionary" candidates mined from the live correction text
    /// (CapsTermSelector criteria; new-vs-raw and not-in-dictionary filtered).
    @State private var dictionaryCandidates: [String] = []
    @State private var dictionaryMineTask: Task<Void, Never>? = nil
    /// True while a mining pass is debouncing - drives the bar's loading state.
    @State private var isMiningDictionary: Bool = false
    /// Per-dictation identity for the chip bar (regenerated on appear).
    @State private var dictionaryBarSession = UUID()

    /// Re-mine candidates, debounced for per-keystroke edits.
    private func scheduleDictionaryMine(for text: String) {
        dictionaryMineTask?.cancel()
        let raw = state.rawASRText
        isMiningDictionary = true
        dictionaryMineTask = Task { @MainActor in
            // 1s: long enough that half-typed words don't mine (and get
            // auto-added to the dictionary) mid-keystroke.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            dictionaryCandidates = CorrectionTermMiner.newTerms(
                correction: text,
                raw: raw
            )
            isMiningDictionary = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.S_0)

                Text(String.localized("Correct your transcript", table: "Transcription"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.S_0)

                Spacer()

                #if DEBUG && canImport(TranscriptionCleanup) // the scoring debug window shows Smart Cleanup decisions
                // Scoring debug viewer (debug builds only)
                if overlayDebugUI {
                    Button(action: {
                        ScoringDebugWindowController.shared.show()
                    }) {
                        Image(systemName: "function")
                            .foregroundColor(Color.T_2)
                            .font(.system(size: 14))
                            .frame(width: 24, height: 24)
                            .background(Color.S_0.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Open Scoring Debug Viewer")
                }
                #endif

                // Cancel button
                Button(action: {
                    TranscriptionManager.shared.dismissOverlay()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.S_1)
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)

            // Before/After comparison (always shown when raw ASR text is available)
            if !state.rawASRText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    // Before (raw ASR)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String.localized("Before:", table: "Transcription"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(state.rawASRText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }

                    // After (cleaned)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String.localized("After:", table: "Transcription"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                        Text(state.insertedText)
                            .font(.system(size: 12))
                            .foregroundColor(Color.S_0)
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.S_0.opacity(0.05))
                .addBorder(cornerRadius: 6, stroke: Color.T_7.opacity(0.5))
                .padding(.horizontal, 8)
            }

            #if DEBUG || ONIT_BETA
            // Surrounding context (debug/beta only). Always render the row so you can
            // tell the difference between "AX didn't capture context for this app" (italic
            // placeholders) vs "context wasn't requested" (row absent on Release). The
            // capture lives in TranscriptionManager.startTranscription's Task.detached AX
            // query and silently returns nil on apps without solid AX text support.
            //
            // The preceding tail also shows the cleanup pipeline's consume-preceding-chars
            // decision: when force-correction mode captured a positive `deletePrecedingChars`
            // and the user's edit hasn't invalidated it (leadingBoundarySignature match), the
            // chars that will be consumed at paste time are rendered with red strikethrough.
            // Strikethrough disappears live as the user edits the leading boundary.
            if overlayDebugUI {
            HStack(spacing: 0) {
                if let preceding = state.precedingContext, !preceding.isEmpty {
                    let tail = String(preceding.suffix(30))
                    let willConsume = state.deletePrecedingChars > 0
                        && state.correctionText.leadingBoundarySignature == state.leadingBoundarySnapshot
                    let consumeCount = willConsume ? min(state.deletePrecedingChars, tail.count) : 0
                    let keep = String(tail.dropLast(consumeCount))
                    let strike = String(tail.suffix(consumeCount))

                    Text("…" + keep)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.T_3)
                        .lineLimit(1)
                    if !strike.isEmpty {
                        Text(strike)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color.red.opacity(0.7))
                            .strikethrough(true, color: Color.red.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    Text(String.localized("(no preceding)", table: "Transcription"))
                        .font(.system(size: 11, design: .monospaced).italic())
                        .foregroundColor(Color.T_3.opacity(0.6))
                        .lineLimit(1)
                }
                Text(" [\(String.localized("transcript", table: "Transcription"))] ")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.purple.opacity(0.7))
                    .lineLimit(1)
                if let following = state.followingContext, !following.isEmpty {
                    Text(String(following.prefix(30)) + "…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.T_3)
                        .lineLimit(1)
                } else {
                    Text(String.localized("(no following)", table: "Transcription"))
                        .font(.system(size: 11, design: .monospaced).italic())
                        .foregroundColor(Color.T_3.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.S_0.opacity(0.04))
            .addBorder(cornerRadius: 6, stroke: Color.T_7.opacity(0.3))
            .padding(.horizontal, 8)
            }
            #endif

            // Text editor - multi-line TextField with vertical axis auto-grows with
            // content (unlike TextEditor whose intrinsic size always reports its
            // minimum, leaving the field compressed when the debug sections claim
            // space above). `lineLimit(1...6)` caps growth at 6 lines so the overlay
            // stays bounded on very long dictations; the user can scroll inside the
            // field beyond that.
            VStack(spacing: 0) {
                TextField("", text: $state.correctionText, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(Color.S_0)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .lineLimit(1...6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.S_0.opacity(0.07))
            .addBorder(cornerRadius: 9, stroke: Color.T_7)
            .padding(.horizontal, 8)

            // Audio playback controls (only if audio samples are available)
            if state.recordedAudioSamples != nil {
                AudioPlaybackControlView()
                    .padding(.horizontal, 8)
                    .onAppear {
                        if let samples = state.recordedAudioSamples {
                            AudioPlaybackService.shared.loadAudio(samples: samples)
                        }
                    }
                    .onChange(of: state.recordedAudioSamples) { _, samples in
                        // Re-load whenever samples are replaced (e.g. re-entering correction
                        // mode after a previous session cleared AudioPlaybackService).
                        if let samples {
                            AudioPlaybackService.shared.loadAudio(samples: samples)
                        } else {
                            AudioPlaybackService.shared.clear()
                        }
                    }
            }

            #if DEBUG || ONIT_BETA
            // Tag row for labelling corrections (debug/beta only)
            if overlayDebugUI {
                TranscriptionTagRowView(state: state)
                    .padding(.horizontal, 8)
            }
            #endif

            // "Add to dictionary" segment - terms the user introduced in this
            // correction that pass the key-term criteria. Chip state is per
            // dictation: keyed to the raw ASR text so a new session resets it.
            CorrectionAddToDictionaryBar(
                candidates: dictionaryCandidates,
                correctionText: state.correctionText,
                isMining: isMiningDictionary
            )
                .padding(.horizontal, -6)   // bar pads 16; align with the 10pt sections
                // Fresh identity per correction-view appearance. Keying on
                // rawASRText.hashValue carried chip state across dictations with
                // identical raw text - reconcile could then roll a PREVIOUS
                // session's saved term out of the dictionary.
                .id(dictionaryBarSession)
                .onChange(of: state.correctionText) { _, newText in
                    scheduleDictionaryMine(for: newText)
                }
                .onAppear {
                    dictionaryBarSession = UUID()
                    scheduleDictionaryMine(for: state.correctionText)
                }

            // Footer with buttons
            if config.forceCorrectionUI {
                HStack(spacing: 8) {
                    // Primary button - confirm the transcript is correct (adds it to
                    // the user's reviewed / source-of-truth set) and insert it.
                    Button(action: {
                        TranscriptionManager.shared.saveCorrection()
                    }) {
                        HStack(spacing: 4) {
                            Text(String.localized("Mark Correct & Insert", table: "Transcription"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.black)

                            Text("⌘⏎")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.black.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28, alignment: .center)
                        .background(Color.sky)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)

                    // Secondary button - insert without marking the transcript correct.
                    // Signals the user did not review it, so the history row isn't
                    // promoted to `.reviewed` (kept out of the source-of-truth set).
                    Button(action: {
                        TranscriptionManager.shared.saveCorrection(markAsReviewed: false)
                    }) {
                        Text(String.localized("Just Insert", table: "Transcription"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.T_1)
                            .padding(.horizontal, 10)
                            .frame(height: 28, alignment: .center)
                            .background(Color.S_0.opacity(0.1))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)

                    #if DEBUG || ONIT_BETA
                    // Tertiary button - save to history without pasting. Internal
                    // labeling affordance; hidden in release builds.
                    Button(action: {
                        TranscriptionManager.shared.saveCorrectionToHistoryOnly()
                    }) {
                        Text(String.localized("Just save", table: "Transcription"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.T_1)
                            .padding(.horizontal, 10)
                            .frame(height: 28, alignment: .center)
                            .background(Color.S_0.opacity(0.1))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    #endif

                    Spacer()
                }
                .padding(.horizontal, 10)
            } else {
                HStack(spacing: 8) {
                    // Info message
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(Color.T_2)

                        Text(String.localized("Every correction matters", table: "Transcription"))
                            .font(.system(size: 12))
                            .foregroundColor(Color.T_2)
                    }

                    Spacer()
                    
                    IconButton(
                        systemName: "arrow.uturn.backward",
                        iconSize: 16,
                        buttonSize: 28,
                        cornerRadius: 7
                    ) {
                        TranscriptionManager.shared.undoLastTranscription()
                    }

                    // Save: replaces the previously pasted text in-place when safe; otherwise
                    // copies the corrected text to the clipboard so the user can paste it manually.
                    Button(action: {
                        TranscriptionManager.shared.saveCorrection()
                    }) {
                        HStack(spacing: 4) {
                            Text(state.canReplacePastedText
                                 ? String.localized("Save", table: "Transcription")
                                 : String.localized("Copy corrected", table: "Transcription"))
                                .styleText(
                                    size: 12
                                )

                            Text("⌘⏎")
                                .styleText(
                                    size: 10,
                                    weight: .semibold,
                                    color: Color.S_0.opacity(0.7)
                                )
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28, alignment: .center)
                        .background(Color.T_7)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 446)
        .background(Color.S_10.opacity(0.4))
        .background(Backgrounds.BrushedGlass())
        .addBorder(cornerRadius: 14, stroke: Color.T_7)
        #if DEBUG || ONIT_BETA
        // Debug ⇄ production preview switch, tucked into the bottom-right corner.
        .overlay(alignment: .bottomTrailing) {
            Button {
                overlayDebugUI.toggle()
            } label: {
                Image(systemName: overlayDebugUI ? "ladybug.fill" : "ladybug")
                    .font(.system(size: 10))
                    .foregroundColor(overlayDebugUI ? Color.blue400 : Color.T_4)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .help(overlayDebugUI
                  ? "Showing debug UI - click for the production view"
                  : "Showing production view - click for debug UI")
        }
        #endif
        .onExitCommand {
            /// Handle ESC when the panel is key (edit mode). The global key monitor only sees events
            /// dispatched to other processes, so it misses ESC while this panel is key.
            TranscriptionManager.shared.dismissOverlay()
        }
        .onAppear {
            /// The `transcriptionOverlayDidMove()` selector function automatically sets `userHasManuallyPositionedOverlay` to `true`.
            /// This breaks the correction UI being properly positioned next to the Hint.
            /// Setting this value to `false` only on initial appearance allows the correction UI to appear at the proper place, while maintaining user-induced draggability.
            HintManager.shared.userHasManuallyPositionedOverlay = false

            HintManager.shared.updateTranscriptionOverlaySize()

            // Delay focus request to ensure window is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }

}

#Preview {
    TranscriptionOverlayView(state: TranscriptionState())
        .padding()
}
