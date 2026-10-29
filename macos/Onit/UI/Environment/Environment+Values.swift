// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Environment+Values.swift
//  Onit
//
//  Created by Kévin Naudin on 03/02/2025.
//

#if DEBUG || ONIT_BETA
#if canImport(Darwin)
import Darwin
#endif
#endif

import SwiftUI

private struct OnitAppStateKey: @preconcurrency EnvironmentKey {

    @MainActor
    static let defaultValue: AppState = AppState.shared
}

extension EnvironmentValues {
    var appState: AppState {
        get { self[OnitAppStateKey.self] }
        set { self[OnitAppStateKey.self] = newValue }
    }
}
