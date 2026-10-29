// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppHomeSetupCard.swift
//  Onit
//
//  Created by Loyd Kim on 6/10/26.
//

/*
 * Defaults
 * Observations
 * States
 * Private Variables: Gates
 * Private Variables: Copy
 * Body
 * Child Components: Downloading
 * Child Components: Ready
 * Child Components: Gear Button
 * Private Functions: Timer
 * Private Functions: Actions
 */

import Defaults
import SwiftUI

/// The post-onboarding App Home card that surfaces model-preparation status and the "Try it now"
/// dictation-demo offer.
///
/// It has two phases, both driven by the shared [[ModelDownloadIndicator]] so it stays in lock-step
/// with the menu-bar row / Hint indicators:
///   - **Downloading** - "Don't quit the app! …" with a live progress bar. The title is phase-aware
///     (Downloading vs Loading, dictation vs Smart Cleanup) so it never desyncs from the real state.
///   - **Ready** - "Cloudless is ready!" with a **Try it now** button that opens the demo standalone.
///
/// "Try it now" requires Smart Cleanup; if it's off, it's enabled first (which kicks off its
/// download), the card flips back to the downloading phase, and the demo auto-opens once warmed.
///
/// The gear (top-right) deep-links to Voice Dictation → Configuration → "Browse all models…". The
/// card hides automatically once the user completes the demo (`dictationDemoCompleted`). The separate
/// "Cloudless is ready!" announcement is a Hint pop-up (`HintPopUpMessageType.modelsReady`), not this card.
struct AppHomeSetupCard: View {
    // MARK: - Defaults

    @Default(.mainOnboardingCompleted) private var mainOnboardingCompleted
    @Default(.dictationDemoCompleted) private var dictationDemoCompleted
    @Default(.appHomeSetupCardDismissed) private var appHomeSetupCardDismissed

    // MARK: - Observations

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var downloader = HuggingFaceModelDownloader.shared
    @ObservedObject private var scoring = ScoringWarmupProvider.shared
    @ObservedObject private var improvement = ImprovementLLMWarmupProvider.shared
    @ObservedObject private var localization = LocalizationManager.shared
    /// Owns "Try it now": it enables what the demo needs, waits for the models, opens the demo, and
    /// puts the borrowed settings back when it closes. `isWaitingForModels` keeps this card on
    /// screen (with its download bar) for the duration of that wait.
    @ObservedObject private var demoLauncher = DictationDemoLauncher.shared

    // MARK: - States

    @State private var progress: Double = 0
    @State private var pollTimer: Timer?
    @State private var isGearHovered: Bool = false

    // MARK: - Private Variables: Gates

    private let cornerRadius: CGFloat = 22

    private var preparing: Bool {
        ModelDownloadIndicator.isAnyModelPreparing
    }

    /// The dictation engine is up and nothing required is still preparing.
    private var ready: Bool {
        transcriptionManager.isInitialized && !preparing
    }

    /// Only post-onboarding, before the demo is done, and before "Try it now" has opened the demo.
    private var shouldShow: Bool {
        return
            mainOnboardingCompleted &&
            !dictationDemoCompleted &&
            !appHomeSetupCardDismissed &&
            (preparing || ready || demoLauncher.isWaitingForModels)
    }

    private var timerShouldRun: Bool {
        return shouldShow && (preparing || demoLauncher.isWaitingForModels)
    }

    // MARK: - Private Variables: Copy

    /// Phase- and model-aware title, derived from the same source as the menu-bar row so the card can
    /// never claim "Downloading" while the engine is actually warming up.
    private var cardTitle: String {
        switch ModelDownloadIndicator.current {
        case .dictationDownloading:
            return String.localized("Don't quit the app! – Downloading your local model…", table: "App")
        case .dictationLoading:
            return String.localized("Don't quit the app! – Loading your local model…", table: "App")
        case .smartCleanupDownloading:
            return String.localized("Don't quit the app! – Downloading Smart Cleanup model…", table: "App")
        case .smartCleanupLoading:
            return String.localized("Don't quit the app! – Loading Smart Cleanup model…", table: "App")
        case .none:
            return String.localized("Don't quit the app! – Loading your local model…", table: "App")
        }
    }

