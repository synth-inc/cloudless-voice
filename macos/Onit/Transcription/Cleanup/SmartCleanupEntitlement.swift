// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupEntitlement.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  The app's view of the Smart Cleanup paywall. Metering lives in the closed
//  TranscriptionCleanup library (`CleanupEntitlement`): this file only wires it to
//  the account (server, token, sign-in/out) and republishes its usage for Settings
//  and the upgrade prompt. Everything outside this file uses the app-side types
//  below, so it builds with or without the library.
//
//  Dictation itself is free and unlimited in every build; only Smart Cleanup is paid.
//

import Combine
import Defaults
import Foundation
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

// MARK: - Usage

/// Smart Cleanup usage for the current period, as Settings and the paywall show it.
struct SmartCleanupUsage: Equatable, Sendable {
    enum Plan: Equatable, Sendable {
        /// Metered: a free monthly allowance (none in a build without the free tier).
        case free
        case subscription
        case lifetime
    }

    var plan: Plan
    /// Words cleaned up this period: the billing period for subscribers, the calendar
    /// month otherwise.
    var wordsUsed: Int
    /// Free allowance for the period; nil when unlimited. 0 when this build has no free tier.
    var wordLimit: Int?
    /// Words cleaned up this calendar month on any plan.
    var wordsThisMonth: Int
    /// When the counting period ends (the free words reset, or the billing period renews).
    var periodEnd: Date
    /// False in a build that can't keep a word counter (not signed with an Apple Developer
    /// team): no free allowance, Smart Cleanup needs a subscription.
    var freeTierAvailable: Bool
    /// When the library last got an answer from the server about this account's plan; nil
    /// when it has none (never answered, or dropped on sign-out / account switch).
    var lastConfirmedAt: Date? = nil

    var wordsRemaining: Int? { wordLimit.map { max(0, $0 - wordsUsed) } }
    var isUnlimited: Bool { plan != .free }

    /// Why a refused cleanup was refused, read from the usage it was refused with.
    var denialReason: SmartCleanupDenialReason {
        freeTierAvailable ? .freeAllowanceUsed : .freeTierRequiresSignedBuild
    }

    /// The library has no server answer it may trust: none at all, one older than its
    /// offline grace, or one dated in the future (the clock was set back), which the library
    /// also treats as expired. A subscriber offline since updating, or for longer than the
    /// grace, looks like a free user until the server answers again.
    func isUnconfirmed(offlineGrace: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastConfirmedAt else { return true }
        let age = now.timeIntervalSince(lastConfirmedAt)
        return age < 0 || age > offlineGrace
    }
}

/// Why Smart Cleanup was refused. Mirrors the library's `CleanupDenialReason`.
enum SmartCleanupDenialReason: Equatable, Sendable {
    /// The free monthly allowance is used up.
    case freeAllowanceUsed
    /// This build has no free allowance (not signed with an Apple Developer team).
    case freeTierRequiresSignedBuild
}

// MARK: - Entitlement

@MainActor
final class SmartCleanupEntitlement: ObservableObject {

    static let shared = SmartCleanupEntitlement()

    /// Current usage; nil in a build without Smart Cleanup, or before `configure()`.
    @Published private(set) var usage: SmartCleanupUsage?

    private var changeObserver: NSObjectProtocol?

    private init() {}

    /// Free Smart Cleanup words per month; nil in a build without Smart Cleanup.
    nonisolated static var freeWordsPerMonth: Int? {
        #if canImport(TranscriptionCleanup)
        CleanupEntitlement.freeWordsPerMonth
        #else
        nil
        #endif
    }

