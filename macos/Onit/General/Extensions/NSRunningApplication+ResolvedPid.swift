// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NSRunningApplication+ResolvedPid.swift
//  Onit
//
//  `NSRunningApplication.processIdentifier` can be -1 for an app that is running with a
//  perfectly valid PID. Launchers that replace themselves with the target app via execv
//  (keeping the PID), such as Parall app shortcuts, produce this. Posting the paste event to
//  pid -1 delivers it nowhere, so dictation silently fails to type into those apps.
//
//  `resolvedProcessIdentifier` returns a usable PID, falling back to the Accessibility focus
//  owner and then to a scan of running processes by executable path (the same recovery
//  DockDoor uses for Parall instances).
//

import AppKit
import ApplicationServices
import Darwin

extension NSRunningApplication {

    /// A valid (> 0) PID for this app, or `nil` when none can be determined.
    ///
    /// Callers that post events must treat `nil` as "no specific target" and fall back to a
    /// system-wide post rather than posting to an invalid PID.
    var resolvedProcessIdentifier: pid_t? {
        resolvedProcessIdentifier(usingFocusedElement: true)
    }

    /// - Parameter usingFocusedElement: Pass `false` when this app is not (or is no longer)
    ///   the focused app, e.g. on deactivation, so the AX focus owner is not consulted.
    func resolvedProcessIdentifier(usingFocusedElement: Bool) -> pid_t? {
        ProcessIdentifierResolver.resolve(
            reportedPid: ProcessIdentifierResolver.reportedPid(of: self),
            bundleIdentifier: bundleIdentifier,
            executablePath: executableURL?.resolvingSymlinksInPath().path,
            axFocusedPid: usingFocusedElement ? ProcessIdentifierResolver.liveAXFocusedPid : { nil },
            bundleIdentifierOfPid: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
            pidsRunningExecutable: ProcessIdentifierResolver.livePidsRunningExecutable,
            isSameApplication: { [self] pid in NSRunningApplication(processIdentifier: pid)?.isEqual(self) == true }
        )
    }
}

enum ProcessIdentifierResolver {

    /// AX messaging timeout (seconds) so a hung foreground app cannot stall resolution.
    private static let axMessagingTimeout: Float = 0.2

    /// Debug-only switch that makes every app look like a Parall instance (pid -1), so the
    /// fallback path can be exercised end-to-end without Parall installed. Launch the Debug
    /// build with `CLOUDLESS_SIMULATE_UNRESOLVED_PID=1` in its environment.
    static func reportedPid(of app: NSRunningApplication) -> pid_t {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLOUDLESS_SIMULATE_UNRESOLVED_PID"] == "1",
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return -1
        }
        #endif
        return app.processIdentifier
    }

    /// Pure resolution logic; all system lookups are injected so it can be unit tested.
    ///
    /// 1. The reported PID, when valid.
    /// 2. The PID owning the system-wide Accessibility focus, when it belongs to the same
    ///    bundle (the frontmost app is what we resolve in practice, so this is the cheap,
    ///    exact answer even with several instances of the same app running).
    /// 3. A running process with the same executable that NSRunningApplication considers the
    ///    same application; failing that, the only process running that executable.
    static func resolve(
        reportedPid: pid_t,
        bundleIdentifier: String?,
        executablePath: String?,
        axFocusedPid: () -> pid_t?,
        bundleIdentifierOfPid: (pid_t) -> String?,
        pidsRunningExecutable: (String) -> [pid_t],
        isSameApplication: (pid_t) -> Bool
    ) -> pid_t? {
        if reportedPid > 0 { return reportedPid }

        if let bundleIdentifier,
           let focusedPid = axFocusedPid(), focusedPid > 0,
           bundleIdentifierOfPid(focusedPid) == bundleIdentifier {
            log.info("[PidResolve] pid \(reportedPid) for \(bundleIdentifier) resolved via AX focus to \(focusedPid)")
            return focusedPid
        }

        guard let executablePath else {
            log.warning("[PidResolve] pid \(reportedPid) for \(bundleIdentifier ?? "nil") unresolved (no executable path)")
            return nil
        }
        let candidates = pidsRunningExecutable(executablePath).filter { $0 > 0 }
        if let match = candidates.first(where: isSameApplication) ?? (candidates.count == 1 ? candidates.first : nil) {
            log.info("[PidResolve] pid \(reportedPid) for \(bundleIdentifier ?? "nil") resolved via executable scan to \(match)")
            return match
        }

        log.warning("[PidResolve] pid \(reportedPid) for \(bundleIdentifier ?? "nil") unresolved (\(candidates.count) executable matches)")
        return nil
    }

    // MARK: - Live lookups

    static func liveAXFocusedPid() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
                  systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    static func livePidsRunningExecutable(_ executablePath: String) -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(max(count, 0)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath().path == executablePath
        }
    }
}
