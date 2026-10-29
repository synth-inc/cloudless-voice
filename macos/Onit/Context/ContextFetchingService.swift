// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ContextFetchingService.swift
//  Onit
//
//  Created by Timothy Lenardo on 7/29/25.
//

import ApplicationServices
import Defaults
import Foundation

@MainActor
class ContextFetchingService {
    static let shared = ContextFetchingService()

    // MARK: - Properties

    private var lastActiveWindowPid: pid_t?

    // MARK: - Private initializer

    private init() { }

    // MARK: - Functions

    func setLastActive(windowPid: pid_t?) {
        lastActiveWindowPid = windowPid
    }

    func reset() {
        lastActiveWindowPid = nil
    }
}
