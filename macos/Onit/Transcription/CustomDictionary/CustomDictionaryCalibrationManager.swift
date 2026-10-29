// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CustomDictionaryCalibrationManager.swift
//  Onit
//
//  Manages the calibration lifecycle for custom dictionary terms.
//
//  Calibration provides per-term NLL gate data:
//    • positiveExamples – sentences where the term is used correctly
//    • negativeExamples – sentences where the confusion span appears naturally
//    • proxyWord         – auto-selected or user-confirmed proxy for NLL scoring
//    • threshold         – computed from positive/negative NLL deltas
//

import Defaults
import Foundation

// MARK: - Data Model

/// A labelled sentence example for NLL gate calibration.
struct CalibrationExample: Codable, Sendable, Equatable {
    let sentence: String
    let span: String       // confusion span in the sentence (e.g. "on it")
}

/// Pending calibration data for a term (transient - cleared once calibrated).
struct TermCalibrationData: Codable, Sendable, Identifiable {
    var id: UUID           // matches CustomDictionaryTerm.id
    var positiveExamples: [CalibrationExample] = []
    var negativeExamples: [CalibrationExample] = []
    var proxyWordCandidates: [String] = []
}

// MARK: - Manager

@MainActor
final class CustomDictionaryCalibrationManager: ObservableObject {

    static let shared = CustomDictionaryCalibrationManager()
    private init() {}

    // MARK: - Published

    /// Set when a newly added term needs calibration (drives the calibration sheet).
    @Published var termPendingCalibration: CustomDictionaryTerm?

    /// History scan results for the term currently being calibrated.
    @Published private(set) var historyCandidates: [CalibrationCandidate] = []
    @Published private(set) var isScanning = false
    /// Raw TDT transcript from the most recent enrollment recording attempt.
    @Published private(set) var lastEnrollmentTranscript: String?

    // MARK: - Types

    struct CalibrationCandidate: Identifiable, Sendable {
        let id = UUID()
        let sentence: String      // full transcription text
        let matchedSpan: String   // the span in the sentence that matches the term
        let spanAudioSamples: [Float]
        let detectionStartSec: Double
        let detectionEndSec: Double
        let transcriptTimestamp: Date
    }

    // MARK: - Enrollment Recording

    /// Result of processing a user-recorded enrollment sentence.
    struct EnrollmentSpanResult: Sendable {
        let transcript: String
        let matchedSpan: String       // words overlapping the detection
        let spanAudioSamples: [Float] // 16kHz mono, ±300ms context
        let startSec: Float
        let endSec: Float
        /// Encoder embedding frames for the matched span [T × 512].
        /// nil when CTC model was unavailable.
        let enrollmentFrames: [[Float]]?
    }

    /// Find the term span in a freshly-recorded sentence using TDT word timestamps.
    ///
    /// Returns `nil` if the term was not found in the transcript.
    func processEnrollmentRecording(
        samples: [Float],
        for term: CustomDictionaryTerm
    ) async -> EnrollmentSpanResult? {
        do {
            try await ParakeetCoreMLEngine.shared.ensureLoaded()
        } catch {
            log.warning("CalibrationEnrollment: TDT model unavailable: \(error)")
            return nil
        }

        // TDT word timestamps - actor-isolated call
        guard let timestamps = try? await ParakeetCoreMLEngine.shared.transcribeWithWordTimestamps(samples),
              !timestamps.isEmpty else {
            log.warning("CalibrationEnrollment: TDT returned no timestamps for recording")
            return nil
        }

        let fullTranscript = timestamps.map(\.word).joined(separator: " ")
        lastEnrollmentTranscript = fullTranscript
        log.debug("CalibrationEnrollment: transcript \(LogPrivacy.summary(fullTranscript))")

        // N-gram text match: try 1, 2, 3 consecutive words
        guard let (startSec, endSec, span) = findTermSpan(in: timestamps, term: term.text) else {
            log.warning("CalibrationEnrollment: term (\(LogPrivacy.summary(term.text))) not found in transcript (\(LogPrivacy.summary(fullTranscript)))")
            return nil
        }

        log.debug("CalibrationEnrollment: found span (\(LogPrivacy.summary(span))) at \(startSec)…\(endSec)s")

        let spanStart = max(0, Int(Double(startSec) * 16000))
        let spanEnd   = min(samples.count, Int(Double(endSec) * 16000))
        let spanAudio = spanStart < spanEnd ? Array(samples[spanStart..<spanEnd]) : []

        return EnrollmentSpanResult(
            transcript: fullTranscript,
            matchedSpan: span,
            spanAudioSamples: spanAudio,
            startSec: startSec,
            endSec: endSec,
            enrollmentFrames: nil
        )
    }

