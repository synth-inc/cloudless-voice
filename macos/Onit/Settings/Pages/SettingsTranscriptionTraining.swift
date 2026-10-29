// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsTranscriptionTraining.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-02-04.
//

// Needs `TrainingSentenceGenerator`, which uses the TranscriptionCleanup library.
#if canImport(TranscriptionCleanup)

import SwiftUI
import Defaults
import AppKit

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// Interface for capturing training data for transcription cleanup fine-tuning.
/// Users are prompted with sentences to speak, and the raw vs cleaned transcriptions are captured.
struct SettingsTranscriptionTraining: View {
    // MARK: - State

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var sentenceGenerator = TrainingSentenceGenerator.shared
    @ObservedObject private var trainingDataManager = TrainingDataManager.shared

    /// Current generated sentence to speak
    @State private var currentSentence: TrainingSentenceGenerator.GeneratedSentence?

    /// The raw transcription (what ASR returned)
    @State private var rawTranscription: String = ""

    /// The cleaned transcription (after cleanup processing)
    @State private var cleanedTranscription: String = ""

    /// The pipeline's cleaned output (for comparison)
    @State private var pipelineCleanedTranscription: String = ""

    /// Whether the pipeline output section is expanded
    @State private var pipelineOutputExpanded: Bool = false

    /// Track if we've already captured results for the current recording
    @State private var hasCapturedResults: Bool = false

    /// Focus state for text editors - used to prevent double insertion
    enum Field: Hashable {
        case raw
        case cleaned
    }
    @FocusState private var focusedField: Field?

    /// Number of samples saved this session
    @State private var samplesSavedCount: Int = 0

    /// Number of samples skipped this session
    @State private var samplesSkippedCount: Int = 0

    /// Whether to show the clear confirmation dialog
    @State private var showingClearConfirmation: Bool = false

    /// Whether instructions section is expanded
    @State private var instructionsExpanded: Bool = false

    /// Whether generation context section is expanded
    @State private var contextExpanded: Bool = false

    /// Selected app category for simulated context
    @State private var selectedAppCategory: SimulatedApp = .general

    /// Whether we're currently recording (derived from transcription state)
    private var isRecording: Bool {
        transcriptionManager.state.isActive || transcriptionManager.state.isProcessing
    }

    /// The sentence the user should speak
    private var promptSentence: String {
        currentSentence?.sentence ?? "Loading..."
    }

    /// Category info for display
    private var categoryInfo: String {
        guard let sentence = currentSentence else { return "" }
        let type = sentence.isPositiveExample ? "should be cleaned" : "should be preserved"
        return "\(sentence.category.name) (\(type))"
    }

