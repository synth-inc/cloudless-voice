// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarCorrectionMode.swift
//  Onit
//

import AppKit
import Combine
import Defaults

@MainActor
final class MenuBarCorrectionMode: MenuBarItemBase {
    private var cancellables = Set<AnyCancellable>()

    override func initializeProperties() {
        self.title = "Correction Mode"
        self.action = #selector(toggleCorrectionMode)
        self.keyEquivalent = ""
        self.target = self
    }

    override func runPostInitilizationSetup() {
        self.refreshState()

        Defaults.publisher(Defaults.Keys.TranscriptionConfigKeys.forceCorrectionUI)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshState()
            }
            .store(in: &self.cancellables)
    }

    private func refreshState() {
        self.state = Defaults[Defaults.Keys.TranscriptionConfigKeys.forceCorrectionUI] ? .on : .off
    }

    @objc private func toggleCorrectionMode() {
        TranscriptionConfig.shared.forceCorrectionUI.toggle()
    }
}
