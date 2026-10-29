// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionBacktestRunner.swift
//  Onit
//
//  Replays the audio of the user's corrected transcripts through a set of
//  candidate ASR models and scores every output against the saved correction
//  (the ground truth the user wrote). Models that aren't installed yet are
//  downloaded first (through ASRModelDownloadManager, so Settings reflects
//  them too). Runs model-by-model so variant-hosting engines (MLX, Whisper)
//  load each model exactly once.
//
//  Concurrency: the backtest drives the *same* singleton ASR engines that live
//  dictation uses, swapping their loaded model out from under everything else.
//  To prevent a dictation from being transcribed by a candidate model (and
//  saved as the selected one), the runner takes exclusive use of the ASR
//  engines for the duration of a run - `isRunning` gates `startTranscription`,
//  and the run refuses to start while a dictation is in flight.
//

import Foundation

@MainActor
final class CorrectionBacktestRunner: ObservableObject {

    // MARK: - Types

    enum Phase: Equatable {
        case idle
        case downloading
        case running
        case finished
        case failed(String)
    }

    struct ModelRun {
        /// `nil` when transcription threw for this case (skipped in the mean).
        let transcript: String?
        let wer: Double?
    }

    struct CaseResult: Identifiable {
        let id: Int64
        /// The user's correction - the ground truth everything is scored against.
        let reference: String
        /// Replayed transcripts keyed by candidate model id.
        var runs: [String: ModelRun]
    }

    // MARK: - Exclusive ASR access

    /// True while a backtest holds the shared ASR engines. `startTranscription`
    /// checks this and refuses to start a dictation - otherwise the dictation
    /// would run through whatever candidate model the backtest last loaded.
    @MainActor private(set) static var isRunning = false

    // MARK: - Published

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [CaseResult] = []
    @Published private(set) var completedSteps: Int = 0
    @Published private(set) var totalSteps: Int = 0
    @Published private(set) var currentModelName: String = ""
    /// 0…1 while `phase == .downloading`.
    @Published private(set) var downloadFraction: Double = 0
    /// Models that actually ran (selected minus failed downloads) - what the
    /// results view renders columns for.
    @Published private(set) var testedModels: [ASRModel] = []
    /// Display names of selected models whose download failed.
    @Published private(set) var skippedModels: [String] = []
    /// Total replayable cases the run scored against (denominator for coverage).
    @Published private(set) var scoredCaseCount: Int = 0

    // MARK: - Private

    private var isCancelled = false

    /// Hard ceiling regardless of the user's case-count choice - a multi-model
    /// run over an unbounded history must stay tractable. Generous on purpose:
    /// audio is loaded lazily per case (not all upfront), so this bounds run
    /// time, not memory.
    static let maxCases = 500

    /// Minimum replayable corrections before a backtest is worth running - WER
    /// over a handful of clips is statistical noise. Doubles as the goal the
    /// Transcripts banner nudges the user toward.
    static let minCases = 25

    // MARK: - API

    /// A row the backtest can replay: a saved correction and its audio still on disk.
    /// File transcripts are left out: the backtest measures the models on the user's
    /// dictations, and a long file would be replayed in one engine call. Shared with
    /// the sheet's case count so the two never disagree.
    static func isReplayable(_ row: TranscriptionHistory, historyManager: TranscriptionHistoryManager) -> Bool {
        guard !row.isFromFile,
              let reference = row.correctedTranscription,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return historyManager.audioFileURL(for: row) != nil
    }

    /// Mean WER across all scored cases for a candidate model id.
    func meanWER(modelId: String) -> Double? {
        let wers = results.compactMap { $0.runs[modelId]?.wer }
        guard !wers.isEmpty else { return nil }
        return wers.reduce(0, +) / Double(wers.count)
    }

    /// How many cases this model actually produced a score for (failures and
    /// not-yet-run cases excluded) - the denominator behind `meanWER`, surfaced
    /// so a model that failed most cases can't hide behind a flattering mean.
    func scoredCount(modelId: String) -> Int {
        results.reduce(0) { $0 + ($1.runs[modelId]?.wer != nil ? 1 : 0) }
    }

    func cancel() {
        isCancelled = true
    }

