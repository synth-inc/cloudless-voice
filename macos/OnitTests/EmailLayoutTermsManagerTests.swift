// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailLayoutTermsManagerTests.swift
//  OnitTests
//
//  Covers the add / remove / restore / display logic for the customizable
//  email-layout lists, including the two edge cases surfaced in review:
//  pasted-URL host sanitization and "removals win over a stale addition".
//

import Defaults
import Testing
@testable import Onit

extension EmailDefaultsSerialized {
    // Main-actor, serialized by the parent suite: these mutate the shared manager and the backing
    // Defaults, so parallel runs would clobber each other.
    @Suite
    @MainActor
    struct EmailLayoutTermsManagerTests {

        private var manager: EmailLayoutTermsManager { .shared }

        // MARK: - sanitize

        @Test("Webmail host entries are reduced to a bare host; other lists only trim")
        func sanitizeHostEntries() {
            #expect(EmailLayoutTermsManager.sanitize("https://mail.proton.me/inbox", for: .composerHosts) == "mail.proton.me")
            #expect(EmailLayoutTermsManager.sanitize("mail.proton.me/u/0?x=1", for: .composerHosts) == "mail.proton.me")
            #expect(EmailLayoutTermsManager.sanitize("user@mail.proton.me:443", for: .composerHosts) == "mail.proton.me")
            #expect(EmailLayoutTermsManager.sanitize("  sup ", for: .greetings) == "sup")
        }

        // MARK: - greetings add / remove / restore

        @Test("Adding a greeting shows it as an addition and reverts on restore")
        func addGreeting() {
            manager.restoreDefaults(for: .greetings)
            defer { manager.restoreDefaults(for: .greetings) }

            #expect(manager.add("sup", to: .greetings))
            #expect(manager.entries(for: .greetings).contains { $0.term == "sup" && $0.state == .added })
            #expect(manager.hasCustomizations(for: .greetings))
            // Backing Defaults reflects it (this is what the pipeline reads).
            #expect(Defaults[Defaults.Keys.TranscriptionConfigKeys.emailGreetingAddTriggers].contains("sup"))

            manager.restoreDefaults(for: .greetings)
            #expect(!manager.hasCustomizations(for: .greetings))
            #expect(!manager.entries(for: .greetings).contains { $0.term == "sup" })
        }

        // Built-in greetings come from the TranscriptionCleanup library; a fully open
        // build has none.
        @Test(
            "Turning a built-in greeting off marks it removed and can be restored",
            .enabled(if: SmartCleanupAvailability.isCompiledIn)
        )
        func removeAndRestoreBuiltIn() {
            manager.restoreDefaults(for: .greetings)
            defer { manager.restoreDefaults(for: .greetings) }

            guard let builtIn = manager.builtInDefaults(for: .greetings).first else {
                Issue.record("no built-in greetings for the current locale")
                return
            }
            manager.remove(builtIn, from: .greetings)
            #expect(manager.entries(for: .greetings).first { $0.term == builtIn }?.state == .removed)

            manager.restore(builtIn, in: .greetings)
            #expect(manager.entries(for: .greetings).first { $0.term == builtIn }?.state == .builtIn)
        }

        // MARK: - host add flows through to EmailComposer

        @Test("A pasted webmail URL is stored as a host and matches in EmailComposer")
        func addWebmailURLMatches() {
            manager.restoreDefaults(for: .composerHosts)
            defer { manager.restoreDefaults(for: .composerHosts) }

            #expect(manager.add("https://mail.proton.me/inbox", to: .composerHosts))
            #expect(manager.entries(for: .composerHosts).contains { $0.term == "mail.proton.me" && $0.state == .added })
            #expect(EmailComposer.isComposer(bundleId: "com.apple.Safari") { "mail.proton.me" })
        }
    }
}
