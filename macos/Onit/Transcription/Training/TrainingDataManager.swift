// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TrainingDataManager.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-02-04.
//

import Foundation

/// Generation context metadata - describes how the sentence was generated
struct TrainingSampleContext: Codable {
    /// The career/profession used for context (e.g., "dentist", "software engineer")
    let career: String?

    /// The communication medium (e.g., "dictating an email", "leaving a voice memo")
    let medium: String?

    /// The recipient relationship (e.g., "to their assistant", "to a client")
    let recipient: String?

    /// The tone/urgency context (e.g., "in a hurry before a meeting")
    let tone: String?

    /// The specific trigger word/phrase required (e.g., "erm", "gonna")
    let specificTrigger: String?

    /// Random word from dictionary that was required in the sentence
    let randomWord: String?
}

/// A single training sample for transcription cleanup fine-tuning
struct TrainingSample: Codable, Identifiable {
    let id: String
    let timestamp: Date

    /// The prompt sentence the user was asked to speak
    let promptSentence: String

    /// The cleanup rule category being tested
    let category: String

    /// Whether this is a positive example (should be cleaned) or negative (should be preserved)
    let isPositiveExample: Bool

    /// The expected clean output for reference (from the category examples)
    let expectedCleanOutput: String?

    /// Raw transcription directly from ASR
    let rawTranscription: String

    /// Cleaned transcription after running through the LLM pipeline
    let cleanedTranscription: String

    /// Generation context metadata (how the sentence was generated)
    let generationContext: TrainingSampleContext?

    /// Name of the simulated app context (e.g., "Terminal", "Visual Studio Code")
    let appName: String?

    /// Bundle ID of the simulated app context (e.g., "com.apple.Terminal")
    let appBundleId: String?
}

/// Manager for saving and loading training data samples
@MainActor
final class TrainingDataManager: ObservableObject {

    // MARK: - Singleton

    static let shared = TrainingDataManager()

    // MARK: - Published Properties

    @Published private(set) var sampleCount: Int = 0
    @Published private(set) var lastSaveError: String?

    // MARK: - Private Properties

    /// Directory for storing training data
    private var trainingDataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let onitDir = appSupport.appendingPathComponent("Onit", isDirectory: true)
        return onitDir.appendingPathComponent("TrainingData", isDirectory: true)
    }

    /// Path to the current training samples file
    private var samplesFilePath: URL {
        trainingDataDirectory.appendingPathComponent("training_samples.jsonl")
    }

    // MARK: - Initialization

    private init() {
        ensureDirectoryExists()
        loadSampleCount()
    }

    // MARK: - Public Methods

    /// Save a training sample to the JSONL file
    func saveSample(_ sample: TrainingSample) async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(sample)

            guard var jsonString = String(data: jsonData, encoding: .utf8) else {
                throw TrainingDataError.encodingFailed
            }

            // Append newline for JSONL format
            jsonString += "\n"

            // Append to file
            if FileManager.default.fileExists(atPath: samplesFilePath.path) {
                let fileHandle = try FileHandle(forWritingTo: samplesFilePath)
                fileHandle.seekToEndOfFile()
                if let data = jsonString.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try jsonString.write(to: samplesFilePath, atomically: true, encoding: .utf8)
            }

            sampleCount += 1
            lastSaveError = nil

            log.info("TrainingDataManager: Saved sample \(sample.id) (total: \(sampleCount))")

        } catch {
            lastSaveError = error.localizedDescription
            log.error("TrainingDataManager: Failed to save sample: \(error)")
        }
    }

    /// Load all training samples from the file
    func loadSamples() async -> [TrainingSample] {
        guard FileManager.default.fileExists(atPath: samplesFilePath.path) else {
            return []
        }

        do {
            let content = try String(contentsOf: samplesFilePath, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var samples: [TrainingSample] = []
            for line in lines {
                if let data = line.data(using: .utf8) {
                    if let sample = try? decoder.decode(TrainingSample.self, from: data) {
                        samples.append(sample)
                    }
                }
            }

            return samples

        } catch {
            log.error("TrainingDataManager: Failed to load samples: \(error)")
            return []
        }
    }

    /// Export samples to a specified location
    func exportSamples(to destination: URL) async throws {
        let samples = await loadSamples()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(samples)
        try data.write(to: destination)

        log.info("TrainingDataManager: Exported \(samples.count) samples")
    }

    /// Clear all training samples
    func clearSamples() async {
        do {
            if FileManager.default.fileExists(atPath: samplesFilePath.path) {
                try FileManager.default.removeItem(at: samplesFilePath)
            }
            sampleCount = 0
            log.info("TrainingDataManager: Cleared all samples")
        } catch {
            log.error("TrainingDataManager: Failed to clear samples: \(error)")
        }
    }

    /// Get the path to the training data file
    func getDataFilePath() -> URL {
        return samplesFilePath
    }

    // MARK: - Private Methods

    private func ensureDirectoryExists() {
        do {
            try FileManager.default.createDirectory(
                at: trainingDataDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            log.error("TrainingDataManager: Failed to create directory: \(error)")
        }
    }

    private func loadSampleCount() {
        guard FileManager.default.fileExists(atPath: samplesFilePath.path) else {
            sampleCount = 0
            return
        }

        do {
            let content = try String(contentsOf: samplesFilePath, encoding: .utf8)
            sampleCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        } catch {
            sampleCount = 0
        }
    }
}

// MARK: - Errors

enum TrainingDataError: LocalizedError {
    case encodingFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode training sample"
        case .writeFailed(let message):
            return "Failed to write training data: \(message)"
        }
    }
}