    func start(models: [ASRModel], caseLimit: Int) async {
        guard phase != .running && phase != .downloading else { return }

        // Exclusive-use guard: never run while a dictation is recording or its
        // post-recording inference is still in flight (`isTranscribing` flips
        // false before inference completes, so check `isProcessing` too).
        let manager = TranscriptionManager.shared
        guard !manager.isTranscribing, !manager.state.isProcessing else {
            phase = .failed(String.localized(
                "Finish your current dictation before testing models.",
                table: "App"
            ))
            return
        }
        guard !FileTranscriptionService.shared.isRunning else {
            phase = .failed(String.localized(
                "Wait for the audio file to finish transcribing before testing models.",
                table: "App"
            ))
            return
        }

        isCancelled = false
        results = []
        completedSteps = 0
        scoredCaseCount = 0
        skippedModels = []
        testedModels = []

        Self.isRunning = true
        defer { Self.isRunning = false }

        // Stage 0: download anything the user selected that isn't on disk.
        // A failed download skips that model rather than killing the run.
        var runnable: [ASRModel] = []
        for model in models {
            if await ensureDownloaded(model) {
                runnable.append(model)
            } else if isCancelled {
                phase = .idle
                return
            } else {
                skippedModels.append(model.displayName)
            }
        }

        guard !runnable.isEmpty else {
            phase = .failed(String.localized(
                "The selected models couldn't be downloaded. Check your connection and try again.",
                table: "App"
            ))
            return
        }
        testedModels = runnable

        phase = .running

        let historyManager = TranscriptionHistoryManager.shared
        let corrected = await historyManager.fetchPaginated(
            limit: min(max(caseLimit, 1), Self.maxCases),
            offset: 0,
            sortOrder: .newest,
            reviewStatus: .corrected
        )

        // Audio samples are loaded lazily inside the run loop (not all upfront)
        // so a 500-case run doesn't allocate gigabytes.
        let cases = corrected.filter { Self.isReplayable($0, historyManager: historyManager) }

        guard !cases.isEmpty else {
            phase = .failed(String.localized(
                "None of your corrections still have their audio on disk.",
                table: "App"
            ))
            return
        }

        scoredCaseCount = cases.count
        totalSteps = cases.count * runnable.count

        results = cases.map { item in
            CaseResult(
                id: item.id ?? -1,
                reference: item.correctedTranscription ?? "",
                runs: [:]
            )
        }

        // Model-major order: variant engines (MLX, Whisper) swap weights on
        // ensureLoaded, so visiting case-major would reload per step. The same
        // audio file is therefore re-read once per model - cheap (small WAVs)
        // and far safer than holding every clip in memory at once.
        for model in runnable {
            currentModelName = model.displayName
            for (index, item) in cases.enumerated() {
                if isCancelled {
                    phase = .finished
                    await restoreSelectedModel()
                    return
                }
                guard let samples = await loadSamples(for: item),
                      !samples.isEmpty
                else {
                    results[index].runs[model.id] = ModelRun(transcript: nil, wer: nil)
                    completedSteps += 1
                    continue
                }
                do {
                    let transcript = try await transcribe(model: model, samples: samples)
                    results[index].runs[model.id] = ModelRun(
                        transcript: transcript,
                        wer: BacktestMetrics.wer(
                            reference: results[index].reference,
                            hypothesis: transcript
                        )
                    )
                } catch {
                    log.error("Backtest: \(model.id) failed on case \(item.id ?? -1): \(error)")
                    results[index].runs[model.id] = ModelRun(transcript: nil, wer: nil)
                }
                completedSteps += 1
            }
        }

        await restoreSelectedModel()
        phase = .finished
    }

    // MARK: - Private Functions

    /// Loads (and resamples) a row's audio off the main actor so a large run
    /// doesn't hitch the UI on each disk read.
    private func loadSamples(for item: TranscriptionHistory) async -> [Float]? {
        let historyManager = TranscriptionHistoryManager.shared
        return await Task.detached {
            historyManager.loadAudioSamples(for: item)
        }.value
    }

    /// Returns once the model is on disk (true) or its download failed /
    /// the run was cancelled (false). Downloads go through
    /// `ASRModelDownloadManager` so install state stays consistent with the
    /// Settings picker, and a download the user kicked off there is awaited
    /// here rather than started twice.
    private func ensureDownloaded(_ model: ASRModel) async -> Bool {
        let manager = ASRModelDownloadManager.shared

        if manager.installState(for: model) == .installed { return true }

        phase = .downloading
        currentModelName = model.displayName
        downloadFraction = 0
        manager.download(model)

        while manager.installState(for: model) == .downloading {
            if isCancelled {
                // The download itself is left running - it'll finish in the
                // background and the model will simply be installed next time.
                return false
            }
            downloadFraction = manager.progress(for: model).value
            try? await Task.sleep(for: .milliseconds(200))
        }
        return manager.installState(for: model) == .installed
    }

    private func transcribe(model: ASRModel, samples: [Float]) async throws -> String {
        // Make sure the backend's engine is resident before transcribing -
        // `reTranscribe` throws `modelNotLoaded` otherwise. Variant-hosting
        // engines (MLX/Whisper/Moonshine) also pin the requested variant here;
        // Parakeet is single-model but still needs loading when it isn't the
        // user's selected model (e.g. they dictate with Qwen).
        switch model.backend {
        case .mlx:
            try await MLXASREngine.shared.ensureLoaded(modelId: model.id)
        case .whisperCoreML:
            try await WhisperCoreMLEngine.shared.ensureLoaded(modelId: model.id)
        case .moonshineONNX:
            try await MoonshineEngine.shared.ensureLoaded(modelId: model.id)
        case .parakeetCoreML:
            try await ParakeetCoreMLEngine.shared.ensureLoaded()
        case .canaryCoreML:
            try await CanaryCoreMLEngine.shared.ensureLoaded()
        case .fluidAudio:
            break
        }
        return try await ASREngineGate.asr.withEngine {
            try await ASRBackendRegistry.descriptor(for: model.backend).reTranscribe(samples)
        }
    }

    /// A backtest swaps variant-hosting engines to candidate models *behind the
    /// warmup providers' backs* - the providers still believe the selected model
    /// is loaded. Restore by going through each touched provider's own
    /// `reset()` → `warmup()` path: `warmup()` internally awaits the teardown
    /// `reset()` enqueues before reloading, so the selected model ends up loaded
    /// with no unload-after-load race (the bug a separate `ensureLoaded` task
    /// had). Awaited before the run is declared finished so a dictation started
    /// from the results screen can't hit `modelNotLoaded`.
    private func restoreSelectedModel() async {
        let touchedBackends = Set(testedModels.map(\.backend))
        let selectedBackend = TranscriptionConfig.shared.selectedASRModel.backend

        for backend in touchedBackends {
            let provider = ASRBackendRegistry.descriptor(for: backend).warmupProvider
            provider.reset()
            // Re-warm only the backend the user actually dictates with; other
            // touched backends stay unloaded (correct - they free memory and
            // the coordinator won't re-warm a non-selected backend).
            if backend == selectedBackend {
                try? await provider.warmup()
            }
        }
    }
}
