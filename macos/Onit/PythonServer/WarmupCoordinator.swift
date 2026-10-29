// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WarmupCoordinator.swift
//  Onit
//
//  Replaces the previous PythonServerCoordinator after removing the Python server.
//  Manages on-device model warmup (Parakeet CoreML ASR + Llama scoring).
//

import Combine
import Foundation

/// Singleton orchestrator for on-device model warmup providers.
/// Manages warmup execution for Parakeet (ASR) and scoring (smart cleanup).
@MainActor
final class WarmupCoordinator: ObservableObject {

    // MARK: - Singleton

    static let shared = WarmupCoordinator()

    // MARK: - Published Properties

    /// Current warmup state
    @Published private(set) var warmupState: WarmupState = .idle

    /// Whether all enabled providers have completed warmup
    @Published private(set) var isFullyWarmedUp = false

    /// Providers that failed during warmup (keyed by identifier)
    @Published private(set) var failedProviders: [String: WarmupError] = [:]

    // MARK: - Private Properties

    private var providers: [WarmupProvider] = []
    private var warmupTask: Task<Void, Never>?
    /// Per-provider in-flight retry tasks. Keyed by provider identifier so a second click on
    /// a retry button cancels the previous attempt before starting a new one, instead of
    /// stacking concurrent downloads of the same model.
    private var retryTasks: [String: Task<Void, Never>] = [:]

    /// Listens for system-wide memory pressure events and ejects every provider whose
    /// `isEnabled` is currently false but who is still holding a warmed-up engine in RAM
    /// (e.g. the user turned off Smart Formatting but the Perplexity LLM is still resident
    /// from earlier in the session). The fix in PR #601 already handles the "user-driven
    /// disable" path; this source covers the "user did nothing, but the system is about to
    /// jetsam us" path - which is especially relevant once heavyweight ASR models like
    /// Qwen-1.7B (~3 GB) and Granite-Speech 4.1-2b (~5 GB) ship.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // MARK: - Initialization

    private init() {
        installMemoryPressureSource()
    }

    // MARK: - Public Methods

    /// Register a warmup provider
    func registerProvider(_ provider: WarmupProvider) {
        guard !providers.contains(where: { $0.identifier == provider.identifier }) else { return }
        providers.append(provider)
        providers.sort { $0.priority < $1.priority }
        log.info("WarmupCoordinator: Registered provider '\(provider.identifier)' with priority \(provider.priority)")
    }

    /// Called when a feature state changes (enabled/disabled). Handles both directions:
    /// warmup providers whose `isEnabled` just flipped to true, AND reset providers
    /// whose `isEnabled` just flipped to false (so their model RAM is released instead
    /// of staying resident until app exit). The previous version only handled the
    /// warmup side, causing e.g. Smart Formatting OFF to leak ~1.25 GB of MLX memory.
    func featureStateChanged() {
        log.info("WarmupCoordinator: Feature state changed")
        // Reset a provider when it's either (a) no longer enabled (free its RAM)
        // or (b) still enabled but STALE - warmed for a model that is no longer
        // selected (an intra-backend model switch, e.g. Granite → Qwen on the
        // shared `.mlx` provider). Without (b) the outgoing model stays resident
        // and keeps transcribing because `isEnabled`/`isWarmedUp` never change.
        for provider in providers where (!provider.isEnabled && provider.isWarmedUp) || provider.isStale {
            let reason = provider.isStale ? "selected model changed" : "no longer enabled"
            log.info("WarmupCoordinator: '\(provider.identifier)' \(reason), resetting to free RAM")
            provider.reset()
            failedProviders.removeValue(forKey: provider.identifier)
        }
        let hasEnabledFeature = providers.contains { $0.isEnabled }
        if hasEnabledFeature {
            checkAndRunWarmups()
        }
        updateFullyWarmedUpState()
    }

