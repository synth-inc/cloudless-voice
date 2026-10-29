// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsASRModelsPickerSheet.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-05-18.
//

import SwiftUI

// MARK: - Sheet
//
// Layout, typography and colours track the Settings design system (see
// `SettingsPageSection` / `SettingsPageSubsection` for canonical tokens):
//   • Surface fill           Color.S_6
//   • Surface border         Color.T_9
//   • Title text             Color.S_0
//   • Secondary text         Color.T_1 / Color.T_2
//   • Typography             `.styleText(size:weight:color:)`
//   • Card corner radius     12  (subsections use 12; sections use 20)
//   • Inner padding          16  (matches `SettingsPageSection.size.padding`)
//
// The sheet itself sits on `windowBackgroundColor` so it blends with the
// rest of the Settings window when presented modally.

struct SettingsASRModelsPickerSheet: View {

    @StateObject private var viewModel = ASRModelsViewModel()
    // `ASRModelDownloadManager.shared` is owned elsewhere - `@ObservedObject` is
    // correct for an externally-managed instance. `@StateObject` would claim
    // ownership and silently break SwiftUI's lifetime invariant.
    @ObservedObject private var downloads = ASRModelDownloadManager.shared
    // Also observe `TranscriptionConfig.shared` so the "Active" pill on the cards
    // flips immediately when the user taps "Use" - `viewModel.cardState(for:)` reads
    // `config.selectedASRModelId` to decide `.active` vs `.downloaded`, but without
    // an observer on `config` the view would only re-render when `downloads`
    // happened to publish for an unrelated reason.
    @ObservedObject private var config = TranscriptionConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !installedAndDownloading.isEmpty {
                        section(
                            title: String.localized("Downloaded", table: "Transcription"),
                            models: installedAndDownloading
                        )
                    }

                    if !viewModel.availableModels.isEmpty {
                        section(
                            title: String.localized("More models", table: "Transcription"),
                            models: viewModel.availableModels
                        )
                    }

                    if !viewModel.experimentalModels.isEmpty {
                        section(
                            title: String.localized("Experimental", table: "Transcription"),
                            subtitle: String.localized(
                                "These models are unpolished and may transcribe poorly. Use only if a supported model doesn't cover your language.",
                                table: "Transcription"
                            ),
                            models: viewModel.experimentalModels
                        )
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 540, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Subviews

    /// Installed + currently-downloading models surface in the same group so
    /// progress stays in context - splitting them would create a third
    /// "Downloading" section the Figma doesn't have.
    private var installedAndDownloading: [ASRModel] {
        viewModel.downloadedModels + viewModel.downloadingModels
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String.localized("Local AI Models", table: "Transcription"))
                .styleText(size: 16, weight: .semibold, color: Color.S_0)
            Text(String.localized(
                "Choose a model based on your speed, accuracy and language preferences. Once downloaded, these models run entirely on your device.",
                table: "Transcription"
            ))
            .styleText(size: 12, weight: .regular, color: Color.T_2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(title: String, subtitle: String? = nil, models: [ASRModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .styleText(size: 12, weight: .regular, color: Color.T_2)
                if let subtitle {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .accessibilityHidden(true)
                        Text(subtitle)
                            .styleText(size: 11, weight: .regular, color: Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.orange)
                }
            }
            VStack(spacing: 10) {
                ForEach(models) { model in
                    ASRModelCardView(
                        model: model,
                        state: viewModel.cardState(for: model),
                        progress: downloads.progress(for: model),
                        onUse: {
                            AnalyticsManager.AsrModel.modelSelected(
                                modelId: model.id,
                                backend: model.backend.rawValue
                            )
                            viewModel.select(model)
                        },
                        onDownload: { downloads.download(model) },
                        onCancel: { downloads.cancel(model) },
                        onDelete: {
                            AnalyticsManager.AsrModel.modelDeleted(
                                modelId: model.id,
                                backend: model.backend.rawValue
                            )
                            Task { await downloads.delete(model) }
                        }
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String.localized("Done", table: "Transcription")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

// MARK: - Card

struct ASRModelCardView: View {

    let model: ASRModel
    let state: ASRModelsViewModel.CardState
    let progress: AtomicProgress
    let onUse: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .styleText(size: 13, weight: .semibold, color: Color.S_0)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HardwareTierBadge(tier: model.hardwareTier)
                            .fixedSize()
                        if model.isExperimental {
                            ExperimentalBadge()
                                .fixedSize()
                        }
                    }
                    Text(model.shortDescription)
                        .styleText(size: 12, weight: .regular, color: model.isExperimental ? Color.orange : Color.T_1)
                }
                Spacer()
                trailingControl
            }

            metaRow

            if state == .downloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressBar(progress: progress)
                    DownloadingLabel(progress: progress)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.S_6)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.T_9, lineWidth: 1)
        )
    }

