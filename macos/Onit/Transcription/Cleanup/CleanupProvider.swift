// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupProvider.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  The seam every transcript cleanup goes through. `CleanupService` picks the
//  active provider and owns the fallback: whatever a provider does (throws, hangs,
//  isn't entitled), the dictation still gets its raw transcript.
//
//  Nothing in this file depends on the closed TranscriptionCleanup library, so
//  it builds with or without it.
//

import Foundation

// MARK: - Provider IDs

/// Stable ids of the built-in providers, persisted in
/// `TranscriptionConfigKeys.cleanupProviderID`. Never rename one: a stored id that
/// no longer resolves falls back to no cleanup.
enum CleanupProviderID {
    /// On-device Smart Cleanup (`SmartCleanupProvider`).
    static let smart = "smart"
    /// Cleanup off: the raw transcript is inserted (`NoCleanupProvider`).
    static let none = "none"
    /// The user's own model: a local or hosted LLM (`BYOKCleanupProvider`). Not a
    /// choice in the Cleanup picker: it is the Rewrite stage, which runs after
    /// whichever cleanup is chosen (`CleanupService`).
    static let byok = "byok"
}

// MARK: - Provider

/// One way of turning a raw transcript into the text that gets inserted.
///
/// Main-actor isolated: every caller (`TranscriptionManager`, Settings) already is,
/// and providers read `TranscriptionConfig`. A provider that does real work off the
/// main actor awaits it from `cleanup(_:)`.
@MainActor
protocol CleanupProvider: AnyObject {
    /// Stable id, persisted as the user's choice. See `CleanupProviderID`.
    var id: String { get }
    /// Name shown in Settings.
    var displayName: String { get }
    /// Budget for one live `cleanup(_:)` call, applied by `CleanupService`. The
    /// clock starts after `availability`, so loading a model is not charged to it.
    var timeout: Duration? { get }
    /// Whether the provider can clean a transcript right now. May wait for the
    /// provider's local models to become resident, so resolve it once per cleanup.
    var availability: ProviderAvailability { get async }
    /// Cleans one transcript. Throwing is fine: `CleanupService` turns any error
    /// into the raw transcript.
    func cleanup(_ input: CleanupInput) async throws -> CleanupOutput
}

extension CleanupProvider {
    var timeout: Duration? { .seconds(10) }
}

// MARK: - Availability

/// Where a provider stands before a dictation can use it.
enum ProviderAvailability: Equatable, Sendable {
    case ready
    /// Usable once something finishes or the user does something (a model still
    /// loading, a missing API key). `reason` is for logs and Settings.
    case needsSetup(reason: String)
    /// Not usable on this machine or build.
    case unavailable(reason: String)
}

// MARK: - Input

/// Everything a provider may use to clean one transcript.
struct CleanupInput: Equatable, Sendable {
    /// The app the text is being dictated into.
    struct AppContext: Equatable, Sendable {
        var name: String?
        var bundleIdentifier: String?
    }

    /// Raw ASR output.
    var transcript: String
    /// Cleanup rules to apply (`TranscriptionConfig.cleanupLocale`).
    var locale: CleanupLocale
    /// Text before the cursor in the target field, already sanitised by the caller.
    var precedingText: String?
    /// Text after the cursor in the target field, already sanitised by the caller.
    var followingText: String?
    /// Whether the text lands in an email composer (see `EmailComposer`).
    var inEmailComposer: Bool
    /// The user's custom dictionary terms (empty when the dictionary is off).
    var vocabulary: [String] = []
    var appContext: AppContext?
    /// A live dictation, as opposed to a re-transcription or a file job. A live
    /// dictation goes first on shared models and is held to the provider's timeout.
    var isLive: Bool = true
}

/// Cleanup rules, by language. Mirrors the locales Smart Cleanup ships rules for.
enum CleanupLocale: String, Equatable, Sendable, CaseIterable {
    case english
    case french
}

// MARK: - Output

/// A provider's cleaned text, plus what it did when it can say.
struct CleanupOutput: Equatable, Sendable {
    /// What a provider reports about one cleanup, for logs, history and analytics.
    struct Stats: Equatable, Sendable {
        var candidateCount: Int = 0
        var categoriesEvaluated: [String: Int] = [:]
        var categoriesApplied: [String: Int] = [:]
        var chunkCount: Int = 1
        /// Characters to delete before the cursor before inserting (e.g. the
        /// preceding text's punctuation, consumed by the cleaned text).
        var deletePrecedingChars: Int = 0
        /// True when `text` already carries its trailing-space decision; otherwise
        /// the caller adds a space by heuristic.
        var trailingSpaceHandled: Bool = false
        /// Preformatted decision report (debug/logging only).
        var debugReport: String?
    }

    var text: String
    var stats: Stats?
    /// The model that produced `text`, when the provider is a user-chosen model. Read at call
    /// time so a settings change mid-request can't mislabel the result.
    var modelName: String? = nil
}

// MARK: - Errors

enum CleanupError: Error, Equatable, LocalizedError {
    /// The user's plan doesn't cover this provider.
    case notEntitled
    /// The provider didn't answer within its `timeout`.
    case timeout
    case providerFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEntitled: "Not entitled to this cleanup provider"
        case .timeout: "Cleanup timed out"
        // Verbatim: analytics and history logs carry the provider's own message.
        case .providerFailed(let message): message
        }
    }
}