    /// Runs `operation` with Smart Cleanup unmetered: for the onboarding demo, whose
    /// dictations must not spend the free words. The library caps this at
    /// `CleanupEntitlement.unmeteredWordBudget` words per install and gives no exemption in
    /// a build without the free tier. The scope is task-local: it reaches child tasks and
    /// unstructured `Task {}`s (`CleanupService`'s live timeout task), never `Task.detached`.
    static func withoutMetering<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        #if canImport(TranscriptionCleanup)
        try await CleanupEntitlement.withoutMetering(operation)
        #else
        try await operation()
        #endif
    }

    /// How long the library honours a cached server answer offline; nil in a build without
    /// Smart Cleanup.
    nonisolated static var offlineGrace: TimeInterval? {
        #if canImport(TranscriptionCleanup)
        CleanupEntitlement.offlineGrace
        #else
        nil
        #endif
    }

    /// Whether Smart Cleanup is (or would be) refused only because the subscription could not
    /// be confirmed: signed in, metered, and no server answer the library may trust. Such a
    /// user may well be a subscriber who is offline; telling them to upgrade would be wrong.
    /// Signed-out users never get here (they keep the normal upgrade card).
    static func isRefusalUnconfirmed(
        _ usage: SmartCleanupUsage?,
        signedIn: Bool,
        offlineGrace: TimeInterval? = SmartCleanupEntitlement.offlineGrace,
        now: Date = Date()
    ) -> Bool {
        guard signedIn, let usage, usage.plan == .free, let offlineGrace else { return false }
        return usage.isUnconfirmed(offlineGrace: offlineGrace, now: now)
    }

    /// `isRefusalUnconfirmed` for the current account and usage.
    var isSubscriptionUnconfirmed: Bool {
        Self.isRefusalUnconfirmed(usage, signedIn: AuthManager.shared.userLoggedIn)
    }

    /// Whether this build has the free allowance. Synchronous, never prompts. True in a
    /// build without Smart Cleanup (there is nothing to explain there).
    var isFreeTierAvailable: Bool {
        #if canImport(TranscriptionCleanup)
        CleanupEntitlement.shared.isFreeTierAvailable
        #else
        true
        #endif
    }

    /// Point the library at the backend and the sign-in token. Once, at launch.
    func configure() {
        #if canImport(TranscriptionCleanup)
        CleanupEntitlement.shared.configure(serverBaseURL: OnitServer.baseURL) {
            TokenManager.token
        }
        if changeObserver == nil {
            /// Posted on any thread.
            changeObserver = NotificationCenter.default.addObserver(
                forName: CleanupEntitlement.didChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    SmartCleanupEntitlement.shared.reload()
                    HintManager.shared.resolvePendingPaywallIfEntitled()
                }
            }
        }
        reload()
        #endif
    }

    /// Ask the server now: after sign-in, a purchase, or opening Settings.
    func refresh() async {
        #if canImport(TranscriptionCleanup)
        _ = await CleanupEntitlement.shared.refresh()
        reload()
        #endif
    }

    /// Sign-out: forget the cached server answer. The word count is kept.
    func reset() {
        #if canImport(TranscriptionCleanup)
        CleanupEntitlement.shared.reset()
        reload()
        #endif
    }

    /// Re-read the library's usage.
    func reload() {
        #if canImport(TranscriptionCleanup)
        let next = SmartCleanupUsage(CleanupEntitlement.shared.usage)
        if next != usage { usage = next }
        #endif
    }

    /// True when Smart Cleanup is unlimited for this account: the library says so, or the
    /// app has just learned of a seat or subscription the library has not fetched yet (a
    /// mismatch starts a library refresh, see `syncWithAccountState()`).
    var hasUnlimitedSmartCleanup: Bool {
        usage?.isUnlimited == true || Self.accountIsEntitled
    }

    /// Lifetime seat or a paid-up subscription, as the app last fetched them.
    static var accountIsEntitled: Bool {
        if LifetimeActivationManager.shared.activation?.isActive == true { return true }
        return SubscriptionStatus.entitles(
            status: AppState.shared.subscriptionStatus,
            periodStart: AppState.shared.subscription.map { Date(timeIntervalSince1970: $0.currentPeriodStart) }
        )
    }

    /// Called whenever the app gets a seat or subscription answer. When it disagrees with
    /// the library's cached plan (a purchase or a lapse the library has not seen yet), ask
    /// the library to check the server now instead of waiting for its own schedule.
    func syncWithAccountState() {
        guard let usage, AuthManager.shared.userLoggedIn else { return }
        guard usage.isUnlimited != Self.accountIsEntitled else { return }
        Task { await refresh() }
    }
}