    private var displayName: String {
        model.isDefault ? "\(model.displayName) (default)" : model.displayName
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .active:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.green)
                Text(String.localized("Active", table: "Transcription"))
                    .styleText(size: 12, weight: .medium, color: Color.green)
            }

        case .downloaded:
            HStack(spacing: 8) {
                Button(String.localized("Use", table: "Transcription"), action: onUse)
                    .buttonStyle(.bordered)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.T_1)
                }
                .buttonStyle(.borderless)
                .help(String.localized("Delete model", table: "Transcription"))
            }

        case .downloading:
            Button(String.localized("Cancel", table: "Transcription"), role: .destructive, action: onCancel)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.red)

        case .available:
            Button(String.localized("Download", table: "Transcription"), action: onDownload)
                .buttonStyle(.bordered)

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Button(String.localized("Retry", table: "Transcription"), action: onDownload)
                    .buttonStyle(.bordered)
                Text(message)
                    .styleText(size: 10, weight: .regular, color: Color.red)
                    .lineLimit(1)
            }
        }
    }

    private var metaRow: some View {
        // Wrap into a second row when peak RAM is present so a 5-item HStack
        // doesn't overflow narrow Settings panels (~480 pt typical). Light
        // models keep the original single-row layout.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                RatingDots(label: String.localized("Speed", table: "Transcription"), value: model.speedRating)
                RatingDots(label: String.localized("Accuracy", table: "Transcription"), value: model.accuracyRating)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .accessibilityHidden(true)
                    Text(formattedSize)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: String.localized("Download size: %@", table: "Transcription"), formattedSize))
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .accessibilityHidden(true)
                    Text(String.localized(model.isMultilingual ? "Multilingual" : "English only", table: "Transcription"))
                }
            }
            if let formattedRAM {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .accessibilityHidden(true)
                    Text(String(format: String.localized("Up to %@ RAM during transcription", table: "Transcription"), formattedRAM))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: String.localized("Estimated peak memory: %@", table: "Transcription"), formattedRAM))
            }
        }
        .styleText(size: 11, weight: .regular, color: Color.T_1)
    }

    private var formattedSize: String {
        Self.byteFormatter.string(fromByteCount: model.sizeBytes)
    }

    /// `nil` for `.light` models - peak RAM tracks the on-disk size closely
    /// enough that surfacing both would be noise.
    private var formattedRAM: String? {
        guard let bytes = model.estimatedPeakRAMBytes else { return nil }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f
    }()
}

// MARK: - Hardware Tier Badge

private struct HardwareTierBadge: View {
    let tier: ASRModel.HardwareTier

    var body: some View {
        switch tier {
        case .light:
            EmptyView()
        case .heavy:
            badge(
                text: String.localized("Heavy", table: "Transcription"),
                color: .orange,
                hint: String.localized(
                    "Recommended on M2 or newer with 16 GB RAM",
                    table: "Transcription"
                )
            )
        case .extreme:
            badge(
                text: String.localized("Very heavy", table: "Transcription"),
                color: .red,
                hint: String.localized(
                    "Recommended on M3 or newer with 32 GB RAM",
                    table: "Transcription"
                )
            )
        }
    }

    private func badge(text: String, color: Color, hint: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(text)
                .styleText(size: 10, weight: .semibold, color: color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .foregroundStyle(color)
        .help(hint)
        .accessibilityLabel("\(text). \(hint)")
    }
}

// MARK: - Experimental Badge

/// Amber "Experimental" pill shown next to the name of any model shipped as
/// unpolished. Mirrors `HardwareTierBadge`'s styling so the two pills read as
/// a family. The tooltip restates the quality caveat for hover / VoiceOver.
private struct ExperimentalBadge: View {
    var body: some View {
        let text = String.localized("Experimental", table: "Transcription")
        let hint = String.localized(
            "We've seen poor transcription quality. May work better for some non-English languages.",
            table: "Transcription"
        )
        return HStack(spacing: 3) {
            Image(systemName: "testtube.2")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(text)
                .styleText(size: 10, weight: .semibold, color: .orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.15))
        .clipShape(Capsule())
        .foregroundStyle(Color.orange)
        .help(hint)
        .accessibilityLabel("\(text). \(hint)")
    }
}

// MARK: - Sub-components

struct RatingDots: View {
    let label: String
    let value: Int
    var total: Int = 4

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { idx in
                    Circle()
                        .fill(idx < value ? Color.accentColor : Color.T_3)
                        .frame(width: 6, height: 6)
                }
            }
        }
        // VoiceOver was previously reading the dot row as "circle, circle,
        // circle" - collapse the children and announce the value as a fraction.
        // Format string rather than concat so locales that need different
        // word order (and "out of" → "sur" / "von" / ...) read naturally.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: String.localized("%@: %d out of %d", table: "Transcription"),
            label, value, total
        ))
    }
}

/// Progress bar driven by `TimelineView(.periodic(...))`. We can't observe
/// `AtomicProgress` directly (it's written by URLSession delegates off the main
/// actor and isn't an `ObservableObject`), so we poll at 5 Hz. Unlike
/// `Timer.publish().autoconnect()`, `TimelineView` stops firing automatically
/// when the view disappears - no manual cleanup needed.
///
/// Rendering uses the native `ProgressView(value:)` rather than a custom
/// `GeometryReader + RoundedRectangle` pair. The previous custom version had a
/// geometry-propagation bug under `TimelineView`: `geometry.size.width` came
/// back as `0`, so the fill rect collapsed to nothing even when `value > 0`.
struct ProgressBar: View {
    let progress: AtomicProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            ProgressView(value: progress.value, total: 1.0)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
        }
        .frame(height: 6)
    }
}

/// "Downloading… 32%" label shown under the progress bar in the Figma comp.
/// Polled like `ProgressBar` so it ticks even when the underlying `AtomicProgress`
/// is updated off the main actor.
struct DownloadingLabel: View {
    let progress: AtomicProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let percent = Int((progress.value * 100).rounded())
            Text(String(format: String.localized("Downloading… %d%%", table: "Transcription"), percent))
                .styleText(size: 11, weight: .regular, color: Color.T_1)
        }
    }
}
