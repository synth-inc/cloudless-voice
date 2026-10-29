// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TrainingSentenceGenerator.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-02-04.
//

#if canImport(TranscriptionCleanup)

import Foundation
import Defaults
import TranscriptionCleanup


/// Service for generating training sentences using LLM
@MainActor
final class TrainingSentenceGenerator: ObservableObject {

    // MARK: - Singleton

    static let shared = TrainingSentenceGenerator()

    // MARK: - Constants

    /// Number of sentences to keep pre-generated in the queue
    private static let queueSize = 3

    // MARK: - Published Properties

    @Published var isGenerating: Bool = false
    @Published var lastError: String?
    @Published var lastGenerationSource: String = ""  // "llm" or "static" - for debugging
    @Published var queueCount: Int = 0  // For UI display

    // MARK: - Queue

    /// Pre-generated sentences ready to use
    private var sentenceQueue: [GeneratedSentence] = []

    /// Whether we're currently filling the queue
    private var isFillingQueue: Bool = false

    // MARK: - Cleanup Rule Categories


    // MARK: - Sentence Generation

    /// Context details about how a sentence was generated
    struct GenerationContext {
        let career: String
        let medium: String
        let recipient: String
        let tone: String
        let specificTrigger: String?
        let randomWord: String
    }

    /// Result of sentence generation
    struct GeneratedSentence {
        let sentence: String
        let category: CleanupRuleCategory
        let isPositiveExample: Bool
        let expectedCleanOutput: String
        let context: GenerationContext?
    }

    /// Start pre-generating sentences to fill the queue
    func startPreGenerating() {
        Task {
            await fillQueue()
        }
    }

    /// Get the next training sentence from the queue, or generate one if queue is empty
    /// - Returns: A GeneratedSentence with the prompt, category, and expected output
    func generateTrainingSentence() async throws -> GeneratedSentence {
        // If we have a queued sentence, return it immediately
        if !sentenceQueue.isEmpty {
            let sentence = sentenceQueue.removeFirst()
            queueCount = sentenceQueue.count
            log.info("TrainingSentenceGenerator: Using queued sentence (\(sentenceQueue.count) remaining in queue)")

            // Trigger background generation to refill the queue
            Task {
                await fillQueue()
            }

            return sentence
        }

        // Queue is empty, generate one directly (with loading state)
        log.info("TrainingSentenceGenerator: Queue empty, generating directly...")
        let sentence = try await generateSingleSentence()

        // Also start filling the queue in background
        Task {
            await fillQueue()
        }

        return sentence
    }

    /// Fill the queue up to the target size
    private func fillQueue() async {
        // Prevent multiple concurrent fill operations
        guard !isFillingQueue else { return }
        isFillingQueue = true

        defer { isFillingQueue = false }

        while sentenceQueue.count < Self.queueSize {
            do {
                let sentence = try await generateSingleSentence()
                sentenceQueue.append(sentence)
                queueCount = sentenceQueue.count
                log.info("TrainingSentenceGenerator: Added to queue (now \(sentenceQueue.count)/\(Self.queueSize))")
            } catch {
                log.error("TrainingSentenceGenerator: Failed to fill queue: \(error)")
                // Don't keep retrying on errors
                break
            }
        }
    }

    /// Generate a single sentence (internal method)
    private func generateSingleSentence() async throws -> GeneratedSentence {
        isGenerating = true
        lastError = nil

        defer { isGenerating = false }

        // 1. Randomly select a category
        guard let category = CleanupTrainingData.categories.randomElement() else {
            throw TrainingGeneratorError.noCategories
        }

        // 2. Randomly decide positive (70%) or negative (30%) example
        let isPositive = Double.random(in: 0...1) < 0.7

        // 3. Get example patterns for this category
        let examples = isPositive ? category.positiveExamples : category.negativeExamples
        guard let examplePattern = examples.randomElement() else {
            // Fallback to positive if no negative examples
            guard let fallbackExample = category.positiveExamples.randomElement() else {
                throw TrainingGeneratorError.noExamples
            }
            return try await generateWithLLM(
                category: category,
                examplePattern: fallbackExample,
                isPositive: true
            )
        }

        // 4. Generate a sentence using the LLM
        return try await generateWithLLM(
            category: category,
            examplePattern: examplePattern,
            isPositive: isPositive
        )
    }

