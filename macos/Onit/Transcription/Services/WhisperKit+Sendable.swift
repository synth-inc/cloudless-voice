// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhisperKit+Sendable.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import WhisperKit

/// WhisperKit's upstream class is not declared `Sendable`, but every call site in
/// this app accesses it through an actor (`WhisperLanguageDetector`,
/// `WhisperCoreMLEngine`) that serialises reads and writes. Declaring the
/// conformance retroactively in one place keeps the opt-in explicit and avoids
/// silently coupling unrelated files through a hidden cross-file extension.
extension WhisperKit: @unchecked @retroactive Sendable {}