    /// Record a failure detected *outside* the coordinator's own warmup task, so the provider ends
    /// up in `failedProviders` like any other failure. `TranscriptionManager`'s init watchdog is the
    /// caller: it gives up on its own timeout, and without this the provider stays "still preparing"
    /// forever - every readiness gate (`ModelDownloadIndicator.isDictationPreparing`, the menu-bar
    /// download row, the status header) keys off `failedProviders` to stop waiting and offer Retry.
    func recordFailure(_ error: WarmupError, for providerIdentifier: String) {
        guard providers.contains(where: { $0.identifier == providerIdentifier }) else {
            log.warning("WarmupCoordinator: Unknown provider '\(providerIdentifier)' for recordFailure")
            return
        }
        guard failedProviders[providerIdentifier] == nil else { return }
        log.error("WarmupCoordinator: Recording external failure for '\(providerIdentifier)': \(error.localizedDescription)")
        failedProviders[providerIdentifier] = error
        updateFullyWarmedUpState()
    }

    /// Retry warmup for a specific provider (after failure).
    /// Only re-runs the targeted provider - does NOT touch other pending providers, so a
    /// retry of provider A never re-triggers an already-running download of provider B
    /// (which would spawn a duplicate concurrent download).
    func retryWarmup(for providerIdentifier: String) {
        log.info("WarmupCoordinator: Retrying warmup for '\(providerIdentifier)'")
        guard let provider = providers.first(where: { $0.identifier == providerIdentifier }) else {
            log.warning("WarmupCoordinator: Provider '\(providerIdentifier)' not found")
            return
        }
        provider.reset()
        failedProviders.removeValue(forKey: providerIdentifier)
        if case .failed = warmupState {
            warmupState = .idle
        }
        runSingleWarmup(provider)
    }

    /// Retry all warmups after a failure
    func retryAllWarmups() {
        log.info("WarmupCoordinator: Retrying all warmups")
        cancelInFlightTasks()
        for provider in providers { provider.reset() }
        warmupState = .idle
        isFullyWarmedUp = false
        failedProviders = [:]
        checkAndRunWarmups()
    }

    /// Reset all provider warmup states
    func resetProviderStates() {
        log.info("WarmupCoordinator: Resetting provider states")
        cancelInFlightTasks()
        for provider in providers { provider.reset() }
        isFullyWarmedUp = false
        failedProviders = [:]
        warmupState = .idle
    }

    /// Refresh the warmup status without resetting providers
    func refreshStatus() {
        updateFullyWarmedUpState()
    }

    // MARK: - Private Methods

