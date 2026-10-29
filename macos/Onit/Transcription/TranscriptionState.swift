// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionState.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import SwiftUI

/// UI state for transcription feature
@MainActor
final class TranscriptionState: ObservableObject {

    // MARK: - Session State

    /// Whether transcription is currently active
    @Published var isActive = false

    /// Whether transcription is initializing (loading models for session)
    @Published var isInitializing = false

    /// Whether transcription is processing final audio (after recording stops)
    @Published var isProcessing = false

    /// Current transcription text (volatile, may change)
    @Published var currentTranscription = ""

    /// Text that has been inserted into the target app
    @Published var insertedText = ""

    /// Current audio input level (0.0 - 1.0)
    @Published var audioLevel: Float = 0.0

    /// Error message if any
    @Published var errorMessage: String?

    // MARK: - Correction State

    /// Whether transcription has completed and showing correction prompt
    @Published var isCompleted = false

    /// Whether the correction UI is being shown
    @Published var isShowingCorrection = false

    /// Whether an editing signal (delete, arrow, click in text) has fired since the overlay appeared.
    /// Controls overlay opacity: 0.5 initially, 1.0 once highlighted.
    @Published var isHighlighted = false

    /// The text being edited in correction mode
    @Published var correctionText = ""

    /// Original transcription before correction (for dataset)
    @Published var originalTranscription = ""

    /// Raw ASR text before Smart Formatting processing
    @Published var rawASRText = ""

    /// Whether the text has been modified by LLM (to show discard option)
    @Published var hasLLMModification = false

    /// Whether Smart Formatting was applied
    @Published var wasSmartFormattingApplied = false

    /// Whether a user snippet expansion fired during this dictation. Rides to the
    /// correction record so snippet-affected dictations can be identified (and
    /// filtered) in the training/contribution data.
    @Published var snippetExpanded = false

    /// Recorded audio samples for playback in correction mode (mono, 16kHz)
    @Published var recordedAudioSamples: [Float]?

    /// `True` when the user entered the correction overlay via "Correct & Teach Onit" from the Hint More Menu.
    /// `TranscriptionManager.saveCorrection()` reads this to skip the destructive replace-in-target-app branch.
    @Published var isCorrectingAndTeachingWithLastHistory = false

    /// Edit-last-transcription: false when keystrokes have happened since the last paste, the focused
    /// window changed, or the safety timeout elapsed. When false, Save copies the corrected text to the
    /// clipboard instead of backspace-and-replacing into whatever the user is now focused on.
    @Published var canReplacePastedText = true

    /// Force-correction-mode consume-preceding-punctuation: the cleanup pipeline's
    /// `deletePrecedingChars` decision is computed at dictation time but the paste is deferred to
    /// the user's correction-save click, so the decision must travel through the overlay. Applied
    /// at paste time in `saveCorrection`'s force-correction-paste branch, but ONLY when
    /// `leadingBoundarySnapshot` still matches `correctionText.leadingBoundarySignature` - the
    /// user's edit may have invalidated the cleanup decision by altering the leading boundary.
    @Published var deletePrecedingChars: Int = 0

    /// Leading boundary signature (leading whitespace + first non-whitespace char, case-sensitive)
    /// of the cleaned text at dictation time. Compared against `correctionText.leadingBoundarySignature`
    /// at paste time to decide if `deletePrecedingChars` is still valid. Empty when no consume decision
    /// was captured (auto-paste mode, or cleanup decided not to consume).
    @Published var leadingBoundarySnapshot: String = ""

    /// Used to accurately feed already-corrected transcriptions for training.
    /// `nil` outside the correct-and-teach flow (the in-flight dictation flow already has `originalTranscription` set to the cleaned text via `showCorrectionPrompt()`).
    @Published var trainingOriginalTextOverride: String? = nil

    #if DEBUG || ONIT_BETA
    /// Tags selected by the user in the correction UI (debug builds only)
    @Published var selectedTags: Set<String> = []
    /// Surrounding text context captured at transcription start (debug builds only)
    @Published var precedingContext: String? = nil
    @Published var followingContext: String? = nil
    #endif

    // MARK: - Computed Properties

    /// Display text for the overlay
    var displayText: String {
        if !currentTranscription.isEmpty {
            return currentTranscription
        } else if !insertedText.isEmpty {
            // Show last few words of inserted text
            let words = insertedText.split(separator: " ").suffix(5)
            return "..." + words.joined(separator: " ")
        } else {
            return String.localized("Listening...", table: "Transcription")
        }
    }

    /// Whether there's an error to display
    var hasError: Bool {
        errorMessage != nil
    }

    // MARK: - Methods

    /// Reset all state
    func reset() {
        isActive = false
        isInitializing = false
        isProcessing = false
        currentTranscription = ""
        insertedText = ""
        audioLevel = 0.0
        errorMessage = nil
        isCompleted = false
        isShowingCorrection = false
        isHighlighted = false
        correctionText = ""
        originalTranscription = ""
        rawASRText = ""
        hasLLMModification = false
        wasSmartFormattingApplied = false
        snippetExpanded = false
        recordedAudioSamples = nil
        isCorrectingAndTeachingWithLastHistory = false
        trainingOriginalTextOverride = nil
        canReplacePastedText = true
        deletePrecedingChars = 0
        leadingBoundarySnapshot = ""
        AudioPlaybackService.shared.clear()
        #if DEBUG || ONIT_BETA
        selectedTags = []
        precedingContext = nil
        followingContext = nil
        #endif
    }

    /// Show correction prompt after transcription completes
    func showCorrectionPrompt() {
        isCompleted = true
        originalTranscription = insertedText
        correctionText = insertedText
    }

    /// Enter correction editing mode
    func enterCorrectionMode() {
        isShowingCorrection = true
    }

    /// Discard LLM modification and revert to original transcription
    func discardLLMModification() {
        correctionText = originalTranscription
        hasLLMModification = false
    }

    /// Dismiss the overlay completely
    func dismiss() {
        reset()
    }
}
