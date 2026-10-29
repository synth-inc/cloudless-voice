// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsAccountAndBilling.swift
//  Onit
//
//  Created by Loyd Kim on 9/2/25.
//

import Defaults
import SwiftUI

struct SettingsAccountAndBilling: View {
    // MARK: - Environment
    
    @Environment(\.appState) var appState
    @Environment(\.openURL) var openURL
    
    // MARK: - States
    
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var stripeManager = StripeManager.shared
    @ObservedObject private var lifetimeActivationManager = LifetimeActivationManager.shared
    @ObservedObject private var smartCleanup = SmartCleanupEntitlement.shared

    // MARK: - Private Variables
    
    private var signInStatusText: String {
        if authManager.userLoggedIn {
            if let email = authManager.account?.email {
                return String(format: String.localized("You are signed in as %@", table: "Settings"), email)
            } else if let appleEmail = authManager.account?.appleEmail {
                return String(format: String.localized("You are signed in as %@", table: "Settings"), appleEmail)
            } else {
                return String.localized("Signed in.", table: "Settings")
            }
        } else {
            return String.localized("Create an account to save your settings and preferences.", table: "Settings")
        }
    }

    private var hasLifetimeSeat: Bool {
        lifetimeActivationManager.activation?.isActive ?? false
    }

    /// Same rule as the Smart Cleanup entitlement: a past_due beyond the grace is no longer Pro.
    private var isSubscribed: Bool {
        SubscriptionStatus.entitles(
            status: appState.subscriptionStatus,
            periodStart: appState.subscription.map { Date(timeIntervalSince1970: $0.currentPeriodStart) }
        )
    }

    private var isPastDue: Bool {
        appState.subscriptionStatus == SubscriptionStatus.pastDue
    }

    // MARK: - Body
    
    var body: some View {
        Group {
            dictationLifetimeActivationSection
            if isSubscribed || !hasLifetimeSeat {
                billingSection
            }
            accountSection
        }
        .onAppear {
            Task {
                async let activation: Void = lifetimeActivationManager.fetchActivation()
                async let subscription: Void = stripeManager.fetchSubscriptionData()
                _ = await (activation, subscription)
                await smartCleanup.refresh()
            }
        }
        .onChange(of: authManager.userLoggedIn) { _, _ in
            Task {
                async let activation: Void = lifetimeActivationManager.fetchActivation()
                async let subscription: Void = stripeManager.fetchSubscriptionData()
                _ = await (activation, subscription)
            }
        }
    }
    
    // MARK: - Child Components: Shared
    
    private func captionText(_ text: String) -> some View {
        Text(text)
            .styleText(
                size: 13,
                weight: .regular,
                color: Color.S_1
            )
    }

    // MARK: - Child Components: Dictation Lifetime Activation Section

