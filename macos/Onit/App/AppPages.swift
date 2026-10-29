// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppPages.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import Defaults

enum AppPages: CaseIterable {
    case home
    case transcripts
    case dictionary
    case snippets
    case support
    
    @MainActor
    var sidebarName: String {
        switch self {
        case .home:
            return String.localized("Home", table: "App")
        case .transcripts:
            return String.localized("Transcripts", table: "App")
        case .dictionary:
            return String.localized("Dictionary", table: "App")
        case .snippets:
            return String.localized("Snippets", table: "App")
        case .support:
            return String.localized("Spread the Word", table: "App")
        }
    }

    @MainActor
    var sidebarIcon: String {
        switch self {
        case .home:
            return "house"
        case .transcripts:
            return "clock"
        case .dictionary:
            return "book.closed"
        case .snippets:
            return "bolt"
        case .support:
            return "heart"
        }
    }
    
    /// `return ""` indicates that there is custom UI treatment on the page name in `AppWindowPages`.
    @MainActor
    var pageName: String {
        switch self {
        case .home:
            return ""
        case .transcripts:
            return ""
        case .dictionary:
            return String.localized("Dictionary", table: "App")
        case .snippets:
            // Custom header (AppSnippetsHeader) renders the title + tools.
            return ""
        case .support:
            return String.localized("Help us grow & keep dictation local!", table: "App")
        }
    }
}
