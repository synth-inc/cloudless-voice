// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKCleanupProvider.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  "Your own model": the Rewrite stage (Settings > Rewrite). An LLM the user runs
//  or pays for - Ollama or LM Studio on this Mac, or a hosted API with their own
//  key - gets the text after cleanup (or the raw transcript when cleanup is off)
//  with the user's instructions. Free, unmetered, and independent of the closed
//  TranscriptionCleanup library, so it works in the fully open build.
//
//  Only the prompt and the transcript are sent. The user's dictionary and the
//  frontmost app's name go too only if they switch those on (both off by default).
//  Audio never leaves the Mac.
//

import Defaults
import Foundation

@MainActor
final class BYOKCleanupProvider: CleanupProvider {
    let id = CleanupProviderID.byok
    var displayName: String { String.localized("Your own model", table: "Settings") }

    /// Reply token cap: at least 2048 (room for a local model's `<think>` block),
    /// growing with the transcript so a long file transcript isn't cut short, up to
    /// 8192, which every current hosted model accepts. One token is at least one
    /// character for the scripts dictation produces, so `transcript.count` tokens
    /// covers a cleaned copy (the length check rejects a reply over twice the characters).
    /// A reply that still hits the cap is rejected (`BYOKClientError.truncated`).
    static func maxReplyTokens(for transcript: String) -> Int {
        min(8192, max(2048, transcript.count))
    }

    /// Longest transcript sent. A cleaned copy needs about one reply token per
    /// character, and replies are capped at `maxReplyTokens`' ceiling (8192), so a
    /// longer transcript always comes back truncated and rejected: refuse it
    /// up front rather than pay for a request that cannot succeed.
    static let maxTranscriptCharacters = 8192

    /// Requests go through their own ephemeral session: no cookies a hosted API
    /// sets are kept or sent back, and nothing is cached to disk.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let configuration: @MainActor () -> BYOKCleanupConfiguration
    private let dictationLanguages: @MainActor () -> [String]
    private let keyStore: APIKeyStore
    private let session: URLSession
    private let notice: CleanupFailureNotice?

    init(
        configuration: @escaping @MainActor () -> BYOKCleanupConfiguration = { .load() },
        dictationLanguages: @escaping @MainActor () -> [String] = { TranscriptionConfig.shared.transcriptionLanguages },
        keyStore: APIKeyStore = KeychainAPIKeyStore.shared,
        session: URLSession = BYOKCleanupProvider.defaultSession,
        notice: CleanupFailureNotice? = .shared
    ) {
        self.configuration = configuration
        self.dictationLanguages = dictationLanguages
        self.keyStore = keyStore
        self.session = session
        self.notice = notice
    }

    /// Hosted APIs answer fast or not at all; a local model may need longer.
    var timeout: Duration {
        configuration().isCloud ? .seconds(5) : .seconds(10)
    }

    var availability: ProviderAvailability {
        get async { Self.availability(of: configuration(), keyStore: keyStore) }
    }

    /// Settings-only: no network. Reachability is what "Test connection" is for.
    static func availability(of configuration: BYOKCleanupConfiguration, keyStore: APIKeyStore) -> ProviderAvailability {
        guard configuration.resolvedBaseURL != nil else {
            return .needsSetup(reason: configuration.isInsecureRemoteURL ? "Server URL needs https" : "No server URL")
        }
        guard !configuration.trimmedModel.isEmpty else {
            return .needsSetup(reason: "No model chosen")
        }
        if configuration.preset.requiresAPIKey, keyStore.apiKey(for: configuration.preset.keychainAccount) == nil {
            return .needsSetup(reason: "No API key")
        }
        return .ready
    }

    func cleanup(_ input: CleanupInput) async throws -> CleanupOutput {
        let configuration = configuration()
        do {
            guard input.transcript.count <= Self.maxTranscriptCharacters else {
                throw BYOKClientError.transcriptTooLong
            }
            let client = try makeClient(for: configuration, timeout: Self.requestTimeout(for: input, configuration))
            let prompt = BYOKPrompt.render(
                Self.template(configuration),
                values(for: input, configuration)
            )
            let reply = try await client.complete(
                prompt: prompt, model: configuration.trimmedModel, maxTokens: Self.maxReplyTokens(for: input.transcript)
            )
            return CleanupOutput(
                text: try Self.text(from: reply, transcript: input.transcript, configuration: configuration),
                modelName: configuration.trimmedModel
            )
        } catch {
            // Includes the cancellation `CleanupService` sends when the timeout hits.
            // The notice says why, so a rejected reply is never silently replaced.
            if input.isLive { notice?.cleanupFailed(CleanupFailureNotice.Reason(error)) }
            if let rejection = error as? BYOKReplyExtractor.Rejection {
                throw CleanupError.providerFailed("BYOK reply rejected: \(rejection)")
            }
            if let error = error as? BYOKClientError {
                throw CleanupError.providerFailed(error.localizedDescription)
            }
            throw error
        }
    }

