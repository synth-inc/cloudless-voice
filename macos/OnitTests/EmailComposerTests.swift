// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailComposerTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-09-11.
//

import ApplicationServices
import Defaults
import Testing
@testable import Onit

// Parent suite for every suite that mutates the email allowlist Defaults (the
// composer overrides and the manager's backing keys). Swift Testing runs suites
// in parallel, so `.serialized` on each child only orders its own tests; the trait
// on a parent applies to all nested suites, which makes them run one at a time.
@Suite(.serialized)
enum EmailDefaultsSerialized {}

extension EmailDefaultsSerialized {
    // These cases mutate the shared allowlist Defaults (serialized by the parent suite):
    // parallel runs would let one test's reset wipe another's additions mid-flight.
    @Suite
    struct EmailComposerTests {

        private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

        /// Fails the test if the decision reads the page host, the costly AX walk.
        private static func hostNeverRead() -> String? {
            Issue.record("the page host was read")
            return nil
        }

        /// Clear the user allowlist overrides so a test starts from the built-ins.
        private static func resetAllowlists() {
            Defaults[ConfigKeys.emailComposerAddBundleIds] = []
            Defaults[ConfigKeys.emailComposerRemoveBundleIds] = []
            Defaults[ConfigKeys.emailComposerAddHosts] = []
            Defaults[ConfigKeys.emailComposerRemoveHosts] = []
        }

        @Test("A native mail app is a composer, without reading the page")
        func mailApp() {
            Self.resetAllowlists()
            #expect(EmailComposer.isComposer(bundleId: "com.apple.mail", host: Self.hostNeverRead))
            #expect(EmailComposer.isComposer(bundleId: "com.microsoft.Outlook", host: Self.hostNeverRead))
        }

        @Test("A stored dictation keeps the layout only when the verdict was recorded live")
        func storedVerdict() {
            #expect(EmailComposer.isComposer(recorded: true))
            #expect(!EmailComposer.isComposer(recorded: false))
            // The row knows the app but not the page, so a dictation whose composer
            // verdict was never recorded live must not come back laid out.
            #expect(!EmailComposer.isComposer(recorded: nil))
        }

        @Test("Webmail matches on the exact host, case-insensitively")
        func webmailHost() {
            Self.resetAllowlists()
            #expect(EmailComposer.isComposer(bundleId: "company.thebrowser.Browser") { "mail.google.com" })
            #expect(EmailComposer.isComposer(bundleId: "com.apple.Safari") { "Outlook.Office.com" })
            #expect(EmailComposer.isComposer(bundleId: "com.apple.Safari") { "outlook.cloud.microsoft" })
            #expect(EmailComposer.isComposer(bundleId: "com.apple.Safari") { "outlook.office365.us" })
            #expect(!EmailComposer.isComposer(bundleId: "com.apple.Safari") { "google.com" })
            #expect(!EmailComposer.isComposer(bundleId: "com.apple.Safari") { "mail.google.com.example.net" })
        }

        @Test("The field role no longer gates: a mail app is a composer whatever the focused field")
        func fieldRoleNoLongerGates() {
            Self.resetAllowlists()
            // Formerly rejected as single-line (subject / recipients / search). The
            // role is not consulted anymore, so these count too, the trade-off for
            // supporting apps that expose their body under an unexpected role.
            #expect(EmailComposer.isComposer(bundleId: "com.apple.mail", host: Self.hostNeverRead))
        }

        @Test("A user-added app and host are treated as composers")
        func userAdditionsMatch() {
            Self.resetAllowlists()
            defer { Self.resetAllowlists() }
            Defaults[ConfigKeys.emailComposerAddBundleIds] = ["me.proton.mail.mac"]
            Defaults[ConfigKeys.emailComposerAddHosts] = ["mail.proton.me"]
            #expect(EmailComposer.isComposer(bundleId: "me.proton.mail.mac", host: Self.hostNeverRead))
            #expect(EmailComposer.isComposer(bundleId: "com.apple.Safari") { "mail.proton.me" })
        }

        @Test("A removed built-in app and host stop matching")
        func userRemovalsExcludeBuiltIns() {
            Self.resetAllowlists()
            defer { Self.resetAllowlists() }
            Defaults[ConfigKeys.emailComposerRemoveBundleIds] = ["com.microsoft.Outlook"]
            Defaults[ConfigKeys.emailComposerRemoveHosts] = ["mail.google.com"]
            #expect(!EmailComposer.isComposer(bundleId: "com.microsoft.Outlook") { nil })
            #expect(!EmailComposer.isComposer(bundleId: "com.apple.Safari") { "mail.google.com" })
            // A built-in that wasn't removed still works.
            #expect(EmailComposer.isComposer(bundleId: "com.apple.mail", host: Self.hostNeverRead))
        }

        @Test("A removal wins over a stale addition of the same host")
        func removalWinsOverAddition() {
            Self.resetAllowlists()
            defer { Self.resetAllowlists() }
            // A term promoted into the built-ins can linger in the add list; a
            // removal must still turn it off (EmailComposer.merged subtracts last).
            Defaults[ConfigKeys.emailComposerAddHosts] = ["mail.google.com"]
            Defaults[ConfigKeys.emailComposerRemoveHosts] = ["mail.google.com"]
            #expect(!EmailComposer.isComposer(bundleId: "com.apple.Safari") { "mail.google.com" })
        }

        @Test("Anything else is not a composer")
        func otherApps() {
            Self.resetAllowlists()
            #expect(!EmailComposer.isComposer(bundleId: "com.tinyspeck.slackmacgap") { "app.slack.com" })
            #expect(!EmailComposer.isComposer(bundleId: nil) { nil })
        }
    }
}
