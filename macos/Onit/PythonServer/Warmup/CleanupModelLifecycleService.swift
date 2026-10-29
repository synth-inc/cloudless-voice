// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupModelLifecycleService.swift
//  Onit
//
//  Unloads the resident Smart Cleanup LLMs after a period of dictation
//  inactivity to reclaim RAM, then reloads them transparently on the next
//  dictation. These are the two MLX language models that sit resident between
//  dictations and account for the bulk of Onit's idle footprint:
//
//    • the scoring LLM (`MLXScoringEngine`, Llama 3.2 1B, ~1.25 GB) - the real
//      perplexity-based Smart Cleanup + custom-dictionary NLL gate, and
//    • the improvement LLM (`TranscriptionLLMService`, fine-tuned Llama 3.2 1B,
//      ~680 MB) - N-best selection + Smart Cleanup backtracking.
//
//  This is the cleanup-model analogue of `ASRModelLifecycleService`, and it
//  mirrors that service's design deliberately:
//    - wall-clock `lastActivity` so sleep/wake is handled for free;
//    - `recordActivity()` at every dictation boundary reloads (re-arms) an
//      idle-unloaded model so the reload overlaps the user speaking;
//    - unloading goes straight to the engines, NOT through the warmup providers,
//      so it doesn't flip warmup/UI status or trip `WarmupCoordinator`'s
//      re-warm loop. The registered `KeepAliveService` pings self-skip while a
//      model is unloaded (their `isActive` closures check `isLoaded`) and resume
//      automatically once it reloads, so nothing there needs touching.
//
//  Correctness guarantee. Unlike ASR - whose transcribe path calls
//  `ensureLoaded` internally - the Smart Cleanup path does NOT lazy-load: it
//  gates on `isLoaded` and silently falls back to raw text if the model is gone
//  (`TranscriptionManager` lines ~625 / ~2537). So the reload started at
//  recording start is only a latency optimization; `ensureResidentForCleanup()`
//  is the guarantee, awaited at the top of both cleanup sites (live + the
//  on-demand reTranscribe path, which never fires `recordActivity`).
//
//  Reuses the existing `asrInactivityUnloadMinutes` setting as the shared
//  "unload after N idle minutes" control - the reload here overlaps the whole
//  dictation (not just its tail), so it is if anything safer to evict than ASR.
//

import AppKit
import Combine
import Defaults
import Foundation
import MLX

@MainActor
final class CleanupModelLifecycleService {

    // MARK: - Singleton

    static let shared = CleanupModelLifecycleService()

    // MARK: - Configuration

    /// How often the wall-clock idle check runs. Coarse on purpose - the timeout
    /// is in minutes. Matches `ASRModelLifecycleService`.
    private let checkInterval: TimeInterval = 30

    private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

    // MARK: - State

    private var checkTimer: Timer?
    /// Wall-clock timestamp of the last dictation activity. Wall-clock (not a
    /// fired Timer) so a sleep/wake gap is measured correctly on the next tick.
    private var lastActivity = Date()
    /// True while at least one cleanup model has been unloaded for inactivity.
    /// Guards double-unload and tells `recordActivity()` it must re-arm.
    private var isSuspended = false
    /// In-flight idle-unload, awaited by `reArm()` / `ensureResidentForCleanup()`
    /// so a reload can't race the unload on the scoring-engine actor.
    private var suspendTask: Task<Void, Never>?
    /// In-flight reload kicked off by `recordActivity()`.
    private var reArmTask: Task<Void, Never>?
    /// Guards the async suspend check spawned from the (sync) timer tick.
    private var suspendCheckTask: Task<Void, Never>?
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Derived config

