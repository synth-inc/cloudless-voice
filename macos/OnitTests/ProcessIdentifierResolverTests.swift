// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ProcessIdentifierResolverTests.swift
//  OnitTests
//
//  NSRunningApplication can report processIdentifier == -1 for apps relaunched in place via
//  execv (e.g. Parall shortcuts). These cover the fallback that recovers the real PID.
//

import Foundation
import Testing
@testable import Onit

struct ProcessIdentifierResolverTests {

    private let bundleId = "com.example.target"
    private let exe = "/Applications/Target.app/Contents/MacOS/Target"

    private func resolve(
        reported: pid_t,
        bundleId: String? = "com.example.target",
        exe: String? = "/Applications/Target.app/Contents/MacOS/Target",
        axFocused: pid_t? = nil,
        bundles: [pid_t: String] = [:],
        running: [pid_t] = [],
        same: Set<pid_t> = []
    ) -> pid_t? {
        ProcessIdentifierResolver.resolve(
            reportedPid: reported,
            bundleIdentifier: bundleId,
            executablePath: exe,
            axFocusedPid: { axFocused },
            bundleIdentifierOfPid: { bundles[$0] },
            pidsRunningExecutable: { $0 == "/Applications/Target.app/Contents/MacOS/Target" ? running : [] },
            isSameApplication: { same.contains($0) }
        )
    }

    @Test func validReportedPidIsReturnedUnchanged() {
        #expect(resolve(reported: 123, axFocused: 999, bundles: [999: bundleId]) == 123)
    }

    @Test func minusOneResolvesViaFocusedElementOfSameBundle() {
        #expect(resolve(reported: -1, axFocused: 456, bundles: [456: bundleId], running: [456, 789]) == 456)
    }

    @Test func focusedElementOfOtherBundleIsIgnored() {
        // Focus is in a floating panel of another app; fall through to the executable scan.
        #expect(resolve(reported: -1, axFocused: 999, bundles: [999: "com.other"], running: [456]) == 456)
    }

    @Test func executableScanPrefersSameApplication() {
        // Two instances of the same executable (normal + Parall): pick the one that is this app.
        #expect(resolve(reported: -1, running: [456, 789], same: [789]) == 789)
    }

    @Test func executableScanAmbiguousWithoutIdentityIsNil() {
        #expect(resolve(reported: -1, running: [456, 789]) == nil)
    }

    @Test func singleExecutableMatchIsUsed() {
        #expect(resolve(reported: -1, running: [456]) == 456)
    }

    @Test func invalidCandidatesAreFiltered() {
        #expect(resolve(reported: -1, axFocused: 0, bundles: [0: bundleId], running: [-1, 0]) == nil)
    }

    @Test func nothingResolvableIsNil() {
        #expect(resolve(reported: -1, bundleId: nil, exe: nil) == nil)
    }
}
