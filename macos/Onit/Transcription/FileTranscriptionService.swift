// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FileTranscriptionService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-09-15.
//

import AVFoundation
import Defaults
import Foundation
import UniformTypeIdentifiers

/// Transcribes an audio file picked on the Transcripts page and saves it to history as a
/// file transcript (`TranscriptionHistory.sourceFilename`). Same text path as a
/// re-transcription: segmented ASR with the active model, then Smart Formatting. Nothing
/// is inserted or copied. Owns the job, so it keeps running when the user leaves the page.
@MainActor
final class FileTranscriptionService: ObservableObject {

    static let shared = FileTranscriptionService()

    enum Phase: Equatable {
        case idle
        /// `fraction` is nil while the file is decoded, then advances segment by segment.
        case running(filename: String, fraction: Double?)
        case failed(String)
    }

    /// Messages are resolved in `message(for:)`: `String.localized` is main-actor isolated.
    enum FileTranscriptionError: Error {
        case unreadable
        case tooLong
        case noSpeech
        case historyDisabled
    }

    /// Formats `AVAudioFile` decodes natively.
    static let supportedTypes: [UTType] = [.wav, .aiff, .mp3, .mpeg4Audio]
        + ["caf", "flac"].compactMap { UTType(filenameExtension: $0) }

    /// Bounds the job: the decoded clip is held in memory (3.84 MB of float32 per
    /// minute, two copies at peak) and saved to history as a 16-bit WAV (1.92 MB per minute).
    nonisolated static let maxDurationSeconds: Double = 30 * 60

    @Published private(set) var phase: Phase = .idle
    /// Set by `cancel()` until the job actually stops.
    @Published private(set) var isCancelling = false

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var job: Task<Void, Never>?

    private init() {}

    // MARK: - API

    func start(url: URL) {
        guard !isRunning else { return }
        // A backtest swaps the loaded model to score candidates.
        guard !CorrectionBacktestRunner.isRunning else {
            phase = .failed(String.localized("Model testing is in progress. Try again when it finishes.", table: "Transcription"))
            return
        }
        // Dictation off means the models were unloaded on purpose, and nothing would
        // unload them again after the job.
        guard Defaults[.transcriptionEnabled] else {
            phase = .failed(String.localized("Turn on dictation to transcribe audio files.", table: "App"))
            return
        }
        // One offline pipeline at a time: both drive the scorer and the prompt side channel.
        guard !TranscriptionManager.shared.isReTranscribing else {
            phase = .failed(String.localized("Another transcription is already running. Try again when it finishes.", table: "App"))
            return
        }
        guard Defaults[.transcriptionHistoryEnabled] else { return }

        let filename = url.lastPathComponent
        isCancelling = false
        phase = .running(filename: filename, fraction: nil)
        job = Task { await run(url: url, filename: filename) }
    }

    /// Stops at the next checkpoint: after decoding, between two segments, after the
    /// cleanup. An engine call or a cleanup pass in flight runs to its end.
    func cancel() {
        guard let job else { return }
        isCancelling = true
        job.cancel()
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Job

    private func run(url: URL, filename: String) async {
        defer {
            job = nil
            isCancelling = false
        }
        let manager = TranscriptionManager.shared
        log.info("[fileTranscription] START")

        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try Self.decode(url)
            }.value
            try Task.checkCancellation()
            // After decoding: `transcribeInSegments` pins the model from this point on.
            let modelId = TranscriptionConfig.shared.selectedASRModelId

            let rawText = try await manager.transcribeInSegments(samples) { fraction in
                // The last segment is not the end: cleanup and saving follow, shown
                // as an indeterminate bar rather than a frozen 100%.
                phase = .running(filename: filename, fraction: fraction < 1 ? fraction : nil)
            }
            try Task.checkCancellation()
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FileTranscriptionError.noSpeech
            }
            // Cleanup would reload the scoring model the user just unloaded.
            guard Defaults[.transcriptionEnabled] else {
                throw TranscriptionManager.ReTranscribeError.settingsChanged
            }

            let cleanup = try await manager.cleanUpOffline(
                rawText,
                inEmailComposer: false,
                precedingText: nil,
                followingText: nil,
                logTag: "fileTranscription"
            )
            try Task.checkCancellation()
            // The user may have turned history off during the job.
            guard Defaults[.transcriptionHistoryEnabled] else {
                throw FileTranscriptionError.historyDisabled
            }

            // Past the last checkpoint: the save runs in its own task, which a Cancel
            // does not reach. Interrupted between the WAV write and the insert, it would
            // leave an audio file no row points to.
            try await Task {
                try await TranscriptionHistoryManager.shared.saveTranscription(
                    rawTranscription: rawText,
                    cleanedTranscription: cleanup.text,
                    audioSamples: samples,
                    sampleRate: 16_000,
                    appName: nil,
                    appBundleId: nil,
                    cleanupMethod: cleanup.method,
                    cleanupLogEntries: cleanup.logJSON,
                    asrModel: modelId,
                    sourceFilename: filename,
                    rewriteSourceText: cleanup.rewriteSource,
                    rewriteModel: cleanup.rewriteModel
                )
            }.value
            log.info("[fileTranscription] DONE audio=\(String(format: "%.1f", Double(samples.count) / 16_000))s chars=\(cleanup.text.count)")
            phase = .idle
        } catch {
            // Some engines wrap the cancellation in their own error (WhisperKit's
            // `inferenceFailed`): a cancelled job is a cancel, whatever it threw.
            if error is CancellationError || Task.isCancelled {
                log.info("[fileTranscription] CANCELLED")
                phase = .idle
            } else {
                log.warning("[fileTranscription] FAILED: \(error)")
                phase = .failed(message(for: error))
            }
        }
    }

    /// Engine and database errors are not localized and rarely readable: they get a
    /// generic message, the detail stays in the log.
    private func message(for error: Error) -> String {
        if case .settingsChanged? = error as? TranscriptionManager.ReTranscribeError {
            return String.localized("The transcription model or dictation settings changed. Try again.", table: "App")
        }
        switch error as? FileTranscriptionError {
        case .unreadable:
            return String.localized("This file couldn't be read. Try a WAV, M4A, MP3, AIFF, CAF or FLAC file.", table: "App")
        case .tooLong:
            return String.localized("This file is longer than 30 minutes.", table: "App")
        case .noSpeech:
            return String.localized("No speech was found in this file.", table: "App")
        case .historyDisabled:
            return String.localized("File transcripts are saved to your history. Turn on “Save Transcripts to History” to use this.", table: "App")
        case nil:
            return String.localized("Couldn't transcribe this file.", table: "App")
        }
    }

    /// Checks the duration from the header before decoding the whole file.
    nonisolated private static func decode(_ url: URL) throws -> [Float] {
        let seconds: Double
        do {
            let file = try AVAudioFile(forReading: url)
            seconds = Double(file.length) / file.fileFormat.sampleRate
        } catch {
            throw FileTranscriptionError.unreadable
        }
        guard seconds <= maxDurationSeconds else { throw FileTranscriptionError.tooLong }

        let samples: [Float]
        do {
            samples = try AudioResampling.decodeFile(at: url)
        } catch {
            throw FileTranscriptionError.unreadable
        }
        guard !samples.isEmpty else { throw FileTranscriptionError.noSpeech }
        return samples
    }
}
