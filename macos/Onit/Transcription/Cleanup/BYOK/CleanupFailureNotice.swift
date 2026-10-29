// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CleanupFailureNotice.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//

import Foundation

/// Tells the user that the rewrite failed, why, and that the text was inserted
/// without it, through the Hint's transcription alert (the same pop-up as "Smart
/// Cleanup loading..."). Without it a slow or misconfigured server, or a reply
/// without the output markers, just looks like the rewrite "not doing anything".
///
/// Rate-limited per reason: the same reason shows at most once a minute, but a
/// different reason shows straight away, so a rejection is never hidden behind an
/// earlier notice about something else.
@MainActor
final class CleanupFailureNotice {
    static let shared = CleanupFailureNotice()

    /// Why a rewrite fell back to the text it was given.
    enum Reason: Hashable, Sendable {
        /// The reply never contained the output marker (`BYOKReplyExtractor.Rejection.missingMarker`).
        case replyMissingMarker
        /// Nothing between the markers.
        case replyEmpty
        /// Far longer than the text it was given: the model answered instead of rewriting.
        case replyTooLong
        /// Far shorter than the text it was given: summarised, or the server cut the input.
        case replyTooShort
        /// Rewrite is on but the model isn't set up (no server URL, model or API key).
        case notConfigured
        /// The reply hit the token limit (`BYOKClientError.truncated`).
        case replyCutOff
        /// No answer within the dictation's budget.
        case timedOut
        /// The server couldn't be reached.
        case unreachable
        /// The server rejected the API key.
        case unauthorized
        /// Anything else (HTTP error, unreadable reply, bad URL).
        case other

        /// The reason for an error thrown by `BYOKCleanupProvider` or its client.
        init(_ error: Error) {
            switch error {
            case let rejection as BYOKReplyExtractor.Rejection:
                switch rejection {
                case .missingMarker: self = .replyMissingMarker
                case .empty: self = .replyEmpty
                case .tooLong: self = .replyTooLong
                case .tooShort: self = .replyTooShort
                }
            case let error as BYOKClientError:
                switch error {
                case .truncated: self = .replyCutOff
                case .timeout: self = .timedOut
                case .unreachable: self = .unreachable
                case .unauthorized: self = .unauthorized
                default: self = .other
                }
            // `CleanupService` cancels the work when the dictation's budget runs out.
            case is CancellationError, CleanupError.timeout: self = .timedOut
            default: self = .other
            }
        }

        /// One line for the Hint pop-up: what went wrong. The pop-up adds what was
        /// inserted instead.
        @MainActor
        var message: String {
            switch self {
            case .replyMissingMarker:
                String.localized("Your model's reply had no output tags.", table: "MenuBar")
            case .replyEmpty:
                String.localized("Your model's reply had nothing between the output tags.", table: "MenuBar")
            case .replyTooLong:
                String.localized("Your model's reply was much longer than what you said.", table: "MenuBar")
            case .replyTooShort:
                String.localized("Your model's reply was much shorter than what you said.", table: "MenuBar")
            case .notConfigured:
                String.localized("Your model isn't set up yet.", table: "MenuBar")
            case .replyCutOff:
                String.localized("Your model's reply was cut off.", table: "MenuBar")
            case .timedOut:
                String.localized("Your model took too long to answer.", table: "MenuBar")
            case .unreachable:
                String.localized("Couldn't reach your model's server.", table: "MenuBar")
            case .unauthorized:
                String.localized("Your model's server rejected the API key.", table: "MenuBar")
            case .other:
                String.localized("Your model couldn't rewrite this one.", table: "MenuBar")
            }
        }
    }

    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private let present: @MainActor (Reason) -> Void
    private var lastShown: [Reason: Date] = [:]

    init(
        minimumInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        present: @escaping @MainActor (Reason) -> Void = { reason in
            HintManager.shared.showTranscriptionAlert(.rewriteFailed(reason))
        }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.present = present
    }

    /// Shows the notice for `reason` unless that same reason was shown within the
    /// last `minimumInterval`. Returns whether it was shown.
    @discardableResult
    func cleanupFailed(_ reason: Reason = .other) -> Bool {
        let time = now()
        if let last = lastShown[reason], time.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastShown[reason] = time
        present(reason)
        return true
    }
}
