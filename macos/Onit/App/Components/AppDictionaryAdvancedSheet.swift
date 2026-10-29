// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDictionaryAdvancedSheet.swift
//  Onit
//
//  Created by Loyd Kim on 5/13/26.
//

import Defaults
import SwiftUI

struct AppDictionaryAdvancedSheet: View {
    // MARK: - Environments
    
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Observations
    
    @ObservedObject private var service = CustomDictionaryService.shared
    @ObservedObject private var downloader = HuggingFaceModelDownloader.shared
    @ObservedObject private var localization = LocalizationManager.shared
    
    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(alignment: .center, spacing: 8) {
                    Text(String.localized("Dictionary Settings", table: "App"))
                        .styleText(
                            fontFamily: .libreBaskerville,
                            size: 18,
                            weight: .regular
                        )
                }
                Spacer()
                Button(String.localized("Done", table: "App")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    enableSection
                    
                    if service.isEnabled {
                        modelSection
                    }
                    
                    scanSection
                    
                    if !service.pendingSuggestions.isEmpty {
                        suggestionsSection
                    }
                    
                    #if DEBUG
                    debugSection
                    #endif
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .id(localization.currentLanguage)
    }
    
    // MARK: - Child Components: Enable Section

    private var enableSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String.localized("Enable Custom Dictionary", table: "App"))
                        .styleText(size: 13, weight: .semibold)
                    Text(String.localized(
                        "Disable to free the model from memory. Adding a new term re-enables automatically.",
                        table: "App"
                    ))
                    .styleText(size: 11, weight: .regular, color: Color.S_2)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { service.isEnabled },
                    set: { enabled in
                        Task {
                            if enabled { await service.enable() } else { service.disable() }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }
    
    // MARK: - Child Components: Model Section

    private var modelSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String.localized("CTC Model", table: "App"))
                        .styleText(size: 13, weight: .semibold)
                    Text("parakeet-ctc-110m")
                        .styleText(size: 11, weight: .regular, color: Color.S_2)
                }
                Spacer(minLength: 0)
                modelStatusBadge
            }
        }
    }

    @ViewBuilder
    private var modelStatusBadge: some View {
        if service.isModelReady {
            Text(String.localized("Ready", table: "App"))
                .styleText(size: 12, color: .green)
        } else if downloader.ctcState == .downloading || downloader.ctcState == .fetching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String.localized("Downloading…", table: "App"))
                    .styleText(size: 12, color: Color.S_2)
            }
        } else if service.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String.localized("Loading…", table: "App"))
                    .styleText(size: 12, color: Color.S_2)
            }
        } else {
            Button(String.localized("Download", table: "App")) {
                Task { await service.loadModelIfNeeded() }
            }
            .controlSize(.small)
        }
    }
    
    // MARK: - Child Components: Scan Section

    private var scanSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String.localized("Scan Correction History", table: "App"))
                        .styleText(size: 13, weight: .semibold)
                    Text(String.localized(
                        "Detect candidate terms from your past transcription edits.",
                        table: "App"
                    ))
                    .styleText(size: 11, weight: .regular, color: Color.S_2)
                }
                Spacer(minLength: 0)
                if service.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(String.localized("Scan", table: "App")) {
                        Task { await service.scanHistoryForSuggestions() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var suggestionsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String.localized("Suggested Terms", table: "App"))
                        .styleText(size: 13, weight: .semibold)
                    Text(String.localized(
                        "Detected from your corrections. Add the ones you want Cloudless to recognize.",
                        table: "App"
                    ))
                    .styleText(size: 11, weight: .regular, color: Color.S_2)
                }
                ForEach(service.pendingSuggestions, id: \.self) { term in
                    suggestionRow(term: term)
                }
            }
        }
    }

    private func suggestionRow(term: String) -> some View {
        HStack(spacing: 8) {
            Text(term).styleText(size: 13)
            Spacer()
            Button(String.localized("Add", table: "App")) {
                service.acceptSuggestion(term)
            }
            .controlSize(.small)
            Button {
                service.dismissSuggestion(term)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color.S_3)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.T_9.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.T_9.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Child Components: Debug Section

    #if DEBUG
    @Default(.customDictionaryDisableKWS) private var kwsDisabled

    /// DEBUG-only: simulate the KWS model failing to load so the
    /// common-mistakes substring path is the only way replacements can fire.
    /// Doesn't unload the model - the spotter just gets bypassed in `rescore`.
    private var debugSection: some View {
        sectionCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug: disable KWS model")
                        .styleText(size: 13, weight: .semibold, color: Color.orange)
                    Text("Simulates the model failing to load. Only common-mistakes substring matches will fire. Restart not required.")
                        .styleText(size: 11, weight: .regular, color: Color.S_2)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $kwsDisabled).labelsHidden()
            }
        }
    }
    #endif
}