    /// Idle timeout in seconds, or 0 when disabled ("never unload"). Read fresh
    /// each tick so a Settings change applies within one `checkInterval`.
    private var timeoutSeconds: TimeInterval {
        #if DEBUG
        // Test hook: `ONIT_IDLE_UNLOAD_SECONDS=45` forces a short idle timeout so
        // the evict→reload cycle can be exercised in seconds without waiting out
        // the minutes-granularity setting. DEBUG-only; compiled out of Release.
        if let raw = ProcessInfo.processInfo.environment["ONIT_IDLE_UNLOAD_SECONDS"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        let minutes = Defaults[ConfigKeys.asrInactivityUnloadMinutes]
        return minutes <= 0 ? 0 : Double(minutes) * 60
    }

    /// The scoring LLM is needed when Smart Formatting, LM conditioning, or the
    /// custom-dictionary NLL gate can fire. Mirrors `ScoringWarmupProvider.isEnabled`.
    private var scoringNeeded: Bool {
        TranscriptionConfig.isSmartCleanupSelected
            || Defaults[ConfigKeys.lmConditioningEnabled]
            || dictionaryNeedsGate
    }

    private var dictionaryNeedsGate: Bool {
        guard Defaults[.customDictionaryEnabled] else { return false }
        return Defaults[ConfigKeys.backend] == .parakeetCoreML
            || Defaults[.customDictionaryRescoreEnabled]
    }

    /// The improvement LLM is needed for N-best selection or Smart Cleanup
    /// backtracking. Mirrors `ImprovementLLMWarmupProvider.isEnabled`.
    private var improvementNeeded: Bool {
        guard Defaults[.transcriptionEnabled] else { return false }
        let nbest = Defaults[ConfigKeys.nbestSelectionEnabled]
        let smartFormatting = TranscriptionConfig.isSmartCleanupSelected
        let backtracking = Defaults[ConfigKeys.sfBacktrackingEnabled]
        return nbest || (smartFormatting && backtracking)
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
        log.info("CleanupModelLifecycleService: started")
    }

    /// Record dictation activity: push the idle deadline forward and, if a
    /// cleanup model was idle-unloaded, kick off the reload now so it overlaps
    /// the user speaking. Call at every dictation session boundary.
    func recordActivity() {
        lastActivity = Date()
        if isSuspended {
            reArm()
        }
    }

    /// Correctness guarantee for the cleanup path: ensure every currently-needed
    /// cleanup model is resident before the caller reads `isLoaded`. Awaits any
    /// in-flight re-arm first (started at recording start), then loads
    /// synchronously if still suspended - covering the reTranscribe path, which
    /// never calls `recordActivity()`. A no-op (one awaited nil) when nothing was
    /// evicted, so it's cheap to call on every dictation.
    func ensureResidentForCleanup() async {
        // Order AFTER any in-flight idle-unload as well as any reload. Awaiting only
        // the re-arm isn't enough: on the reTranscribe path no re-arm was started
        // (`reArmTask` is nil or a stale completed task), so without awaiting the
        // unload first, `loadNeededNow()` could race `unload()` on the scoring-engine
        // actor and lose - leaving the model unloaded with `isSuspended` cleared,
        // which strands Smart Cleanup on raw text until app restart.
        await suspendTask?.value
        await reArmTask?.value
        guard isSuspended else { return }
        await loadNeededNow()
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
            Task { @MainActor in self?.tick() }
        }
    }

    /// Reset lifecycle state when the user switches the scoring model. Switching
    /// (`ScoringWarmupProvider.switchToSelectedModel`) unloads then re-warms the
    /// shared `MLXScoringEngine`, so the engine ends up resident - but our
    /// `isSuspended`/in-flight tasks would still refer to the pre-switch state
    /// (e.g. `isSuspended == true` against a now-resident model, which `tick()`
    /// won't re-unload). Clear our own bookkeeping so the next tick acts cleanly.
    private func observeModelChange() {
        Defaults.publisher(.selectedScoringModelId)
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
        suspendCheckTask?.cancel()
        suspendCheckTask = nil
        isSuspended = false
        lastActivity = Date()
        log.info("CleanupModelLifecycleService: scoring model changed - lifecycle state reset")
    }

