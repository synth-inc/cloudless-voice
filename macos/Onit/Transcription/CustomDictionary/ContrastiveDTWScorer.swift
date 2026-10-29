// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ContrastiveDTWScorer.swift
//  Onit
//
//  Contrastive DTW keyword detection using Parakeet encoder embeddings.
//
//  Algorithm (from CTCEncoderEmbeddingTests - AUC 0.980 on 37 clips,
//  but AUC is no longer used for evaluation):
//    score = dtwNeg / (dtwTarget + dtwNeg)
//    where dtwTarget = mean DTW distance to enrollment templates
//          dtwNeg    = mean DTW distance to other-word spans from the same clip
//
//  Score ∈ (0, 1): values near 1.0 mean "sounds more like target than background".
//  Threshold 0.60 gives ~92% recall with ~7% FP rate (full template library).
//  With K=1 enrollment recording the distribution shifts slightly - the NLL gate
//  handles residual false positives.
//

import Foundation

struct ContrastiveDTWScorer {

    /// Default detection threshold. Conservative to work well with K=1 enrollment.
    static let detectionThreshold: Float = 0.60

    /// Encoder embedding dimension for parakeet-ctc-110m.
    static let embeddingDim = 512

    // MARK: - Scoring

    /// Contrastive score: how much more similar the query is to enrollment templates
    /// than to other-word spans from the same audio clip.
    ///
    /// - Parameters:
    ///   - query: Encoder frames for the candidate word span [T_q × 512]
    ///   - templates: K enrollment recording spans [[T_k × 512]]
    ///   - negatives: Other word spans from same clip [[T_n × 512]]
    static func score(
        query: [[Float]],
        templates: [[[Float]]],
        negatives: [[[Float]]]
    ) -> Float {
        guard !query.isEmpty, !templates.isEmpty else { return 0 }

        // DTW scores are unreliable when the query is much shorter than the
        // enrollment templates: a 1-frame query gets smeared across the whole
        // template path, producing artificially low dtwTarget and a noisy
        // contrastive ratio. Require the query to be at least 1/3 the mean
        // template length so function words like "a" / "I" are never matched.
        let meanTemplateLen = templates.reduce(0) { $0 + $1.count } / templates.count
        guard query.count * 3 >= meanTemplateLen else { return 0 }

        let dtwTarget = templates.map { dtwDist(query, $0) }.reduce(0, +) / Float(templates.count)

        guard !negatives.isEmpty else { return 0 }

        let dtwNeg = negatives.map { dtwDist(query, $0) }.reduce(0, +) / Float(negatives.count)
        let total = dtwTarget + dtwNeg
        return total > 0 ? dtwNeg / total : 0.5
    }

    // MARK: - DTW (cosine distance, path-length normalised)

    static func dtwDist(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return 1 }

        // Allocate flat buffer - avoids 2-D array overhead for small spans.
        let cols = m + 1
        var dp = [Float](repeating: .infinity, count: (n + 1) * cols)
        dp[0] = 0

        for i in 1...n {
            for j in 1...m {
                let cost = 1 - cosine(a[i - 1], b[j - 1])
                let prev = min(dp[(i - 1) * cols + j],      // insertion
                               dp[i * cols + (j - 1)],      // deletion
                               dp[(i - 1) * cols + (j - 1)]) // match
                dp[i * cols + j] = cost + prev
            }
        }
        return dp[n * cols + m] / Float(n + m)
    }

    // MARK: - Cosine similarity

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<len {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        return denom > 0 ? dot / denom : 0
    }
}
