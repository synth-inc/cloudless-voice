// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WarmupProvider.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

import Foundation

// MARK: - WarmupError

/// Errors that can occur during warmup operations.
enum WarmupError: LocalizedError, Equatable {
    /// Warmup failed for a specific provider
    case warmupFailed(provider: String, reason: String)

    /// Warmup timed out
    case timeout(provider: String)

    /// Warmup was cancelled
    case cancelled

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .warmupFailed(let provider, let reason):
            return "Warmup failed for \(provider): \(reason)"
        case .timeout(let provider):
            return "Warmup timed out for \(provider)"
        case .cancelled:
            return "Warmup was cancelled"
        }
    }
}

// MARK: - WarmupState

/// Represents the global warmup state.
enum WarmupState: Equatable {
    /// No warmup in progress
    case idle

    /// Warming up providers
    case warmingUp

    /// All enabled providers have completed warmup
    case ready

    /// Warmup failed with an error
    case failed(error: WarmupError)

    // MARK: - Equatable

    static func == (lhs: WarmupState, rhs: WarmupState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.warmingUp, .warmingUp):
            return true
        case (.ready, .ready):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

// MARK: - WarmupProvider

/// Protocol defining a warmup provider.
/// Each feature that requires a warmup should implement this protocol.
@MainActor
protocol WarmupProvider: AnyObject {
    /// Unique identifier for this provider
    var identifier: String { get }

    /// Priority for warmup execution (lower = first)
    var priority: Int { get }

    /// Whether this provider's warmup should be executed
    var isEnabled: Bool { get }

    /// Whether the warmup has completed successfully
    var isWarmedUp: Bool { get }

    /// Whether a *completed* warmup is for a model that is no longer the selected
    /// one - i.e. the resident model must be swapped. Only meaningful for providers
    /// that serve multiple models behind one backend (the unified MLX provider);
    /// single-model providers are never stale. The coordinator resets a stale
    /// provider on a model switch so its engine reloads the new model and the old
    /// one's RAM is freed (otherwise the outgoing model stays pinned and keeps
    /// transcribing). Defaults to `false`.
    var isStale: Bool { get }

    /// Execute the warmup
    /// - Throws: WarmupError if warmup fails
    func warmup() async throws

    /// Reset the warmup state
    func reset()
}

extension WarmupProvider {
    var isStale: Bool { false }
}
