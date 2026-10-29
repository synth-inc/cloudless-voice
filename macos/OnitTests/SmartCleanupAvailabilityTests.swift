// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SmartCleanupAvailabilityTests.swift
//  OnitTests
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  A build without the closed TranscriptionCleanup library (scripts/build-fully-open.sh)
//  must not offer or run Smart Cleanup. CI runs these in both builds.
//

import Defaults
import Testing
@testable import Onit

@MainActor
struct SmartCleanupAvailabilityTests {

    @Test("Smart Cleanup is registered exactly when the library is compiled in")
    func defaultProvidersFollowTheLibrary() {
        let ids = CleanupService.defaultProviders().map(\.id)
        #expect(ids.contains(CleanupProviderID.smart) == SmartCleanupAvailability.isCompiledIn)
        #expect(ids.contains(CleanupProviderID.none))
        // Bring-your-own-model is open, so both builds register it.
        #expect(ids.contains(CleanupProviderID.byok))
    }

    @Test("A stored Smart Cleanup choice falls back to no cleanup where it isn't registered")
    func storedSmartChoiceWithoutTheLibrary() {
        let service = CleanupService(providers: [NoCleanupProvider()], activeProviderID: { CleanupProviderID.smart })
        #expect(service.activeProvider.id == CleanupProviderID.none)
    }

    @Test(
        "Smart Cleanup can't be switched on without the library",
        .enabled(if: !SmartCleanupAvailability.isCompiledIn)
    )
    func smartFormattingStaysOffWithoutTheLibrary() {
        let config = TranscriptionConfig.shared
        #expect(!config.smartFormattingEnabled)
        config.smartFormattingEnabled = true
        #expect(!config.smartFormattingEnabled)
        #expect(config.cleanupProviderID != CleanupProviderID.smart)
    }

    @Test(
        "Choosing the Smart Cleanup provider without the library falls back to none",
        .enabled(if: !SmartCleanupAvailability.isCompiledIn)
    )
    func smartProviderStaysOffWithoutTheLibrary() {
        let config = TranscriptionConfig.shared
        config.cleanupProviderID = CleanupProviderID.smart
        #expect(config.cleanupProviderID == CleanupProviderID.none)
        #expect(!config.smartFormattingEnabled)
        #expect(Defaults[Defaults.Keys.TranscriptionConfigKeys.cleanupProviderID] == CleanupProviderID.none)
    }
}
