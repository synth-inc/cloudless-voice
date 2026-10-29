// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupService.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//

import Foundation

/// The single entry point for cleaning a transcript.
///
/// Picks the provider the user chose (`TranscriptionConfig.cleanupProviderID`),
/// holds a live dictation to the provider's timeout, and never fails: any error,
/// timeout or missing entitlement comes back as the raw transcript, with the
/// reason in `outcome` for the caller's logs and analytics.
///
/// With Rewrite on (`TranscriptionConfig.rewriteEnabled`), the result then goes
/// through the user's own model (`BYOKCleanupProvider`) as a second stage with its
/// own timeout: the cleaned text, or the raw transcript when cleanup is off or
/// couldn't run. If the rewrite can't run or fails, the first stage's text is
/// kept. `Result.rewrite` says what it did.
@MainActor
final class CleanupService {

    static let shared = CleanupService()

    /// What happened to one transcript. `CleanupService.Result.text` is the text to
    /// insert in every case.
    enum Outcome: Equatable {
        /// The provider ran. `durationMs` counts from after the availability check.
        case cleaned(CleanupOutput, durationMs: Double)
        /// Cleanup is off (`NoCleanupProvider`).
        case disabled
        /// The provider can't run right now; the raw transcript was kept.
        case notReady(ProviderAvailability)
        /// The provider threw or timed out; the raw transcript was kept.
        case failed(CleanupError)
    }

    struct Result {
        /// The text to insert: the rewritten text when the rewrite ran, else the first stage's.
        var text: String
        /// The provider the user chose (the first stage, when there are two).
        let providerID: String
        /// The first stage's outcome, untouched by the rewrite: a refusal
        /// (`.failed(.notEntitled)`) or a loading model (`.notReady`) stays visible
        /// to the caller (paywall, alert, analytics) even when the rewrite succeeded.
        /// Its `output.text` is the first stage's text, not the rewritten one.
        let outcome: Outcome
        /// The rewrite stage's outcome (with its own duration), or nil when Rewrite is off.
        var rewrite: Outcome? = nil
        /// The text the rewrite was given and changed (the first stage's result, or
        /// the raw transcript), for the history row to show next to the rewrite.
        /// Nil when no rewrite ran or it returned the text unchanged.
        var rewriteSource: String? = nil

        /// The first stage's output, when it ran.
        var output: CleanupOutput? {
            if case .cleaned(let output, _) = outcome { output } else { nil }
        }

        /// The first stage's stats as they apply to `text`. A rewrite that changed
        /// the text replaced the text those stats were computed for, so their edge decisions
        /// (characters to delete before the caret, the trailing space) are void and
        /// the caller's heuristic takes over; the counts still describe the first stage.
        var statsForInsertion: CleanupOutput.Stats? {
            guard var stats = output?.stats else { return nil }
            if rewriteSource != nil {
                stats.deletePrecedingChars = 0
                stats.trailingSpaceHandled = false
            }
            return stats
        }

        /// The model that rewrote the text, as captured when the provider was called.
        /// Nil when the rewrite didn't change the text.
        var rewriteModel: String? {
            guard rewriteSource != nil, case .cleaned(let output, _) = rewrite,
                  let name = output.modelName, !name.isEmpty else { return nil }
            return name
        }

        /// True when the rewrite ran and its text is the one in `text`.
        var rewriteApplied: Bool {
            if case .cleaned = rewrite { true } else { false }
        }
    }

    private let providers: [String: any CleanupProvider]
    private let activeProviderID: @MainActor () -> String
    private let rewriteEnabled: @MainActor () -> Bool

    init(
        providers: [any CleanupProvider] = CleanupService.defaultProviders(),
        activeProviderID: @escaping @MainActor () -> String = { TranscriptionConfig.shared.cleanupProviderID },
        rewriteEnabled: @escaping @MainActor () -> Bool = { TranscriptionConfig.shared.rewriteEnabled }
    ) {
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.activeProviderID = activeProviderID
        self.rewriteEnabled = rewriteEnabled
    }

    /// The providers this build ships. Smart Cleanup needs the closed
    /// TranscriptionCleanup library, so a fully open build
    /// (`scripts/build-fully-open.sh`) registers only the open ones. A stored
    /// "smart" there resolves to no cleanup (see `activeProvider`).
    static func defaultProviders() -> [any CleanupProvider] {
        var providers: [any CleanupProvider] = []
        #if canImport(TranscriptionCleanup)
        providers.append(SmartCleanupProvider())
        #endif
        // Open providers register here, in both builds.
        providers.append(BYOKCleanupProvider())
        providers.append(NoCleanupProvider())
        return providers
    }

