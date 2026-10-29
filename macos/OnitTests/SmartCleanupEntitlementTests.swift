// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupEntitlementTests.swift
//  OnitTests
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  App-side Smart Cleanup paywall rules: usage display, the upgrade prompt's rate
//  limit, refusal reasons, and the subscription rule Settings shares with the library.
//  Metering itself lives in (and is tested by) the TranscriptionCleanup library.
//

import Foundation
import Testing
@testable import Onit

@MainActor
struct SmartCleanupEntitlementTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func usage(
        plan: SmartCleanupUsage.Plan = .free,
        wordsUsed: Int = 0,
        wordLimit: Int? = 1_000,
        wordsThisMonth: Int = 0,
        freeTierAvailable: Bool = true,
        lastConfirmedAt: Date? = nil
    ) -> SmartCleanupUsage {
        SmartCleanupUsage(
            plan: plan,
            wordsUsed: wordsUsed,
            wordLimit: wordLimit,
            wordsThisMonth: wordsThisMonth,
            periodEnd: date(2026, 11, 1, hour: 0),
            freeTierAvailable: freeTierAvailable,
            lastConfirmedAt: lastConfirmedAt
        )
    }

    // MARK: - Unconfirmed subscription (offline)

    private let grace: TimeInterval = 14 * 24 * 60 * 60

    @Test func neverConfirmedWhileSignedInIsUnconfirmed() {
        let now = date(2026, 10, 19)
        #expect(SmartCleanupEntitlement.isRefusalUnconfirmed(usage(), signedIn: true, offlineGrace: grace, now: now))
    }

    @Test func signedOutUsersKeepTheUpgradeCard() {
        let now = date(2026, 10, 19)
        #expect(!SmartCleanupEntitlement.isRefusalUnconfirmed(usage(), signedIn: false, offlineGrace: grace, now: now))
    }

    @Test func aRecentServerAnswerIsConfirmed() {
        let now = date(2026, 10, 19)
        let checked = usage(lastConfirmedAt: date(2026, 10, 10))
        #expect(!SmartCleanupEntitlement.isRefusalUnconfirmed(checked, signedIn: true, offlineGrace: grace, now: now))
    }

    @Test func anAnswerOlderThanTheGraceIsUnconfirmed() {
        let now = date(2026, 10, 19)
        let stale = usage(lastConfirmedAt: date(2026, 10, 4))
        #expect(SmartCleanupEntitlement.isRefusalUnconfirmed(stale, signedIn: true, offlineGrace: grace, now: now))
    }

    /// The library treats a future check date (clock set back) as expired; so does the app.
    @Test func anAnswerDatedInTheFutureIsUnconfirmed() {
        let now = date(2026, 10, 19)
        let future = usage(lastConfirmedAt: date(2026, 10, 25))
        #expect(SmartCleanupEntitlement.isRefusalUnconfirmed(future, signedIn: true, offlineGrace: grace, now: now))
    }

    @Test func unlimitedPlansAndMissingLibraryAreNeverUnconfirmed() {
        let now = date(2026, 10, 19)
        let subscribed = usage(plan: .subscription, wordLimit: nil)
        #expect(!SmartCleanupEntitlement.isRefusalUnconfirmed(subscribed, signedIn: true, offlineGrace: grace, now: now))
        #expect(!SmartCleanupEntitlement.isRefusalUnconfirmed(nil, signedIn: true, offlineGrace: grace, now: now))
        #expect(!SmartCleanupEntitlement.isRefusalUnconfirmed(usage(), signedIn: true, offlineGrace: nil, now: now))
    }

    @Test func unconfirmedCopyDoesNotSell() {
        let texts = [SmartCleanupUnconfirmedCopy.title, SmartCleanupUnconfirmedCopy.afterDictation, SmartCleanupUnconfirmedCopy.settings]
        for text in texts {
            #expect(!text.contains("$"))
            #expect(!text.lowercased().contains("upgrade"))
        }
        #expect(SmartCleanupUnconfirmedCopy.afterDictation.contains("internet"))
    }

    // MARK: - Usage

    @Test func wordsRemainingNeverGoesNegative() {
        #expect(usage(wordsUsed: 250).wordsRemaining == 750)
        #expect(usage(wordsUsed: 1_400).wordsRemaining == 0)
        #expect(usage(plan: .subscription, wordLimit: nil).wordsRemaining == nil)
    }

    @Test func onlyPaidPlansAreUnlimited() {
        #expect(!usage().isUnlimited)
        #expect(usage(plan: .subscription, wordLimit: nil).isUnlimited)
        #expect(usage(plan: .lifetime, wordLimit: nil).isUnlimited)
    }

    @Test func denialReasonFollowsTheFreeTier() {
        #expect(usage(wordsUsed: 1_000).denialReason == .freeAllowanceUsed)
        #expect(usage(wordLimit: 0, freeTierAvailable: false).denialReason == .freeTierRequiresSignedBuild)
    }

    // MARK: - Display

    @Test func freeMeterShowsUsedOfLimit() {
        let text = SmartCleanupUsageFormat.freeMeter(usage(wordsUsed: 250))
        #expect(text?.contains(250.formatted()) == true)
        #expect(text?.contains(1_000.formatted()) == true)
    }

    @Test func freeMeterIsCappedAtTheLimit() {
        let text = SmartCleanupUsageFormat.freeMeter(usage(wordsUsed: 1_400))
        #expect(text?.contains(1_400.formatted()) == false)
        #expect(text?.contains(1_000.formatted()) == true)
    }

    @Test func freeMeterIsHiddenWithoutAFreeTierOrForSubscribers() {
        #expect(SmartCleanupUsageFormat.freeMeter(usage(wordLimit: 0, freeTierAvailable: false)) == nil)
        #expect(SmartCleanupUsageFormat.freeMeter(usage(plan: .subscription, wordLimit: nil)) == nil)
        #expect(SmartCleanupUsageFormat.freeMeter(usage(plan: .lifetime, wordLimit: nil)) == nil)
    }

    @Test func subscribersSeeTheirWordsThisMonth() {
        let text = SmartCleanupUsageFormat.monthlyWords(usage(plan: .subscription, wordsUsed: 900, wordLimit: nil, wordsThisMonth: 12_345))
        #expect(text.contains(12_345.formatted()))
    }

    @Test func resetDateIsAMediumDate() {
        let text = SmartCleanupUsageFormat.date(date(2026, 11, 1), locale: Locale(identifier: "en_US"))
        #expect(text == "Nov 1, 2026")
    }

    @Test func signedBuildCopyMentionsSubscriptionAndBYOK() {
        let text = SmartCleanupSignedBuildCopy.explanation
        #expect(text.contains("Apple Developer team"))
        #expect(text.contains("BYOK"))
        #expect(SmartCleanupPaywallCopy.body(for: .freeTierRequiresSignedBuild) == text)
    }

    @Test func paywallCopyNeverHardCodesThePriceOrAllowance() {
        let body = SmartCleanupPaywallCopy.body(for: .freeAllowanceUsed)
        #expect(body.contains(DictationPlan.monthlyPriceWithPeriod))
        if let words = SmartCleanupEntitlement.freeWordsPerMonth {
            #expect(SmartCleanupPaywallCopy.title(for: .freeAllowanceUsed).contains(words.formatted()))
        }
    }

    // MARK: - Upgrade prompt rate limit

    @Test func firstRefusalPrompts() {
        #expect(SmartCleanupUpgradePrompt.shouldShow(lastShownAt: nil, now: date(2026, 10, 19)))
    }

    @Test func promptIsNotShownAfterEveryDictation() {
        let shown = date(2026, 10, 19, hour: 9)
        #expect(!SmartCleanupUpgradePrompt.shouldShow(lastShownAt: shown, now: shown.addingTimeInterval(60)))
        #expect(!SmartCleanupUpgradePrompt.shouldShow(lastShownAt: shown, now: shown.addingTimeInterval(23 * 60 * 60)))
        #expect(SmartCleanupUpgradePrompt.shouldShow(lastShownAt: shown, now: shown.addingTimeInterval(24 * 60 * 60)))
    }

    @Test func clockSetBackDoesNotSilenceThePrompt() {
        let shown = date(2026, 10, 19)
        #expect(SmartCleanupUpgradePrompt.shouldShow(lastShownAt: shown, now: shown.addingTimeInterval(-3600)))
    }

    // MARK: - Subscription rule (moved from DictationUsageManager)

    @Test func activeOrTrialingSubscriptionEntitles() {
        #expect(SubscriptionStatus.entitles(status: SubscriptionStatus.active, periodStart: nil))
        #expect(SubscriptionStatus.entitles(status: SubscriptionStatus.trialing, periodStart: nil))
    }

    @Test func pastDueEntitlesOnlyWithinGrace() {
        let unpaidPeriodStart = date(2026, 3, 1)
        #expect(SubscriptionStatus.entitles(status: SubscriptionStatus.pastDue, periodStart: unpaidPeriodStart, now: date(2026, 3, 5)))
        #expect(!SubscriptionStatus.entitles(status: SubscriptionStatus.pastDue, periodStart: unpaidPeriodStart, now: date(2026, 3, 9)))
        #expect(SubscriptionStatus.entitles(status: SubscriptionStatus.pastDue, periodStart: nil))
    }

    @Test func otherStatusesDoNotEntitle() {
        #expect(!SubscriptionStatus.entitles(status: SubscriptionStatus.unpaid, periodStart: nil))
        #expect(!SubscriptionStatus.entitles(status: SubscriptionStatus.canceled, periodStart: nil))
        #expect(!SubscriptionStatus.entitles(status: SubscriptionStatus.free, periodStart: nil))
        #expect(!SubscriptionStatus.entitles(status: nil, periodStart: nil))
    }
}
