// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  EmailComposer.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-09-11.
//

import ApplicationServices
import Defaults

/// Decides whether a dictation lands in an email composer, the only place the
/// email layout (`PipelineConfig.emailFormattingEnabled`) is allowed to run.
enum EmailComposer {

    private typealias ConfigKeys = Defaults.Keys.TranscriptionConfigKeys

    /// Built-in native mail clients, matched on the frontmost app's bundle id.
    /// The user's own additions / removals are layered on in
    /// ``effectiveMailAppBundleIds``.
    static let mailAppBundleIds: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.SparkDesktop",
        "com.readdle.SparkDesktop.appstore",
        "com.readdle.SparkDesktop-setapp",
        "com.readdle.smartemail-Mac",
        "it.bloop.airmail2",
        "com.mimestream.Mimestream",
        "com.superhuman.electron",
        "org.mozilla.thunderbird",
        "io.canarymail.mac",
    ]

    /// Built-in webmail, matched on the exact host of the page holding the focus.
    /// User additions / removals are layered on in ``effectiveWebmailHosts``.
    static let webmailHosts: Set<String> = [
        "mail.google.com",
        "outlook.live.com",
        "outlook.office.com",
        "outlook.office365.com",
        "outlook.office365.us",
        "outlook.cloud.microsoft",
    ]

    // MARK: - Effective allowlists (built-ins + user add/remove)

    /// A comparison key for an allowlist entry: trimmed + lowercased, so a bundle
    /// id or host typed with a stray space or capital still matches.
    private static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Merge a built-in set with the user's add / remove lists from Defaults.
    /// Reads Defaults directly (thread-safe) since this runs off the main actor.
    private static func merged(
        builtIns: Set<String>,
        add: Defaults.Key<[String]>,
        remove: Defaults.Key<[String]>
    ) -> Set<String> {
        var result = Set(builtIns.map(key))
        for entry in Defaults[add] {
            let k = key(entry)
            if !k.isEmpty { result.insert(k) }
        }
        // Removals win over both built-ins and additions, so a built-in the user
        // turned off stays off even if a stale addition (e.g. a term later
        // promoted into the built-in list) still names it.
        return result.subtracting(Set(Defaults[remove].map(key)))
    }

    /// Mail-app bundle ids the user currently treats as a composer: the built-ins
    /// minus the ones they turned off, plus the ones they added.
    static var effectiveMailAppBundleIds: Set<String> {
        merged(
            builtIns: mailAppBundleIds,
            add: ConfigKeys.emailComposerAddBundleIds,
            remove: ConfigKeys.emailComposerRemoveBundleIds
        )
    }

    /// Webmail hosts the user currently treats as a composer.
    static var effectiveWebmailHosts: Set<String> {
        merged(
            builtIns: webmailHosts,
            add: ConfigKeys.emailComposerAddHosts,
            remove: ConfigKeys.emailComposerRemoveHosts
        )
    }

    /// Same cap as the Spotlight insertion path: a hung app must not stall the walk.
    private static let axMessagingTimeout: Float = 0.2

    /// Budget for the whole walk. Every hop is capped on its own, but a deep
    /// tree of slow hops would still sit on the dictation start path.
    private static let walkBudget: TimeInterval = 0.05

    /// Extra budget for the toolbar fallback (window document + address-bar
    /// search). Chrome's AX tree is slow to answer, and unlike the up-walk this
    /// searches downward, so it gets more room - it still only runs once, in the
    /// background, at record start.
    private static let toolbarWalkBudget: TimeInterval = 0.2

    /// The decision, kept free of AX so it can be tested. `host` is only asked
    /// for when the app has not already settled it, since reading it walks the AX
    /// tree.
    ///
    /// No field-role gate: apps expose their compose body under too many roles to
    /// generalize safely, and a role check would silently defeat a user's own
    /// allowlist entry (an app added by the user whose body is an `AXTextField`
    /// would still be rejected). The trade-off is that a greeting-shaped phrase
    /// dictated into a subject or search field of a mail app can be laid out;
    /// that is uncommon, low-damage and immediately visible.
    static func isComposer(bundleId: String?, host: () -> String?) -> Bool {
        if let bundleId, effectiveMailAppBundleIds.contains(key(bundleId)) { return true }
        guard let host = host() else { return false }
        return effectiveWebmailHosts.contains(key(host))
    }

    /// The verdict for a stored dictation, from what its history row recorded.
    ///
    /// A row keeps neither the field role nor the page host, so the app alone
    /// cannot stand in for a missing verdict: a subject line dictated in Mail
    /// would come back laid out. Only a verdict recorded live counts.
    static func isComposer(recorded: Bool?) -> Bool {
        recorded ?? false
    }

    /// Host of the web page enclosing `element` (whose role the caller already read).
    ///
    /// Three sources, in order, so every browser is covered:
    ///  1. The nearest `AXWebArea`'s URL - Safari and Arc expose it there (and not
    ///     on the window's `AXDocument`), measured 2026-09-11.
    ///  2. The window's `AXDocument` URL - where some browsers publish it.
    ///  3. The address bar's displayed value - native toolbar chrome, always
    ///     readable. This is what makes Chrome / Edge / Firefox work: they hide
    ///     the web area's URL until `AXManualAccessibility` is set, but never the
    ///     toolbar. `isBrowserURLBar()` recognizes the field per browser.
    static func webPageHost(of element: AXUIElement, role: String?) -> String? {
        let deadline = Date().addingTimeInterval(walkBudget)

        // Walk up from the focus. Safari/Arc give the URL on the AXWebArea; on the
        // way we also remember the enclosing window for the toolbar-based fallback.
        var node = element
        var nodeRole = role
        var window: AXUIElement?
        // ponytail: bounded walk, a composer nested deeper than 64 levels reads as "not a web page".
        for _ in 0..<64 {
            // Cap messaging before reading anything from this element, the one
            // the caller passed in included.
            AXUIElementSetMessagingTimeout(node, axMessagingTimeout)
            let currentRole = nodeRole ?? node.role()
            if currentRole == "AXWebArea", let host = node.url()?.host { return host }
            if currentRole == (kAXWindowRole as String) { window = node }
            guard Date() < deadline, let parent = node.parent() else { break }
            node = parent
            nodeRole = nil
        }

        // Toolbar-based fallback (Chrome / Edge / Firefox / Opera). Its own budget:
        // Chrome's AX tree is slow, and this only runs once at record start.
        let tbDeadline = Date().addingTimeInterval(toolbarWalkBudget)
        guard let window = window ?? element.topLevelUIElement() else { return nil }
        AXUIElementSetMessagingTimeout(window, axMessagingTimeout)

        // The window's document URL (kAXDocument), a single cheap read.
        if let host = host(fromURLString: window.documentURL()) { return host }

        // Otherwise the address bar's displayed URL.
        if let bar = firstURLBar(in: window, before: tbDeadline),
           let host = host(fromURLString: bar.value()) {
            return host
        }
        return nil
    }

    /// The address-bar element in a browser window, found by a bounded search
    /// (the toolbar sits near the top, so a shallow depth cap keeps it cheap).
    private static func firstURLBar(in element: AXUIElement, before deadline: Date, depth: Int = 0) -> AXUIElement? {
        guard depth < 6, Date() < deadline, let children = element.children() else { return nil }
        for child in children {
            // Re-check between siblings: without this, a wide or stalled tree
            // keeps paying the per-hop messaging timeout long after the budget
            // is spent, and the dictation start path waits on the whole search.
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, axMessagingTimeout)
            if child.isBrowserURLBar() { return child }
            if let found = firstURLBar(in: child, before: deadline, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Parse a host from a URL string that may lack a scheme or carry a path,
    /// e.g. "mail.google.com/mail/u/0" -> "mail.google.com".
    private static func host(fromURLString raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        s = s.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? s
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        s = s.lowercased()
        guard s.contains("."), !s.contains(" ") else { return nil }
        return s
    }
}
