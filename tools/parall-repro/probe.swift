// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
// Prints, once a second, what each PID source reports for the frontmost app:
//   NSWorkspace.frontmostApplication.processIdentifier  (what Cloudless used)
//   AX system-wide focused element owner pid
//   CGWindowList frontmost layer-0 window owner pid
// Needs Accessibility permission for the terminal running it (for the AX column).

import AppKit
import ApplicationServices

func axFocusedPid() -> pid_t? {
    let sys = AXUIElementCreateSystemWide()
    var ref: AnyObject?
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
          let obj = ref, CFGetTypeID(obj) == AXUIElementGetTypeID() else { return nil }
    var pid: pid_t = 0
    return AXUIElementGetPid(obj as! AXUIElement, &pid) == .success ? pid : nil
}

func frontWindowPid() -> pid_t? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    let me = ProcessInfo.processInfo.processIdentifier
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me { return pid }
    }
    return nil
}

setbuf(stdout, nil)
print("NSWorkspace pid | bundle id                         | AX focused pid | front window pid")
while true {
    let app = NSWorkspace.shared.frontmostApplication
    let ws = app.map { String($0.processIdentifier) } ?? "nil"
    let bid = app?.bundleIdentifier ?? "nil"
    let ax = axFocusedPid().map(String.init) ?? "nil"
    let cg = frontWindowPid().map(String.init) ?? "nil"
    print("\(ws.padding(toLength: 15, withPad: " ", startingAt: 0)) | \(bid.padding(toLength: 33, withPad: " ", startingAt: 0)) | \(ax.padding(toLength: 14, withPad: " ", startingAt: 0)) | \(cg)")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
}
