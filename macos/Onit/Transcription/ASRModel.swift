// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModel.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation

/// On-device automatic speech recognition model exposed in the "Local AI Models"
/// settings sheet. One row in the picker = one `ASRModel`. Each entry pins the
/// inference backend so the user-facing selection translates unambiguously into
/// a routing decision in `TranscriptionManager`.
struct ASRModel: Identifiable, Hashable, Sendable {

    // MARK: - Identity

    let id: String
    let displayName: String
    let shortDescription: String

    // MARK: - Capability Metadata (UI)

    /// Subjective speed rating on a 0…4 scale; rendered as filled dots in the picker.
    let speedRating: Int
    /// Subjective accuracy rating on a 0…4 scale; rendered as filled dots in the picker.
    let accuracyRating: Int
    /// Approximate on-disk size in bytes (used for the "1.2 GB" label).
    let sizeBytes: Int64
    /// `true` if the model supports more than just English.
    let isMultilingual: Bool

    // MARK: - Wiring

    let isDefault: Bool
    let backend: TranscriptionBackend

    /// `true` for models we ship but don't stand behind for general use. The
    /// picker pulls these out of the normal groups into a dedicated
    /// "Experimental" section with a quality warning, so nobody selects one
    /// expecting production-grade transcription. Defaults to `false`.
    var isExperimental: Bool = false
}

// MARK: - Catalog

extension ASRModel {

    // Stable model ids - single source of truth for the catalog. Tests, Defaults
    // defaults, the WhisperKit variant mapping and the view-model partitioning
    // all reference these instead of literal strings.
    static let parakeetV3Id = "parakeet-v3"
    static let whisperLargeTurboV3Id = "whisper-large-turbo-v3"
    static let whisperMediumId = "whisper-medium"
    static let moonshineBaseId = "moonshine-base"
    static let qwen3ASRId = "qwen3-asr-0.6b"
    static let qwen3ASR17B4bitId = "qwen3-asr-1.7b-4bit"
    static let qwen3ASR17B8bitId = "qwen3-asr-1.7b-8bit"
    static let graniteSpeechId = "granite-speech-4.1-2b"
    static let canaryV2Id = "canary-1b-v2"

    static let defaultModelId = parakeetV3Id

    /// Out-of-box default ASR model, chosen by device capability: machines with
    /// >= 32 GB RAM default to the higher-quality Qwen3-ASR 1.7B (8-bit); everything
    /// else stays on the lighter Parakeet v3. This is used only as the `Defaults`
    /// fallback, so it applies to installs that never explicitly picked a model -
    /// an explicit choice is persisted in `selectedASRModelId` and is untouched.
    static var recommendedDefaultModelId: String {
        let has32GBPlus = ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024
        return has32GBPlus ? qwen3ASR17B4bitId : parakeetV3Id
    }