    private func tick() {
        // Honor the master switch: no unloads while transcription is off.
        guard Defaults[.transcriptionEnabled] else { return }

        // Never unload mid-dictation, mid-cleanup, or mid-offline job.
        // `isTranscribing` covers capture; `state.isProcessing` covers the ASR +
        // cleanup after recording stops; `isTranscribingOffline` covers the
        // re-run of a history row and a file transcription (which never call
        // `recordActivity()`, so their models would otherwise be yanked
        // mid-pipeline). Treat any as activity so the deadline can't fire the
        // instant one ends.
        let manager = TranscriptionManager.shared
        guard !manager.isTranscribing, !manager.state.isProcessing, !manager.isTranscribingOffline else {
            lastActivity = Date()
            return
        }

        let timeout = timeoutSeconds
        let idle = Date().timeIntervalSince(lastActivity)
        log.debug("CleanupModelLifecycleService: tick - idle=\(Int(idle))s timeout=\(Int(timeout))s "
            + "suspended=\(isSuspended) transcribing=\(manager.isTranscribing) processing=\(manager.state.isProcessing)")
        guard timeout > 0, !isSuspended, suspendCheckTask == nil else { return }
        guard idle >= timeout else { return }

        suspendCheckTask = Task { @MainActor in
            defer { suspendCheckTask = nil }
            await maybeSuspend()
        }
    }

    // MARK: - Private - suspend / re-arm

    private func maybeSuspend() async {
        guard !isSuspended else { return }

        // Only suspend what's actually resident. Reading the loaded state here
        // (rather than the consumer flags) means a model the user never warmed
        // isn't counted, and we don't flip `isSuspended` with nothing to free.
        let scoringLoaded = await MLXScoringEngine.shared.isLoaded
        let improvementLoaded = TranscriptionLLMService.shared.isImprovementModelLoaded
        guard scoringLoaded || improvementLoaded else { return }

        // Re-assert idle AFTER the async `isLoaded` hop. `tick()` checked activity
        // before spawning this task; in the gap the user may have started a
        // dictation/reTranscribe (whose `recordActivity()` ran while `isSuspended`
        // was still false, so it did NOT arm a reload). Unloading now would pull
        // the models out from under an active session.
        let manager = TranscriptionManager.shared
        guard !manager.isTranscribing, !manager.state.isProcessing, !manager.isTranscribingOffline,
              timeoutSeconds > 0,
              Date().timeIntervalSince(lastActivity) >= timeoutSeconds
        else { return }

        isSuspended = true
        log.info("CleanupModelLifecycleService: idle \(Int(timeoutSeconds))s - unloading cleanup LLM(s) "
            + "(scoring=\(scoringLoaded) improvement=\(improvementLoaded))")

        suspendTask = Task { @MainActor in
            if scoringLoaded { await MLXScoringEngine.shared.unload() }
            if improvementLoaded { TranscriptionLLMService.shared.unloadModel() }
            // Drop the MLX buffer pool so the IOAccelerator footprint actually
            // falls - same rationale as the warmup providers' `reset()`.
            MLXRuntime.clearCache()
            log.info("CleanupModelLifecycleService: cleanup LLM(s) unloaded")
        }
    }

    private func reArm() {
        guard isSuspended else { return }
        reArmTask?.cancel()
        let pendingUnload = suspendTask
        reArmTask = Task { @MainActor in
            // Order the reload after any in-flight idle-unload so they can't race
            // on the engine actor.
            await pendingUnload?.value
            await self.loadNeededNow()
        }
    }

    /// Reload every currently-needed cleanup model, clearing `isSuspended` only on
    /// full success so a failed reload retries on the next activity while the
    /// cleanup-site `ensureResidentForCleanup()` still guarantees a load attempt.
    private func loadNeededNow() async {
        let start = Date()
        do {
            if scoringNeeded { try await MLXScoringEngine.shared.ensureLoaded() }
            if improvementNeeded { try await TranscriptionLLMService.shared.loadImprovementModel() }
            isSuspended = false
            let durationMs = Date().timeIntervalSince(start) * 1000
            log.info("CleanupModelLifecycleService: cleanup LLM(s) reloaded in \(Int(durationMs))ms")
        } catch is CancellationError {
            // Superseded by a newer re-arm; leave `isSuspended` for the successor.
        } catch {
            log.error("CleanupModelLifecycleService: cleanup LLM reload failed: \(error.localizedDescription)")
        }
    }
}
