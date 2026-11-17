// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
// Long-running observer (like Cloudless itself): start it BEFORE launching the
// repro shortcut, then watch what NSWorkspace reports for the relaunched app.
// Usage: build/watch [substring-to-match, default "Repro"]
import AppKit
setbuf(stdout, nil)
let needle = CommandLine.arguments.dropFirst().first ?? "Repro"
func matches(_ a: NSRunningApplication) -> Bool {
    (a.localizedName ?? "").contains(needle) || (a.bundleIdentifier ?? "").contains("parall-repro")
}
func describe(_ a: NSRunningApplication) -> String {
    "pid=\(a.processIdentifier) bundle=\(a.bundleIdentifier ?? "nil") name=\(a.localizedName ?? "nil") active=\(a.isActive) terminated=\(a.isTerminated)"
}
let nc = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
    nc.addObserver(forName: name, object: nil, queue: .main) { n in
        guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, matches(a) else { return }
        print("[\(name.rawValue.replacingOccurrences(of: "NSWorkspace", with: ""))] \(describe(a))")
    }
}
var last = ""
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let snap = NSWorkspace.shared.runningApplications.filter(matches).map(describe).joined(separator: "\n  ")
    let front = NSWorkspace.shared.frontmostApplication.map { "frontmost: pid=\($0.processIdentifier) bundle=\($0.bundleIdentifier ?? "nil")" } ?? "frontmost: nil"
    let line = "running:\n  \(snap)\n\(front)"
    if line != last { print(line); last = line }
}
RunLoop.main.run()
