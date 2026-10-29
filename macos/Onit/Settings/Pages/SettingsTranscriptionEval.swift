// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsTranscriptionEval.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-02-26.
//

import AVFoundation
import Defaults
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

/// DEV-only interface for recording real audio against validated test cases.
/// Shows one test case at a time; use your normal transcription shortcut (CapsLock) to record.
struct SettingsTranscriptionEval: View {

    // MARK: - State

    @ObservedObject private var manager = EvalRecordingManager.shared
    @ObservedObject private var transcriptionManager = TranscriptionManager.shared


    @State private var selectedCategory: String? = nil
    @State private var currentIndex: Int = 0
    @State private var captured = EvalCapturedResult()
    @State private var currentAccountId: String? = nil
    @State private var audioPlayer: AVAudioPlayer? = nil
    @State private var isPlayingAudio = false

    @State private var newTagInput: String = ""
    @State private var showEasyFixInput = false
    @State private var easyFixDescription: String = ""
    @State private var isEvalActive: Bool = false
    @State private var wasEvalActiveBeforeSheet: Bool = false
    @FocusState private var isTagFieldFocused: Bool
    @State private var tagSuggestions: [String] = []

    // Sheets
    @State private var showNewSessionSheet = false
    @State private var newSessionName: String = ""
    @State private var showRetranscribeSheet = false
    @State private var retranscribeDestination: String = ""

    // MARK: - Computed

    private var filteredCases: [EvalTestCase] {
        let cases = selectedCategory.map { cat in
            manager.testCases.filter { $0.category == cat }
        } ?? manager.testCases
        return cases
    }

    private var currentCase: EvalTestCase? {
        guard !filteredCases.isEmpty else { return nil }
        return filteredCases[min(currentIndex, filteredCases.count - 1)]
    }

    private var isRecording: Bool {
        transcriptionManager.state.isActive
    }

    private var isProcessing: Bool {
        transcriptionManager.state.isProcessing
    }

    private var isRecorded: Bool {
        guard let c = currentCase else { return false }
        return manager.recordedIndices.contains(c.index)
    }

