// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRBackend.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-06-04.
//

@preconcurrency import AVFoundation
import Foundation

/// The uniform surface every per-backend ASR *service* exposes to
/// `TranscriptionManager` (audio accumulation + the transcribe envelope). The
/// `ASRService` base conforms for the simple wrappers; `ParakeetCoreMLASRService`
/// and `FluidAudioASRService` conform directly (they already implement it).
@MainActor
protocol ASRBackendService: AnyObject {
    var accumulatedSamples: [Float] { get }
    var accumulatedDuration: Double { get }
    var isModelReady: Bool { get }
    func reset()
    func appendAudio(_ buffer: AVAudioPCMBuffer)
    func transcribe() async throws -> ([NbestHypothesis], String?, Bool)
    func markAsReady()

    /// Load the underlying engine for the currently-selected model if it isn't
    /// already resident. Idempotent and cheap when loaded. Two callers:
    /// `ASRModelLifecycleService` re-arms with this at dictation start (so the
    /// reload overlaps the user speaking), and the `transcribe()` path calls it
    /// defensively so an idle-unloaded engine self-heals instead of throwing
    /// `.modelNotLoaded`.
    func ensureEngineLoaded() async throws

    /// Drop the engine's weights to reclaim RAM after inactivity. Unlike the
    /// warmup provider's `reset()`, this does NOT clear `isModelReady` / warmup
    /// state - from the user's point of view the model is still "ready" and the
    /// menu-bar/Settings status must not flip to "loading"; the next transcribe
    /// reloads transparently.
    func unloadEngine() async
}

/// Per-backend keep-alive policy: how to keep a *loaded* model warm between
/// dictations so the OS doesn't evict it (which costs 5-10 s of cold-start on
/// memory-constrained machines - 32/64 GB field reports). Distinct from
/// unload-on-idle, which deliberately frees the model after a long gap; the two
/// coexist (keep-alive covers the active window, unload covers "done for a while").
///
/// **The clip matters.** A measurement spike showed VAD-gated engines (Whisper,
/// Moonshine) short-circuit silent / near-silent clips *inside the engine*, so a
/// silent ping keeps nothing warm there - they need ~2 s of audible signal to run
/// the encoder and keep the weights resident. Parakeet and MLX have no such gate
/// and stay warm on cheap silence.
struct ASRKeepAlivePolicy {
    /// Seconds between pings. 120 s keeps inside the ~5 min OS eviction window.
    let interval: TimeInterval
    /// Builds the ping clip (16 kHz mono float32), chosen to actually run this
    /// backend's compute.
    let makeClip: @MainActor () -> [Float]

    /// 16 kHz mono silence - cheapest ping; only keeps non-gated engines warm
    /// (Parakeet, MLX).
    @MainActor static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// 16 kHz mono 440 Hz tone at `amplitude`. Enough signal to pass the internal
    /// energy/VAD gate of WhisperKit / Moonshine so the encoder actually runs.
    @MainActor static func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * 16_000)
        let sampleRate: Float = 16_000
        return (0..<count).map { amplitude * sin(2 * .pi * 440 * Float($0) / sampleRate) }
    }
}

/// Everything `TranscriptionManager` / `ASRModelDownloadManager` /
/// `SettingsTranscriptionBehavior` need to route a `TranscriptionBackend`,
/// gathered in one value so the routing layers dispatch through the registry
/// instead of a switch per concern. Adding a backend = register one descriptor.
@MainActor
struct ASRBackendDescriptor {
    let service: ASRBackendService
    let warmupProvider: any WarmupProvider
    /// Raw engine transcription used by the re-transcribe path (corrections).
    let reTranscribe: @MainActor (_ samples: [Float]) async throws -> String
    /// Canonical on-disk directory for a model's weights (nil if N/A).
    let installDirectory: @MainActor (_ model: ASRModel) -> URL?
    /// Whether the model's bundle is fully present on disk.
    let isInstalledOnDisk: @MainActor (_ model: ASRModel) -> Bool
    /// Download the model's bundle, teeing into `progress`.
    let download: @MainActor (_ model: ASRModel, _ progress: AtomicProgress?) async throws -> Void
    /// Drop the engine + reset the warmup provider when a download replaces the
    /// on-disk model. No-op for backends not exposed in the picker (FluidAudio).
    let unloadForReplacedDownload: @MainActor (_ modelId: String) async -> Void

