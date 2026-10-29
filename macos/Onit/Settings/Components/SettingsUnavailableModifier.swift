// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsUnavailableModifier.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-09-02.
//

import SwiftUI

extension View {

    /// Mark a settings row as unavailable: not interactive, and visibly so.
    ///
    /// `.disabled()` alone is not enough here. It dims controls, but the labels
    /// in these rows are painted by `styleText` with an explicit colour, which
    /// SwiftUI leaves untouched - so a disabled row reads almost like an
    /// enabled one and the user tries to click it anyway.
    ///
    /// Pair it with the subtitle spelling out why the row is unavailable: the
    /// dimming says "not now", only the text says "because of this".
    ///
    /// Apply it to the `SettingsPageSubsection`, not to the enclosing
    /// `SettingsPageSection`: on the section it fades the card's background and
    /// border too, and the greyed row loses the outline that groups it.
    func settingsUnavailable(_ isUnavailable: Bool) -> some View {
        disabled(isUnavailable)
            .opacity(isUnavailable ? 0.45 : 1)
    }
}
