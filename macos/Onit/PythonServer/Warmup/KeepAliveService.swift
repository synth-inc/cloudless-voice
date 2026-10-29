// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  KeepAliveService.swift
//  Onit
//
//  Periodically runs a tiny dummy inference against every loaded on-device model
//  (ASR engines, the scoring LLM, the improvement LLM, Silero VAD) so the ANE/GPU
//  keeps them resident between user recordings.
//
//  Without this, a gap of ~2–5 minutes lets the OS evict a model from ANE/GPU
//  memory, producing multi-second cold-start latency on the next transcription.
//
//  Generalizes the former ParakeetKeepAliveService: each warmup provider registers
//  a backend-specific ping on successful warmup (`register`) and removes it on reset
//  (`deregister`). A single shared timer drives all registered targets, so adding a
//  new backend is one `register(...)` call rather than a whole new timer service.
//

import Combine
import Defaults
import Foundation

// MARK: - KeepAliveTarget

/// A single registered keep-alive target - one per loaded model.
@MainActor
struct KeepAliveTarget {

    /// Stable identifier (reuse the provider's `identifier`). Also used as the
    /// analytics ping suffix: `keepalive_<identifier>`.
    let identifier: String

    /// Whether the backend is currently worth pinging. Should check that the
    /// model is loaded - and, for consumer-gated models (improvement LLM), that
    /// at least one consumer feature is enabled. Returning `false` records a
    /// `skipped` ping and does no inference.
    let isActive: @MainActor () async -> Bool

    /// The dummy inference. The result is discarded; a thrown error is logged and
    /// reported as an `error` ping, never propagated.
    let ping: @MainActor () async throws -> Void
}

// MARK: - KeepAliveService

/// Sends periodic keep-alive pings to every registered on-device model.
///
/// After a model warms up, its warmup provider calls `register(_:)`. A single
/// repeating timer fires every `keepAliveInterval` seconds and, for each target
/// that is currently active, runs its dummy inference. Results are discarded.
///
/// The timer pauses when transcription is disabled and resumes when it is
/// re-enabled (registered targets are retained across that transition). A target
/// is removed only via `deregister(_:)`, which its provider calls from `reset()`
/// when the underlying model unloads.
@MainActor
final class KeepAliveService {

    // MARK: - Singleton

    static let shared = KeepAliveService()

    // MARK: - Configuration

    /// How often (in seconds) to ping. 2 minutes keeps well inside the typical
    /// ~5 minute OS eviction window.
    private let keepAliveInterval: TimeInterval = 120

    /// Duration of the silent audio clip sent to ASR/VAD targets (seconds at 16 kHz).
    private let silenceDuration: TimeInterval = 0.5
    private let targetSampleRate: Double = 16_000

    /// Hard upper bound on a single ping. A wedged engine can't stall the whole
    /// loop (and pile up future ticks) past this - comfortably above a warm-model
    /// inference, well below the 120s interval even summed across every backend.
    private let pingTimeoutSeconds: Double = 10

    // MARK: - State

    private var targets: [String: KeepAliveTarget] = [:]
    private var timer: Timer?
    private var pingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var isObservingDefaults = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Registration

    /// Register (or replace) a keep-alive target and ensure the timer is running.
    /// Safe to call repeatedly - re-registering the same identifier just refreshes
    /// the stored closures.
    func register(_ target: KeepAliveTarget) {
        targets[target.identifier] = target
        observeTranscriptionEnabledIfNeeded()
        if Defaults[.transcriptionEnabled] {
            scheduleTimerIfNeeded()
        }
        log.info("KeepAliveService: registered '\(target.identifier)' (\(targets.count) target(s))")
    }

    /// Remove a target. Stops the timer once the last target is gone so an idle
    /// app with no warmed models isn't waking up every 2 minutes for nothing.
    func deregister(_ identifier: String) {
        guard targets.removeValue(forKey: identifier) != nil else { return }
        log.info("KeepAliveService: deregistered '\(identifier)' (\(targets.count) target(s))")
        if targets.isEmpty { stopTimer() }
    }

    /// A buffer of `silenceDuration` seconds of silence at 16 kHz - the standard
    /// payload for the ASR and VAD ping closures.
    func silenceClip() -> [Float] {
        [Float](repeating: 0, count: Int(silenceDuration * targetSampleRate))
    }

