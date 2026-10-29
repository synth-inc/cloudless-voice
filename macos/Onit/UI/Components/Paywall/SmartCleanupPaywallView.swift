// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupPaywallView.swift
//  Onit
//
//  Dictation paywall card, retargeted to Smart Cleanup (Oct 2026) when dictation became
//  free and unlimited.
//

import SwiftUI

/// Upgrade card shown next to the Hint after a Smart Cleanup run was refused. The dictation
/// itself was already pasted (raw), so the card only explains and offers the upgrade:
/// - free allowance used: the monthly meter, the price, when the free words reset;
/// - no free tier in this build (not signed with an Apple Developer team): why, plus the
///   subscription and the free BYOK option.
struct SmartCleanupPaywallView: View {

    // MARK: - Environment

    @Environment(\.openURL) var openURL

    // MARK: - Properties

    let mode: String
    let onDismiss: () -> Void
    var initialShowSuccess: Bool = false
    /// Error to surface on first render (e.g. checkout failed after the sign-in handoff).
    var initialError: String? = nil
    /// Whether this presentation counts as a new impression for analytics.
    var logShown: Bool = true

    // MARK: - State

    @ObservedObject private var entitlement = SmartCleanupEntitlement.shared
    @State private var isOpeningCheckout: Bool = false
    @State private var checkoutError: String? = nil

    init(
        mode: String,
        onDismiss: @escaping () -> Void,
        initialShowSuccess: Bool = false,
        initialError: String? = nil,
        logShown: Bool = true
    ) {
        self.mode = mode
        self.onDismiss = onDismiss
        self.initialShowSuccess = initialShowSuccess
        self.initialError = initialError
        self.logShown = logShown
        self._checkoutError = State(initialValue: initialError)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if initialShowSuccess {
                successCard
            } else {
                paywallCard
            }
        }
        .padding(14)
        .frame(maxWidth: 300)
        .background(Color.S_10.opacity(0.4))
        .background(Backgrounds.BrushedGlass())
        .addBorder(cornerRadius: 16, stroke: initialShowSuccess ? Color.lime400.opacity(0.5) : Color.T_4)
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .onAppear {
            if !initialShowSuccess && logShown {
                AnalyticsManager.SmartCleanupPaywall.paywallShown(mode: mode)
            }
        }
    }

    // MARK: - Paywall Card

    private var denialReason: SmartCleanupDenialReason {
        entitlement.usage?.denialReason ?? .freeAllowanceUsed
    }

    private var paywallCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SmartCleanupPaywallCopy.title(for: denialReason))
                .styleText(size: 15, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)

            Text(SmartCleanupPaywallCopy.body(for: denialReason))
                .styleText(size: 12, weight: .medium, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            PaywallCTAButton(
                text: needsBillingPortal
                    ? String.localized("Manage Subscription", table: "Settings")
                    : String(
                        format: AuthManager.shared.userLoggedIn
                            ? String.localized("Upgrade to Pro: %@", table: "Settings")
                            : String.localized("Sign in to upgrade: %@", table: "Settings"),
                        DictationPlan.monthlyPriceWithPeriod
                    ),
                action: handleCTATapped,
                isLoading: isOpeningCheckout
            )
            .fixedSize()

            if let checkoutError {
                Text(checkoutError)
                    .styleText(size: 11, weight: .regular, color: Color.red500)
                    .padding(.top, 2)
            }

            switch denialReason {
            case .freeAllowanceUsed:
                if let periodEnd = entitlement.usage?.periodEnd {
                    Text(String(
                        format: String.localized("Free words reset %@.", table: "Settings"),
                        SmartCleanupUsageFormat.date(periodEnd)
                    ))
                    .styleText(size: 11, weight: .regular, color: Color.T_2)
                    .padding(.top, 2)
                }
            case .freeTierRequiresSignedBuild:
                Button {
                    AnalyticsManager.SmartCleanupPaywall.paywallCTAClicked(ctaType: "byok")
                    onDismiss()
                    AppWindowManager.shared.showWindow(settingsPage: .transcriptionRewrite)
                } label: {
                    Text(String.localized("Use your own API key instead →", table: "Settings"))
                        .styleText(size: 11, weight: .regular, color: Color.blue)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 2)
            }

            whyLink
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Why Does This Cost Money

    private var whyLink: some View {
        WhyItCostsMoneyLink(title: DictationPlanCopy.whyTitle) {
            AnalyticsManager.SmartCleanupPaywall.whyOpened()
        }
    }

    // MARK: - Success Card

    private var successCard: some View {
        VStack(spacing: 4) {
            Text("🎉")
                .font(.system(size: 32))
                .frame(maxWidth: .infinity)

            Text(String.localized("You're all set!", table: "Settings"))
                .styleText(size: 15, weight: .bold)
                .frame(maxWidth: .infinity)

            Text(String.localized("Unlimited Smart Cleanup, enjoy.", table: "Settings"))
                .styleText(size: 12, weight: .medium, color: Color.T_1)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button {
            if !initialShowSuccess {
                AnalyticsManager.SmartCleanupPaywall.paywallDismissed()
            }
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.T_3)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(8)
    }

    // MARK: - Actions

    private var needsBillingPortal: Bool {
        AppState.shared.subscriptionNeedsBillingPortal
    }

    private func handleCTATapped() {
        if needsBillingPortal {
            openBillingPortal()
            return
        }

        AnalyticsManager.SmartCleanupPaywall.paywallCTAClicked(ctaType: "upgrade")
        AnalyticsManager.Billing.upgradeProPressed()

        /// Checkout needs an account token. Send logged-out users through sign-in first; the
        /// Hint resumes checkout automatically once the account arrives (see
        /// `HintManager.pendingDictationCheckoutAfterLogin`).
        guard AuthManager.shared.userLoggedIn else {
            HintManager.shared.pendingDictationCheckoutAfterLogin = true
            onDismiss()
            OnboardingWindowManager.shared.showAuthOnly()
            return
        }

        isOpeningCheckout = true
        checkoutError = nil
        Task {
            let error = await HintManager.shared.openDictationCheckout(openURL)
            isOpeningCheckout = false
            if let error {
                checkoutError = error
            } else {
                onDismiss()
            }
        }
    }

    private func openBillingPortal() {
        AnalyticsManager.SmartCleanupPaywall.paywallCTAClicked(ctaType: "manage")
        AnalyticsManager.Billing.manageSubscriptionPressed()

        isOpeningCheckout = true
        checkoutError = nil
        Task {
            let error = await StripeManager.shared.openBillingPortal(with: openURL)
            isOpeningCheckout = false
            if let error {
                checkoutError = error
            } else {
                /// The fix happens in the browser: poll so the success card follows on its own.
                HintManager.shared.startCheckoutPolling()
                onDismiss()
            }
        }
    }
}
