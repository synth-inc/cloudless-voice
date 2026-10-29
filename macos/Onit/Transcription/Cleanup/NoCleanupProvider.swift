// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NoCleanupProvider.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//

import Foundation

/// Cleanup off: the raw transcript is inserted as is.
@MainActor
final class NoCleanupProvider: CleanupProvider {
    let id = CleanupProviderID.none
    var displayName: String { String.localized("None", table: "Settings") }

    var availability: ProviderAvailability {
        get async { .ready }
    }

    func cleanup(_ input: CleanupInput) async throws -> CleanupOutput {
        CleanupOutput(text: input.transcript)
    }
}