    // MARK: - Timer

    private func scheduleTimerIfNeeded() {
        guard timer == nil else { return }
        // Install the timer in `.common` mode rather than via `scheduledTimer(...)`,
        // which only registers in `.default` mode. A menu-bar app spends real time in
        // event-tracking / modal run-loop modes (open menu, Settings sheet, window
        // drag) - a `.default`-only timer silently pauses during exactly those idle
        // windows, letting the OS evict the model the keep-alive is meant to protect.
        let timer = Timer(timeInterval: keepAliveInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.info("KeepAliveService: timer started (interval=\(Int(keepAliveInterval))s)")
    }

    private func stopTimer() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        pingTask?.cancel()
        pingTask = nil
        log.info("KeepAliveService: timer stopped")
    }

    /// Pause pinging entirely while transcription is disabled, resume when it
    /// comes back. Targets are preserved across the toggle so we don't depend on
    /// providers re-running `warmup()` (which short-circuits when already warmed)
    /// to re-register them.
    private func observeTranscriptionEnabledIfNeeded() {
        guard !isObservingDefaults else { return }
        isObservingDefaults = true
        Defaults.publisher(.transcriptionEnabled)
            .sink { [weak self] change in
                guard let self else { return }
                Task { @MainActor in
                    if change.newValue {
                        if !self.targets.isEmpty { self.scheduleTimerIfNeeded() }
                    } else {
                        self.stopTimer()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Ping

    private func tick() async {
        guard Defaults[.transcriptionEnabled] else { return }

        // Skip while the user is recording OR while a just-finished recording is
        // still being decoded. `isTranscribing` flips false the moment recording
        // stops, but the real ASR + LLM cleanup runs afterward under
        // `state.isProcessing` - pinging then would contend with the user's own
        // inference and add the very latency keep-alive exists to hide. Same for an
        // offline job (re-transcription, file transcription), which keeps the
        // models busy on its own.
        let manager = TranscriptionManager.shared
        guard !manager.isTranscribing, !manager.state.isProcessing, !manager.isTranscribingOffline else {
            log.debug("KeepAliveService: skipping tick - transcription active or processing")
            return
        }

        // Re-entrancy guard: never run two ping batches at once. Each ping is
        // time-bounded (pingTimeoutSeconds), so a batch always finishes well within
        // the 120s interval; this only trips if an engine genuinely wedges, and it
        // keeps the single `pingTask` handle valid for cancellation.
        guard pingTask == nil else {
            log.debug("KeepAliveService: skipping tick - previous ping batch still running")
            return
        }

        // Snapshot the targets so a ping that triggers (de)registration can't
        // mutate the collection mid-iteration. Pings run sequentially to avoid
        // ANE/GPU contention between backends. A target deregistered after the
        // snapshot self-skips via its `isActive` check (engine no longer loaded).
        let current = Array(targets.values)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for target in current {
                if Task.isCancelled { return }
                await self.ping(target)
            }
        }
        pingTask = task
        await task.value
        pingTask = nil
    }

    private func ping(_ target: KeepAliveTarget) async {
        let pingType = "keepalive_\(target.identifier)"

        guard await target.isActive() else {
            log.debug("KeepAliveService: skipping '\(target.identifier)' - inactive")
            AnalyticsManager.Transcription.modelPing(pingType: pingType, durationMs: 0, status: "skipped")
            return
        }

        let start = Date()
        // Bound every ping so one hung engine can't stall the sequential loop and
        // pile future ticks behind it. A timeout surfaces as a normal "error" ping.
        let work = target.ping
        do {
            try await withThrowingTimeout(seconds: pingTimeoutSeconds) {
                try await work()
            }
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.debug("KeepAliveService: ping '\(target.identifier)' ok (\(Int(durationMs))ms)")
            AnalyticsManager.Transcription.modelPing(pingType: pingType, durationMs: durationMs, status: "ok")
        } catch is CancellationError {
            // Service paused/stopped mid-ping - expected, not an error.
        } catch {
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.warning("KeepAliveService: ping '\(target.identifier)' failed: \(error.localizedDescription)")
            AnalyticsManager.Transcription.modelPing(pingType: pingType, durationMs: durationMs, status: "error")
        }
    }
}
