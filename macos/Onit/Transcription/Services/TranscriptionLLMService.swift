// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionLLMService.swift
//  Onit
//
//  Created by Kévin Naudin on 14/01/2026.
//

import Foundation
import MLXLLM
import MLXLMCommon
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

/// Service responsible for loading and running the local improvement LLM.
/// Uses MLX Swift for fast on-device inference optimized for Apple Silicon.
/// Manages Llama 3.2 1B for N-best hypothesis selection.
@MainActor
final class TranscriptionLLMService: ObservableObject {

    // MARK: - Singleton

    static let shared = TranscriptionLLMService()

    // MARK: - Model IDs

    /// Improvement model (~680MB)
    static let improvementModelId = "getonit/transcription-cleanup-llama3.2-1b"


    // MARK: - Published Properties

    /// Whether the improvement model is loaded and ready
    @Published private(set) var isImprovementModelLoaded = false

    /// Whether the improvement model is currently being downloaded/loaded
    @Published private(set) var isImprovementModelLoading = false

    /// Improvement model download/loading progress (0.0 - 1.0)
    @Published private(set) var improvementLoadingProgress: Double = 0.0

    /// Error message if improvement model loading fails
    @Published private(set) var improvementErrorMessage: String?

    // MARK: - Private Properties

    private var improvementModelContainer: ModelContainer?

    /// In-flight load task, used to coalesce concurrent `loadImprovementModel`
    /// callers so two near-simultaneous warmup triggers don't spawn duplicate
    /// HuggingFace downloads of the same checkpoint.
    private var loadingTask: Task<Void, Error>?

    /// Timeout for LLM inference in seconds
    private let inferenceTimeoutSeconds: Double = 30.0

    /// Minimum required disk space in MB (model size + buffer)
    private let diskSpaceBufferMB: Int = 500

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Awaitable load of the improvement model. Idempotent - returns
    /// immediately when the model is already loaded; concurrent callers
    /// share the in-flight load via `loadingTask`.
    ///
    /// Owned by `ImprovementLLMWarmupProvider`, which surfaces progress
    /// and errors through the shared `WarmupCoordinator` pipeline. Direct
    /// callers should generally go through the coordinator instead so the
    /// app-wide warmup status (`WarmupCoordinator.isFullyWarmedUp`, the
    /// retry surface, analytics) stays consistent.
    func loadImprovementModel() async throws {
        // Last line of defence: MLX is a hard crash on Intel (see `MLXRuntime`).
        guard MLXRuntime.isSupported else { throw MLXRuntime.UnsupportedError() }
        if isImprovementModelLoaded { return }

        // Coalesce concurrent callers onto a single in-flight load. Without
        // this, two near-simultaneous warmup triggers would spawn duplicate
        // HuggingFace downloads of the same ~680MB checkpoint.
        if let existing = loadingTask {
            try await existing.value
            return
        }

        isImprovementModelLoading = true
        improvementErrorMessage = nil
        improvementLoadingProgress = 0.0

        AnalyticsManager.TranscriptionLLM.modelLoadStarted(modelId: Self.improvementModelId)
        let loadStartedAt = Date()

        // Strong capture is intentional: this is a singleton, so `self` outlives
        // the task. `[weak self]` would create a silent "no-op success" path
        // (guard let self else { return }) that callers can't distinguish from
        // a real successful load.
        let task = Task<Void, Error> {
            let requiredSpaceMB = Self.modelSizeMB(for: Self.improvementModelId) + diskSpaceBufferMB
            let availableSpaceMB = Self.availableDiskSpaceMB()

            if availableSpaceMB < requiredSpaceMB {
                throw TranscriptionLLMError.insufficientDiskSpace(
                    required: requiredSpaceMB,
                    available: availableSpaceMB
                )
            }

            log.info("TranscriptionLLMService: Loading improvement model \(Self.improvementModelId) from HuggingFace...")
            let configuration = ModelConfiguration(id: Self.improvementModelId)

            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.improvementLoadingProgress = progress.fractionCompleted
                }
            }

            await MainActor.run {
                self.improvementModelContainer = container
                self.isImprovementModelLoaded = true
                self.improvementLoadingProgress = 1.0
            }