    // MARK: - Remote API Configuration

    /// Model to use for sentence generation via Onit server
    private static let generationModel = AIModel(
        id: "claude-sonnet-4-5-20250929",
        displayName: "Claude Sonnet 4.5",
        provider: .anthropic,
        defaultOn: false,
        supportsVision: false,
        supportsSystemPrompts: true,
        supportsToolCalling: false
    )

    /// Generate a sentence using remote LLM via Onit server
    private func generateWithLLM(
        category: CleanupRuleCategory,
        examplePattern: (input: String, output: String),
        isPositive: Bool
    ) async throws -> GeneratedSentence {
        // Build the prompt for the LLM (we do this first to get context for display even if auth fails)
        let (systemPrompt, userPrompt, generationContext) = buildGenerationPromptWithParsing(
            category: category,
            examplePattern: examplePattern,
            isPositive: isPositive
        )

        // Check if user is authenticated (has token for Onit server)
        guard TokenManager.token != nil else {
            log.warning("TrainingSentenceGenerator: ❌ Not authenticated, falling back to static example")
            lastGenerationSource = "static (not authenticated)"
            return GeneratedSentence(
                sentence: examplePattern.input,
                category: category,
                isPositiveExample: isPositive,
                expectedCleanOutput: examplePattern.output,
                context: generationContext
            )
        }

        log.info("TrainingSentenceGenerator: Generating sentence for category '\(category.name)' (positive: \(isPositive)) via Onit server")

        do {
            // Use StreamingClient to call Onit server
            let streamingClient = StreamingClient()
            var fullResponse = ""

            let stream = try await streamingClient.chat(
                systemMessage: systemPrompt,
                instructions: [userPrompt],
                inputs: [nil],
                files: [[]],
                images: [[]],
                autoContexts: [[:]],
                webSearchContexts: [[]],
                responses: [],
                tools: [],
                useOnitServer: true,  // Use Onit server (handles API tokens)
                model: Self.generationModel,
                apiToken: nil,  // Onit server handles auth
                includeSearch: nil,
                featureType: "training_data_generation"
            )

            for try await response in stream {
                if let content = response.content {
                    fullResponse += content
                }
            }

            if fullResponse.isEmpty {
                throw TrainingGeneratorError.llmFailed("Empty response from server")
            }

            // Parse the response to extract sentence and expected output
            let (sentence, expectedOutput) = parseGeneratedResponse(fullResponse, isPositive: isPositive)

            let wordCount = sentence.split(separator: " ").count
            log.info("TrainingSentenceGenerator: ✅ LLM Generated (\(wordCount) words) - Sentence: \(LogPrivacy.summary(sentence))")
            log.info("TrainingSentenceGenerator: ✅ Expected clean: \(LogPrivacy.summary(expectedOutput))")
            lastGenerationSource = "llm (\(wordCount) words)"

            return GeneratedSentence(
                sentence: sentence,
                category: category,
                isPositiveExample: isPositive,
                expectedCleanOutput: expectedOutput,
                context: generationContext
            )

        } catch {
            log.error("TrainingSentenceGenerator: ❌ Remote LLM generation failed: \(error)")
            lastError = error.localizedDescription
            lastGenerationSource = "static (llm failed: \(error.localizedDescription.prefix(50)))"

            // Fall back to static example on error
            return GeneratedSentence(
                sentence: examplePattern.input,
                category: category,
                isPositiveExample: isPositive,
                expectedCleanOutput: examplePattern.output,
                context: generationContext
            )
        }
    }

