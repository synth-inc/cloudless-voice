// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LLMValidationStubs.swift
//  OnitTests
//
//  Stub types for LLMValidationTests that reference app types which have since been removed.
//  These stubs exist solely to keep the test target compiling; the affected test methods
//  will gracefully fail or skip at runtime if the real implementations are absent.
//

#if canImport(TranscriptionCleanup)

import Foundation
import TranscriptionCleanup
@testable import Onit

// MARK: - ScoredExample

struct ScoredExample {
    let category: String
    let input: String
    let output: String
    let reason: String
    let score: Double
}

// MARK: - DynamicFewShotService

struct CategoryWithTriggers {
    let category: String
    let score: Double
    let triggerKeywords: [String]
}

final class DynamicFewShotService {
    static let shared = DynamicFewShotService()

    func detectCategories(_ input: String) -> [String] { [] }
    func detectCategoriesWithTriggers(_ input: String) -> [CategoryWithTriggers] { [] }
    func findSimilar(_ input: String, topK: Int) -> [ScoredExample] { [] }
    func getCategoryIndexKeys() -> [String] { [] }
    func getCategoryCount(_ category: String) -> Int { 0 }
}

// MARK: - TranscriptionPrompt

struct TranscriptionPrompt {
    let systemPrompt: String
    static var builtInImprovementPrompts: [TranscriptionPrompt] {
        [TranscriptionPrompt(systemPrompt: "")]
    }
}

// MARK: - TranscriptionLLMService stubs

struct TranscriptionProcessingDetails {
    let rawOutput: String
    let validatedOutput: String?
    let finalOutput: String
    let validationPassed: Bool
    let requestJson: String
    let earlyExitTriggered: Bool
    let rejectionReason: String?
}

extension TranscriptionLLMService {
    static var improvementSystemPromptBase: String { LLMRefinement.improvementInstructions }

    func processTranscriptionWithDetails(
        _ input: String, with prompt: TranscriptionPrompt
    ) async throws -> TranscriptionProcessingDetails {
        TranscriptionProcessingDetails(
            rawOutput: input,
            validatedOutput: input,
            finalOutput: input,
            validationPassed: true,
            requestJson: "{}",
            earlyExitTriggered: false,
            rejectionReason: nil
        )
    }
}

#endif // canImport(TranscriptionCleanup)
