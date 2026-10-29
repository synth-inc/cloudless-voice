// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SimulatedApp.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-12.
//

import Foundation

/// Representative applications for simulated transcription context in training UI.
/// Each case maps to a real app with its bundle ID, providing realistic metadata
/// for training data collection. The Python scoring pipeline resolves `appCategory`
/// from `appName` + `appBundleId` via `context.py`.
enum SimulatedApp: String, CaseIterable, Identifiable {
    case general
    case terminal
    case codeEditor
    case browser
    case email
    case chat
    case notes
    case docEditor
    case spreadsheet

    var id: String { rawValue }

    /// Display name shown in the picker (representative app name)
    var displayName: String {
        switch self {
        case .general:     return "General"
        case .terminal:    return "Terminal"
        case .codeEditor:  return "VS Code"
        case .browser:     return "Safari"
        case .email:       return "Mail"
        case .chat:        return "Slack"
        case .notes:       return "Notes"
        case .docEditor:   return "Pages"
        case .spreadsheet: return "Numbers"
        }
    }

    /// App name as reported by macOS (nil for general/no specific app)
    var appName: String? {
        switch self {
        case .general:     return nil
        case .terminal:    return "Terminal"
        case .codeEditor:  return "Visual Studio Code"
        case .browser:     return "Safari"
        case .email:       return "Mail"
        case .chat:        return "Slack"
        case .notes:       return "Notes"
        case .docEditor:   return "Pages"
        case .spreadsheet: return "Numbers"
        }
    }

    /// Bundle identifier of the representative app (nil for general)
    var appBundleId: String? {
        switch self {
        case .general:     return nil
        case .terminal:    return "com.apple.Terminal"
        case .codeEditor:  return "com.microsoft.VSCode"
        case .browser:     return "com.apple.Safari"
        case .email:       return "com.apple.mail"
        case .chat:        return "com.tinyspeck.slackmacgap"
        case .notes:       return "com.apple.Notes"
        case .docEditor:   return "com.apple.iWork.Pages"
        case .spreadsheet: return "com.apple.iWork.Numbers"
        }
    }

    /// Category name (matches Python context.py categories)
    var categoryName: String {
        switch self {
        case .general:     return "General"
        case .terminal:    return "Terminal"
        case .codeEditor:  return "Code Editor"
        case .browser:     return "Browser"
        case .email:       return "Email"
        case .chat:        return "Chat"
        case .notes:       return "Notes"
        case .docEditor:   return "Document Editor"
        case .spreadsheet: return "Spreadsheet"
        }
    }

    /// Description of the category's typical transcription context
    var categoryDescription: String {
        switch self {
        case .general:
            return "General application with no specific context."
        case .terminal:
            return "Shell commands, file paths, and technical arguments."
        case .codeEditor:
            return "Code, variable names, function calls, and technical comments."
        case .browser:
            return "Search queries, URLs, form inputs, or general text."
        case .email:
            return "Email subject lines, body text, and replies."
        case .chat:
            return "Informal messages, quick replies, and conversational text."
        case .notes:
            return "Notes, lists, and ideas with mixed formatting."
        case .docEditor:
            return "Formal text, paragraphs, and structured content."
        case .spreadsheet:
            return "Cell values, formulas, column headers, and data entries."
        }
    }
}
