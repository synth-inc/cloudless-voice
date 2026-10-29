// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NoTranscriptsPlaceholder.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-29.
//

import Defaults
import SwiftUI

/// Empty-state card shown when the user has no transcripts. Reused by both
/// the Home page (Recent Transcripts preview) and the Transcripts page list.
struct NoTranscriptsPlaceholder: View {
    private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

    @Default(TranscriptionConfigKeys.shortcutType) private var shortcutType

    var body: some View {
        TranscriptSectionCard {
            AppEmptyResultsView(
                iconSystemName: "doc.text",
                title: String.localized("No transcripts yet", table: "Transcription")
            ) {
                HStack(alignment: .center, spacing: 3) {
                    Text(String.localized("Press and hold", table: "Transcription"))
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: Color.T_1
                        )
                    
                    Text(shortcutType.displayNameSymbol)
                        .styleText(
                            size: 15,
                            weight: .light,
                            color: Color.T_1
                        )
                    
                    Text(String.localized("to dictate into any text field.", table: "Transcription"))
                        .styleText(
                            size: 13,
                            weight: .regular,
                            color: Color.T_1
                        )
                }
            }
        }
    }
}