// MARK: - Library mapping

#if canImport(TranscriptionCleanup)
extension SmartCleanupUsage {
    init(_ usage: CleanupUsage) {
        let plan: Plan = switch usage.plan {
        case .free: .free
        case .subscription: .subscription
        case .lifetime: .lifetime
        /// A plan a newer library knows: it unlocks Smart Cleanup, show it as unlimited.
        @unknown default: .subscription
        }
        self.init(
            plan: plan,
            wordsUsed: usage.wordsUsed,
            wordLimit: usage.wordLimit,
            wordsThisMonth: usage.wordsThisMonth,
            periodEnd: usage.periodEnd,
            freeTierAvailable: usage.freeTierAvailable,
            lastConfirmedAt: usage.lastConfirmedAt
        )
    }
}
#endif

// MARK: - Upgrade prompt

/// When a refused Smart Cleanup may show the upgrade prompt. The dictation is pasted
/// raw either way; the prompt must not follow every dictation.
enum SmartCleanupUpgradePrompt {
    /// At most one prompt per day.
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    static func shouldShow(lastShownAt: Date?, now: Date = Date()) -> Bool {
        guard let lastShownAt else { return true }
        let elapsed = now.timeIntervalSince(lastShownAt)
        /// A clock set back would otherwise silence the prompt until it catches up.
        return elapsed < 0 || elapsed >= minimumInterval
    }
}

// MARK: - Display

/// Formatting for Smart Cleanup usage, shared by Settings and the paywall card.
enum SmartCleanupUsageFormat {
    @MainActor
    static func words(_ count: Int) -> String {
        count.formatted()
    }

    /// "Free words reset Nov 1, 2026." / renewal date, medium date style.
    static func date(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Free-plan meter, e.g. "250 of 1,000 free Smart Cleanup words used this month."
    @MainActor
    static func freeMeter(_ usage: SmartCleanupUsage) -> String? {
        guard usage.plan == .free, usage.freeTierAvailable, let limit = usage.wordLimit else { return nil }
        return String(
            format: String.localized("%@ of %@ free Smart Cleanup words used this month.", table: "Settings"),
            words(min(usage.wordsUsed, limit)),
            words(limit)
        )
    }

    /// Subscriber / lifetime stat, e.g. "12,345 words cleaned up this month."
    @MainActor
    static func monthlyWords(_ usage: SmartCleanupUsage) -> String {
        String(
            format: String.localized("%@ words cleaned up this month.", table: "Settings"),
            words(usage.wordsThisMonth)
        )
    }
}

/// Copy for a refusal while the subscription can't be confirmed (offline since updating, or
/// longer than the library's offline grace).
@MainActor
enum SmartCleanupUnconfirmedCopy {
    /// Hint pop-up title.
    static var title: String {
        String.localized("Couldn't confirm your subscription.", table: "MenuBar")
    }

    /// Hint pop-up body, after a refused dictation.
    static var afterDictation: String {
        String.localized("Connect to the internet once to restore Smart Cleanup. Your dictation was pasted as you said it.", table: "MenuBar")
    }

    /// Settings > Account.
    static var settings: String {
        String.localized("Couldn't confirm your subscription. Connect to the internet once to restore Smart Cleanup.", table: "Settings")
    }
}

/// Copy for builds without the free allowance (the library README's suggested wording).
@MainActor
enum SmartCleanupSignedBuildCopy {
    static var explanation: String {
        String.localized("Free Smart Cleanup words need an app signed with an Apple Developer team. This build isn't, so Smart Cleanup needs a subscription here. BYOK cleanup works for free.", table: "Settings")
    }
}
