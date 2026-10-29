// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionModeDailyReset.swift
//  Onit
//

#if DEBUG

import Defaults
import Foundation

/// In DEBUG builds, forces TranscriptionConfig.forceCorrectionUI back to `true` once per
/// calendar day so the dev team starts each day with Correction Mode on and must opt out
/// explicitly via the menu bar toggle.
@MainActor
final class CorrectionModeDailyReset {
    static let shared = CorrectionModeDailyReset()

    private var midnightTimer: Timer?

    private init() {}

    func start() {
        applyResetIfNeeded()
        scheduleNextMidnight()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func applyResetIfNeeded() {
        let today = Self.dayFormatter.string(from: Date())
        let lastReset = Defaults[Defaults.Keys.TranscriptionConfigKeys.forceCorrectionUILastResetDay]
        guard lastReset != today else { return }

        TranscriptionConfig.shared.forceCorrectionUI = true
        Defaults[Defaults.Keys.TranscriptionConfigKeys.forceCorrectionUILastResetDay] = today
    }

    private func scheduleNextMidnight() {
        midnightTimer?.invalidate()

        let now = Date()
        let calendar = Calendar.current
        guard let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return }

        // Pad a few seconds to make sure we're firmly on the new day when the timer fires.
        let fireDate = nextMidnight.addingTimeInterval(2)
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyResetIfNeeded()
                self.scheduleNextMidnight()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }
}

#endif