            log.info("TranscriptionLLMService: Improvement model loaded successfully")
        }
        loadingTask = task

        defer {
            loadingTask = nil
            isImprovementModelLoading = false
        }

        do {
            try await task.value
            let durationMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
            AnalyticsManager.TranscriptionLLM.modelLoadCompleted(
                modelId: Self.improvementModelId,
                durationMs: durationMs
            )
        } catch {
            improvementErrorMessage = "Failed to load improvement model: \(error.localizedDescription)"
            log.error("TranscriptionLLMService: Failed to load improvement model: \(error.localizedDescription)")
            // Classify so we can tell apart "user out of disk" from "network
            // failure during HuggingFace download" from everything else.
            let reason: AnalyticsManager.TranscriptionLLM.LoadFailureReason
            if case TranscriptionLLMError.insufficientDiskSpace = error {
                reason = .insufficientDiskSpace
            } else if (error as NSError).domain == NSURLErrorDomain {
                reason = .network
            } else {
                reason = .other
            }
            AnalyticsManager.TranscriptionLLM.modelLoadFailed(
                modelId: Self.improvementModelId,
                reason: reason,
                errorDescription: error.localizedDescription
            )
            throw error
        }
    }

    /// Generate text using the improvement model with custom system/user prompts.
    /// Used by NbestSelectionService for hypothesis selection.
    /// - Parameters:
    ///   - userPrompt: The user prompt to send
    ///   - systemPrompt: Optional custom system prompt (uses default improvement prompt if nil)
    ///   - timeoutSeconds: Timeout for inference (default: 10s for quick selection)
    /// - Returns: Generated text
    func generateWithImprovementModel(
        userPrompt: String,
        systemPrompt: String? = nil,
        timeoutSeconds: Double = 10.0
    ) async throws -> String {
        let raw = try await generateRaw(
            system: systemPrompt ?? Self.defaultSystemPrompt,
            user: userPrompt,
            timeoutSeconds: timeoutSeconds
        )
        return Self.cleanLLMResponse(raw)
    }

    /// System prompt when a caller doesn't pass one: the improvement prompt the
    /// model was fine-tuned on. Without the TranscriptionCleanup library (a fully
    /// open build) only N-best selection uses the model, and it passes its own.
    #if canImport(TranscriptionCleanup)
    private static let defaultSystemPrompt = LLMRefinement.improvementInstructions
    #else
    private static let defaultSystemPrompt = "Repeat the user's text, correcting only obvious transcription errors."
    #endif

    /// Raw inference core: runs the model under a timeout and returns the
    /// unparsed output. Backs both the parsed `generateWithImprovementModel`
    /// and the `RawTextInference` conformance used by the cleanup package
    /// (`TranscriptionLLMService+Cleanup.swift`).
    func generateRaw(
        system: String,
        user: String,
        timeoutSeconds: Double
    ) async throws -> String {
        guard let container = improvementModelContainer else {
            throw TranscriptionLLMError.modelNotLoaded
        }

        log.info("TranscriptionLLMService: Generating with improvement model")

        // nonisolated(unsafe) needed because ChatSession is not Sendable
        nonisolated(unsafe) let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(temperature: 0.0, topP: 0.9)
        )

        do {
            return try await withThrowingTimeout(seconds: timeoutSeconds) {
                try await session.respond(to: user)
            }
        } catch is TimeoutError {
            throw TranscriptionLLMError.inferenceTimeout(seconds: timeoutSeconds)
        }
    }


    /// Unload the model to free memory. Cancels any in-flight load so the
    /// freshly-cleared container isn't immediately re-populated by a download
    /// that was already in flight when the caller decided to unload.
    func unloadModel() {
        loadingTask?.cancel()
        loadingTask = nil
        improvementModelContainer = nil
        isImprovementModelLoaded = false
        improvementLoadingProgress = 0.0
    }

    /// Check if model needs to be loaded
    var needsLoading: Bool {
        !isImprovementModelLoaded && !isImprovementModelLoading
    }

    /// Get model size in MB for a given model ID
    static func modelSizeMB(for modelId: String) -> Int {
        switch modelId {
        case improvementModelId: return 700   // Fine-tuned Llama 3.2 1B ~680MB
        default: return 2000  // Default estimate
        }
    }

    /// Get available disk space in MB
    static func availableDiskSpaceMB() -> Int {
        do {
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int(capacity / (1024 * 1024))
            }
        } catch {
            log.warning("TranscriptionLLMService: Could not determine available disk space: \(error)")
        }
        return Int.max // Assume enough space if we can't determine
    }

    // MARK: - Private Methods

    /// Clean up LLM response by removing model-specific artifacts
    static func cleanLLMResponse(_ response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove surrounding quotes if present (some models add them)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove Llama-specific artifacts
        if cleaned.hasSuffix("<|eot_id|>") {
            cleaned = String(cleaned.dropLast("<|eot_id|>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove <output> wrapper tags
        if cleaned.hasPrefix("<output>") {
            cleaned = String(cleaned.dropFirst("<output>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasSuffix("</output>") {
            cleaned = String(cleaned.dropLast("</output>".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }
}

// MARK: - Errors

enum TranscriptionLLMError: LocalizedError {
    case modelNotLoaded
    case generationFailed(Error)
    case inferenceTimeout(seconds: Double)
    case insufficientDiskSpace(required: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "LLM model is not loaded. Please wait for initialization."
        case .generationFailed(let error):
            return "Text generation failed: \(error.localizedDescription)"
        case .inferenceTimeout(let seconds):
            return "LLM inference timed out after \(Int(seconds)) seconds."
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space. Required: \(required)MB, Available: \(available)MB"
        }
    }
}

// MARK: - Timeout Helper

/// Error thrown when an operation times out
struct TimeoutError: Error {}

/// Execute an async operation with a timeout
/// - Parameters:
///   - seconds: Maximum time to wait in seconds
///   - operation: The async operation to execute
/// - Returns: The result of the operation
/// - Throws: TimeoutError if the operation takes longer than the specified timeout
func withThrowingTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Start the actual operation
        group.addTask {
            try await operation()
        }

        // Start a timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }

        // Return the first result (either success or timeout)
        guard let result = try await group.next() else {
            throw TimeoutError()
        }

        // Cancel any remaining tasks
        group.cancelAll()

        return result
    }
}
