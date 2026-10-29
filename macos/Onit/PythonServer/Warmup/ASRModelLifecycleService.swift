// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelLifecycleService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-15.
//
//  Unloads the resident ASR model after a configurable period of dictation
//  inactivity to reclaim RAM (Granite ~8-10 GB, Qwen ~5.5 GB), then reloads it
//  transparently on the next dictation. A measurement spike (feat/asr-keep-alive)
//  showed that idle eviction costs only +80-150 ms on the first inference and
//  reload-from-disk is ≤1 s for every backend except Whisper (~5.4 s) - so the
//  reload is cheap enough to mask behind the user speaking, and the RAM win is
//  the real payoff. The same spike showed keep-alive *pings* buy nothing on the
//  other backends (no-ops on Whisper/Moonshine, MLX has no ANE eviction), so we
//  do NOT generalize pings - only Parakeet keeps its existing ping.
//

import AppKit
import Combine
import Defaults
import Foundation

/// Tracks dictation inactivity and unloads / reloads the active ASR model
/// accordingly. Singleton, main-actor isolated like the rest of the warmup stack.
///
/// **Why this doesn't touch the warmup provider.** Unloading goes straight to the
/// engine via `ASRBackendService.unloadEngine()`, leaving `isWarmedUp` /
/// `isModelReady` / `WarmupCoordinator.isFullyWarmedUp` untouched. From the user's
/// point of view the model is still "ready" (the menu-bar dot and Settings status
/// must not flip to "loading" while they did nothing); it simply reloads on next
/// use. This also sidesteps the re-warmup loop that resetting a provider would
/// trigger via `WarmupCoordinator.checkAndRunWarmups()`.
@MainActor
final class ASRModelLifecycleService {

    // MARK: - Singleton

    static let shared = ASRModelLifecycleService()

    // MARK: - Configuration

    /// How often the wall-clock idle check runs. Coarse on purpose: the timeout
    /// is in minutes, so 30 s granularity is plenty and keeps the timer cheap.
    private let checkInterval: TimeInterval = 30

    /// A reload slower than this is logged as "slow" - the Granite reload anomaly
    /// (one non-reproducible 16-minute reload) is exactly what this surfaces.
    private let reloadWatchdogSeconds: TimeInterval = 30

    private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

    // MARK: - State

    private var checkTimer: Timer?
    /// Wall-clock timestamp of the last dictation activity. Wall-clock (not a
    /// fired-once Timer) so sleep/wake is handled for free: after the Mac wakes,
    /// the next tick sees the elapsed time and unloads if the gap exceeded the
    /// timeout (the ANE/GPU state is gone after sleep anyway).
    private var lastActivity = Date()
    /// True while the model has been unloaded due to inactivity. Guards against
    /// double-unload and tells `recordActivity()` it must re-arm.
    private var isSuspended = false
    private var reArmTask: Task<Void, Never>?
    /// In-flight idle-unload, kept so `reArm()` can await it before reloading -
    /// otherwise a reload could race the unload on the engine actor.
    private var suspendTask: Task<Void, Never>?
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    /// Wall-clock timestamp of the last keep-alive ping (or last activity - a real
    /// dictation counts as a ping). Drives the per-backend ping cadence off the
    /// same `checkInterval` tick.
    private var lastPing = Date()
    /// In-flight keep-alive ping; guards against overlapping pings if one runs
    /// long (e.g. a 2 s Whisper tone).
    private var pingTask: Task<Void, Never>?

    // MARK: - Init

    private init() {}

    // MARK: - Derived config

    /// Inactivity timeout in seconds, or 0 when the feature is disabled
    /// ("never unload"). Read fresh on every tick so a Settings change applies
    /// within one `checkInterval`.
    private var timeoutSeconds: TimeInterval {
        let minutes = Defaults[ConfigKeys.asrInactivityUnloadMinutes]
        return minutes <= 0 ? 0 : Double(minutes) * 60
    }

    // MARK: - Lifecycle