    private var progressPercent: Int {
        return Int((progress * 100).rounded())
    }

    /// `nil` while warming up (no determinate progress to show).
    private var downloadFraction: Double? {
        return ModelDownloadIndicator.current?.progress
    }

    // MARK: - Body

    var body: some View {
        Group {
            if shouldShow {
                VStack(alignment: .leading, spacing: 0) {
                    if ready {
                        readyContent
                    } else {
                        downloadingContent
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cloud)
                .addBorder(
                    cornerRadius: cornerRadius,
                    stroke: Color.T_8
                )
                .overlay(alignment: .topTrailing) {
                    settingsButton
                }
            }
        }
        .onAppear { refreshTimer() }
        .onDisappear {
            // The wait used to live in this view's state, so leaving Home cancelled it. It's global
            // now, so cancel explicitly - otherwise the demo window jumps in front of whatever the
            // user moved on to, minutes later.
            demoLauncher.cancel()
        }
        .onDisappear { stopPollTimer() }
        .onChange(of: timerShouldRun) { _, _ in refreshTimer() }
        .id(localization.currentLanguage)
    }

    // MARK: - Child Components: Downloading

    private var downloadingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(cardTitle)
                    .styleText(
                        size: 14,
                        weight: .semibold,
                        color: Color.black
                    )
                Text(String.localized("We'll let you know once it's ready!", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.black.opacity(0.6)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                progressBar

                if downloadFraction != nil {
                    Text("\(progressPercent)%")
                        .styleText(
                            size: 12,
                            weight: .regular,
                            color: Color.black.opacity(0.6)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = downloadFraction {
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
                .tint(Color.info500)
        } else {
            // Warmup phase - no determinate progress, so animate an indeterminate bar.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Color.info500)
        }
    }

    // MARK: - Child Components: Ready

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String.localized("Cloudless is ready!", table: "App"))
                    .styleText(
                        size: 14,
                        weight: .semibold,
                        color: Color.black
                    )
                Text(String.localized("Your models are downloaded and the engine is warmed up, let's go!", table: "App"))
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.black.opacity(0.6)
                    )
            }

            TextButton(
                type: .primary,
                text: String.localized("Try it now", table: "App"),
                sizeConfig: .init(
                    textWeight: .regular,
                    horizontalPadding: 12,
                    height: 32
                )
            ) {
                tryItNow()
            }
            .fixedSize()
        }
    }

    // MARK: - Child Components: Gear Button

    /// Deep-links to Voice Dictation → Configuration → "Browse all models…" so the user can inspect /
    /// manage the model that's downloading.
    private var settingsButton: some View {
        Button {
            openModelSettings()
        } label: {
            Image(systemName: "gear")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isGearHovered ? Color.info500 : Color.black)
                .contentShape(Rectangle())
                .addAnimation(dependency: isGearHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isGearHovered = $0 }
        .padding(.top, 24)
        .padding(.trailing, 24)
    }

    // MARK: - Private Functions: Timer

    /// Start/stop the poll to match the current phase. The progress fields are written off the main
    /// thread via lock-free `AtomicProgress` (not `@Published`), so polling is the sanctioned way to
    /// surface them - the same approach the menu-bar row and Hint pill use.
    private func refreshTimer() {
        if timerShouldRun {
            startPollTimer()
        } else {
            stopPollTimer()
        }
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }

        tick()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15,
            repeats: true
        ) { _ in
            Task { @MainActor in tick() }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @MainActor
    private func tick() {
        progress = ModelDownloadIndicator.current?.progress ?? 0
    }

    // MARK: - Private Functions: Actions

    private func tryItNow() {
        // The launcher dismisses this card once it actually opens the demo ("Try it now" is a
        // one-shot offer); until then the card stays up as the wait's status surface.
        demoLauncher.launch(dismissesHomeCard: true)
        refreshTimer()
    }

    private func openModelSettings() {
        Defaults[.pendingOpenASRModelsSheet] = true
        AppWindowManager.shared.showWindow(settingsPage: .transcriptionBehavior)
    }
}