    /// The provider the user chose. An id this build doesn't know (a provider from a
    /// newer version, or one compiled out) falls back to no cleanup.
    var activeProvider: any CleanupProvider {
        providers[activeProviderID()] ?? providers[CleanupProviderID.none] ?? NoCleanupProvider()
    }

    /// Cleans `input.transcript` with the active provider, then rewrites the result
    /// when Rewrite is on. Never throws: on any failure `text` is the raw transcript
    /// (or, if only the rewrite failed, the first stage's text).
    ///
    /// A live dictation (`input.isLive`) is held to each provider's `timeout`, counted
    /// from after its availability check so a model reload isn't charged to it.
    /// Offline jobs (re-transcription, file transcription) run without one: a long
    /// file's transcript legitimately takes longer, and the job is cancellable.
    func cleanup(_ input: CleanupInput) async -> Result {
        do {
            return try await cleanupCancellable(input)
        } catch {
            // Only an offline input can throw (see `cleanupCancellable`); treat it as the
            // timeout path so this entry point keeps its never-throws contract.
            return Result(text: input.transcript, providerID: activeProvider.id, outcome: .failed(.timeout))
        }
    }

    /// Same as `cleanup`, but an offline job (`isLive == false`) that is cancelled throws
    /// `CancellationError`: cancelling a file job is not a timeout. A live run never throws.
    func cleanupCancellable(_ input: CleanupInput) async throws -> Result {
        let provider = activeProvider
        let first = try await run(provider, input)
        var result = Result(text: first.text, providerID: provider.id, outcome: first.outcome)

        guard let rewriter = rewriteProvider else { return result }
        var rewriteInput = input
        rewriteInput.transcript = first.text
        let second = try await run(rewriter, rewriteInput)
        result.rewrite = second.outcome
        if case .cleaned(let rewritten, _) = second.outcome {
            result.text = rewritten.text
            // Only a rewrite that changed the text has a source worth showing.
            if rewritten.text != first.text { result.rewriteSource = first.text }
        }
        return result
    }

    /// The rewrite stage, when the user turned it on: always the user's own model.
    private var rewriteProvider: (any CleanupProvider)? {
        guard rewriteEnabled() else { return nil }
        return providers[CleanupProviderID.byok]
    }

    /// Runs one provider on `input`, with the timeout and fallback rules above.
    private func run(_ provider: any CleanupProvider, _ input: CleanupInput) async throws -> (text: String, outcome: Outcome) {
        guard provider.id != CleanupProviderID.none else {
            return (input.transcript, .disabled)
        }
        let availability = await provider.availability
        guard availability == .ready else {
            return (input.transcript, .notReady(availability))
        }

        let start = Date()
        do {
            let output = if input.isLive, let limit = provider.timeout {
                try await Self.withTimeout(limit) { try await provider.cleanup(input) }
            } else {
                try await provider.cleanup(input)
            }
            let durationMs = Date().timeIntervalSince(start) * 1000
            return (output.text, .cleaned(output, durationMs: durationMs))
        } catch let error as CleanupError {
            return (input.transcript, .failed(error))
        } catch is CancellationError {
            // The pipeline stops a cancelled live run early (and doesn't count it): that is
            // the timeout path, not a provider failure and not a refusal. An offline job's
            // cancellation is the caller's, so it propagates.
            if !input.isLive { throw CancellationError() }
            return (input.transcript, .failed(.timeout))
        } catch {
            return (input.transcript, .failed(.providerFailed(error.localizedDescription)))
        }
    }

    /// Runs `operation`, or throws `CleanupError.timeout` once `timeout` elapses.
    ///
    /// A task group would wait for a child that ignores cancellation (the cleanup
    /// pipeline doesn't check it between chunks), so the work runs in its own task
    /// and whichever of it and the clock finishes first resumes the caller. On a
    /// timeout the work is cancelled and left to wind down on its own.
    ///
    /// The caller's own cancellation is deliberately not forwarded. Starting a new
    /// recording cancels the previous dictation's processing task
    /// (`clearRecordedAudioProcessingTask`), and that dictation has always still been
    /// cleaned and inserted: aborting here would paste its raw transcript instead.
    /// The timeout still bounds the wait.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let state = TimeoutState<T>()
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            state.work = Task { @MainActor in
                do {
                    state.finish(.success(try await operation()))
                } catch {
                    state.finish(.failure(error))
                }
            }
            state.clock = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                state.finish(.failure(CleanupError.timeout))
            }
        }
    }
}

/// Resumes `withTimeout`'s caller once, from whichever side finishes first.
@MainActor
private final class TimeoutState<T: Sendable> {
    var continuation: CheckedContinuation<T, Error>?
    var work: Task<Void, Never>?
    var clock: Task<Void, Never>?

    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        clock?.cancel()
        continuation.resume(with: result)
    }
}