    /// Installs a `.warning` + `.critical` memory-pressure listener. On either signal,
    /// `reset()` is called on every provider that is not currently enabled - which both
    /// flushes the engine and (for MLX backends) the Metal buffer pool. We intentionally
    /// do NOT reset the active provider: that would mid-dictation evict the model the
    /// user is actively using, manifesting as "transcription took 30 seconds because we
    /// reloaded from disk." The system is more forgiving than the user.
    ///
    /// Idle providers can usually be re-warmed in <1 s from on-disk weights, so the cost
    /// of evicting them at pressure time is small compared to being jetsamed by the OS.
    private func installMemoryPressureSource() {
        // `.utility` so the handler doesn't compete with the active inference QoS class -
        // memory pressure is a back-pressure signal, not a hot-path event.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        // `@Sendable` is load-bearing: this type is `@MainActor` (the target builds with
        // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), so a plain closure here would be
        // *inferred* MainActor-isolated. libdispatch then invokes it on the `.utility`
        // queue above, the Swift 6 runtime runs an executor check at the closure's entry,
        // sees it is not on the main actor, and traps (`dispatch_assert_queue_fail` /
        // EXC_BREAKPOINT). `@Sendable` makes the handler `nonisolated`, so it legitimately
        // runs on the utility queue and only touches the main actor through the
        // `Task { @MainActor }` hop below.
        //
        // `source` is thread-safe but not formally `Sendable`, so capturing it in a
        // `@Sendable` closure needs `nonisolated(unsafe)`.
        nonisolated(unsafe) let pressureSource = source
        source.setEventHandler { @Sendable [weak self] in
            // Capture the event mask outside the MainActor hop so the log reports the
            // pressure level the kernel signalled, not whatever the source happens to
            // report after we've already been re-scheduled.
            let event = pressureSource.data
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(event: event)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure(event: DispatchSource.MemoryPressureEvent) {
        let label = event.contains(.critical) ? "critical" : "warning"
        // Exclude providers with an in-flight warmup task - evicting one mid-load
        // would leave the warmup task to flip `isWarmedUp = true` against an
        // engine we just signaled was freed, creating a phantom "ready" state
        // pointing at no model.
        let idleProviders = providers.filter {
            !$0.isEnabled && $0.isWarmedUp && retryTasks[$0.identifier] == nil
        }
        guard !idleProviders.isEmpty else {
            log.info("WarmupCoordinator: Memory pressure (\(label)) - no idle providers to evict")
            return
        }
        log.warning(
            "WarmupCoordinator: Memory pressure (\(label)) - evicting \(idleProviders.count) idle provider(s): "
            + idleProviders.map(\.identifier).joined(separator: ", ")
        )
        for provider in idleProviders {
            provider.reset()
            failedProviders.removeValue(forKey: provider.identifier)
        }
        updateFullyWarmedUpState()
    }

    /// Cancel and forget every in-flight warmup task. Per-provider tasks live in `retryTasks`
    /// and are otherwise free-running - without explicit cancellation they would resume past
    /// their `await` and write a stale failure into the freshly-cleared `failedProviders`,
    /// resurrecting the failure banner immediately after a bulk reset. Their guards on
    /// `Task.isCancelled` make this bail cleanly.
    private func cancelInFlightTasks() {
        warmupTask?.cancel()
        warmupTask = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
    }

    private func checkAndRunWarmups() {
        let pendingProviders = providers.filter { $0.isEnabled && !$0.isWarmedUp }
        if pendingProviders.isEmpty {
            updateFullyWarmedUpState()
            return
        }
        warmupTask?.cancel()
        warmupTask = Task { @MainActor in
            await runParallelWarmups(providers: pendingProviders)
        }
    }

    /// Run a single provider's warmup in isolation. Used by `retryWarmup(for:)` so retrying
    /// one failed provider doesn't disturb other providers (still pending, in progress, or done).
    private func runSingleWarmup(_ provider: WarmupProvider) {
        let identifier = provider.identifier
        // Cancel any previous in-flight task for this identifier - covers both a stale retry
        // AND the per-provider Task spawned by `runParallelWarmups` (which registers itself in
        // `retryTasks` for exactly this reason). Without this, retrying mid-batch could spawn
        // a second concurrent warmup for the same provider.
        retryTasks[identifier]?.cancel()

        retryTasks[identifier] = Task { @MainActor in
            log.info("WarmupCoordinator: Single-provider retry for '\(identifier)'")
            // Only flip to `.warmingUp` if no other provider is still failed. Otherwise we'd
            // hide an existing failure banner for ~the duration of this retry, causing UI flicker.
            if failedProviders.isEmpty {
                warmupState = .warmingUp
            }
            let result: WarmupError?
            do {
                try await provider.warmup()
                result = nil
            } catch let error as WarmupError {
                result = error
            } catch {
                result = .warmupFailed(provider: identifier, reason: error.localizedDescription)
            }
            // A cancelled task has been superseded by a newer retry that already replaced the
            // slot in `retryTasks` - bail out before touching shared state. Otherwise the
            // CancellationError surfaced from `provider.warmup()` would be recorded as a stale
            // failure AND `retryTasks[identifier] = nil` below would wipe the replacing task,
            // leaving the UI stuck on a phantom failure with no way to retry again.
            guard !Task.isCancelled else { return }
            if let error = result {
                log.error("WarmupCoordinator: '\(identifier)' retry failed: \(error)")
                failedProviders[identifier] = error
            } else {
                log.info("WarmupCoordinator: '\(identifier)' retry complete")
                // Drop any stale failure left by a prior cancelled task that wrote to
                // `failedProviders` before observing its own cancellation.
                failedProviders.removeValue(forKey: identifier)
            }
            updateFullyWarmedUpState()
            // Restore the failed state if other providers are still flagged. Note: `firstFailure`
            // ordering is non-deterministic - UI re-derives the priority from a fixed list in
            // AppState+Status.swift, so the associated error here is "any one of the failures",
            // not necessarily the most critical one.
            if !failedProviders.isEmpty, !isFullyWarmedUp,
               let firstFailure = failedProviders.first {
                warmupState = .failed(error: firstFailure.value)
            }
            retryTasks[identifier] = nil
        }
    }

    private func runParallelWarmups(providers: [WarmupProvider]) async {
        log.info("WarmupCoordinator: Starting parallel warmups for \(providers.count) provider(s)")
        warmupState = .warmingUp

        let activeProviders = providers.filter { $0.isEnabled && !$0.isWarmedUp }
        var tasks: [Task<Void, Never>] = []

        // Each task records its own success/failure into `failedProviders` as soon as it
        // completes - do NOT collect results in a sequential `for task in tasks { await ... }`
        // because that blocks reporting on the slowest task and hides earlier failures from
        // the UI (e.g. a VAD failure invisible while Parakeet is still downloading).
        for provider in activeProviders {
            let identifier = provider.identifier
            log.info("WarmupCoordinator: Warming up '\(identifier)'...")
            let task = Task { @MainActor () -> Void in
                let result: WarmupError?
                do {
                    try await provider.warmup()
                    log.info("WarmupCoordinator: '\(identifier)' warmup complete")
                    result = nil
                } catch let error as WarmupError {
                    log.error("WarmupCoordinator: '\(identifier)' warmup failed: \(error)")
                    result = error
                } catch {
                    let warmupError = WarmupError.warmupFailed(provider: identifier, reason: error.localizedDescription)
                    log.error("WarmupCoordinator: '\(identifier)' warmup failed: \(warmupError)")
                    result = warmupError
                }
                // If a single-provider retry has cancelled and replaced this task, bail out
                // before touching shared state - otherwise we'd write a stale failure into
                // `failedProviders` and nil out `retryTasks[identifier]`, wiping the
                // replacing task's reference (see `runSingleWarmup` for the same pattern).
                guard !Task.isCancelled else { return }
                if let error = result {
                    self.failedProviders[identifier] = error
                } else {
                    // Drop any stale failure left by a prior cancelled task that wrote to
                    // `failedProviders` before observing its own cancellation.
                    self.failedProviders.removeValue(forKey: identifier)
                }
                self.updateFullyWarmedUpState()
                // Promote `warmupState` to `.failed` as soon as we have a failure, so the menu
                // bar can surface the retry button without waiting for the rest of the batch.
                if !self.failedProviders.isEmpty,
                   case .warmingUp = self.warmupState,
                   let firstFailure = self.failedProviders.first {
                    self.warmupState = .failed(error: firstFailure.value)
                }
                // Clear the per-provider task slot so retries don't try to cancel a finished task.
                self.retryTasks[identifier] = nil
            }
            // Register the per-provider task so a mid-batch retry for this same identifier
            // can cancel it (instead of spawning a second concurrent warmup for the same model).
            retryTasks[identifier] = task
            tasks.append(task)
        }

        // Wait for all tasks to finish (just to gate the final summary log) - individual
        // success/failure has already been recorded by each task's closure above.
        for task in tasks {
            await task.value
        }

        log.info("WarmupCoordinator: All warmups finished, isFullyWarmedUp=\(isFullyWarmedUp)")
    }

    private func updateFullyWarmedUpState() {
        let enabledProviders = providers.filter { $0.isEnabled }
        let allWarmedUp = enabledProviders.allSatisfy { $0.isWarmedUp }
        isFullyWarmedUp = allWarmedUp
        if allWarmedUp && !enabledProviders.isEmpty {
            warmupState = .ready
            log.info("WarmupCoordinator: All warmups complete, system ready")
        } else if enabledProviders.isEmpty {
            warmupState = .idle
            isFullyWarmedUp = false
        }
    }
}
