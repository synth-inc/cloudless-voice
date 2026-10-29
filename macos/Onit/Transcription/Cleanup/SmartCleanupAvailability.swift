// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupAvailability.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Smart Cleanup is built from the closed TranscriptionCleanup library. A fully
//  open build (`scripts/build-fully-open.sh`) replaces that library with an empty
//  stub, and every file that needs it is behind `#if canImport(TranscriptionCleanup)`.
//  Open code that has to know at runtime (Settings, warmup) asks here instead of
//  repeating the check.
//

import Foundation

enum SmartCleanupAvailability {
    /// Whether this build contains Smart Cleanup.
    static let isCompiledIn: Bool = {
        #if canImport(TranscriptionCleanup)
        return true
        #else
        return false
        #endif
    }()

    /// Where a fully open build sends people who want Smart Cleanup.
    static let officialAppURL = URL(string: "https://www.cloudless.so")!
}