    static let catalog: [ASRModel] = [
        // Sizes verified against the HuggingFace folders we actually download from:
        // - FluidInference/parakeet-tdt-0.6b-v3-coreml         (~700 MB on disk)
        // - argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo (~950 MB)
        // - argmaxinc/whisperkit-coreml/openai_whisper-medium  (~1.53 GB)
        ASRModel(
            id: parakeetV3Id,
            displayName: "Parakeet v3",
            shortDescription: "Fast & accurate.",
            speedRating: 4,
            accuracyRating: 3,
            sizeBytes: 700_000_000,
            isMultilingual: true,
            isDefault: true,
            backend: .parakeetCoreML
        ),
        ASRModel(
            id: whisperLargeTurboV3Id,
            displayName: "Whisper Large Turbo v3",
            shortDescription: "Good accuracy, but slow.",
            speedRating: 1,
            accuracyRating: 4,
            sizeBytes: 950_000_000,
            // Figma comp surfaces Large-v3 Turbo as "English only" even though the
            // model technically supports every Whisper language - keeping the
            // Figma label so the picker matches design intent.
            isMultilingual: false,
            isDefault: false,
            backend: .whisperCoreML
        ),
        ASRModel(
            id: whisperMediumId,
            displayName: "Whisper Medium",
            shortDescription: "Good accuracy, medium speed.",
            speedRating: 2,
            accuracyRating: 3,
            sizeBytes: 1_530_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .whisperCoreML
        ),
        // Moonshine Base (Useful Sensors) - English-only, ~58 MB ONNX, ~107 ms
        // latency on a MacBook Pro. Routed through `MoonshineEngine` (ONNX
        // Moonshine Base via `moonshine-ai/moonshine-swift` SPM (`MoonshineVoice`
        // product wrapping ONNX Runtime). Weights are 4 `.ort` files served from
        // `download.moonshine.ai/model/base-en/quantized/base-en/` (NOT HuggingFace):
        // encoder_model.ort (~30 MB), decoder_model_merged.ort (~104 MB),
        // decoder_with_attention.ort (~104 MB), tokenizer.bin (~240 KB) ≈ 250 MB.
        ASRModel(
            id: moonshineBaseId,
            displayName: "Moonshine Base",
            shortDescription: "Ultra-fast, English only.",
            speedRating: 4,
            accuracyRating: 3,
            sizeBytes: 250_000_000,
            isMultilingual: false,
            isDefault: false,
            backend: .moonshineONNX
        ),
        // Qwen3-ASR 0.6B (Alibaba) - 52 languages, ~400 MB 4-bit MLX. Routed
        // through `MLXASREngine` (MLX Swift). Hub:
        // `mlx-community/Qwen3-ASR-0.6B-4bit` (mirrors the layout of the
        // upstream port `moona3k/mlx-qwen3-asr`).
        ASRModel(
            id: qwen3ASRId,
            displayName: "Qwen3-ASR 0.6B",
            shortDescription: "Multilingual, balanced speed/accuracy.",
            speedRating: 3,
            accuracyRating: 4,
            sizeBytes: 400_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .mlx
        ),
        // Qwen3-ASR 1.7B 4-bit (Alibaba) - same 52 languages as 0.6B. ~1.6 GB
        // on-disk weights, ~2.5 GB peak RAM during inference (measured via
        // `Qwen3ASR17BSmokeTest.swift` on Apple Silicon, phys_footprint).
        // Accuracy rating is intentionally one step below the 0.6B and 8-bit
        // sibling: mlx-community benchmarks report 4-bit pays a +0.43 WER hit
        // that effectively erodes the accuracy benefit of moving up from
        // 0.6B (the larger 1.7B model recovers some of that, but not enough
        // to claim parity with the higher-precision variants in the picker).
        ASRModel(
            id: qwen3ASR17B4bitId,
            displayName: "Qwen3-ASR 1.7B (4-bit)",
            shortDescription: "Multilingual, larger model in a compact bundle.",
            speedRating: 2,
            accuracyRating: 3,
            sizeBytes: 1_600_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .mlx
        ),
        // Qwen3-ASR 1.7B 8-bit (Alibaba) - best quality on-device option
        // pre-Granite. ~2.5 GB on-disk weights, ~3-3.5 GB peak RAM.
        // 8-bit is intentionally a separate picker entry rather than a
        // hidden quality knob because the size delta (~900 MB) is significant
        // on smaller drives. mlx-community benchmarks show ~3.1× speedup with
        // only a +0.04 WER vs base - the best accuracy / cost trade-off in
        // the catalog until Granite ships.
        ASRModel(
            id: qwen3ASR17B8bitId,
            displayName: "Qwen3-ASR 1.7B (8-bit)",
            shortDescription: "Multilingual, max accuracy.",
            speedRating: 2,
            accuracyRating: 4,
            sizeBytes: 2_500_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .mlx
        ),
        // Granite-Speech 4.1-2b (IBM) - native MLX-Swift port (the first public
        // one), routed through `MLXASREngine`. ~4.6 GB bf16 weights on
        // disk (Conformer encoder + Q-Former projector + 40-layer Granite LLM),
        // several GB peak RAM. English-centric. Hub:
        // `ibm-granite/granite-speech-4.1-2b`.
        // Ratings calibrated by the Phase 4j engine bench (`GraniteSpeechBenchTest`,
        // 22 internal test cases, Apple Silicon):
        //  - accuracy: median WER 5% vs the cleaned reference (Granite is
        //    instruction-tuned and lightly cleans its own output). Best on-device.
        //  - speed: ~0.19× realtime once warm (~1.2 s / utterance); the cold
        //    first inference is slow (Metal kernel compile) but per-utterance is fast.
        //  - RAM: 9.4 GB sustained peak with the engine's 2 GB MLX cache cap
        //    (16.1 GB without). Still heavy - recommends ≥16 GB.
        // The live full-pipeline bench (transcription-benchmark, 15 samples)
        // read 29.8% avg WER, but that is dominated by reference-mismatch, not
        // word errors: Granite faithfully keeps spoken lexical repetitions
        // ("le projet le projet le projet") that the cleanup pipeline doesn't
        // collapse, verbalized punctuation, and a few proper-noun misses;
        // clean sentences (incl. French) score WER 0. 15 samples is below the
        // variance floor, so accuracy stays at 5 on the engine-bench median.
        // isMultilingual: confirmed live - French transcribed correctly
        // (model supports en/fr/de/es/pt/ja via auto-detect; forced-language is
        // not yet wired, the engine ignores the language hint).
        ASRModel(
            id: graniteSpeechId,
            displayName: "Granite-Speech 2B",
            shortDescription: "IBM, top accuracy, multilingual. Large download, heavy on RAM (≥16 GB).",
            speedRating: 2,
            accuracyRating: 5,
            sizeBytes: 4_600_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .mlx
        ),
        // Canary-1B-v2 (NVIDIA) - FastConformer encoder + Transformer attention
        // encoder-decoder, 25 European languages. Isolated CoreML engine
        // (`CanaryCoreMLEngine`) driving the pre-converted int4 `.mlmodelc` bundle
        // `FluidInference/canary-1b-v2-coreml` (~573 MB; encoder/decoder/projection
        // run on GPU/Metal via `.cpuAndGPU` - ANE deadlocks on int4 load, see
        // CanaryCoreMLEngine). int4 payloads
        // require macOS 15+ (gated in `isAvailableForCurrentOS`). WER ~2.1% on
        // LibriSpeech test-clean (int4), ~7× realtime.
        // Ships as EXPERIMENTAL. The pre-converted int4 CoreML port produces
        // poor English transcription (drops clauses, garbles proper nouns) - a
        // limitation of the int4 model port, not our engine. We ship it only
        // because it may still be a user's best option for a specific
        // non-English language. `isExperimental` moves it into its own picker
        // section with a quality warning; the low accuracy rating keeps the dots
        // honest so nobody reads 4/4 next to the warning.
        ASRModel(
            id: canaryV2Id,
            displayName: "Canary 1B v2",
            shortDescription: "Experimental - we've seen poor transcription quality. May work better for some non-English languages. macOS 15+.",
            speedRating: 3,
            accuracyRating: 1,
            sizeBytes: 573_000_000,
            isMultilingual: true,
            isDefault: false,
            backend: .canaryCoreML,
            isExperimental: true
        ),
    ]

