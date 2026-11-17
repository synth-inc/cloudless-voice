// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
// Tiny standalone text editor used as the execv target for the Parall repro, so
// testing never touches an app you already have open. It shows what
// NSRunningApplication reports for its own PID right in the window title.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ note: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 420)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = rect
        let text = scroll.documentView as! NSTextView
        text.font = .systemFont(ofSize: 16)
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
        refreshTitle()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.refreshTitle() }
    }
    func refreshTitle() {
        let real = ProcessInfo.processInfo.processIdentifier
        let reported = NSRunningApplication.current.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        window.title = "Repro Notepad - real pid \(real) - NSRunningApplication.current \(reported) - frontmost \(front)"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
let sub = NSMenu()
sub.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = sub
let editItem = NSMenuItem(); menu.addItem(editItem)
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = edit
app.mainMenu = menu
app.run()