    /// Begin tracking inactivity. Idempotent. Called once at app launch.
    func start() {
        guard !started else { return }
        started = true
        lastActivity = Date()
        scheduleTimer()
        observeWake()
        observeModelChange()
        log.info("ASRModelLifecycleService: started")
    }

    /// Record dictation activity: push the idle deadline forward and, if the
    /// model was idle-unloaded, kick off the reload now so it overlaps the user
    /// speaking. Call at every dictation session boundary (start/stop/cancel).
    func recordActivity() {
        let now = Date()
        lastActivity = now
        // A real dictation just exercised the model - no keep-alive ping needed
        // until a fresh gap elapses.
        lastPing = now
        if isSuspended {
            reArm()
        }
    }

    // MARK: - Private - timer

    private func scheduleTimer() {
        checkTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire during menu tracking / scrolling too - idle is idle.
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to the main actor; the closure is delivered on the main queue
            // but isn't statically main-actor isolated.
            Task { @MainActor in self?.tick() }
        }
    }

    /// Reset lifecycle state when the user switches ASR model/backend. Without
    /// this, `isSuspended` and the in-flight unload/reArm/ping tasks would still
    /// refer to the *previous* backend: e.g. a model switched while suspended
    /// would leave `isSuspended == true` against a fresh, resident model. The
    /// `WarmupCoordinator` already (re)warms the new backend; we only clear our
    /// own bookkeeping so the next tick acts on the new `activeService` cleanly.
    private func observeModelChange() {
        Defaults.publisher(ConfigKeys.selectedASRModelId)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleModelChange() }
            }
            .store(in: &cancellables)
    }

    private func handleModelChange() {
        suspendTask?.cancel()
        suspendTask = nil
        reArmTask?.cancel()
        reArmTask = nil
        pingTask?.cancel()
        pingTask = nil
        isSuspended = false
        let now = Date()
        lastActivity = now
        lastPing = now
        log.info("ASRModelLifecycleService: model changed - lifecycle state reset")
    }

    private func tick() {
        // Honor the master switch: no unloads, no pings when transcription is off.
        guard Defaults[.transcriptionEnabled] else { return }

        // Never unload or ping mid-dictation or mid-offline job (re-transcription,
        // file transcription); treat either as activity so neither deadline can
        // fire the instant it ends.
        let manager = TranscriptionManager.shared
        guard !manager.isTranscribing, !manager.isTranscribingOffline else {
            let now = Date()
            lastActivity = now
            lastPing = now
            return
        }

        // 1) Inactivity unload: free the model's RAM after a long gap.
        let timeout = timeoutSeconds
        if timeout > 0, !isSuspended, activeService.isModelReady,
           Date().timeIntervalSince(lastActivity) >= timeout {
            suspend()
            return // just unloaded - don't also ping this tick
        }

        // 2) Keep-alive: ping the loaded model so the OS doesn't evict it during
        //    the active window (the 5-10 s cold-start seen on 32/64 GB machines).
        maybeKeepAlive()
    }

    private func maybeKeepAlive() {
        guard !isSuspended, pingTask == nil else { return }
        let descriptor = ASRBackendRegistry.descriptor(for: TranscriptionConfig.shared.backend)
        guard let policy = descriptor.keepAlivePolicy else { return }
        guard descriptor.service.isModelReady else { return }
        guard Date().timeIntervalSince(lastPing) >= policy.interval else { return }

        lastPing = Date()
        let clip = policy.makeClip()
        let modelId = TranscriptionConfig.shared.selectedASRModelId

        pingTask = Task { @MainActor in
            defer { pingTask = nil }
            // Defense-in-depth: never let a ping reload a model that isn't
            // resident. `reTranscribe` calls `ensureLoaded` internally, so without
            // this an engine that was freed (idle-unload, memory pressure, a
            // backend-switch race) would be silently reloaded - defeating the
            // unload. The `!isSuspended` guard above is the primary gate; this
            // checks the engine's real state so the invariant doesn't rest on one
            // bool.
            guard await descriptor.isEngineLoaded() else {
                log.debug("ASRModelLifecycleService: skip keep-alive - engine not resident")
                return
            }
            let start = Date()
            do {
                // `reTranscribe` runs the raw engine (no Silero gate); with the
                // model resident (guarded above) its `ensureLoaded` is a no-op -
                // so this exercises the weights and keeps them paged-in without
                // reloading. Result discarded.
                _ = try await ASREngineGate.asr.withEngine {
                    try await descriptor.reTranscribe(clip)
                }
                let durationMs = Date().timeIntervalSince(start) * 1000
                log.debug("ASRModelLifecycleService: keep-alive ping \(modelId) ok (\(Int(durationMs))ms)")
            } catch is CancellationError {
                // Superseded by suspend/backend-switch - expected.
            } catch {
                let durationMs = Date().timeIntervalSince(start) * 1000
                log.warning("ASRModelLifecycleService: keep-alive ping \(modelId) failed: \(error.localizedDescription)")
                AnalyticsManager.Transcription.modelPing(
                    pingType: "keepalive", durationMs: durationMs, status: "error")
            }
        }
    }

    // MARK: - Private - suspend / re-arm

    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true

        let backend = TranscriptionConfig.shared.backend
        let modelId = TranscriptionConfig.shared.selectedASRModelId
        let idleMinutes = Defaults[ConfigKeys.asrInactivityUnloadMinutes]

        // Cancel any in-flight keep-alive ping so it can't page the weights back
        // in while we're unloading. New pings are suppressed by `isSuspended`.
        pingTask?.cancel()
        pingTask = nil

        let service = activeService
        log.info("ASRModelLifecycleService: idle \(idleMinutes) min - unloading \(modelId) to reclaim RAM")
        suspendTask = Task { @MainActor in
            await service.unloadEngine()
            AnalyticsManager.Transcription.asrModelUnloadedForIdle(model: modelId, idleMinutes: idleMinutes)
            log.info("ASRModelLifecycleService: \(modelId) unloaded (\(backend.rawValue))")
        }
    }

    private func reArm() {
        guard isSuspended else { return }
        reArmTask?.cancel()

        let modelId = TranscriptionConfig.shared.selectedASRModelId
        let service = activeService
        let pendingUnload = suspendTask

        reArmTask = Task { @MainActor in
            // Order the reload after any in-flight idle-unload so they can't race
            // on the engine actor (unload nils the model, reload re-materializes it).
            await pendingUnload?.value
            let start = Date()
            do {
                try await service.ensureEngineLoaded()
                // Clear the suspend flag only on success: a failed reload leaves
                // it set so the next dictation retries, while the transcribe-path
                // self-heal still guarantees the model loads before inference.
                isSuspended = false
                let durationMs = Date().timeIntervalSince(start) * 1000
                let slow = durationMs / 1000 > reloadWatchdogSeconds
                let status = slow ? "slow" : "ok"
                if slow {
                    log.warning("ASRModelLifecycleService: reload of \(modelId) took \(Int(durationMs))ms (> watchdog)")
                } else {
                    log.info("ASRModelLifecycleService: \(modelId) reloaded in \(Int(durationMs))ms")
                }
                AnalyticsManager.Transcription.asrModelReloadedAfterIdle(
                    model: modelId, durationMs: durationMs, status: status)

                // Keep-alive resumes automatically: the next tick sees
                // `isSuspended == false` and the model resident, and pings per
                // the active backend's policy.
                lastPing = Date()
            } catch is CancellationError {
                // A newer re-arm (or backend switch) superseded this one; leave
                // `isSuspended` as-is for the successor to resolve.
            } catch {
                let durationMs = Date().timeIntervalSince(start) * 1000
                log.error("ASRModelLifecycleService: reload of \(modelId) failed: \(error.localizedDescription)")
                AnalyticsManager.Transcription.asrModelReloadedAfterIdle(
                    model: modelId, durationMs: durationMs, status: "error")
            }
        }
    }

    // MARK: - Helpers

    private var activeService: ASRBackendService {
        ASRBackendRegistry.descriptor(for: TranscriptionConfig.shared.backend).service
    }
}
