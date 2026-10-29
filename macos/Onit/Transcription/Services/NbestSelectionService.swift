// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NbestSelectionService.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

import Foundation

/// Service for selecting the best transcription hypothesis from N-best candidates.
/// Uses Llama 3.2 1B (improvement model) via TranscriptionLLMService for intelligent selection.
@MainActor
final class NbestSelectionService {

    // MARK: - Singleton

    static let shared = NbestSelectionService()

    // MARK: - Dependencies

    private let llmService = TranscriptionLLMService.shared

    // MARK: - Configuration

    /// System prompt for n-best selection
    private static let selectionSystemPrompt = "You are a transcription quality evaluator. Choose the most accurate and natural transcription."

    /// Timeout for selection inference in seconds
    private let selectionTimeoutSeconds: Double = 10.0

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Check if the selection service is ready (improvement model loaded)
    var isReady: Bool {
        llmService.isImprovementModelLoaded
    }

    /// Select the best hypothesis from a list of N-best candidates.
    /// If LLM is not available or fails, returns the first hypothesis (highest ASR confidence).
    /// - Parameter hypotheses: List of transcription hypotheses from beam search
    /// - Returns: The selected best hypothesis
    func selectBest(from hypotheses: [NbestHypothesis]) async throws -> NbestHypothesis {
        // Fast path: single hypothesis or empty
        guard hypotheses.count > 1 else {
            return hypotheses.first ?? NbestHypothesis(text: "", score: 0, confidence: 0)
        }

        // Fallback if LLM not loaded
        guard llmService.isImprovementModelLoaded else {
            log.info("NbestSelectionService: LLM not loaded, using first hypothesis")
            return hypotheses.first!
        }

        // Build selection prompt
        let prompt = buildSelectionPrompt(hypotheses)

        do {
            // Use improvement model for selection via TranscriptionLLMService
            let response = try await llmService.generateWithImprovementModel(
                userPrompt: prompt,
                systemPrompt: Self.selectionSystemPrompt,
                timeoutSeconds: selectionTimeoutSeconds
            )

            // Parse response to get selected index (1-based)
            if let selectedIndex = parseSelectionResponse(response, count: hypotheses.count) {
                let selected = hypotheses[selectedIndex]
                log.info("NbestSelectionService: Selected hypothesis \(selectedIndex + 1) (\(LogPrivacy.summary(selected.text)))")
                return selected
            } else {
                log.warning("NbestSelectionService: Could not parse selection (\(LogPrivacy.summary(response))), using first hypothesis")
                return hypotheses.first!
            }

        } catch {
            log.error("NbestSelectionService: Selection failed: \(error.localizedDescription), using first hypothesis")
            return hypotheses.first!
        }
    }

    // MARK: - Private Methods

    /// Build the selection prompt for the LLM
    private func buildSelectionPrompt(_ hypotheses: [NbestHypothesis]) -> String {
        var prompt = "Which transcription is most accurate and natural?\n\n"

        for (index, hypothesis) in hypotheses.enumerated() {
            prompt += "\(index + 1). \"\(hypothesis.text)\"\n"
        }

        prompt += "\nReply with ONLY the number (1-\(hypotheses.count))."
        return prompt
    }

    /// Parse the LLM response to extract the selected index
    /// - Parameters:
    ///   - response: LLM response text
    ///   - count: Number of hypotheses
    /// - Returns: 0-based index of selected hypothesis, or nil if parsing fails
    private func parseSelectionResponse(_ response: String, count: Int) -> Int? {
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract a number from the response
        let pattern = #"(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let range = Range(match.range(at: 1), in: cleaned) else {
            return nil
        }

        let numberString = String(cleaned[range])
        guard let number = Int(numberString) else { return nil }

        // Convert 1-based to 0-based index
        let index = number - 1

        // Validate index
        guard index >= 0 && index < count else { return nil }

        return index
    }
}

// MARK: - Errors

enum NbestSelectionError: LocalizedError {
    case modelNotLoaded
    case selectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "N-best selection model is not loaded"
        case .selectionFailed(let reason):
            return "Failed to select best hypothesis: \(reason)"
        }
    }
}
