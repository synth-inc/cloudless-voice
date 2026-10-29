// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LastTranscriptionState.swift
//  Onit
//
//  Created by Loyd Kim on 4/27/26.
//

import Combine
import Defaults
import Foundation
import KeyboardShortcuts

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

@MainActor
final class LastTranscriptionState: ObservableObject {
    // MARK: - Singleton

    static let shared = LastTranscriptionState()

    // MARK: - Published Properties

    @Published private(set) var isActive: Bool = false
    @Published private(set) var previewText: String? = nil
    @Published private(set) var copyShortcutText: String = ""
    @Published private(set) var pasteShortcutText: String = ""
    @Published private(set) var editShortcutText: String = ""

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        observeMostRecentTranscription()
        observeShortcutTypeChanges()
        observeShortcutBindingChanges()
        
        /// Initial population.
        recomputeDerivedStates()
        recomputeShortcutTexts()
    }

    // MARK: - Observers

    private func observeMostRecentTranscription() {
        TranscriptionHistoryManager.shared.$mostRecentTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeDerivedStates()
            }
            .store(in: &cancellables)
    }

    private func observeShortcutTypeChanges() {
        Defaults.publisher(TranscriptionConfigKeys.shortcutType)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.recomputeShortcutTexts()
            }
            .store(in: &cancellables)
    }

    /// The `KeyboardShortcuts` library does not have a public API to listen on real-time updates to custom shortcuts.
    /// Listening directly to `UserDefaults.didChangeNotification` is a microsecond-cheap workaround that lets us react to updates in real time.
    private func observeShortcutBindingChanges() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeShortcutTexts()
            }
            .store(in: &cancellables)
    }

    // MARK: - Private Functions

    private func recomputeDerivedStates() {
        let mostRecentTranscription = TranscriptionHistoryManager.shared.mostRecentTranscription
        
        let newPreviewText = mostRecentTranscription?.pastedText
        
        if previewText != newPreviewText {
            previewText = newPreviewText
        }

        let newIsActive = !(newPreviewText ?? "").isEmpty
        if isActive != newIsActive {
            isActive = newIsActive
        }
    }

    private func recomputeShortcutTexts() {
        let displayNameSymbol = Defaults[TranscriptionConfigKeys.shortcutType].displayNameSymbol

        let newCopyShortcutText = "\(displayNameSymbol) C"
        if copyShortcutText != newCopyShortcutText {
            copyShortcutText = newCopyShortcutText
        }

        let newPasteShortcutText = "\(displayNameSymbol) V"
        if pasteShortcutText != newPasteShortcutText {
            pasteShortcutText = newPasteShortcutText
        }

        let newEditShortcutText = "\(displayNameSymbol) E"
        if editShortcutText != newEditShortcutText {
            editShortcutText = newEditShortcutText
        }
    }
}
