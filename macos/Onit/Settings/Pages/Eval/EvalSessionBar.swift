// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EvalSessionBar.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-10.
//

import SwiftUI

/// Session picker bar with listening toggle, folder reveal, and retranscribe actions.
struct EvalSessionBar: View {

    @ObservedObject var manager: EvalRecordingManager
    @Binding var isEvalActive: Bool
    @Binding var showNewSessionSheet: Bool
    var onRetranscribe: () -> Void
    var onClearResults: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Session:")
                .styleText(size: 11, weight: .medium, color: Color.T_3)

            sessionMenu

            Spacer()

            listeningToggle

            Button {
                manager.revealInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(Color.T_3)
            }
            .buttonStyle(.plain)
            .help("Reveal session folder in Finder")

            Button {
                onRetranscribe()
            } label: {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 11))
                    .foregroundColor(manager.retranscribeProgress != nil ? Color.T_4 : Color.T_3)
            }
            .buttonStyle(.plain)
            .help("Re-transcribe this session's audio through the current pipeline")
            .disabled(manager.retranscribeProgress != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Subviews

    private var sessionMenu: some View {
        Menu {
            ForEach(manager.availableSessions, id: \.self) { session in
                Button {
                    manager.switchSession(session)
                } label: {
                    HStack {
                        Text(session)
                        if session == manager.currentSession {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button {
                showNewSessionSheet = true
            } label: {
                Label("New Session…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(manager.currentSession)
                    .styleText(size: 11, weight: .semibold)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(Color.T_3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.T_6)
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var listeningToggle: some View {
        Button {
            isEvalActive.toggle()
            if !isEvalActive { onClearResults() }
        } label: {
            HStack(spacing: 5) {
                if isEvalActive {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .modifier(EvalPulseAnimation())
                } else {
                    Circle()
                        .fill(Color.T_4)
                        .frame(width: 7, height: 7)
                }
                Text(isEvalActive ? "Listening" : "Paused")
                    .styleText(size: 11, weight: .semibold,
                               color: isEvalActive ? Color.red : Color.T_3)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isEvalActive ? Color.red.opacity(0.1) : Color.T_6)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help(isEvalActive ? "Click to pause eval recording capture" : "Click to start capturing transcription results")
    }
}
