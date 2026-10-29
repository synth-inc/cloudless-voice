// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingStep.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import Defaults
import KeyboardShortcuts

@MainActor
enum OnboardingStep: String, CaseIterable, Codable, Defaults.Serializable {
    // MARK: - Step Cases

    /// Auth
    case auth

    /// Common Steps
    case permissions
    case discord

    /// Feature Step: Transcription
    case transcriptionSetup
    case transcriptionShortcut
    case transcriptionDemo

    case complete

    // MARK: - Feature-Specific Steps

    static let transcriptionSteps: [OnboardingStep] = [
        .transcriptionSetup,
        .transcriptionShortcut,
        .transcriptionDemo
    ]

    // MARK: - Onboarding Steps

    /// Builds the onboarding flow dynamically, based on auth state and enabled features.
    static var steps: [OnboardingStep] {
        /// Booleans
        let userLoggedIn = AuthManager.shared.userLoggedIn
        let authSkipped = Defaults[.onboardingAuthSkipped]

        let transcriptionEnabled = Defaults[.transcriptionEnabled]

        let mainOnboardingCompleted = Defaults[.mainOnboardingCompleted]

        let transcriptionOnboardingCompleted = Defaults[.transcriptionSpecificStepsCompleted]

        /// Computations
        var result: [OnboardingStep] = []

        /// 1. Auth - shown until the user signs in or explicitly proceeds without an account.
        /// Gated on `!mainOnboardingCompleted` so a finished onboarding stays finished: signing out
        /// (which also clears `onboardingAuthSkipped`) or an offline launch that fails session
        /// restore would otherwise put `.auth` back in `steps`, making `isOnboardingComplete` false
        /// and re-opening the whole flow on every launch for a long-onboarded user.
        if !userLoggedIn && !authSkipped && !mainOnboardingCompleted {
            result.append(.auth)
        }

        /// 2. Microphone setup (first half of the transcription flow, before permissions).
        if transcriptionEnabled && !transcriptionOnboardingCompleted {
            result.append(.transcriptionSetup)
        }

        /// 3. Permissions
        if !mainOnboardingCompleted {
            result.append(.permissions)
        }

        /// 4. Remaining transcription flow (shortcut + demo), after permissions.
        if transcriptionEnabled && !transcriptionOnboardingCompleted {
            result.append(.transcriptionShortcut)
            result.append(.transcriptionDemo)
        }

        /// 5. Discord
        if !mainOnboardingCompleted {
            result.append(.discord)
        }

        /// 6. Complete
        result.append(.complete)

        return result
    }

    // MARK: - Navigation

    func nextStep() -> OnboardingStep? {
        let steps = Self.steps
        guard let currentStepIndex = steps.firstIndex(of: self) else { return nil }
        let nextStepIndex = currentStepIndex + 1
        return nextStepIndex < steps.count ? steps[nextStepIndex] : nil
    }

    func previousStep() -> OnboardingStep? {
        let steps = Self.steps
        guard let currentStepIndex = steps.firstIndex(of: self) else { return nil }
        let previousStepIndex = currentStepIndex - 1
        return previousStepIndex >= 0 ? steps[previousStepIndex] : nil
    }

    // MARK: - Step Adjustment

    /// Returns a valid step when the current step belongs to a disabled feature.
    func getNextValidOnboardingStep() -> OnboardingStep? {
        if self == .complete {
            /// Check for feature-specific onboarding, even if main onboarding is complete/dismissed.
            if let firstStep = Self.steps.first,
               firstStep != .complete
            {
                return firstStep
            }
            /// Otherwise, onboarding complete. No adjustment needed.
            else {
                return .complete
            }
        }

        /// Currently in a valid step in the onboarding flow. No adjustment needed.
        if Self.steps.contains(self) {
            return self
        }

        /// If we've hit this point, it means we're in an invalid step.
        /// Redirect to the first valid step in the current flow.
        return Self.steps.first ?? .complete
    }

    // MARK: - Feature-Specific Helpers

    var isTranscriptionSpecific: Bool {
        switch self {
        case .transcriptionShortcut, .transcriptionDemo:
            return true
        default:
            return false
        }
    }

    var isLastTranscriptionStep: Bool {
        self == .transcriptionDemo
    }

    var isFirstStep: Bool {
        self == Self.steps.first
    }

    /// Every step, other than the one `.complete` step, is conditional.
    /// If none of them exist in `OnboardingStep.steps`, it means that we shouldn't show the onboarding flow.
    /// Using `count`, in case future definitions of a "completed" onboarding change.
    static var isOnboardingComplete: Bool {
        return OnboardingStep.steps.count == 1
    }

    // MARK: - Display Properties

    var title: String {
        switch self {
        /// Auth
        case .auth:
            return ""

        /// Common Steps
        case .permissions:
            return String.localized("Grant access to use Cloudless", table: "Onboarding")
        case .discord:
            return String.localized("Join our Discord Server!", table: "Onboarding")

        /// Feature Step: Transcription
        case .transcriptionSetup:
            return String.localized("Set up your microphone", table: "Onboarding")
        case .transcriptionShortcut:
            return String.localized("Test your dictation shortcut", table: "Onboarding")
        case .transcriptionDemo:
            return ""

        case .complete:
            return String.localized("Cloudless is up and running", table: "Onboarding")
        }
    }

    var caption: String {
        switch self {
        /// Auth
        case .auth:
            return ""

        /// Common Steps
        case .permissions:
            return String.localized("Permissions are needed for voice dictation to work properly.", table: "Onboarding")
        case .discord:
            return String.localized("Say hello to the team and other Cloudless users, get updates\nand give feedback.", table: "Onboarding")

        /// Feature Step: Transcription
        case .transcriptionSetup:
            return String.localized("Grant Cloudless access to your microphone to start dictating.", table: "Onboarding")
        case .transcriptionShortcut:
            return String.localized("Use this key anywhere to start dictating.", table: "Onboarding")
        case .transcriptionDemo:
            return ""

        case .complete:
            return String.localized("Start typing in any app, and you'll see Cloudless's\nsuggestions appear.", table: "Onboarding")
        }
    }
}
