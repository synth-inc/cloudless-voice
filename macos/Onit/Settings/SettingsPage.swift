// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsPage.swift
//  Onit
//
//  Created by Loyd Kim on 9/2/25.
//

import Defaults
import SwiftUI

enum SettingsPage: CaseIterable, Codable, Defaults.Serializable {
    // MARK: - Cases

    case general
    case accountAndBilling
    case setup
    case about

    case transcriptionBehavior
    case transcriptionSmartFormatting
    case transcriptionRewrite
    case transcriptionHistory
    case transcriptionNotifications
    #if DEBUG || ONIT_BETA
    case transcriptionTraining
    case transcriptionEval
    #endif

    // MARK: - CaseIterable

    static var rootCases: [SettingsPage] {
        return [
            .general,
            .accountAndBilling,
            .setup,
            .about
        ]
    }

    /// Transcription-specific pages (visible when transcriptionEnabled).
    static var transcriptionCases: [SettingsPage] {
        var pages: [SettingsPage] = [
            .transcriptionBehavior,
            .transcriptionSmartFormatting,
            .transcriptionRewrite,
            .transcriptionNotifications
        ]
        #if DEBUG || ONIT_BETA
        // Training data is for Smart Cleanup, which a fully open build doesn't have.
        if SmartCleanupAvailability.isCompiledIn {
            pages.append(.transcriptionTraining)
        }
        pages.append(.transcriptionEval)
        #endif
        return pages
    }

    // MARK: - Variables

    @MainActor
    var name: String {
        switch self {
        case .general:
            return String.localized("General", table: "Settings")
        case .accountAndBilling:
            return String.localized("Account", table: "Settings")
        case .setup:
            return String.localized("Setup", table: "Settings")
        case .about:
            return String.localized("About", table: "Settings")

        case .transcriptionBehavior:
            return String.localized("Configuration", table: "Settings")
        case .transcriptionSmartFormatting:
            return String.localized("Smart Cleanup", table: "Settings")
        case .transcriptionRewrite:
            return String.localized("Rewrite", table: "Settings")
        case .transcriptionHistory:
            return String.localized("History", table: "Settings")
        case .transcriptionNotifications:
            return String.localized("Notifications", table: "Settings")
        #if DEBUG || ONIT_BETA
        case .transcriptionTraining:
            return String.localized("Training Data", table: "Settings")
        case .transcriptionEval:
            return String.localized("Eval Recordings", table: "Settings")
        #endif
        }
    }

    var hasCustomScrolling: Bool {
        switch self {
        case .transcriptionHistory:
            return true
        default:
            return false
        }
    }

    /// Pages that render their own custom title bar (with inline action buttons)
    /// in their own body, opting out of `SettingsWindowPages`' default header.
    var rendersOwnHeader: Bool {
        switch self {
        default:
            return false
        }
    }

    var icon: String {
        switch self {
        /// Root
        case .general:
            return "gearshape.fill"
        case .accountAndBilling:
            return "person.fill"
        case .setup:
            return "hammer.fill"
        case .about:
            return "info.circle.fill"
        /// Dictation
        case .transcriptionBehavior:
            return "gearshape.fill"
        case .transcriptionSmartFormatting:
            return "list.bullet"
        case .transcriptionRewrite:
            return "wand.and.stars"
        case .transcriptionHistory:
            return "clock.fill"
        case .transcriptionNotifications:
            return "bell.badge.fill"
        #if DEBUG || ONIT_BETA
        case .transcriptionTraining,
                .transcriptionEval:
            return "lightbulb"
        #endif
        }
    }

    /// URL path segment for deep linking via `onit://settings/<deepLinkPath>`.
    var deepLinkPath: String {
        switch self {
        case .general: return "general"
        case .accountAndBilling: return "account"
        case .setup: return "setup"
        case .about: return "about"
        case .transcriptionBehavior: return "dictation"
        case .transcriptionSmartFormatting: return "smart-formatting"
        case .transcriptionRewrite: return "rewrite"
        case .transcriptionHistory: return "history"
        case .transcriptionNotifications: return "notifications"
        #if DEBUG || ONIT_BETA
        case .transcriptionTraining: return "training"
        case .transcriptionEval: return "eval"
        #endif
        }
    }

    var iconBackgroundColor: Color {
        switch self {
        case .setup,
                .about,
                .transcriptionSmartFormatting,
                .transcriptionRewrite:
            return Color.blue

        case .accountAndBilling:
            return Color.green

        #if DEBUG || ONIT_BETA
        case .transcriptionTraining,
                .transcriptionEval:
            return Color.purple
        #endif

        default:
            return Color.gray
        }
    }
}