    static var defaultModel: ASRModel {
        guard let model = catalog.first(where: { $0.id == defaultModelId }) else {
            preconditionFailure("ASRModel.catalog must contain the default model id '\(defaultModelId)'")
        }
        return model
    }

    static func byId(_ id: String) -> ASRModel? {
        catalog.first { $0.id == id }
    }

    /// How long we allow this model's warmup to take *after* the on-disk
    /// files exist. Defaults to 60 s (instant CoreML compile for small
    /// `.mlmodelc` bundles; <10 s MLX `fromPretrained` for the 0.6B / 1.7B
    /// Qwen variants on Apple Silicon). Per-model rather than per-backend
    /// because Whisper Medium and Whisper Large Turbo share `.whisperCoreML`
    /// but differ by ~70 s on a cold first-load CoreML compile - see the
    /// `whisper-warmup-timeout` lesson. Future heavyweight entries (e.g.
    /// the Granite-Speech 4.1-2b port) declare their own ceiling here.
    var warmupTimeoutSeconds: TimeInterval {
        switch id {
        case Self.whisperLargeTurboV3Id: return 180
        // Granite reads ~4.6 GB of safetensors into MLX on first load; the cold
        // load (kernel compile + disk read) can exceed the 60 s default.
        case Self.graniteSpeechId: return 180
        // Canary's int4 encoder/decoder trigger a slow first-time GPU/Metal
        // program compile (quantized 1B → several minutes on the initial load,
        // cached after; ANE is avoided - it deadlocks on int4 load, see
        // CanaryCoreMLEngine). The 60 s default times the warmup out mid-compile.
        case Self.canaryV2Id: return 300
        default: return 60
        }
    }