    // MARK: - Settings

    /// Lists the server's models with the current settings (`apiKey` overrides the
    /// stored one, for a key typed but not yet saved).
    func listModels(configuration: BYOKCleanupConfiguration, apiKey: String? = nil) async throws -> [String] {
        try await makeClient(for: configuration, apiKey: apiKey, timeout: 10).listModels()
    }

    /// Result of "Test connection".
    struct ConnectionTest: Equatable {
        /// What the model made of a short sample sentence.
        var sample: String
        var elapsed: TimeInterval
    }

    /// Cleans a sample sentence end to end, with a generous timeout so a local
    /// model's first load doesn't read as a failure. Throws `BYOKClientError` or
    /// `CleanupError`.
    func testConnection(configuration: BYOKCleanupConfiguration, apiKey: String? = nil) async throws -> ConnectionTest {
        guard configuration.resolvedBaseURL != nil else {
            throw configuration.isInsecureRemoteURL ? BYOKClientError.insecureBaseURL : BYOKClientError.invalidBaseURL
        }
        let input = CleanupInput(transcript: "um so this is a test of the cleanup can you hear me", locale: .english, inEmailComposer: false)
        let client = try makeClient(for: configuration, apiKey: apiKey, timeout: 60)
        let prompt = BYOKPrompt.render(Self.template(configuration), values(for: input, configuration))
        let start = Date()
        let reply = try await client.complete(
            prompt: prompt, model: configuration.trimmedModel, maxTokens: Self.maxReplyTokens(for: input.transcript)
        )
        let elapsed = Date().timeIntervalSince(start)
        return ConnectionTest(sample: try Self.text(from: reply, transcript: input.transcript, configuration: configuration), elapsed: elapsed)
    }

    /// The text to insert from the model's reply: what's between the configured
    /// output markers, with the input's edge whitespace restored, if its length is
    /// plausible for `transcript`. Throws `BYOKReplyExtractor.Rejection`.
    static func text(from reply: String, transcript: String, configuration: BYOKCleanupConfiguration) throws -> String {
        let extracted = try BYOKReplyExtractor.extract(reply, start: configuration.outputStart, end: configuration.outputEnd).get()
        let checked = try BYOKReplyExtractor.checkLength(extracted, transcript: transcript).get()
        return BYOKReplyExtractor.restoringEdges(of: checked, from: transcript)
    }

    // MARK: - Private

    /// The user's prompt, or the default when it is missing, empty or blank.
    static func template(_ configuration: BYOKCleanupConfiguration) -> String {
        guard let custom = configuration.customPrompt,
              !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return BYOKPrompt.defaultTemplate }
        return custom
    }

    /// A live dictation is held to `timeout` by `CleanupService`; the request's own
    /// timeout is a backstop. Offline jobs get longer.
    private static func requestTimeout(for input: CleanupInput, _ configuration: BYOKCleanupConfiguration) -> TimeInterval {
        input.isLive ? (configuration.isCloud ? 6 : 11) : 60
    }

    private func makeClient(for configuration: BYOKCleanupConfiguration, apiKey: String? = nil, timeout: TimeInterval) throws -> BYOKLLMClient {
        guard let baseURL = configuration.resolvedBaseURL else {
            throw configuration.isInsecureRemoteURL ? BYOKClientError.insecureBaseURL : BYOKClientError.invalidBaseURL
        }
        let key: String? = if configuration.preset.acceptsAPIKey {
            apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? keyStore.apiKey(for: configuration.preset.keychainAccount)
        } else {
            nil
        }
        switch configuration.preset.api {
        case .openAICompatible:
            return OpenAICompatibleClient(baseURL: baseURL, apiKey: key, session: session, timeout: timeout)
        case .anthropic:
            return AnthropicClient(baseURL: baseURL, apiKey: key, session: session, timeout: timeout)
        }
    }

    private func values(for input: CleanupInput, _ configuration: BYOKCleanupConfiguration) -> BYOKPrompt.Values {
        BYOKPrompt.Values(
            instructions: configuration.instructions ?? BYOKPrompt.defaultInstructions,
            transcript: input.transcript,
            language: BYOKPrompt.languageName(locale: input.locale, dictationLanguages: dictationLanguages()),
            vocabulary: configuration.sendVocabulary ? input.vocabulary : nil,
            appName: configuration.sendAppName ? input.appContext?.name : nil
        )
    }
}