    func saveEnrollmentEmbedding(_ frames: [[Float]]?, for term: CustomDictionaryTerm) {
        // No-op: enrollment embeddings are not used by the Whisper KWS path.
    }

    /// N-gram text match: try 1–3 consecutive word windows, return first match.
    private func findTermSpan(
        in timestamps: [WordTimestamp],
        term: String
    ) -> (startSec: Float, endSec: Float, span: String)? {
        // Strip spaces before comparing so "on it" (2 tokens) matches term "Onit"
        let normTerm = normalize(term).replacingOccurrences(of: " ", with: "")
        let words = timestamps.map { ($0, normalize($0.word)) }

        for n in 1...min(3, words.count) {
            for i in 0...(words.count - n) {
                let slice = words[i..<(i + n)]
                let joined = slice.map(\.1).joined().replacingOccurrences(of: " ", with: "")
                if joined == normTerm {
                    let span = slice.map { $0.0.word }.joined(separator: " ")
                    return (slice.first!.0.startSec, slice.last!.0.endSec, span)
                }
            }
        }
        return nil
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains($0) }
            .reduce("") { String($0) + String($1) }
    }

    /// Best Levenshtein-matching N-gram span (1–3 words) for a term in a word array.
    /// Used to label detected spans without relying on character-proportional time estimates.
    private func bestLevenshteinSpan(in words: [String], for termText: String) -> String {
        let termKey = CustomDictionaryRescorer.normalize(termText)
            .replacingOccurrences(of: " ", with: "")
        var bestSpan = words.first ?? termText
        var bestSim: Float = 0
        for n in 1...min(3, words.count) {
            for i in 0...(words.count - n) {
                let key = words[i..<(i + n)]
                    .map { CustomDictionaryRescorer.normalize($0).replacingOccurrences(of: " ", with: "") }
                    .joined()
                let sim = CustomDictionaryRescorer.similarity(key, termKey)
                if sim > bestSim { bestSim = sim; bestSpan = words[i..<(i + n)].joined(separator: " ") }
            }
        }
        return bestSpan
    }

    // MARK: - History Scan

    /// Scan transcription history for sentences where the term was acoustically detected by Whisper KWS.
    func scanHistory(for term: CustomDictionaryTerm) async {
        guard !isScanning else {
            log.info("CalibrationScan: already scanning, ignoring duplicate call")
            return
        }
        isScanning = true
        historyCandidates = []
        defer {
            isScanning = false
            log.info("CalibrationScan: defer - isScanning=false, invalidating model")
            CustomDictionaryService.shared.invalidateModel()
        }

        log.info("CalibrationScan: start for term (\(LogPrivacy.summary(term.text)))")

        let scanKeywords: [String] = [term.text]
        log.info("CalibrationScan: keywords=\(scanKeywords.count)")

        log.info("CalibrationScan: loading Whisper KWS model…")
        do {
            try await WhisperKwsService.shared.loadIfNeeded(keywords: scanKeywords)
        } catch {
            log.warning("CalibrationScan: Whisper KWS load failed: \(error)")
            return
        }
        log.info("CalibrationScan: Whisper KWS ready")

        log.info("CalibrationScan: fetching transcription history…")
        let history = await TranscriptionHistoryManager.shared.fetchAll()
        log.info("CalibrationScan: history entries=\(history.count)")
        guard !history.isEmpty else {
            log.info("CalibrationScan: no history - done")
            return
        }

        var seen = Set<String>()
        var entriesProcessed = 0
        var entriesSkipped = 0
        let scanWallStart = Date()
        func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // Dictations only: the examples are sentences, and a file transcript would
        // run the keyword spotter over up to 30 min of audio.
        for entry in history.lazy.filter({ !$0.isFromFile }).prefix(500) {
            guard historyCandidates.count < 20 else { break }

            let text = entry.rawTranscription
            guard !text.isEmpty else { entriesSkipped += 1; continue }
            guard seen.insert(text).inserted else { entriesSkipped += 1; continue }
            guard LevenshteinTextPrefilter.mayContain(term: term.text, in: text) else {
                entriesSkipped += 1
                continue
            }

            guard let samples = TranscriptionHistoryManager.shared.loadAudioSamples(for: entry) else {
                log.debug("CalibrationScan: no audio for entry id=\(entry.id)")
                entriesSkipped += 1
                continue
            }
            entriesProcessed += 1

            log.debug("CalibrationScan: [\(entriesProcessed)] running KWS on \(samples.count) samples (\(String(format:"%.1f",Double(samples.count)/16000))s)")
            let detections: [KWSDetection]? =
                try? await WhisperKwsService.shared.detectKeywords(in: samples)
            guard let detections, let detection = detections.first else {
                log.debug("CalibrationScan: [\(entriesProcessed)] no detection")
                continue
            }

            let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }

            let detStart = detection.startSec
            let detEnd   = detection.endSec
            let span = bestLevenshteinSpan(in: words, for: term.text)

            let sStart = max(0, Int(detStart * 16_000))
            let sEnd   = min(samples.count, Int(detEnd * 16_000))
            let spanAudio = sStart < sEnd ? Array(samples[sStart..<sEnd]) : []

            log.info("CalibrationScan: [\(entriesProcessed)] HIT detStart=\(String(format:"%.2f",detStart))s detEnd=\(String(format:"%.2f",detEnd))s span=\(LogPrivacy.summary(span))")
            historyCandidates.append(CalibrationCandidate(
                sentence: text,
                matchedSpan: span,
                spanAudioSamples: spanAudio,
                detectionStartSec: detStart,
                detectionEndSec: detEnd,
                transcriptTimestamp: entry.timestamp
            ))
        }

        let totalMs = ms(since: scanWallStart)
        log.info("CalibrationScan complete: processed=\(entriesProcessed) skipped=\(entriesSkipped) in \(totalMs)ms, candidates=\(historyCandidates.count)")
    }

    // MARK: - Proxy Selection

    /// Auto-select proxy word candidates from confirmed positive examples.
    func selectProxy(
        for term: CustomDictionaryTerm,
        positives: [CalibrationExample]
    ) async -> [String] {
        guard !positives.isEmpty else { return [] }

        let referenceSentences = positives.map(\.sentence)
        let topCategories = CustomDictionaryCategoryRanker
            .relevantCategories(positives: referenceSentences, topN: 6)
        log.info("CategoryRanker: top categories for term (\(LogPrivacy.summary(term.text))): \(topCategories)")

        do {
            let span = positives.first?.span ?? ""
            return try await CustomDictionaryProxySelector.shared.selectProxy(
                referenceSentences: referenceSentences,
                confusionSpan: span,
                termText: term.text,
                count: 10
            )
        } catch {
            log.warning("CustomDictionaryCalibrationManager: Proxy selection failed: \(error)")
        }
        return []
    }

    // MARK: - Negative Example Generation

    /// Generate negative examples using Llama.
    ///
    /// Asks Llama to write sentences that naturally use the confusion span
    /// (not as a proper noun), producing examples where the NLL gate should reject.
    func generateNegativeExamples(
        confusionSpan: String,
        count: Int = 3
    ) async -> [CalibrationExample] {
        guard await MLXScoringEngine.shared.isLoaded else { return [] }

        var examples: [CalibrationExample] = []
        for _ in 0..<count {
            let prompt = """
                Write one short, natural sentence (10–20 words) where someone uses the phrase '\(confusionSpan)' as a common English expression (not as a product name or proper noun). Output only the sentence.
                """
            do {
                let sentence = try await MLXScoringEngine.shared.generateText(prompt: prompt)
                let cleaned = sentence
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).first ?? sentence
                if !cleaned.isEmpty {
                    examples.append(CalibrationExample(sentence: cleaned, span: confusionSpan))
                }
            } catch {
                log.warning("CustomDictionaryCalibrationManager: Negative example generation failed: \(error)")
            }
        }
        return examples
    }

    // MARK: - Threshold Computation & Save

    /// Compute per-term threshold and persist the calibrated term.
    func finishCalibration(
        term: CustomDictionaryTerm,
        positives: [CalibrationExample],
        negatives: [CalibrationExample],
        proxyWord: String?
    ) async {
        // Rebase off the LATEST service state, not the snapshot the sheet
        // captured at open time. The user may have clicked "yes" on history
        // candidates during this calibration session - each click promotes
        // the matched span to `commonMistakes` via `addCommonMistake(...)`.
        // Without this re-read, those promotions get blown away when we
        // call `updateTerm(updatedTerm)` below.
        var updatedTerm = CustomDictionaryService.shared.terms
            .first(where: { $0.id == term.id }) ?? term

        updatedTerm.proxyWord = proxyWord

        // The NLL gate uses a static default threshold (0.0) - validated on
        // the production case set in NLLGateProxyThresholdEvalTests. We no
        // longer fit a per-term threshold during enrollment: the synthetic
        // positive/negative examples generated here are short and length-
        // diluted in a way that's unrepresentative of real dictation, so
        // fitting to them dragged the threshold to the wrong side of the
        // real-world decision boundary. The `nllThreshold` field on the
        // term remains as an explicit escape hatch.
        log.info("CustomDictionaryCalibrationManager: term (\(LogPrivacy.summary(term.text))) calibrated, proxy=\(proxyWord == nil ? "none" : "set")")

        updatedTerm.calibrationState = .calibrated
        CustomDictionaryService.shared.updateTerm(updatedTerm)
        termPendingCalibration = nil
    }

}