    /// Parse the LLM response to extract sentence and expected clean output
    private func parseGeneratedResponse(_ response: String, isPositive: Bool) -> (sentence: String, expectedOutput: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse XML-style tags first
        if let rawMatch = trimmed.range(of: "<raw>(.*?)</raw>", options: .regularExpression),
           let cleanMatch = trimmed.range(of: "<clean>(.*?)</clean>", options: .regularExpression) {

            var rawContent = String(trimmed[rawMatch])
            rawContent = rawContent.replacingOccurrences(of: "<raw>", with: "")
            rawContent = rawContent.replacingOccurrences(of: "</raw>", with: "")

            var cleanContent = String(trimmed[cleanMatch])
            cleanContent = cleanContent.replacingOccurrences(of: "<clean>", with: "")
            cleanContent = cleanContent.replacingOccurrences(of: "</clean>", with: "")

            return (rawContent.trimmingCharacters(in: .whitespacesAndNewlines),
                    cleanContent.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Try line-based parsing (Raw: ... / Clean: ...)
        let lines = trimmed.components(separatedBy: "\n")
        var rawSentence: String?
        var cleanSentence: String?

        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("raw:") || lowercased.hasPrefix("sentence:") || lowercased.hasPrefix("input:") {
                rawSentence = String(line.dropFirst(line.firstIndex(of: ":")!.utf16Offset(in: line) + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if lowercased.hasPrefix("clean:") || lowercased.hasPrefix("cleaned:") || lowercased.hasPrefix("expected:") || lowercased.hasPrefix("output:") {
                cleanSentence = String(line.dropFirst(line.firstIndex(of: ":")!.utf16Offset(in: line) + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        if let raw = rawSentence, let clean = cleanSentence {
            return (raw, clean)
        }

        // Fallback: treat the whole response as the sentence
        // For negative examples, cleaned = raw (no change expected)
        if isPositive {
            // Can't determine expected output, return same as input
            return (trimmed, trimmed)
        } else {
            // Negative example: output should equal input
            return (trimmed, trimmed)
        }
    }

    // MARK: - Variety Data for Prompts

    /// 50 careers/professions for context variety
    private static let careers = [
        "software engineer", "product manager", "dentist", "nurse", "lawyer",
        "accountant", "real estate agent", "teacher", "professor", "doctor",
        "veterinarian", "architect", "graphic designer", "marketing manager", "sales representative",
        "financial analyst", "HR manager", "data scientist", "project manager", "CEO",
        "consultant", "therapist", "pharmacist", "journalist", "photographer",
        "chef", "restaurant manager", "event planner", "interior designer", "civil engineer",
        "mechanical engineer", "electrician", "plumber", "contractor", "insurance agent",
        "recruiter", "social worker", "physical therapist", "chiropractor", "optometrist",
        "pilot", "air traffic controller", "logistics coordinator", "supply chain manager", "quality assurance engineer",
        "UX designer", "content writer", "video editor", "music producer", "fitness trainer"
    ]

    /// Communication mediums
    private static let mediums = [
        "dictating an email",
        "composing a Slack message",
        "leaving a voice memo",
        "dictating meeting notes",
        "writing a text message",
        "drafting a report",
        "creating a to-do item",
        "dictating a calendar invite description",
        "writing a code review comment",
        "composing a LinkedIn message",
        "dictating patient/client notes",
        "writing a project update",
        "composing a support ticket response"
    ]

    /// Recipient relationships
    private static let recipients = [
        "to their boss",
        "to a colleague",
        "to their team",
        "to a client",
        "to a patient",
        "to a vendor",
        "to their assistant",
        "to a direct report",
        "to a customer",
        "to a partner",
        "to their mentor",
        "to a contractor",
        "to a student"
    ]

    /// Urgency/tone contexts
    private static let tones = [
        "in a hurry before a meeting",
        "carefully and thoughtfully",
        "casually between tasks",
        "while multitasking",
        "urgently about a deadline",
        "professionally for an important matter",
        "informally to someone they know well",
        "while walking to their next appointment"
    ]

    /// Specific trigger words/phrases for each category type
    private static let specificTriggers: [String: [String]] = [
        "filler_words": ["um", "uh", "er", "erm", "ah", "like", "you know", "basically", "I mean", "sort of", "kind of", "actually", "honestly", "literally", "so"],
        "stutters": ["I I", "the the", "we we", "can can", "it's it's", "and and", "to to", "a a", "that that"],
        "self_corrections": ["wait no", "I mean", "sorry", "actually no", "no wait", "let me rephrase", "or rather"],
        "numbers": ["forty two", "twenty five", "one hundred", "three hundred", "ninety nine", "fifteen", "sixty", "seventy five", "eighty", "twelve"],
        "acronyms": ["A P I", "U R L", "H T M L", "C S S", "P D F", "C E O", "C F O", "V P", "A S A P", "F Y I", "E T A"],
        "email_url": ["at gmail dot com", "at company dot com", "dot io", "dot org", "slash", "colon slash slash"],
        "currency": ["fifty dollars", "twenty dollars", "one hundred dollars", "five hundred dollars", "ninety nine cents", "two fifty", "seventy five dollars"],
        "time_date": ["three thirty", "four fifteen", "ten AM", "two PM", "noon", "midnight", "January fifteenth", "March twenty third"],
        "special_characters": ["underscore", "hashtag", "ampersand", "asterisk", "at sign", "percent"],
        "punctuation": ["period", "comma", "question mark", "exclamation point", "colon", "semicolon"],
        "ordinals": ["first", "second", "third", "fourth", "fifth", "twenty first", "thirty second"],
        "informal_contractions": ["gonna", "wanna", "gotta", "kinda", "sorta", "lemme", "gimme", "dunno", "coulda", "shoulda", "woulda"]
    ]

    /// Cached random words loaded from frequency list
    private static var _cachedRandomWords: [String]?

    /// Get random words from the bundled frequency list (eng_news_2024_100K-words.txt)
    /// Filters to recognizable lowercase words, skipping the most common ones
    private static var randomWords: [String] {
        if let cached = _cachedRandomWords {
            return cached
        }

        // Load from bundled frequency list
        guard let url = Bundle.main.url(forResource: "eng_news_2024_100K-words", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            log.warning("TrainingSentenceGenerator: Could not load frequency word list, using fallback")
            _cachedRandomWords = fallbackRandomWords
            return fallbackRandomWords
        }

        // Parse tab-separated format: rank\tword\tfrequency
        // Filter to useful words: lowercase, alphabetic, 4+ chars, skip top 500 most common
        var lineIndex = 0
        let words = content.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                lineIndex += 1
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { return nil }
                let word = parts[1]

                // Skip top ~500 lines (most common words like "the", "and", etc.)
                guard lineIndex > 500 else { return nil }

                let length = word.count
                // Keep: lowercase, alphabetic only, 4-15 chars
                return length >= 4 && length <= 15 &&
                       word == word.lowercased() &&
                       word.allSatisfy { $0.isLetter } ? word : nil
            }

        log.info("TrainingSentenceGenerator: Loaded \(words.count) words from frequency list")
        _cachedRandomWords = words
        return words
    }

    /// Fallback words if frequency list is unavailable
    private static let fallbackRandomWords = [
        "umbrella", "keyboard", "elephant", "telescope", "butterfly", "strawberry", "pineapple",
        "volcano", "hurricane", "tornado", "meadow", "harmony", "paradox", "spectrum",
        "whisper", "stumble", "flourish", "shimmer", "sparkle", "wander", "flutter",
        "magnificent", "peculiar", "whimsical", "meticulous", "mysterious", "ambitious",
        "suddenly", "carefully", "extremely", "occasionally", "frequently", "gradually",
        "cinnamon", "avocado", "broccoli", "espresso", "croissant", "cucumber", "grapefruit",
        "penguin", "giraffe", "kangaroo", "octopus", "dolphin", "flamingo", "hedgehog",
        "algorithm", "dashboard", "interface", "network", "cathedral", "warehouse", "aquarium"
    ]

    /// Build the system and user prompts for LLM sentence generation
    /// Returns the prompts and the generation context for display
    private func buildGenerationPromptWithParsing(
        category: CleanupRuleCategory,
        examplePattern: (input: String, output: String),
        isPositive: Bool
    ) -> (systemPrompt: String, userPrompt: String, context: GenerationContext) {
        // Randomly select context elements
        let career = Self.careers.randomElement() ?? "professional"
        let medium = Self.mediums.randomElement() ?? "dictating a message"
        let recipient = Self.recipients.randomElement() ?? "to a colleague"
        let tone = Self.tones.randomElement() ?? "normally"

        // Get a specific trigger word for this category
        let specificTrigger = Self.specificTriggers[category.id]?.randomElement()

        // Get a random word to force variety
        let randomWord = Self.randomWords.randomElement() ?? "umbrella"

        // Create context for display
        let generationContext = GenerationContext(
            career: career,
            medium: medium,
            recipient: recipient,
            tone: tone,
            specificTrigger: specificTrigger,
            randomWord: randomWord
        )

        let contextDescription = "A \(career) is \(medium) \(recipient), \(tone)"

        let systemPrompt = """
            You generate highly varied training data for a transcription cleanup model.

            CRITICAL REQUIREMENTS:
            1. Length: 8-20 words
            2. Be CREATIVE and VARIED - never repeat patterns
            3. Use realistic workplace vocabulary for the given profession
            4. Make it sound like natural, spontaneous speech

            RESPONSE FORMAT (strictly follow this):
            <raw>The sentence as someone would naturally speak it, including speech patterns</raw>
            <clean>The cleaned up version with speech artifacts removed</clean>

            Output ONLY the two XML tags. No other text.
            """

        let userPrompt: String
        if isPositive {
            let triggerInstruction: String
            if let trigger = specificTrigger {
                triggerInstruction = "MUST include the specific pattern: \"\(trigger)\""
            } else {
                triggerInstruction = "Include a \(category.name) pattern"
            }

            userPrompt = """
            CONTEXT: \(contextDescription)

            Generate a realistic dictation sentence (8-20 words) that this person might actually say.

            MANDATORY REQUIREMENTS:
            1. MUST include the word "\(randomWord)" somewhere in the sentence
            2. MUST include speech pattern: \(triggerInstruction)
            - Category: \(category.name)
            - Example transformation: "\(examplePattern.input)" → "\(examplePattern.output)"

            Make it specific to what a \(career) would actually say in their work. Be creative!

            Respond ONLY with <raw>...</raw> and <clean>...</clean> tags.
            """
        } else {
            userPrompt = """
            CONTEXT: \(contextDescription)

            Generate a realistic dictation sentence (8-20 words) that this person might actually say.

            MANDATORY REQUIREMENTS:
            1. MUST include the word "\(randomWord)" somewhere in the sentence
            2. Include words that LOOK like they need cleanup but should be PRESERVED:
            - Category: \(category.name)
            - Example: "\(examplePattern.input)" (this should NOT be changed because it's used correctly)

            The raw and clean versions should be IDENTICAL because the word is used correctly in context.
            Make it specific to what a \(career) would actually say in their work. Be creative!

            Respond ONLY with <raw>...</raw> and <clean>...</clean> tags.
            """
        }

        return (systemPrompt, userPrompt, generationContext)
    }

    // MARK: - Quick Generation (No LLM)

    /// Get a random example sentence without LLM (for testing/fallback)
    func getRandomExampleSentence() -> GeneratedSentence {
        lastGenerationSource = "static (quick generation)"
        log.info("TrainingSentenceGenerator: 📋 Using static example (no LLM)")

        guard let category = CleanupTrainingData.categories.randomElement() else {
            return GeneratedSentence(
                sentence: "The quick brown fox jumps over the lazy dog.",
                category: CleanupTrainingData.categories[0],
                isPositiveExample: true,
                expectedCleanOutput: "The quick brown fox jumps over the lazy dog.",
                context: nil
            )
        }

        let isPositive = Double.random(in: 0...1) < 0.7
        let examples = isPositive ? category.positiveExamples : category.negativeExamples

        if let example = examples.randomElement() {
            return GeneratedSentence(
                sentence: example.input,
                category: category,
                isPositiveExample: isPositive,
                expectedCleanOutput: example.output,
                context: nil
            )
        } else if let fallback = category.positiveExamples.randomElement() {
            return GeneratedSentence(
                sentence: fallback.input,
                category: category,
                isPositiveExample: true,
                expectedCleanOutput: fallback.output,
                context: nil
            )
        }

        return GeneratedSentence(
            sentence: "Um, I think we should proceed.",
            category: category,
            isPositiveExample: true,
            expectedCleanOutput: "I think we should proceed.",
            context: nil
        )
    }
}

// MARK: - Errors

enum TrainingGeneratorError: LocalizedError {
    case noCategories
    case noExamples
    case llmFailed(String)
    case llmNotLoaded
    case parsingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCategories:
            return "No cleanup rule categories available"
        case .noExamples:
            return "No example patterns available for this category"
        case .llmFailed(let message):
            return "LLM generation failed: \(message)"
        case .llmNotLoaded:
            return "LLM model is not loaded"
        case .parsingFailed(let response):
            return "Failed to parse LLM response: \(response.prefix(100))"
        }
    }
}

#endif // canImport(TranscriptionCleanup)