    @ViewBuilder
    private var dictationLifetimeActivationSection: some View {
        if let activation = lifetimeActivationManager.activation, activation.isActive {
            // Activated state
            VStack(alignment: .center, spacing: 6) {
                Text(String(
                    format: String.localized("You are #%@", table: "Settings"),
                    activation.seatNumber.formatted()
                ))
                .styleText(size: 13, weight: .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.T_7)
                .cornerRadius(6)

                Text(String.localized("Smart Cleanup Unlocked!", table: "Settings"))
                    .styleText(fontFamily: .libreBaskerville, size: 18, weight: .regular)

                captionText(String.localized("You have unlimited Smart Cleanup, forever. Thanks for being early.", table: "Settings"))

                if let usage = smartCleanup.usage, usage.isUnlimited {
                    captionText(SmartCleanupUsageFormat.monthlyWords(usage))
                }
                unconfirmedSubscriptionNotice

                HStack(spacing: 0) {
                    Text(String.localized("Enjoying Cloudless? Help us ", table: "Settings"))
                        .styleText(size: 13, weight: .regular, color: Color.S_1)
                    Button {
                        AppWindowManager.shared.showSettingsSheet = false
                        AppWindowManager.shared.setPage(page: .support)
                    } label: {
                        Text(String.localized("spread the word →", table: "Settings"))
                            .styleText(size: 13, weight: .regular, color: Color.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.special2)
            .addBorder(cornerRadius: 14, stroke: Color.T_7)
        }
    }
    
    // MARK: - Child Components: Account Section
    
    private var accountSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Account", table: "Settings"))) {
            SettingsPageSubsection(
                vertical: .init(spacing: 12),
                header: .init(title: signInStatusText)
            ) {
                accountAuthButtonsView
            }
        }
    }
    
    private var accountAuthButtonsView: some View {
        HStack(alignment: .center, spacing: 9) {
            if authManager.userLoggedIn {
                AuthHelpers.logoutButton
                    .cornerRadius(7)
                DeleteAccountButton()
                    .cornerRadius(7)
            } else {
                AuthHelpers.createAnAccountButton {
                    OnboardingWindowManager.shared.showAuthOnly()
                }
                .cornerRadius(7)
                AuthHelpers.signInButton {
                    OnboardingWindowManager.shared.showAuthOnly()
                }
                .cornerRadius(7)
            }
        }
    }
    
    // MARK: - Child Components: Plan & Billing Section
    
    private var billingSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Plan & Billing", table: "Settings"))) {
            SettingsPageSubsection(vertical: .init(spacing: 12)) {
                planAndBillingSubscriptionErrorView
                planAndBillingInfo
                subscriptionActions
                whyItCostsMoneySection
            }
        }
    }

    // MARK: - Child Components: Why It Costs Money

    private var whyItCostsMoneySection: some View {
        WhyItCostsMoneyLink(title: DictationPlanCopy.whyLongTitle, fontSize: 12)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var planAndBillingSubscriptionErrorView: some View {
        if let subscriptionDataErrorMessage = stripeManager.subscriptionDataErrorMessage {
            Text(subscriptionDataErrorMessage)
                .styleText(
                    size: 13,
                    weight: .regular,
                    color: Color.red500
                )
        }
    }
    
    // MARK: - Child Components: Plan & Billing → Info
    
    @ViewBuilder
    private var planAndBillingInfo: some View {
        if stripeManager.fetchingSubscriptionData {
            VStack(alignment: .leading, spacing: 6) {
                Shimmer(width: 100, height: 16)
                Shimmer(width: 160, height: 16)
            }
        } else if isSubscribed {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    isPastDue
                        ? String.localized("Pro plan: payment issue", table: "Settings")
                        : appState.subscriptionCanceled
                            ? String.localized("Pro plan expiring soon", table: "Settings")
                            : String.localized("Pro Plan", table: "Settings")
                )
                .styleText(size: 13, weight: .regular)

                VStack(alignment: .leading, spacing: 1) {
                    unconfirmedSubscriptionNotice
                    if isPastDue {
                        captionText(String.localized("Your last payment didn't go through. Update your card in Manage Subscription to keep unlimited Smart Cleanup.", table: "Settings"))
                    } else {
                        captionText(String.localized("You have unlimited Smart Cleanup.", table: "Settings"))
                    }
                    if let usage = smartCleanup.usage {
                        captionText(SmartCleanupUsageFormat.monthlyWords(usage))
                    }
                    if let renewalDate = formattedPeriodEnd {
                        captionText(renewalText(renewalDate))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(String.localized("Free Plan", table: "Settings"))
                    .styleText(size: 13, weight: .regular)

                VStack(alignment: .leading, spacing: 1) {
                    captionText(String.localized("Dictation is free and unlimited.", table: "Settings"))
                    unconfirmedSubscriptionNotice
                    if !smartCleanup.isFreeTierAvailable {
                        /// Unsigned / ad-hoc build: no free Smart Cleanup words, say so up front.
                        captionText(SmartCleanupSignedBuildCopy.explanation)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let usage = smartCleanup.usage {
                        if let meter = SmartCleanupUsageFormat.freeMeter(usage) {
                            captionText(meter)
                        }
                        captionText(String(
                            format: String.localized("Free words reset %@.", table: "Settings"),
                            SmartCleanupUsageFormat.date(usage.periodEnd)
                        ))
                    }
                    if appState.subscriptionNeedsBillingPortal {
                        captionText(String.localized("Your last payment didn't go through. Update your card in Manage Subscription to get unlimited Smart Cleanup back.", table: "Settings"))
                    } else {
                        captionText(String(
                            format: String.localized("Pro is %@ for unlimited Smart Cleanup, 100%% local and private.", table: "Settings"),
                            DictationPlan.monthlyPriceWithPeriod
                        ))
                    }
                }
            }
        }
    }

    /// Signed in, but Smart Cleanup can't confirm the plan (offline since updating, or for
    /// longer than the library's grace), so it is metered like the free plan until it can.
    @ViewBuilder
    private var unconfirmedSubscriptionNotice: some View {
        if smartCleanup.isSubscriptionUnconfirmed {
            captionText(SmartCleanupUnconfirmedCopy.settings)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formattedPeriodEnd: String? {
        guard let end = appState.subscription?.currentPeriodEnd else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: end))
    }

    private func renewalText(_ renewalDate: String) -> String {
        if appState.subscriptionCanceled {
            return String(format: String.localized("Your Cloudless subscription expires on %@.", table: "Settings"), renewalDate)
        }
        switch appState.subscriptionStatus {
        case SubscriptionStatus.trialing:
            return String(format: String.localized("Your trial ends %@.", table: "Settings"), renewalDate)
        default:
            return String(format: String.localized("Next billing & renewal date is %@.", table: "Settings"), renewalDate)
        }
    }
    
    // MARK: - Child Components: Plan & Billing → Subscription Actions
    
    @ViewBuilder
    private var subscriptionActions: some View {
        if !authManager.userLoggedIn {
            planAndBillingSignInToUpgradeButton
        } else if isSubscribed {
            HStack(spacing: 11) {
                if appState.subscriptionCanceled {
                    planAndBillingRenewSubscriptionButton
                }
                planAndBillingManageSubscriptionButton
            }
        } else if appState.subscriptionNeedsBillingPortal {
            /// Checkout would refuse the existing subscription: only the portal can fix it.
            planAndBillingManageSubscriptionButton
        } else {
            HStack(spacing: 8) {
                planAndBillingUpgradeToProButton
                if appState.subscription != nil {
                    planAndBillingViewPastBillingInfoButton
                }
            }
        }
    }
    
    // MARK: - Child Components: Plan & Billing → Plan Buttons
    
    private var planAndBillingUpgradeToProButton: some View {
        SimpleButton(
            iconText: "🚀",
            text: String(
                format: String.localized("Upgrade to Pro: %@", table: "Settings"),
                DictationPlan.monthlyPriceWithPeriod
            ),
            textColor: Color.white,
            cornerRadius: 7,
            action: {
                AnalyticsManager.Billing.upgradeProPressed()
                Task {
                    if let error = await HintManager.shared.openDictationCheckout(openURL) {
                        stripeManager.setSubscriptionDataErrorMessage(error)
                    }
                }
            },
            background: Color.blue
        )
    }

    private var planAndBillingSignInToUpgradeButton: some View {
        SimpleButton(
            iconText: "🚀",
            text: String(
                format: String.localized("Sign in to upgrade: %@", table: "Settings"),
                DictationPlan.monthlyPriceWithPeriod
            ),
            textColor: Color.white,
            cornerRadius: 7,
            action: {
                AnalyticsManager.Billing.upgradeProPressed()
                HintManager.shared.pendingDictationCheckoutAfterLogin = true
                OnboardingWindowManager.shared.showAuthOnly()
            },
            background: Color.blue
        )
    }

    private var planAndBillingRenewSubscriptionButton: some View {
        SimpleButton(
            iconText: "💫",
            text: String.localized("Renew Subscription", table: "Settings"),
            textColor: Color.white,
            cornerRadius: 7,
            action: {
                AnalyticsManager.Billing.renewSubscriptionPressed()
                Task {
                    await stripeManager.renewSubscription()
                }
            },
            background: Color.blue
        )
    }

    private var planAndBillingManageSubscriptionButton: some View {
        SimpleButton(
            iconText: "⚙️",
            text: String.localized("Manage Subscription", table: "Settings"),
            cornerRadius: 7,
            action: {
                AnalyticsManager.Billing.manageSubscriptionPressed()
                Task {
                    await stripeManager.openBillingPortal(with: openURL)
                }
            }
        )
    }

    private var planAndBillingViewPastBillingInfoButton: some View {
        SimpleButton(
            iconText: "⚙️",
            text: String.localized("View Past Billing Info", table: "Settings"),
            cornerRadius: 7,
            action: {
                AnalyticsManager.Billing.viewPastBillingsPressed()
                Task {
                    await stripeManager.openBillingPortal(with: openURL)
                }
            }
        )
    }
}