    /// How to keep this backend warm between dictations, or nil for backends that
    /// don't need / can't use keep-alive (FluidAudio is framework-managed and not
    /// in the picker). Driven by `ASRModelLifecycleService`.
    let keepAlivePolicy: ASRKeepAlivePolicy?

    /// Whether the engine's weights are physically resident right now. Distinct
    /// from `isWarmedUp`/`isModelReady` (which an idle-unload deliberately leaves
    /// `true`): this reflects the engine itself. `ASRModelLifecycleService` uses
    /// it as a hard guard so a keep-alive ping can never accidentally reload a
    /// model that was just unloaded-on-idle.
    let isEngineLoaded: @MainActor () async -> Bool

    /// Whether this backend's engine can be driven segment-by-segment during
    /// recording (the chunked-streaming path). Registry-resolved: set `true`
    /// only for backends whose engine conforms to `StreamingASRCapable`
    /// (Parakeet, MLX); the streaming pipeline gates on this and otherwise stays
    /// single-shot. Defaults to `false` so non-streaming backends need not set it.
    var supportsChunkedStreaming: Bool = false

    /// The engine that drives this backend's chunked-streaming path, erased to
    /// `StreamingASRCapable`, or `nil` for single-shot-only backends. Set only
    /// for `.parakeetCoreML` and `.mlx` (the `supportsChunkedStreaming == true`
    /// backends). `TranscriptionManager` reaches the streaming engine through
    /// here so the registry stays the single `switch` over `TranscriptionBackend`
    /// - the same reason `reTranscribe` is a descriptor closure.
    ///
    /// Deliberately **non-isolated** (unlike the other descriptor closures): the
    /// erased `any StreamingASRCapable` isn't statically `Sendable`, and the
    /// owning `StreamingDictationSession` takes its engine as a `sending`
    /// parameter. A `@MainActor`-isolated closure's non-Sendable result would sit
    /// in the MainActor region and couldn't be transferred; a non-isolated
    /// closure's result is region-disconnected, so it transfers cleanly. The body
    /// only reads the engine's nonisolated `static let shared`, so no isolation is
    /// needed anyway.
    var streamingEngine: () -> (any StreamingASRCapable)? = { nil }

    var providerId: String { warmupProvider.identifier }
    var isWarmedUp: Bool { warmupProvider.isWarmedUp }
}

/// The single registration point: `TranscriptionBackend` -> descriptor. This is
/// the only `switch` over the backend enum; every other site dispatches through
/// `descriptor(for:)`.
@MainActor
enum ASRBackendRegistry {

    /// Built lazily once per backend (the descriptor's closures only capture
    /// singletons/statics, so a cached instance is safe). MainActor-isolated,
    /// so reads/writes are serialized.
    private static var cache: [TranscriptionBackend: ASRBackendDescriptor] = [:]

    /// The descriptor for `backend` - the one place that maps the enum to a
    /// backend. Every other site dispatches through here.
    static func descriptor(for backend: TranscriptionBackend) -> ASRBackendDescriptor {
        if let cached = cache[backend] { return cached }
        let descriptor = build(backend)
        cache[backend] = descriptor
        return descriptor
    }