    /// Whether the current sample is ready to save
    private var canSave: Bool {
        !rawTranscription.isEmpty
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                explanationSection
                instructionsSection
                promptSection
                transcriptionSection
                actionButtonsSection
                statsSection
            }
            .padding(.bottom, 20)
        }
        .background {
            // Hidden button for CMD+Enter keyboard shortcut
            Button("") {
                if canSave {
                    saveSample()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()
        }
        .onAppear {
            // Start pre-generating sentences in the background
            sentenceGenerator.startPreGenerating()

            if currentSentence == nil {
                generateNewSentence()
            }
        }
        .onChange(of: transcriptionManager.state.isProcessing) { oldValue, newValue in
            // Only capture when transitioning from processing -> not processing
            if oldValue == true && newValue == false {
                if !transcriptionManager.state.rawASRText.isEmpty && !hasCapturedResults {
                    hasCapturedResults = true
                    captureTranscriptionResults()
                }
            }
        }
        .onChange(of: transcriptionManager.state.isActive) { oldValue, newValue in
            // Reset capture flag when a new recording starts (transition to active)
            if oldValue == false && newValue == true {
                hasCapturedResults = false
                // Remove focus from text editors to prevent transcription system from inserting there
                focusedField = nil
            }
        }
        .alert(
            String.localized("Clear Training Data"),
            isPresented: $showingClearConfirmation
        ) {
            Button(String.localized("Cancel"), role: .cancel) {}
            Button(String.localized("Clear"), role: .destructive) {
                clearTrainingData()
            }
        } message: {
            Text(String.localized("This will permanently delete all %d training samples. This action cannot be undone.", trainingDataManager.sampleCount))
        }
    }

    // MARK: - Sections

    private var explanationSection: some View {
        SettingsPageSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 16))
                        .foregroundColor(.purple)

                    Text(String.localized("Create Your Custom Cleanup Model"))
                        .styleText(size: 14, weight: .semibold)
                }

                Text(String.localized("Train a personalized transcription cleanup model that learns your speaking style. Record sample sentences, review the transcriptions, and correct any errors to create training data that will be used to fine-tune a model just for you."))
                    .styleText(size: 12, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String.localized("Sentence to Speak"))
                .padding(.horizontal, 16)
                .styleText(size: 13, weight: .semibold)

            SettingsPageSection {
                VStack(alignment: .leading, spacing: 12) {
                    // Category badge
                    if !categoryInfo.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Color.T_2)
                            Text(categoryInfo)
                                .styleText(size: 11, color: Color.T_2)
                        }
                    }

                    // The sentence to speak
                    Text(promptSentence)
                        .styleText(size: 14, weight: .medium)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )

                    // Expected clean output (for reference)
                    if let sentence = currentSentence, sentence.isPositiveExample {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String.localized("Expected Clean Output"))
                                .styleText(size: 10, weight: .medium, color: Color.T_3)
                            Text(sentence.expectedCleanOutput)
                                .styleText(size: 12, color: Color.T_2)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.05))
                                .cornerRadius(6)
                        }
                    }

                    // Collapsible generation context section
                    if let context = currentSentence?.context {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    contextExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: contextExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(Color.T_3)
                                        .frame(width: 10)

                                    Image(systemName: "gearshape.2")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color.T_3)

                                    Text(String.localized("Generation Context"))
                                        .styleText(size: 10, weight: .medium, color: Color.T_3)

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            if contextExpanded {
                                VStack(alignment: .leading, spacing: 6) {
                                    contextRow(label: "Person", value: context.career.capitalized)
                                    contextRow(label: "Action", value: context.medium)
                                    contextRow(label: "Recipient", value: context.recipient)
                                    contextRow(label: "Tone", value: context.tone)
                                    contextRow(label: "Random Word", value: "\"\(context.randomWord)\"")
                                    if let trigger = context.specificTrigger {
                                        contextRow(label: "Trigger", value: "\"\(trigger)\"")
                                    }
                                    contextRow(label: "Category", value: currentSentence?.category.name ?? "")
                                    contextRow(label: "Type", value: currentSentence?.isPositiveExample == true ? "Positive (needs cleanup)" : "Negative (preserve)")
                                }
                                .padding(8)
                                .background(Color.purple.opacity(0.05))
                                .cornerRadius(6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    // App context picker for simulated context
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String.localized("Simulated App Context"))
                            .styleText(size: 10, weight: .medium, color: Color.T_3)

                        Picker("", selection: $selectedAppCategory) {
                            ForEach(SimulatedApp.allCases) { category in
                                Text(category.displayName).tag(category)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)

                        Text(selectedAppCategory.categoryDescription)
                            .styleText(size: 10, color: Color.T_4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Button {
                            generateNewSentence()
                        } label: {
                            HStack(spacing: 4) {
                                if sentenceGenerator.isGenerating {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 11, height: 11)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
                                }
                                Text(String.localized("New Sentence"))
                                    .styleText(size: 12)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                        .disabled(sentenceGenerator.isGenerating)

                        Spacer()

                        // Queue indicator
                        HStack(spacing: 4) {
                            if sentenceGenerator.isGenerating && sentenceGenerator.queueCount == 0 {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 9))
                            }
                            Text("\(sentenceGenerator.queueCount) ready")
                                .styleText(size: 10)
                        }
                        .foregroundColor(sentenceGenerator.queueCount > 0 ? .green : Color.T_3)
                    }
                }
            }
        }
    }

    private var instructionsSection: some View {
        SettingsPageSection {
            VStack(alignment: .leading, spacing: 8) {
                // Collapsible header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        instructionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: instructionsExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.T_2)
                            .frame(width: 12)

                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(Color.T_2)

                        Text(String.localized("How It Works"))
                            .styleText(size: 13, weight: .medium)

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                // Collapsible content
                if instructionsExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        instructionRow(number: 1, text: String.localized("Hold Caps Lock (or your configured shortcut) to record"))
                        instructionRow(number: 2, text: String.localized("Speak the sentence naturally, as you would when dictating"))
                        instructionRow(number: 3, text: String.localized("Include natural speech patterns - pauses, filler words (um, uh), self-corrections"))
                        instructionRow(number: 4, text: String.localized("Release to stop recording and see the transcription"))
                        instructionRow(number: 5, text: String.localized("Review and edit both fields to correct any errors"))
                        instructionRow(number: 6, text: String.localized("Click Save & Next to add to your training data"))
                    }
                    .padding(.leading, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .styleText(size: 12, weight: .medium, color: Color.T_2)
                .frame(width: 16, alignment: .trailing)

            Text(text)
                .styleText(size: 12, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .styleText(size: 10, weight: .medium, color: Color.T_3)
                .frame(width: 60, alignment: .trailing)

            Text(value)
                .styleText(size: 10, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String.localized("Transcription Results"))
                .padding(.horizontal, 16)
                .styleText(size: 13, weight: .semibold)

            SettingsPageSection {
                VStack(alignment: .leading, spacing: 16) {
                    // Recording status
                    if isRecording {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .modifier(PulseAnimation())

                            Text(String.localized("Recording..."))
                                .styleText(size: 12, weight: .medium, color: Color.red)

                            Spacer()
                        }
                        .padding(10)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Raw transcription (editable)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String.localized("Raw Transcription"))
                                .styleText(size: 11, weight: .medium, color: Color.T_2)

                            Text(String.localized("(edit to match what was actually spoken)"))
                                .styleText(size: 10, color: Color.T_3)
                        }

                        TextEditor(text: $rawTranscription)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 60, maxHeight: 100)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .focused($focusedField, equals: .raw)
                            .overlay(
                                Group {
                                    if rawTranscription.isEmpty {
                                        Text(String.localized("Record a sentence, then edit if needed..."))
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.T_3)
                                            .italic()
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .allowsHitTesting(false)
                                    }
                                },
                                alignment: .topLeading
                            )
                    }

                    // Cleaned transcription (editable)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String.localized("Cleaned Transcription"))
                                .styleText(size: 11, weight: .medium, color: Color.T_2)

                            Text(String.localized("(edit to show the correct cleaned version)"))
                                .styleText(size: 10, color: Color.T_3)
                        }

                        TextEditor(text: $cleanedTranscription)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 60, maxHeight: 100)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            .focused($focusedField, equals: .cleaned)
                            .overlay(
                                Group {
                                    if cleanedTranscription.isEmpty {
                                        Text(String.localized("The cleaned version will appear here..."))
                                            .font(.system(size: 12))
                                            .foregroundColor(Color.T_3)
                                            .italic()
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .allowsHitTesting(false)
                                    }
                                },
                                alignment: .topLeading
                            )
                    }

                    // Collapsible pipeline output section
                    if !pipelineCleanedTranscription.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    pipelineOutputExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: pipelineOutputExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(Color.T_3)
                                        .frame(width: 10)

                                    Text(String.localized("Pipeline Output"))
                                        .styleText(size: 10, weight: .medium, color: Color.T_3)

                                    Text(String.localized("(what our cleanup model produced)"))
                                        .styleText(size: 9, color: Color.T_4)

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            if pipelineOutputExpanded {
                                Text(pipelineCleanedTranscription)
                                    .styleText(size: 11, color: Color.T_2)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.05))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                                    )
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionButtonsSection: some View {
        SettingsPageSection {
            HStack(spacing: 12) {
                // Skip button
                Button {
                    skipSample()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                        Text(String.localized("Skip"))
                            .styleText(size: 13, weight: .medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.T_6)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Save button
                Button {
                    saveSample()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(String.localized("Save & Next"))
                            .styleText(size: 13, weight: .medium, color: .white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(canSave ? Color.green : Color.green.opacity(0.5))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
    }

    private var statsSection: some View {
        SettingsPageSection {
            VStack(alignment: .leading, spacing: 12) {
                // Session stats
                HStack(spacing: 16) {
                    Text(String.localized("This Session"))
                        .styleText(size: 11, weight: .medium, color: Color.T_2)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                        Text(String.localized("%d saved", samplesSavedCount))
                            .styleText(size: 11, color: Color.T_2)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "forward.circle")
                            .font(.system(size: 11))
                            .foregroundColor(Color.T_3)
                        Text(String.localized("%d skipped", samplesSkippedCount))
                            .styleText(size: 11, color: Color.T_2)
                    }
                }

                DividerHorizontal()

                // Total samples
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "cylinder.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color.T_2)
                        Text(String.localized("Total Samples"))
                            .styleText(size: 12, color: Color.T_1)
                    }

                    Spacer()

                    Text("\(trainingDataManager.sampleCount)")
                        .styleText(size: 12, weight: .medium)
                }

                // Export button
                HStack {
                    Button {
                        exportTrainingData()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11))
                            Text(String.localized("Export Data"))
                                .styleText(size: 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .disabled(trainingDataManager.sampleCount == 0)

                    Spacer()

                    Button {
                        showClearConfirmation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text(String.localized("Clear"))
                                .styleText(size: 12)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color.red)
                    .disabled(trainingDataManager.sampleCount == 0)
                }
            }
        }
    }

    // MARK: - Actions

    /// Whether remote LLM generation is available (user is authenticated)
    private var isRemoteLLMAvailable: Bool {
        TokenManager.token != nil
    }

    private func generateNewSentence() {
        // Use remote LLM generation if authenticated, otherwise fall back to static examples
        if isRemoteLLMAvailable {
            // Use async remote LLM generation
            Task {
                do {
                    let sentence = try await sentenceGenerator.generateTrainingSentence()
                    await MainActor.run {
                        currentSentence = sentence
                    }
                } catch {
                    log.error("Failed to generate training sentence: \(error)")
                    // Fall back to quick generation
                    await MainActor.run {
                        currentSentence = sentenceGenerator.getRandomExampleSentence()
                    }
                }
            }
        } else {
            // Use static examples when not authenticated
            currentSentence = sentenceGenerator.getRandomExampleSentence()
        }
    }

    /// Capture transcription results from the TranscriptionManager state
    private func captureTranscriptionResults() {
        let state = transcriptionManager.state

        // Get raw ASR text (before any cleanup)
        rawTranscription = state.rawASRText

        // Prefill cleaned transcription with the LLM's expected output
        if let expectedOutput = currentSentence?.expectedCleanOutput {
            cleanedTranscription = expectedOutput
        } else {
            // Fallback to raw if no expected output
            cleanedTranscription = state.rawASRText
        }

        // Run through the cleanup pipeline to get what it would produce
        Task {
            await runCleanupPipeline(on: state.rawASRText)
        }

        log.info("Training data captured - Raw: \(LogPrivacy.summary(rawTranscription)) Expected: \(LogPrivacy.summary(cleanedTranscription))")
    }

    /// Run the V6 cleanup pipeline on raw text to get pipeline's cleaned version
    private func runCleanupPipeline(on text: String) async {
        let llmService = TranscriptionLLMService.shared

        // Check if model is loaded
        guard llmService.isImprovementModelLoaded else {
            log.warning("Improvement model not loaded, using raw text for pipeline output")
            pipelineCleanedTranscription = text
            return
        }

        do {
            let cleaned = try await llmService.generateWithImprovementModel(userPrompt: text)
            await MainActor.run {
                pipelineCleanedTranscription = cleaned
            }
        } catch {
            log.error("Failed to run cleanup pipeline: \(error)")
            await MainActor.run {
                pipelineCleanedTranscription = text
            }
        }
    }

    private func skipSample() {
        samplesSkippedCount += 1
        resetForNextSample()
    }

    private func saveSample() {
        guard canSave else { return }

        Task {
            await saveTrainingSample()
        }
        samplesSavedCount += 1
        resetForNextSample()
    }

    /// Save the training sample to a JSON file for later fine-tuning
    private func saveTrainingSample() async {
        // Convert generation context to storage format
        let sampleContext: TrainingSampleContext?
        if let context = currentSentence?.context {
            sampleContext = TrainingSampleContext(
                career: context.career,
                medium: context.medium,
                recipient: context.recipient,
                tone: context.tone,
                specificTrigger: context.specificTrigger,
                randomWord: context.randomWord
            )
        } else {
            sampleContext = nil
        }

        let sample = TrainingSample(
            id: UUID().uuidString,
            timestamp: Date(),
            promptSentence: promptSentence,
            category: currentSentence?.category.id ?? "unknown",
            isPositiveExample: currentSentence?.isPositiveExample ?? true,
            expectedCleanOutput: currentSentence?.expectedCleanOutput,
            rawTranscription: rawTranscription,
            cleanedTranscription: cleanedTranscription,
            generationContext: sampleContext,
            appName: selectedAppCategory.appName,
            appBundleId: selectedAppCategory.appBundleId
        )

        await TrainingDataManager.shared.saveSample(sample)
    }

    private func resetForNextSample() {
        rawTranscription = ""
        cleanedTranscription = ""
        pipelineCleanedTranscription = ""
        pipelineOutputExpanded = false
        contextExpanded = false
        hasCapturedResults = false
        // Clear the transcription state to avoid re-capturing
        transcriptionManager.state.rawASRText = ""
        generateNewSentence()
    }

    /// Export training data to a user-selected location
    private func exportTrainingData() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "transcription_training_data.json"
        savePanel.title = String.localized("Export Training Data")
        savePanel.message = String.localized("Choose where to save the training data file")

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                Task {
                    do {
                        try await trainingDataManager.exportSamples(to: url)
                        log.info("Training data exported")
                    } catch {
                        log.error("Failed to export training data: \(error)")
                    }
                }
            }
        }
    }

    /// Show confirmation dialog before clearing
    private func showClearConfirmation() {
        showingClearConfirmation = true
    }

    /// Clear all training data
    private func clearTrainingData() {
        Task {
            await trainingDataManager.clearSamples()
        }
    }

}

// MARK: - Pulse Animation

private struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

#endif // canImport(TranscriptionCleanup)
