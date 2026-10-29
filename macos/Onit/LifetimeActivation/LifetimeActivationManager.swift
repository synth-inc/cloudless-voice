// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LifetimeActivationManager.swift
//  Onit
//
//  Created by Loyd Kim on 4/8/26.
//

import Combine
import Foundation

@MainActor
final class LifetimeActivationManager: ObservableObject {
    // MARK: - Singleton

    static let shared = LifetimeActivationManager()

    private init() {}

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Configuration

    /// Fetches the seat on launch and on every login/logout so the Smart Cleanup entitlement
    /// (see `SmartCleanupEntitlement`) is known before the first dictation, not just when the
    /// user opens Settings.
    func configure() {
        AuthManager.shared.$account
            .map { $0?.id }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accountId in
                guard let self else { return }
                /// Any account change (login, logout, A→B switch) invalidates the in-flight fetch
                /// and the in-memory answer. The Smart Cleanup cache is cleared by an explicit
                /// logout (`AuthManager.logout()`) or a direct switch to another account, never
                /// by the nil emitted before session restore.
                self.activationFetchTask?.cancel()
                self.activationFetchTask = nil
                self.activation = nil
                if let previous = self.lastAccountId, let accountId, previous != accountId {
                    SmartCleanupEntitlement.shared.reset()
                }
                if accountId != nil {
                    self.lastAccountId = accountId
                    Task {
                        await self.fetchActivation()
                        await SmartCleanupEntitlement.shared.refresh()
                    }
                }
            }
            .store(in: &cancellables)

        /// Long-running sessions: re-check seat + subscription every few hours so a lapsed
        /// subscription (or a past_due that resolved) is noticed without a relaunch.
        entitlementRefreshTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in
                guard AuthManager.shared.userLoggedIn else { return }
                await LifetimeActivationManager.shared.fetchActivation()
                await StripeManager.shared.refreshSubscriptionState()
                await SmartCleanupEntitlement.shared.refresh()
            }
        }
    }

    /// The last signed-in account, to tell a direct account switch from a session restore.
    private var lastAccountId: Int?

    private var entitlementRefreshTimer: Timer? {
        willSet { entitlementRefreshTimer?.invalidate() }
    }

    // MARK: - Published Properties

    @Published private(set) var activation: LifetimeActivation? = nil

    // MARK: - Public Methods: Reset

    func reset() {
        activation = nil
    }

    // MARK: - Public Methods: Fetching

    /// In-flight fetch, so concurrent callers (sidebar, settings, hint, launch) share one
    /// request.
    private var activationFetchTask: Task<Void, Never>? = nil

    func fetchActivation() async {
        guard AuthManager.shared.userLoggedIn else {
            activation = nil
            return
        }

        if let inFlight = activationFetchTask {
            await inFlight.value
            return
        }

        let task = Task { @MainActor in
            await self.performActivationFetch()
        }
        activationFetchTask = task
        await task.value
        /// An account change may have replaced (and cancelled) this task meanwhile: never
        /// clear the newer in-flight fetch.
        if activationFetchTask == task { activationFetchTask = nil }
    }

    private func performActivationFetch() async {
        let accountId = AuthManager.shared.account?.id
        /// Discard answers that belong to a different account than the one now signed in.
        func stillCurrent() -> Bool {
            !Task.isCancelled && accountId != nil && AuthManager.shared.account?.id == accountId
        }

        do {
            let client = FetchingClient()
            let result = try await client.getLifetimeActivation(productName: .dictation)
            guard stillCurrent() else { return }
            activation = result
            entitlementAnswerArrived()
        } catch FetchingError.notFound {
            /// A definitive "no seat" answer, not a failure.
            guard stillCurrent() else { return }
            activation = nil
            entitlementAnswerArrived()
        } catch {
            guard stillCurrent() else { return }
            print("[LifetimeActivationManager]: Failed to fetch Dictation lifetime activation: \(error.localizedDescription)")
            AnalyticsManager.LifetimeActivations.activationFetchFailed(error: error.localizedDescription)
            /// A failed fetch is not an answer: keep the last known seat.
        }
    }

    /// A seat or subscription answer arrived. The Smart Cleanup entitlement itself is cached
    /// and checked inside the TranscriptionCleanup library; this only nudges it to ask the
    /// server when the app's answer disagrees with its cache (a purchase, a lapse), and turns
    /// a pending upgrade prompt into the success card.
    func entitlementAnswerArrived() {
        SmartCleanupEntitlement.shared.syncWithAccountState()
        HintManager.shared.resolvePendingPaywallIfEntitled()
    }
}