// MARK: - Text Prefilter

/// Cheap text gate run before `loadAudioSamples` and Whisper KWS. The
/// `floor(termLen × 0.5)` threshold is intentionally permissive - false
/// positives are caught downstream by KWS, but a false negative skips the
/// entry forever. Validated in `OnitTests/LevenshteinPrefilterEvalTests`.
fileprivate enum LevenshteinTextPrefilter {

    static let distanceFraction: Double = 0.5
    static let maxNGram = 3

    static func mayContain(term: String, in text: String) -> Bool {
        let needle = term.lowercased()
        let allowed = max(1, Int(Double(needle.count) * distanceFraction))
        let tokens = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return false }

        for size in 1...min(maxNGram, tokens.count) {
            for start in 0...(tokens.count - size) {
                let window = Array(tokens[start..<(start + size)])
                if boundedLevenshtein(window.joined(), needle, max: allowed) <= allowed {
                    return true
                }
                if size > 1,
                   boundedLevenshtein(window.joined(separator: " "), needle, max: allowed) <= allowed {
                    return true
                }
            }
        }
        return false
    }

    private static func boundedLevenshtein(_ a: String, _ b: String, max: Int) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if abs(aChars.count - bChars.count) > max { return max + 1 }
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                if curr[j] < rowMin { rowMin = curr[j] }
            }
            if rowMin > max { return max + 1 }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }
}
