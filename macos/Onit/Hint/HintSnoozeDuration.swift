// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HintSnoozeDuration.swift
//  Onit
//
//  Created by Kévin Naudin on 8/28/26.
//

import Foundation

/// Durations offered when temporarily silencing the Hint.
///     Shared by the Hint's more menu and Settings > General, hence the `table` parameter on `title`:
///     each surface localizes from its own string catalog.
enum HintSnoozeDuration: Int, CaseIterable {
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60

    @MainActor
    func title(table: String) -> String {
        switch self {
        case .fiveMinutes:
            return String.localized("5 minutes", table: table)
        case .fifteenMinutes:
            return String.localized("15 minutes", table: table)
        case .thirtyMinutes:
            return String.localized("30 minutes", table: table)
        case .oneHour:
            return String.localized("1 hour", table: table)
        }
    }

    var expiryDate: Date {
        return Date().addingTimeInterval(TimeInterval(rawValue) * 60)
    }
}
