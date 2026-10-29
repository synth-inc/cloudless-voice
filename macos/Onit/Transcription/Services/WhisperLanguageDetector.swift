// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperLanguageDetector.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-14.
//
//  Language detection via Whisper-base CoreML through WhisperKit. Used to
//  constrain multi-language transcription when the user has ≥2 candidate
//  languages configured: we detect from the first ~3s of audio, filter to
//  the user's candidates, and pick the highest-probability language. The
//  resulting ISO 639-1 code is passed to Parakeet so it transcribes in the
//  correct language.
//
//  Mirrors the Python `_detect_language_mlx(audio, candidate_langs)` logic.
//  Fails open on any error (returns nil → caller falls back to auto).
//

import Foundation
import WhisperKit

actor WhisperLanguageDetector {

    // MARK: - Singleton

    static let shared = WhisperLanguageDetector()

    // MARK: - Configuration

    /// Whisper-base is ~290 MB in CoreML - enough for reliable language ID, small enough
    /// to load fast. The English-only `openai_whisper-base.en` would be wrong here because
    /// it doesn't predict language tokens.
    private static let modelName = "openai_whisper-base"
    private static let sampleRate: Double = 16_000
    private static let detectionWindowSec: Double = 3.0

    // MARK: - State

    /// `WhisperKit` is not marked Sendable by the upstream package. Declaring
    /// the property `nonisolated(unsafe)` sidesteps the actor-boundary send
    /// diagnostic when we call `kit.detectLangauge(...)`. Safety is preserved
    /// because every access (read + write) happens inside an actor-isolated
    /// method, so the actor itself serialises them.
    nonisolated(unsafe) private var kit: WhisperKit?

    var isLoaded: Bool { kit != nil }

    private init() {}

    // MARK: - Public

    /// Eagerly load the Whisper-base CoreML model. Safe to call multiple times; subsequent
    /// calls are no-ops once the model is loaded. Throws if the download or load fails.
    func ensureLoaded() async throws {
        guard kit == nil else { return }
        // Same store as the Whisper backend: this is WhisperKit too, and it is
        // reached from the Parakeet warmup, so leaving it on HubApi's default
        // would keep writing ~290 MB into `~/Documents` for every multi-language
        // user. The migration moves the whole `whisperkit-coreml` repo, so an
        // existing `openai_whisper-base` and its tokenizer come along with it.
        WhisperCoreMLEngine.migrateLegacyStorageIfNeeded()
        let config = WhisperKitConfig(
            model: Self.modelName, downloadBase: WhisperCoreMLEngine.downloadBase,
            verbose: false, load: true)
        kit = try await WhisperKit(config)
        log.info("WhisperLanguageDetector: \(Self.modelName) loaded")
    }

    /// Detect the language of a raw 16 kHz Float32 audio buffer, optionally constrained
    /// to a set of ISO 639-1 candidates. Returns nil on any error (fail open).
    ///
    /// - Parameters:
    ///   - audio: Mono 16 kHz Float32 samples. Only the first ~3 s are used.
    ///   - candidates: If non-empty, the highest-probability language from this list wins.
    ///     If empty, the unconstrained top language is returned.
    func detectLanguage(audio: [Float], candidates: [String]) async -> String? {
        guard let kit else {
            log.warning("WhisperLanguageDetector: model not loaded - falling back to auto")
            return nil
        }
        guard !audio.isEmpty else { return nil }

        let windowSamples = Int(Self.detectionWindowSec * Self.sampleRate)
        let clip = Array(audio.prefix(windowSamples))

        do {
            let result = try await kit.detectLangauge(audioArray: clip)
            let probs = result.langProbs

            if !candidates.isEmpty {
                var best: (iso: String, prob: Float) = ("", -.infinity)
                for iso in candidates {
                    if let p = probs[iso], p > best.prob {
                        best = (iso, p)
                    }
                }
                if best.prob > -.infinity {
                    log.info("WhisperLanguageDetector: picked \(best.iso) (prob=\(String(format: "%.3f", best.prob))) from candidates \(candidates)")
                    return best.iso
                }
                log.warning("WhisperLanguageDetector: no match in candidates \(candidates) - falling back to auto")
                return nil
            }

            log.info("WhisperLanguageDetector: auto-detected \(result.language)")
            return result.language
        } catch {
            log.warning("WhisperLanguageDetector: detection failed (\(error.localizedDescription)) - falling back to auto")
            return nil
        }
    }
}

// `WhisperKit: @unchecked @retroactive Sendable` lives in WhisperKit+Sendable.swift.