    /// Resource-intensity tier used by the picker to surface a badge + the
    /// estimated peak RAM. Drives UX hints only - selection is never blocked
    /// (we ship to a wide hardware range and rely on the user to decide).
    enum HardwareTier {
        /// Default. No badge.
        case light
        /// Bigger than typical (1.5+ GB on disk, 2+ GB peak RAM). Surfaces an
        /// amber "Heavy" pill. Recommended on M2+ with 16 GB RAM.
        case heavy
        /// Multi-GB model that approaches the memory budget on lower-tier
        /// Macs (4+ GB on disk, 4+ GB peak RAM). Surfaces a red "Very heavy"
        /// pill. Recommended on M3+ with 32 GB RAM.
        case extreme
    }

    /// Subjective resource tier. Promoted from `.heavy` to `.extreme` after
    /// the Phase 5 bench (`Qwen17BBenchTest`) observed sustained-use peak
    /// RSS of 6.0 GB (4-bit) and 6.9 GB (8-bit) - both well past the 4 GB
    /// threshold the picker uses to surface the red 'Very heavy' badge.
    /// MLX accumulates Metal buffers across inferences without releasing
    /// them between transcriptions; the single-shot smoke-test peaks (2.5
    /// and 3.5 GB) were not representative of a real dictation session.
    var hardwareTier: HardwareTier {
        switch id {
        case Self.qwen3ASR17B4bitId, Self.qwen3ASR17B8bitId, Self.graniteSpeechId: return .extreme
        default: return .light
        }
    }

    /// Approximate peak resident memory during inference, used by the picker
    /// to give the user a rough budget hint next to the on-disk size.
    /// `nil` for `.light` models where the on-disk size already tracks the
    /// memory cost closely.
    ///
    /// Sustained-use values from `Qwen17BBenchTest` (22 transcriptions back
    /// to back, phys_footprint, Apple Silicon). The single-shot post-load
    /// figure is ~1 GB lower, but advertising that here would be misleading
    /// - a user who dictates a dozen times in a row will see the sustained
    /// number, not the cold one.
    var estimatedPeakRAMBytes: Int64? {
        switch id {
        case Self.qwen3ASR17B4bitId: return 6_000_000_000
        case Self.qwen3ASR17B8bitId: return 7_000_000_000
        // Measured sustained peak (Phase 4j bench, 22 back-to-back inferences,
        // phys_footprint): 9.4 GB with the engine's 2 GB MLX cache cap (16.1 GB
        // without it). The cap keeps a recycle pool while stopping the Metal
        // buffer pool from growing unbounded across inferences, at ~+2% latency.
        case Self.graniteSpeechId: return 10_000_000_000
        default: return nil
        }
    }

    /// `false` for catalog entries this machine cannot run - the picker, the
    /// downloads list and the backtest sheet all filter on it.
    ///
    /// Two reasons an entry drops out: an OS older than the backend needs, and
    /// an Intel CPU, where MLX crashes outright (see `MLXRuntime`).
    var isAvailableForCurrentOS: Bool {
        switch backend {
        case .mlx:
            // MLX inference requires macOS 15+ *and* Apple Silicon.
            guard MLXRuntime.isSupported else { return false }
            if #available(macOS 15, *) { return true }
            return false
        case .canaryCoreML:
            // Canary's int4 CoreML payloads require macOS 15+.
            if #available(macOS 15, *) { return true }
            return false
        case .fluidAudio, .parakeetCoreML, .whisperCoreML, .moonshineONNX:
            return true
        }
    }
}
