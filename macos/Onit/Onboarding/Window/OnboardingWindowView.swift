// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingWindowView.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import Defaults
import SwiftUI

struct OnboardingWindowView: View {
    // MARK: - Defaults

    @Default(.currentOnboardingStep) var currentStep
    @Default(.transcriptionEnabled) var transcriptionEnabled

    // MARK: - Properties

    @ObservedObject private var localization = LocalizationManager.shared
    /// Observed (not a plain `let`) so flipping `demoOnly`/`authOnly` on an already-open window
    /// re-renders `windowPage` - needed for the post-completion auto-launch of a skipped demo.
    @ObservedObject private var windowManager = OnboardingWindowManager.shared

    // MARK: - States

    @ObservedObject private var authManager = AuthManager.shared

    // MARK: - Body

    var body: some View {
        windowPage
            .id(localization.currentLanguage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Backgrounds.BrushedGlass())
            .cornerRadius(22)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: authManager.userLoggedIn) { _, isLoggedIn in
                if isLoggedIn {
                    if windowManager.authOnly {
                        windowManager.closeWindow()
                    } else if currentStep == nil || currentStep == .auth {
                        updateToValidStepView()
                    }
                }
            }
            .onChange(of: self.currentStep) { previousStep, currentStep in
                markFeatureOnboardingAsCompletedIfNeeded(
                    previousStep,
                    currentStep
                )

                if currentStep == .complete {
                    handleOnboardingComplete()
                }
            }
            .onChange(of: [
                transcriptionEnabled
            ]) { _, _ in
                updateToValidStepView()
            }
    }

    // MARK: - Child Components

    @ViewBuilder
    private var windowPage: some View {
        // Demo-only mode (post-completion "Try it now" / Setup's "Complete Demo"): show just the
        // dictation demo, closing the window when it finishes (the demo isn't in `steps` by now).
        if windowManager.demoOnly {
            OnboardingTranscriptionDemo()
        // Auth-only mode (e.g. "Sign in" from Settings/Home): show just the auth page, close on login.
        } else if windowManager.authOnly && !authManager.userLoggedIn {
            OnboardingAuth()
        } else if let currentStep = self.currentStep {
            switch currentStep {
            /// Auth
            case .auth:
                OnboardingAuth()

            /// Common Steps
            case .permissions:
                OnboardingPermissions()
            case .discord:
                OnboardingDiscord()

            /// Feature Step: Transcription
            case .transcriptionSetup:
                OnboardingTranscriptionSetup()
            case .transcriptionShortcut:
                OnboardingTranscriptionShortcut()
            case .transcriptionDemo:
                OnboardingTranscriptionDemo()

            case .complete:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Private Functions

    private func updateToValidStepView() {
        currentStep = OnboardingStep.steps.first
    }

    private func getStepIndexes(
        _ previousStep: OnboardingStep,
        _ currentStep: OnboardingStep
    ) -> (
        previousStepIndex: Int,
        currentStepIndex: Int
    )? {
        guard let previousStepIndex = OnboardingStep.steps.firstIndex(of: previousStep),
              let currentStepIndex = OnboardingStep.steps.firstIndex(of: currentStep)
        else {
            return nil
        }

        return (
            previousStepIndex: previousStepIndex,
            currentStepIndex: currentStepIndex
        )
    }

    private func didCrossOverLastStepOfFeatureOnboarding(
        for lastStepIndex: Int,
        _ previousStepIndex: Int,
        _ currentStepIndex: Int
    ) -> Bool {
        return previousStepIndex <= lastStepIndex && currentStepIndex > lastStepIndex
    }

    private func markFeatureOnboardingAsCompletedIfNeeded(
        _ previousStep: OnboardingStep?,
        _ currentStep: OnboardingStep?
    ) {
        guard let previousStep = previousStep,
              let currentStep = currentStep,
              let (previousStepIndex, currentStepIndex) = getStepIndexes(previousStep, currentStep)
        else {
            return
        }

        let didNavigateForward = currentStepIndex > previousStepIndex
        guard didNavigateForward else { return }

        let steps = OnboardingStep.steps

        /// Transcription
        if transcriptionEnabled,
           let lastTranscriptionStep = OnboardingStep.transcriptionSteps.last,
           let lastTranscriptionStepIndex = steps.firstIndex(of: lastTranscriptionStep),
           didCrossOverLastStepOfFeatureOnboarding(
                for: lastTranscriptionStepIndex,
                previousStepIndex,
                currentStepIndex
           )
        {
            Defaults[.transcriptionSpecificStepsCompleted] = true
        }
    }

    private func handleOnboardingComplete() {
        // The post-completion sequence below is a *first-completion* celebration, so it runs only
        // once: later arrivals at `.complete` (Settings → Setup's Skip, a `getNextValidOnboardingStep`
        // redirect) must not hijack the user's window to Home or pop the demo open again.
        let isFirstCompletion = !Defaults[.mainOnboardingCompleted]
        Defaults[.mainOnboardingCompleted] = true

        guard isFirstCompletion else {
            windowManager.closeWindow()
            return
        }

        // Land the user on the App Home so the post-completion setup card / "Cloudless is ready!"
        // Hint pop-up is visible - especially while the models are still downloading or warming up.
        AppWindowManager.shared.setPage(page: .home)
        AppWindowManager.shared.showWindow()

        // Edge case: the demo was skipped at the Shortcut step because the models weren't ready yet,
        // but the download has since finished (e.g. while the user sat on Discord). Auto-launch the
        // demo now - the same path the Home card's "Try it now" uses - instead of just closing.
        if ModelDownloadIndicator.demoModelsReady && !Defaults[.dictationDemoCompleted] {
            DictationDemoLauncher.shared.launch()
        } else {
            windowManager.closeWindow()
        }
    }
}