    /// Construct the descriptor (not a static `let` so it runs in this
    /// MainActor-isolated method, where the shared singletons are reachable).
    private static func build(_ backend: TranscriptionBackend) -> ASRBackendDescriptor {
        switch backend {
        case .parakeetCoreML:
            return ASRBackendDescriptor(
                service: ParakeetCoreMLASRService.shared,
                warmupProvider: ParakeetCoreMLWarmupProvider.shared,
                reTranscribe: {
                    // Self-heal: the engine may have been idle-unloaded while the
                    // correction overlay sat open past the inactivity timeout.
                    try await ParakeetCoreMLEngine.shared.ensureLoaded()
                    return try await ParakeetCoreMLEngine.shared.transcribe($0, language: nil)
                },
                installDirectory: { _ in HuggingFaceModelDownloader.parakeetDirectory },
                // Per-file validation, NOT bare directory existence: a cancelled
                // download can leave the dir holding a partial bundle that would
                // crash on load (the bug PR #599 fixed).
                isInstalledOnDisk: { _ in HuggingFaceModelDownloader.shared.isParakeetDownloaded() },
                download: { _, progress in
                    try await HuggingFaceModelDownloader.shared.downloadParakeetIfNeeded()
                    progress?.set(1)
                },
                unloadForReplacedDownload: { _ in
                    await ParakeetCoreMLEngine.shared.unload()
                    ParakeetCoreMLWarmupProvider.shared.reset()
                },
                // CoreML/ANE, no internal VAD gate - cheap silent ping keeps it warm.
                keepAlivePolicy: ASRKeepAlivePolicy(
                    interval: 120,
                    makeClip: { ASRKeepAlivePolicy.silence(seconds: 0.5) }),
                isEngineLoaded: { await ParakeetCoreMLEngine.shared.isLoaded },
                supportsChunkedStreaming: true,
                streamingEngine: { ParakeetCoreMLEngine.shared })

        case .canaryCoreML:
            return ASRBackendDescriptor(
                service: CanaryCoreMLASRService.shared,
                warmupProvider: CanaryCoreMLWarmupProvider.shared,
                reTranscribe: {
                    try await CanaryCoreMLEngine.shared.ensureLoaded()
                    let language = await CanaryCoreMLASRService.forcedLanguage()
                    return try await CanaryCoreMLEngine.shared.transcribe($0, language: language)
                },
                installDirectory: { _ in HuggingFaceModelDownloader.canaryDirectory },
                isInstalledOnDisk: { _ in HuggingFaceModelDownloader.shared.isCanaryDownloaded() },
                download: { _, progress in
                    try await HuggingFaceModelDownloader.shared
                        .downloadCanaryIfNeeded(progress: progress ?? AtomicProgress())
                    progress?.set(1)
                },
                unloadForReplacedDownload: { _ in
                    await CanaryCoreMLEngine.shared.unload()
                    CanaryCoreMLWarmupProvider.shared.reset()
                },
                keepAlivePolicy: ASRKeepAlivePolicy(
                    interval: 120,
                    makeClip: { ASRKeepAlivePolicy.silence(seconds: 0.5) }),
                isEngineLoaded: { await CanaryCoreMLEngine.shared.isLoaded })

        case .whisperCoreML:
            return ASRBackendDescriptor(
                service: WhisperCoreMLASRService.shared,
                warmupProvider: WhisperCoreMLWarmupProvider.shared,
                reTranscribe: {
                    try await WhisperCoreMLEngine.shared.ensureLoaded(
                        modelId: TranscriptionConfig.shared.selectedASRModelId)
                    return try await WhisperCoreMLEngine.shared.transcribe(samples: $0, language: nil)
                },
                installDirectory: { WhisperCoreMLEngine.expectedModelDirectory(forModelId: $0.id) },
                // Per-file validation of the 3 `.mlmodelc` components - a partial
                // download must not report as installed (PR #599).
                isInstalledOnDisk: { WhisperCoreMLEngine.isModelComplete(forModelId: $0.id) },
                download: { model, progress in
                    try await HuggingFaceModelDownloader.shared.downloadWhisperIfNeeded(
                        modelId: model.id, externalProgress: progress)
                },
                unloadForReplacedDownload: { modelId in
                    await WhisperCoreMLEngine.shared.unloadIfCurrent(modelId: modelId)
                    WhisperCoreMLWarmupProvider.shared.reset()
                },
                // WhisperKit gates on energy: a silent ping is a no-op (proven by
                // the spike), so warm it with ~2 s of audible tone to run the encoder.
                keepAlivePolicy: ASRKeepAlivePolicy(
                    interval: 120,
                    makeClip: { ASRKeepAlivePolicy.tone(seconds: 2.0, amplitude: 0.2) }),
                isEngineLoaded: { await WhisperCoreMLEngine.shared.isLoaded })

        case .moonshineONNX:
            return ASRBackendDescriptor(
                service: MoonshineASRService.shared,
                warmupProvider: MoonshineWarmupProvider.shared,
                reTranscribe: {
                    try await MoonshineEngine.shared.ensureLoaded(
                        modelId: TranscriptionConfig.shared.selectedASRModelId)
                    return try await MoonshineEngine.shared.transcribe(samples: $0, language: nil)
                },
                installDirectory: { MoonshineEngine.expectedModelDirectory(forModelId: $0.id) },
                isInstalledOnDisk: { HuggingFaceModelDownloader.shared.isMoonshineDownloaded(modelId: $0.id) },
                download: { model, progress in
                    try await HuggingFaceModelDownloader.shared.downloadMoonshineIfNeeded(
                        modelId: model.id, externalProgress: progress)
                },
                unloadForReplacedDownload: { modelId in
                    await MoonshineEngine.shared.unloadIfCurrent(modelId: modelId)
                    MoonshineWarmupProvider.shared.reset()
                },
                // Moonshine also gates on energy - warm it with audible tone.
                keepAlivePolicy: ASRKeepAlivePolicy(
                    interval: 120,
                    makeClip: { ASRKeepAlivePolicy.tone(seconds: 2.0, amplitude: 0.2) }),
                isEngineLoaded: { await MoonshineEngine.shared.isLoaded })

        case .mlx:
            return ASRBackendDescriptor(
                service: MLXASRService.shared,
                warmupProvider: MLXWarmupProvider.shared,
                reTranscribe: {
                    try await MLXASREngine.shared.ensureLoaded(
                        modelId: TranscriptionConfig.shared.selectedASRModelId)
                    return try await MLXASREngine.shared.transcribe(samples: $0, language: nil)
                },
                installDirectory: { MLXModelRegistry.expectedDirectory(for: $0.id) },
                isInstalledOnDisk: { HuggingFaceModelDownloader.shared.isMLXModelDownloaded(modelId: $0.id) },
                download: { model, progress in
                    try await HuggingFaceModelDownloader.shared.downloadMLXModelIfNeeded(
                        modelId: model.id, externalProgress: progress)
                },
                unloadForReplacedDownload: { modelId in
                    await MLXASREngine.shared.unloadIfCurrent(modelId: modelId)
                    MLXWarmupProvider.shared.reset()
                },
                // MLX (Qwen3/Granite) has no VAD gate and runs compute on silence;
                // a cheap silent ping keeps the unified-memory weights resident.
                keepAlivePolicy: ASRKeepAlivePolicy(
                    interval: 120,
                    makeClip: { ASRKeepAlivePolicy.silence(seconds: 0.5) }),
                isEngineLoaded: { await MLXASREngine.shared.isLoaded },
                supportsChunkedStreaming: true,
                streamingEngine: { MLXASREngine.shared })

        case .fluidAudio:
            return ASRBackendDescriptor(
                service: FluidAudioASRService.shared,
                warmupProvider: FluidAudioWarmupProvider.shared,
                reTranscribe: { try await FluidAudioASRService.shared.transcribe($0) },
                installDirectory: { _ in nil },
                isInstalledOnDisk: { _ in false },
                // FluidAudio is framework-managed and not exposed in the picker.
                download: { _, _ in throw WhisperCoreMLError.unsupportedModel(id: "fluidAudio") },
                unloadForReplacedDownload: { _ in },
                // Not in the picker → never the active backend; no keep-alive.
                keepAlivePolicy: nil,
                isEngineLoaded: { FluidAudioASRService.shared.isModelReady })
        }
    }
}
