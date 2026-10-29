// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  KeyboardPermissionManager.swift
//  Onit
//
//  Created by Loyd Kim on 8/13/25.
//

import AppKit
import Carbon
import Foundation

@MainActor
final class KeyboardPermissionManager: ObservableObject {
    // MARK: - Singleton
    
    static let shared = KeyboardPermissionManager()
    
    // MARK: - Custom Types
    
    typealias AllKeyboardSuggestionsDisabled = Bool
    
    typealias Suggestion = String
    typealias SuggestionEnabled = Bool
    typealias KeyboardSuggestionSettings = [Suggestion: SuggestionEnabled]
    
    // MARK: - Properties
    
    @Published private(set) var isMacKeyboardSuggestionsDisabled: AllKeyboardSuggestionsDisabled
    @Published private(set) var keyboardSuggestionSettings: KeyboardSuggestionSettings
    
    private init() {
        let (allKeyboardSuggestionsDisabled, keyboardSuggestionsSettings) = Self.getPropertyStates()
        
        self.isMacKeyboardSuggestionsDisabled = allKeyboardSuggestionsDisabled
        self.keyboardSuggestionSettings = keyboardSuggestionsSettings
    }
    
    // MARK: - States
    
    private var pollingTimerForMacKeyboardSuggestionsDisabledState: Timer? = nil
    
    // MARK: - Private Variables
    
    /// Built-in macOS keyboard suggestions that may interfere with Typeahead.
    /// All of the Mac keyboard suggestions are considered to be "disabled" (`isMacKeyboardSuggestionsDisabled`) when all of these are `false`.
    private static let macOSKeyboardSuggestions: [String] = [
        "NSAutomaticInlinePredictionEnabled"
        
        // Potentially useful detections below. Uncomment them as needed.
//        "NSAutomaticSpellingCorrectionEnabled",
//        "NSAutomaticCapitalizationEnabled",
//        "NSAutomaticPeriodSubstitutionEnabled",
//        "NSAutomaticQuoteSubstitutionEnabled",
//        "NSAutomaticDashSubstitutionEnabled"
        
        // TODO: LOYD - Wasn't able to find a public API for "Show suggested replies", so there's currently no way for the app to detect whether or not this setting has been turned off. Below were just some guesses that didn't work. Leaving here as reminders.
//        "NSAutomaticSuggestedRepliesEnabled",
//        "NSSuggestedRepliesEnabled"
    ]
    
    // MARK: - Public Variables
    
    static let keyboardSettingsLink = "x-apple.systempreferences:com.apple.preference.keyboard?Text"
    
    // MARK: - Private Functions
    // Helper functions for checking the disabled states for various macOS keyboard suggestions and initializing the class's properties.
    
    private static func getSuggestionEnabled(_ suggestion: String) -> Bool? {
        let enabled = CFPreferencesCopyValue(
            suggestion as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        
        return enabled as? Bool
    }
    
    private static func getPropertyStates() -> (AllKeyboardSuggestionsDisabled, KeyboardSuggestionSettings) {
        var allKeyboardSuggestionsDisabled: AllKeyboardSuggestionsDisabled = true
        var keyboardSuggestionSettings: KeyboardSuggestionSettings = [:]
        
        for suggestion in Self.macOSKeyboardSuggestions {
            /// Setting to `true` here as a fallback to prevent false-positives for keyboard suggestions that couldn't be located (for example, this would've returned true if we were to uncomment the suggested reply properties in `macOSKeyboardSuggestions` above, as they don't actually exist).
            let suggestionEnabled = Self.getSuggestionEnabled(suggestion) ?? true
            
            keyboardSuggestionSettings[suggestion] = suggestionEnabled
            
            /// If any one of the keyboard suggestions are "enabled", it means that not all suggestions are disabled.
            /// Therefore, we set `allKeyboardSuggestionsDisabled` to `false` here.
            if suggestionEnabled {
                allKeyboardSuggestionsDisabled = false
            }
        }
        
        return (allKeyboardSuggestionsDisabled, keyboardSuggestionSettings)
    }
    
    private func updatePropertyStates() {
        let (allKeyboardSuggestionsDisabled, keyboardSuggestionsSettings) = Self.getPropertyStates()
        
        if self.isMacKeyboardSuggestionsDisabled != allKeyboardSuggestionsDisabled {
            self.isMacKeyboardSuggestionsDisabled = allKeyboardSuggestionsDisabled
        }
        
        if self.keyboardSuggestionSettings != keyboardSuggestionsSettings {
            self.keyboardSuggestionSettings = keyboardSuggestionsSettings
        }
    }
    
    @objc private func checkPropertyStates() {
        updatePropertyStates()
    }
    
    // MARK: - Public Functions
    
    func startPollingIsMacKeyboardSuggestionsDisabledState() {
        self.pollingTimerForMacKeyboardSuggestionsDisabledState = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkPropertyStates),
            userInfo: nil,
            repeats: true
        )
    }
    
    func stopPollingIsMacKeyboardSuggestionsDisabledState() {
        self.pollingTimerForMacKeyboardSuggestionsDisabledState?.invalidate()
        self.pollingTimerForMacKeyboardSuggestionsDisabledState = nil
    }
    
    func openKeyboardSettings() {
        if let url = URL(string: Self.keyboardSettingsLink) {
            NSWorkspace.shared.open(url)
        }
    }
}
