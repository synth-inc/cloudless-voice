// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DevBuildDetectionService.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-03.
//

import AppKit
import Combine

/// Service that detects if a dev build (inc.synth.Onit.dev, or the fully open
/// build's inc.synth.Onit.dev.open) is running.
/// Used by production builds to defer to the dev build when both are running.
/// This service only activates in Release builds.
@MainActor
final class DevBuildDetectionService: ObservableObject {

    // MARK: - Singleton

    static let shared = DevBuildDetectionService()

    // MARK: - Constants

    /// The official dev build, and the fully open build (scripts/fully-open/FullyOpen.xcconfig).
    private nonisolated static let devBundleIds: Set<String> = ["inc.synth.Onit.dev", "inc.synth.Onit.dev.open"]

    // MARK: - Published Properties

    /// Whether a dev build is currently running
    @Published private(set) var isDevBuildRunning: Bool = false

    // MARK: - Computed Properties

    /// Whether the current (production) build should defer to the dev build.
    /// Always returns false in DEBUG and BETA builds (neither defers to a dev build).
    var shouldDeferToDevBuild: Bool {
        #if DEBUG || ONIT_BETA
        return false
        #else
        return isDevBuildRunning
        #endif
    }

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Starts monitoring for dev build launch/termination.
    /// Only active in production Release builds (not DEBUG or BETA).
    func startMonitoring() {
        #if DEBUG || ONIT_BETA
        return
        #else
        // Check current state
        checkForDevBuild()

        // Observe app launches
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { app in Self.isDevBuild(app) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isDevBuildRunning = true
            }
            .store(in: &cancellables)

        // Observe app terminations
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { app in Self.isDevBuild(app) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Double-check no other dev instance is running
                self?.checkForDevBuild()
            }
            .store(in: &cancellables)
        #endif
    }

    /// Stops monitoring for dev build.
    func stopMonitoring() {
        cancellables.removeAll()
    }

    // MARK: - Private Methods

    private nonisolated static func isDevBuild(_ app: NSRunningApplication) -> Bool {
        isDevBuild(bundleIdentifier: app.bundleIdentifier)
    }

    nonisolated static func isDevBuild(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return devBundleIds.contains(bundleIdentifier)
    }

    private func checkForDevBuild() {
        let runningApps = NSWorkspace.shared.runningApplications
        let wasRunning = isDevBuildRunning
        isDevBuildRunning = runningApps.contains { Self.isDevBuild($0) }

        // When dev build quits, refresh warmup status
        if wasRunning && !isDevBuildRunning {
            WarmupCoordinator.shared.refreshStatus()
        }
    }
}