    private var shortcutSymbol: String {
        Defaults[TranscriptionConfigKeys.shortcutType].displayNameSymbol
    }


    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EvalSessionBar(
                manager: manager,
                isEvalActive: $isEvalActive,
                showNewSessionSheet: $showNewSessionSheet,
                onRetranscribe: {
                    retranscribeDestination = "\(manager.currentSession)-deepfilter"
                    showRetranscribeSheet = true
                },
                onClearResults: clearResults
            )
            Divider()
            if let progress = manager.retranscribeProgress {
                retranscribeBanner(progress)
                Divider()
            }
            EvalFilterBar(
                manager: manager,
                selectedCategory: $selectedCategory,
                currentCase: currentCase,
                onApplyTag: applyTag
            )
            Divider()
            if manager.isLoading {
                centeredMessage {
                    ProgressView()
                    Text("Loading test cases…").styleText(size: 13, color: Color.T_2)
                }
            } else if let error = manager.loadError {
                errorView(error)
            } else if filteredCases.isEmpty {
                centeredMessage {
                    Text("No test cases.").styleText(size: 13, color: Color.T_2)
                }
            } else {
                mainContent
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isTagFieldFocused = false }
        .sheet(isPresented: $showEasyFixInput) {
            if let testCase = currentCase {
                easyFixSheet(for: testCase)
            }
        }
        .onAppear {
            let account = AuthManager.shared.account
            let accountId = account.map { "\($0.id)" }
            currentAccountId = accountId
            manager.load(accountId: accountId, accountEmail: account?.email)
        }
        .onChange(of: transcriptionManager.state.isProcessing) { _, isNowProcessing in
            guard isEvalActive else { return }
            guard !isNowProcessing, !captured.hasResults else { return }
            captured.raw = transcriptionManager.state.rawASRText
            captured.cleaned = transcriptionManager.state.insertedText
            if let samples = transcriptionManager.state.recordedAudioSamples, !samples.isEmpty,
               let idx = currentCase?.index {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("eval_preview_\(idx).m4a")
                captured.isExportingAudio = true
                Task {
                    await EvalAudioExporter.export(samples: samples, sampleRate: 16000, to: url)
                    captured.audioURL = url
                    captured.isExportingAudio = false
                }
            }
        }
        .onChange(of: transcriptionManager.state.isActive) { _, isNowActive in
            guard isEvalActive else { return }
            if isNowActive {
                captured.clear()
                isTagFieldFocused = false
            }
        }
        .onChange(of: showEasyFixInput) { _, isShowing in
            if isShowing {
                wasEvalActiveBeforeSheet = isEvalActive
                isEvalActive = false
            } else {
                isEvalActive = wasEvalActiveBeforeSheet
            }
        }
        .onChange(of: manager.isLoading) { _, isLoading in
            if !isLoading {
                advanceToFirstUnrecorded()
                isEvalActive = true
            }
        }
        .onChange(of: selectedCategory) { _, _ in
            advanceToFirstUnrecorded()
            clearResults()
        }
        .onChange(of: manager.currentSession) { _, _ in
            advanceToFirstUnrecorded()
            clearResults()
        }
        .sheet(isPresented: $showNewSessionSheet) {
            newSessionSheet
        }
        .sheet(isPresented: $showRetranscribeSheet) {
            retranscribeSheet
        }
    }

    // MARK: - Sheets

    private var newSessionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .styleText(size: 15, weight: .semibold)

            Text("Give this recording session a descriptive name, e.g. \"built-in-quiet\" or \"airpods-fan\".")
                .styleText(size: 12, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Session name", text: $newSessionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewSession() }

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewSessionSheet = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Create") {
                    commitNewSession()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(newSessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var retranscribeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Re-transcribe Session")
                .styleText(size: 15, weight: .semibold)

            Text("Run every recorded audio file in \"\(manager.currentSession)\" through the current transcription pipeline and save results as a new session. Enable Denoise in Transcription Settings to apply DeepFilterNet3.")
                .styleText(size: 12, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Text("Source:")
                    .styleText(size: 12, color: Color.T_3)
                Text(manager.currentSession)
                    .styleText(size: 12, weight: .semibold)
            }

            TextField("Destination session name", text: $retranscribeDestination)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showRetranscribeSheet = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Re-transcribe") {
                    let dest = retranscribeDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dest.isEmpty else { return }
                    let source = manager.currentSession
                    showRetranscribeSheet = false
                    Task { await manager.retranscribeSession(source: source, destination: dest) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(retranscribeDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func retranscribeBanner(_ progress: EvalRecordingManager.RetranscribeProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Re-transcribing \(progress.current) / \(progress.total)…")
                .styleText(size: 12, color: Color.T_2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.T_6)
    }

    private func commitNewSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        manager.createSession(name)
        showNewSessionSheet = false
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                navigationBar
                if let testCase = currentCase {
                    EvalPromptCard(
                        manager: manager,
                        testCase: testCase,
                        isRecorded: isRecorded,
                        newTagInput: $newTagInput,
                        isTagFieldFocused: $isTagFieldFocused,
                        tagSuggestions: $tagSuggestions,
                        onShowEasyFix: { showEasyFixForCurrentCase() },
                        onApplyTag: applyTag
                    )
                    recordingArea
                    if captured.hasResults {
                        EvalResultsSection(
                            manager: manager,
                            testCase: testCase,
                            captured: captured,
                            isPlayingAudio: $isPlayingAudio,
                            audioPlayer: $audioPlayer,
                            onShowEasyFix: { showEasyFixForCurrentCase() },
                            onTogglePlayback: togglePlayback
                        )
                    }
                    EvalActionButtons(
                        testCase: testCase,
                        hasCapturedResults: captured.hasResults,
                        isRecorded: isRecorded,
                        onClearRetry: {
                            if isRecorded { manager.deleteRecording(for: testCase) }
                            clearResults()
                        },
                        onSaveAndAdvance: { saveAndAdvance(testCase) }
                    )
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button {
                navigate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.T_6)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Spacer()

            VStack(spacing: 2) {
                Text("\(currentIndex + 1) / \(filteredCases.count)")
                    .styleText(size: 13, weight: .semibold)
                let rec = manager.recordedCount(for: selectedCategory)
                let tot = manager.totalCount(for: selectedCategory)
                Text("\(rec) of \(tot) recorded")
                    .styleText(size: 10, color: Color.T_3)
            }

            Spacer()

            Button {
                navigate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(Color.T_6)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= filteredCases.count - 1)
        }
    }

    // MARK: - Recording Area

    private var recordingArea: some View {
        SettingsPageSection {
            VStack(alignment: .leading, spacing: 10) {
                if isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .modifier(EvalPulseAnimation())
                        Text("Recording… speak the text above")
                            .styleText(size: 12, weight: .medium, color: Color.red)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                } else if isProcessing {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.75)
                        Text("Processing…")
                            .styleText(size: 12, color: Color.T_2)
                    }
                    .padding(10)
                    .background(Color.T_6)
                    .cornerRadius(8)
                } else if !captured.hasResults {
                    if isRecorded {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.green)
                            (Text("Already recorded - hold ") + Text(shortcutSymbol).bold() + Text(" to re-record"))
                                .styleText(size: 12, color: Color.T_2)
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(8)
                    } else {
                        (Text("Hold ") + Text(shortcutSymbol).bold() + Text(" to record"))
                            .styleText(size: 12, color: Color.T_2)
                    }
                }
            }
        }
    }

    // MARK: - Easy Fix Sheet

    private func showEasyFixForCurrentCase() {
        guard let testCase = currentCase else { return }
        easyFixDescription = manager.easyFixes[testCase.index]?.description ?? ""
        showEasyFixInput = true
    }

    private func easyFixSheet(for testCase: EvalTestCase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.adjustable.fill")
                        .foregroundColor(.orange)
                    Text("Easy Fix")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                if manager.easyFixes[testCase.index] != nil {
                    Button {
                        manager.removeEasyFix(for: testCase.index)
                        showEasyFixInput = false
                        easyFixDescription = ""
                    } label: {
                        Text("Remove Flag")
                            .styleText(size: 12, color: Color.T_3)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Input")
                    .styleText(size: 11, weight: .semibold, color: Color.T_3)
                Text(testCase.input)
                    .styleText(size: 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.T_6)
            .cornerRadius(8)

            easyFixTranscriptionPreview(for: testCase)

            VStack(alignment: .leading, spacing: 6) {
                Text("What's wrong with this case?")
                    .styleText(size: 11, weight: .semibold, color: Color.T_3)
                TextEditor(text: $easyFixDescription)
                    .font(.system(size: 13))
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.T_6)
                    .cornerRadius(8)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    showEasyFixInput = false
                    easyFixDescription = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(Color.T_2)

                Spacer()

                Button {
                    saveEasyFix(for: testCase)
                } label: {
                    Text("Save")
                        .styleText(size: 13, weight: .semibold, color: .white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.orange)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }

    @ViewBuilder
    private func easyFixTranscriptionPreview(for testCase: EvalTestCase) -> some View {
        let rawSTTToShow = captured.hasResults ? captured.raw
            : manager.easyFixes[testCase.index]?.rawSTT
        let cleanedToShow = captured.hasResults ? captured.cleaned
            : manager.easyFixes[testCase.index]?.cleanedText

        if rawSTTToShow != nil || cleanedToShow != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let raw = rawSTTToShow, !raw.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STT Output")
                            .styleText(size: 11, weight: .semibold, color: Color.T_3)
                        Text(raw)
                            .styleText(size: 13)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if let cleaned = cleanedToShow, !cleaned.isEmpty, cleaned != rawSTTToShow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("After Cleanup")
                            .styleText(size: 11, weight: .semibold, color: Color.T_3)
                        Text(cleaned)
                            .styleText(size: 13)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .background(Color.T_6)
            .cornerRadius(8)
        }
    }

    private func saveEasyFix(for testCase: EvalTestCase) {
        let fix = EasyFix(
            index: testCase.index,
            input: testCase.input,
            expected: testCase.expected,
            category: testCase.category,
            description: easyFixDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            flaggedAt: Date(),
            rawSTT: captured.hasResults ? captured.raw : nil,
            cleanedText: captured.hasResults ? captured.cleaned : nil
        )
        manager.flagEasyFix(fix, audioURL: captured.audioURL)
        showEasyFixInput = false
        easyFixDescription = ""
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            Text("Could not find validated_pairs.jsonl")
                .styleText(size: 14, weight: .semibold)

            if !manager.triedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paths tried:")
                        .styleText(size: 11, weight: .semibold, color: Color.T_2)
                    ForEach(manager.triedPaths, id: \.self) { path in
                        Text(path)
                            .styleText(size: 10, color: Color.T_3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .background(Color.T_6)
                .cornerRadius(8)
            }

            Button {
                manager.chooseDataFile(accountId: currentAccountId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose validated_pairs.jsonl…")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .styleText(size: 13, weight: .medium, color: .white)
                .background(Color.blue)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func centeredMessage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyTag(_ tag: String, to testCase: EvalTestCase) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.addTag(trimmed, to: testCase.index)
        newTagInput = ""
        tagSuggestions = []
        isTagFieldFocused = false
    }

    private func advanceToFirstUnrecorded() {
        let firstUnrecorded = filteredCases.firstIndex { !manager.recordedIndices.contains($0.index) }
        currentIndex = firstUnrecorded ?? 0
    }

    private func navigate(by delta: Int) {
        let newIndex = currentIndex + delta
        guard newIndex >= 0, newIndex < filteredCases.count else { return }
        currentIndex = newIndex
        clearResults()
        showEasyFixInput = false
        easyFixDescription = ""
    }

    private func clearResults() {
        captured.clear()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingAudio = false
    }

    private func togglePlayback() {
        if isPlayingAudio {
            audioPlayer?.stop()
            isPlayingAudio = false
            return
        }
        guard let url = captured.audioURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = EvalAudioPlayerDelegate.shared
            audioPlayer = player
            player.play()
            isPlayingAudio = true
            EvalAudioPlayerDelegate.shared.onFinish = { [self] in
                isPlayingAudio = false
            }
        } catch {
            print("SettingsTranscriptionEval: audio playback failed: \(error)")
        }
    }

    private func saveAndAdvance(_ testCase: EvalTestCase) {
        guard captured.hasResults else { return }

        let rawSTT = captured.raw
        let cleaned = captured.cleaned

        if let samples = transcriptionManager.state.recordedAudioSamples, !samples.isEmpty {
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("eval_\(testCase.index).m4a")
            Task {
                await EvalAudioExporter.export(samples: samples, sampleRate: 16000, to: outURL)
                EvalRecordingManager.shared.saveRecording(
                    for: testCase, audioURL: outURL, rawSTT: rawSTT, cleanedTranscript: cleaned
                )
            }
        } else {
            let tempURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("recording.m4a")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                manager.saveRecording(
                    for: testCase, audioURL: tempURL, rawSTT: rawSTT, cleanedTranscript: cleaned
                )
            }
        }

        clearResults()
        if currentIndex < filteredCases.count - 1 {
            currentIndex += 1
        }
    }
}

// MARK: - Audio Exporter

enum EvalAudioExporter {
    static func export(samples: [Float], sampleRate: Double, to url: URL) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try writeM4A(samples: samples, sampleRate: sampleRate, to: url) }
                catch { print("EvalAudioExporter: \(error)") }
                continuation.resume()
            }
        }
    }

    private static func writeM4A(samples: [Float], sampleRate: Double, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buffer.frameLength = count
        let channelData = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() { channelData[i] = s }
        try file.write(from: buffer)
    }
}

// MARK: - AVAudioPlayer Delegate

/// Delegate to detect audio playback completion instead of using Task.sleep.
private final class EvalAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    static let shared = EvalAudioPlayerDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            onFinish?()
        }
    }
}
