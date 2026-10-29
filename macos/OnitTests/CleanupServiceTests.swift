// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupServiceTests.swift
//  OnitTests
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Whatever the active provider does (throws, hangs, isn't entitled), a
//  dictation still gets its raw transcript.
//

import XCTest
@testable import Onit

@MainActor
final class CleanupServiceTests: XCTestCase {

    private let input = CleanupInput(
        transcript: "hello world period",
        locale: .english,
        inEmailComposer: false
    )

    private func service(_ provider: StubCleanupProvider) -> CleanupService {
        CleanupService(providers: [provider, NoCleanupProvider()], activeProviderID: { provider.id })
    }

    // MARK: - Rewrite stage

    private func chained(
        smart: StubCleanupProvider, byok: StubCleanupProvider, rewriteEnabled: Bool = true
    ) -> CleanupService {
        CleanupService(
            providers: [smart, byok, NoCleanupProvider()],
            activeProviderID: { CleanupProviderID.smart },
            rewriteEnabled: { rewriteEnabled }
        )
    }

    func testRewriteRunsOnTheCleanedTextAndKeepsTheFirstStagesOutcomeAndStats() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in
            CleanupOutput(text: "Hello world.", stats: .init(candidateCount: 3, deletePrecedingChars: 1, trailingSpaceHandled: true))
        }
        var seen: String?
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { input in
            seen = input.transcript
            return CleanupOutput(text: "Hello, world!")
        }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertEqual(seen, "Hello world.")
        XCTAssertEqual(result.text, "Hello, world!")
        XCTAssertEqual(result.rewriteSource, "Hello world.", "The row shows what the model was given")
        XCTAssertEqual(result.providerID, CleanupProviderID.smart)
        // The first stage's outcome is its own: its text and stats are untouched.
        XCTAssertEqual(result.output?.text, "Hello world.")
        XCTAssertEqual(result.output?.stats?.candidateCount, 3)
        XCTAssertEqual(result.output?.stats?.deletePrecedingChars, 1)
        XCTAssertEqual(result.output?.stats?.trailingSpaceHandled, true)
        // The edge decisions don't survive the rewrite; the counts do.
        XCTAssertEqual(result.statsForInsertion?.candidateCount, 3)
        XCTAssertEqual(result.statsForInsertion?.deletePrecedingChars, 0)
        XCTAssertEqual(result.statsForInsertion?.trailingSpaceHandled, false)
        XCTAssertTrue(result.rewriteApplied)
        guard case .cleaned(let rewritten, _) = result.rewrite else { return XCTFail("expected a cleaned rewrite, got \(String(describing: result.rewrite))") }
        XCTAssertEqual(rewritten.text, "Hello, world!")
    }

    func testFirstStageStatsAreKeptWhenTheRewriteFails() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in
            CleanupOutput(text: "Hello world.", stats: .init(deletePrecedingChars: 1, trailingSpaceHandled: true))
        }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in throw CleanupError.providerFailed("nope") }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertFalse(result.rewriteApplied)
        XCTAssertEqual(result.statsForInsertion?.deletePrecedingChars, 1)
        XCTAssertEqual(result.statsForInsertion?.trailingSpaceHandled, true)
    }

    func testStageDurationsStaySeparate() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in
            try await Task.sleep(for: .milliseconds(150))
            return CleanupOutput(text: "Hello, world!")
        }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        guard case .cleaned(_, let firstMs) = result.outcome, case .cleaned(_, let secondMs)? = result.rewrite else {
            return XCTFail("expected both stages cleaned")
        }
        XCTAssertLessThan(firstMs, 100, "the rewrite's time is not charged to the first stage")
        XCTAssertGreaterThanOrEqual(secondMs, 100)
    }

    func testRewriteFailureKeepsTheSmartCleanupText() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in throw CleanupError.providerFailed("nope") }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.output?.text, "Hello world.")
        XCTAssertEqual(result.rewrite, .failed(.providerFailed("nope")))
    }

    func testRewriteThatIsNotReadyKeepsTheSmartCleanupText() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok, availability: .needsSetup(reason: "No model chosen")) { _ in
            XCTFail("a provider that isn't ready must not be called")
            return CleanupOutput(text: "")
        }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertEqual(result.rewrite, .notReady(.needsSetup(reason: "No model chosen")))
    }

    func testRewriteIsSkippedWhenOff() async {
        var byokCalls = 0
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { input in
            byokCalls += 1
            return CleanupOutput(text: input.transcript)
        }
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }

        let off = await chained(smart: smart, byok: byok, rewriteEnabled: false).cleanup(input)

        XCTAssertNil(off.rewrite)
        XCTAssertEqual(off.text, "Hello world.")
        XCTAssertEqual(byokCalls, 0)
    }

    /// Rewrite is its own stage, not part of Smart Cleanup: with cleanup off it gets
    /// the raw transcript; the first stage's outcome stays `.disabled`.
    func testRewriteRunsOnTheRawTranscriptWhenCleanupIsOff() async {
        var seen: String?
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { input in
            seen = input.transcript
            return CleanupOutput(text: input.transcript.uppercased())
        }
        let cleanupService = CleanupService(
            providers: [byok, NoCleanupProvider()],
            activeProviderID: { CleanupProviderID.none },
            rewriteEnabled: { true }
        )

        let result = await cleanupService.cleanup(input)

        XCTAssertEqual(seen, input.transcript)
        XCTAssertEqual(result.text, "HELLO WORLD PERIOD")
        XCTAssertEqual(result.rewriteSource, input.transcript)
        XCTAssertEqual(result.providerID, CleanupProviderID.none)
        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertNil(result.output)
        XCTAssertNil(result.statsForInsertion)
        guard case .cleaned = result.rewrite else { return XCTFail("expected a cleaned rewrite, got \(String(describing: result.rewrite))") }
    }

    /// Smart Cleanup refusing (free words used up) or failing doesn't take the
    /// user's own model down with it: the rewrite still runs, on the raw transcript.
    func testRewriteStillRunsWhenSmartCleanupCouldNot() async {
        var seen: [String] = []
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { input in
            seen.append(input.transcript)
            return CleanupOutput(text: "Rewritten.")
        }

        let notEntitled = StubCleanupProvider(id: CleanupProviderID.smart) { _ in throw CleanupError.notEntitled }
        let refused = await chained(smart: notEntitled, byok: byok).cleanup(input)
        XCTAssertEqual(refused.text, "Rewritten.")
        XCTAssertEqual(refused.providerID, CleanupProviderID.smart)
        XCTAssertEqual(refused.outcome, .failed(.notEntitled), "the refusal stays visible for the paywall")
        XCTAssertTrue(refused.rewriteApplied)

        let loading = StubCleanupProvider(id: CleanupProviderID.smart, availability: .needsSetup(reason: "loading")) { _ in
            XCTFail("a provider that isn't ready must not be called")
            return CleanupOutput(text: "")
        }
        let notReady = await chained(smart: loading, byok: byok).cleanup(input)
        XCTAssertEqual(notReady.text, "Rewritten.")
        XCTAssertEqual(notReady.outcome, .notReady(.needsSetup(reason: "loading")), "the loading alert still has its outcome")

        XCTAssertEqual(seen, [input.transcript, input.transcript])
    }

    /// With cleanup off and the rewrite failing, the raw transcript is kept and the
    /// outcome still says cleanup was off.
    func testRewriteFailureWithCleanupOffKeepsTheRawTranscript() async {
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in throw CleanupError.providerFailed("nope") }
        let cleanupService = CleanupService(
            providers: [byok, NoCleanupProvider()],
            activeProviderID: { CleanupProviderID.none },
            rewriteEnabled: { true }
        )

        let result = await cleanupService.cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertEqual(result.rewrite, .failed(.providerFailed("nope")))
        XCTAssertNil(result.rewriteSource)
    }

    /// A rewrite that hands the text back unchanged leaves nothing to show.
    func testUnchangedRewriteHasNoSource() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { input in CleanupOutput(text: input.transcript) }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertNil(result.rewriteSource)
        guard case .cleaned = result.rewrite else { return XCTFail("expected a cleaned rewrite") }
    }

    // MARK: - Success

    func testCleanedTextIsReturned() async {
        let provider = StubCleanupProvider { CleanupOutput(text: $0.transcript.uppercased()) }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, "HELLO WORLD PERIOD")
        XCTAssertEqual(result.providerID, "stub")
        guard case .cleaned = result.outcome else { return XCTFail("Expected .cleaned, got \(result.outcome)") }
    }

    // MARK: - Fallbacks

    func testThrowFallsBackToRawText() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let provider = StubCleanupProvider { _ in throw Boom() }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(let error) = result.outcome else { return XCTFail("Expected .failed, got \(result.outcome)") }
        // The provider's own message reaches the logs unchanged.
        XCTAssertEqual(error, .providerFailed("boom"))
        XCTAssertEqual(error.localizedDescription, "boom")
    }

    func testTimeoutFallsBackToRawText() async {
        let provider = StubCleanupProvider(timeout: .milliseconds(50)) { input in
            try await Task.sleep(for: .seconds(30))
            return CleanupOutput(text: "too late")
        }
        let start = Date()
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(.timeout) = result.outcome else { return XCTFail("Expected .timeout, got \(result.outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Must not wait for the provider")
    }

    /// A provider that ignores cancellation must not hold the dictation either.
    func testTimeoutDoesNotWaitForUncooperativeProvider() async {
        let provider = StubCleanupProvider(timeout: .milliseconds(50)) { input in
            let until = Date().addingTimeInterval(1)
            while Date() < until { await Task.yield() }
            return CleanupOutput(text: "too late")
        }
        let start = Date()
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(.timeout) = result.outcome else { return XCTFail("Expected .timeout, got \(result.outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    func testOfflineCleanupIsNotHeldToTheTimeout() async {
        let provider = StubCleanupProvider(timeout: .milliseconds(10)) { input in
            try await Task.sleep(for: .milliseconds(200))
            return CleanupOutput(text: "cleaned")
        }
        var offline = input
        offline.isLive = false
        let result = await service(provider).cleanup(offline)

        XCTAssertEqual(result.text, "cleaned")
    }

    func testLiveCleanupWithoutTimeoutRunsToCompletion() async {
        let provider = StubCleanupProvider(timeout: nil) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return CleanupOutput(text: "cleaned")
        }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, "cleaned")
    }

    func testNotEntitledFallsBackToRawText() async {
        let provider = StubCleanupProvider { _ in throw CleanupError.notEntitled }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(.notEntitled) = result.outcome else { return XCTFail("Expected .notEntitled, got \(result.outcome)") }
    }

    /// The pipeline stops a cancelled live run with `CancellationError`: that's the timeout
    /// path (raw text), never a provider failure or a paywall refusal.
    func testCancellationErrorIsTheTimeoutPathWhenLive() async {
        var input = input
        input.isLive = true
        let provider = StubCleanupProvider { _ in throw CancellationError() }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(.timeout) = result.outcome else { return XCTFail("Expected .timeout, got \(result.outcome)") }
    }

    /// Cancelling an offline job (file transcription) is not a timeout: it propagates.
    func testCancellationErrorPropagatesWhenOffline() async {
        var input = input
        input.isLive = false
        let provider = StubCleanupProvider { _ in throw CancellationError() }
        do {
            let result = try await service(provider).cleanupCancellable(input)
            XCTFail("Expected CancellationError, got \(result.outcome)")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func cancellingRewrite() -> (StubCleanupProvider, StubCleanupProvider) {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in throw CancellationError() }
        return (smart, byok)
    }

    /// Cancelling the rewrite stage of an offline job propagates too (covers the second `try`).
    func testRewriteCancellationPropagatesWhenOffline() async {
        var input = input
        input.isLive = false
        let (smart, byok) = cancellingRewrite()
        do {
            let result = try await chained(smart: smart, byok: byok).cleanupCancellable(input)
            XCTFail("Expected CancellationError, got \(result.text)")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Live, a cancelled rewrite is a timeout: the first stage's text is kept, nothing throws.
    func testRewriteCancellationIsATimeoutWhenLive() async throws {
        var input = input
        input.isLive = true
        let (smart, byok) = cancellingRewrite()
        let result = try await chained(smart: smart, byok: byok).cleanupCancellable(input)

        XCTAssertEqual(result.text, "Hello world.")
        guard case .failed(.timeout) = result.rewrite else { return XCTFail("Expected .failed(.timeout), got \(String(describing: result.rewrite))") }
    }

    /// A rewrite that returns the same text changed nothing, so the first stage's edge
    /// decisions still hold; one that changes the text voids them.
    func testStatsAreKeptWhenTheRewriteLeavesTheTextUnchanged() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in
            CleanupOutput(text: "Hello world.", stats: .init(deletePrecedingChars: 1, trailingSpaceHandled: true))
        }
        let same = StubCleanupProvider(id: CleanupProviderID.byok) { input in CleanupOutput(text: input.transcript, modelName: "m") }
        let changed = StubCleanupProvider(id: CleanupProviderID.byok) { _ in CleanupOutput(text: "Hello, world!", modelName: "m") }

        let unchanged = await chained(smart: smart, byok: same).cleanup(input)
        XCTAssertTrue(unchanged.rewriteApplied)
        XCTAssertNil(unchanged.rewriteSource)
        XCTAssertEqual(unchanged.statsForInsertion?.deletePrecedingChars, 1)
        XCTAssertEqual(unchanged.statsForInsertion?.trailingSpaceHandled, true)
        XCTAssertNil(unchanged.rewriteModel, "No model is credited for a rewrite that changed nothing")

        let rewritten = await chained(smart: smart, byok: changed).cleanup(input)
        XCTAssertEqual(rewritten.statsForInsertion?.deletePrecedingChars, 0)
        XCTAssertEqual(rewritten.statsForInsertion?.trailingSpaceHandled, false)
    }

    /// The history row names the model the provider reported when it ran, not whatever
    /// the settings say afterwards.
    func testRewriteModelComesFromTheProviderOutput() async {
        let smart = StubCleanupProvider(id: CleanupProviderID.smart) { _ in CleanupOutput(text: "Hello world.") }
        let byok = StubCleanupProvider(id: CleanupProviderID.byok) { _ in CleanupOutput(text: "Hello, world!", modelName: "model-a") }

        let result = await chained(smart: smart, byok: byok).cleanup(input)

        XCTAssertEqual(result.rewriteModel, "model-a")
    }

    /// An offline refusal is reported as `.notEntitled` (no sales prompt, raw text kept).
    func testOfflineNotEntitledKeepsRawText() async throws {
        var input = input
        input.isLive = false
        let provider = StubCleanupProvider { _ in throw CleanupError.notEntitled }
        let result = try await service(provider).cleanupCancellable(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .failed(.notEntitled) = result.outcome else { return XCTFail("Expected .notEntitled, got \(result.outcome)") }
    }

    func testNotEntitledLogEntryNamesTheSkip() throws {
        let json = try XCTUnwrap(TranscriptionManager.notEntitledLogJSON())
        XCTAssertTrue(json.contains("cleanup_skipped"))
        XCTAssertTrue(json.contains("not_entitled"))
    }

    func testProviderThatIsNotReadyIsNotCalled() async {
        let provider = StubCleanupProvider(availability: .needsSetup(reason: "loading")) { _ in
            XCTFail("cleanup must not run when the provider isn't ready")
            return CleanupOutput(text: "cleaned")
        }
        let result = await service(provider).cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .notReady(.needsSetup) = result.outcome else { return XCTFail("Expected .notReady, got \(result.outcome)") }
    }

    /// Starting a new recording cancels the previous dictation's processing task. That
    /// dictation was always still cleaned and inserted, so the caller's cancellation
    /// must not turn its cleanup into the raw transcript.
    func testCallerCancellationDoesNotAbortLiveCleanup() async {
        let provider = StubCleanupProvider { input in
            // Not `Task.sleep`: that would throw if cancellation reached the provider.
            let until = Date().addingTimeInterval(0.2)
            while Date() < until { await Task.yield() }
            return CleanupOutput(text: "cleaned")
        }
        let cleanupService = service(provider)
        let input = self.input
        let task = Task { await cleanupService.cleanup(input) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.text, "cleaned")
        guard case .cleaned = result.outcome else { return XCTFail("Expected .cleaned, got \(result.outcome)") }
    }

    /// On a timeout the provider's work is cancelled, so a provider that checks (Smart
    /// Cleanup, once it gets the scorer) gives up instead of running for nothing.
    func testTimeoutCancelsTheProvidersWork() async {
        let observedCancellation = expectation(description: "provider sees cancellation")
        let provider = StubCleanupProvider(timeout: .milliseconds(50)) { _ in
            let until = Date().addingTimeInterval(2)
            while Date() < until, !Task.isCancelled { await Task.yield() }
            if Task.isCancelled { observedCancellation.fulfill() }
            return CleanupOutput(text: "too late")
        }
        let result = await service(provider).cleanup(input)

        guard case .failed(.timeout) = result.outcome else { return XCTFail("Expected .timeout, got \(result.outcome)") }
        await fulfillment(of: [observedCancellation], timeout: 1)
    }

    // MARK: - Provider selection

    func testNoneProviderIsDisabled() async {
        let cleanupService = CleanupService(providers: [NoCleanupProvider()], activeProviderID: { CleanupProviderID.none })
        let result = await cleanupService.cleanup(input)

        XCTAssertEqual(result.text, input.transcript)
        guard case .disabled = result.outcome else { return XCTFail("Expected .disabled, got \(result.outcome)") }
    }

    func testUnknownProviderFallsBackToNoCleanup() async {
        let cleanupService = CleanupService(providers: [NoCleanupProvider()], activeProviderID: { "from-the-future" })

        XCTAssertEqual(cleanupService.activeProvider.id, CleanupProviderID.none)
        let result = await cleanupService.cleanup(input)
        XCTAssertEqual(result.text, input.transcript)
    }

    // MARK: - Setting migration

    func testMigrationFromSmartFormattingToggle() {
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: nil, smartFormattingEnabled: true), "smart")
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: nil, smartFormattingEnabled: false), "none")
    }

    func testStoredProviderIsKept() {
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "smart", smartFormattingEnabled: true), "smart")
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "none", smartFormattingEnabled: false), "none")
        // A provider the toggle doesn't describe is left alone.
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "from-the-future", smartFormattingEnabled: false), "from-the-future")
    }

    /// "Your own model" was briefly a cleanup choice; it is the Rewrite stage now.
    func testStoredYourOwnModelMeansNoCleanup() {
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "byok", smartFormattingEnabled: false), "none")
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "byok", smartFormattingEnabled: true), "none")
    }

    /// An older build only writes the toggle: whatever the user set there wins
    /// between "smart" and "none".
    func testToggleChangedByOlderBuildWins() {
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "smart", smartFormattingEnabled: false), "none")
        XCTAssertEqual(TranscriptionConfig.resolvedCleanupProviderID(stored: "none", smartFormattingEnabled: true), "smart")
    }

    // MARK: - Onboarding demo (unmetered scope)

    /// `SmartCleanupEntitlement.withoutMetering` (the onboarding demo) is a task-local scope
    /// in the library. A live cleanup runs the provider on `withTimeout`'s own task: it must
    /// still see the caller's task-locals, or the demo would spend the free words.
    func testLiveCleanupKeepsTheCallersTaskLocals() async {
        let provider = StubCleanupProvider { input in
            CleanupOutput(text: DemoScopeProbe.marker ?? "none")
        }
        let result = await DemoScopeProbe.$marker.withValue("demo") {
            await SmartCleanupEntitlement.withoutMetering {
                await service(provider).cleanup(input)
            }
        }
        XCTAssertEqual(result.text, "demo")
    }

    /// The scope hands back the operation's result and its errors unchanged.
    func testWithoutMeteringPassesResultAndErrorsThrough() async {
        let value = await SmartCleanupEntitlement.withoutMetering { 42 }
        XCTAssertEqual(value, 42)

        struct Boom: Error {}
        do {
            try await SmartCleanupEntitlement.withoutMetering { throw Boom() }
            XCTFail("Expected the error to be rethrown")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}

private enum DemoScopeProbe {
    @TaskLocal static var marker: String?
}

// MARK: - Stub

@MainActor
private final class StubCleanupProvider: CleanupProvider {
    let id: String
    let displayName = "Stub"
    let timeout: Duration?
    private let stubAvailability: ProviderAvailability
    private let body: @MainActor (CleanupInput) async throws -> CleanupOutput

    init(
        id: String = "stub",
        timeout: Duration? = .seconds(10),
        availability: ProviderAvailability = .ready,
        body: @escaping @MainActor (CleanupInput) async throws -> CleanupOutput
    ) {
        self.id = id
        self.timeout = timeout
        self.stubAvailability = availability
        self.body = body
    }

    var availability: ProviderAvailability {
        get async { stubAvailability }
    }

    func cleanup(_ input: CleanupInput) async throws -> CleanupOutput {
        try await body(input)
    }
}
