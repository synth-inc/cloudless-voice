// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AmbientTermCaptureService.swift
//  Onit
//
//  Always-on ambient sighting capture for the persistent term memory
//  (capture-surface Phase 2): mine terms
//  from the app you're LOOKING at, not just the one you dictate into -
//  the Calendar-Monday → Zoom-Wednesday transfer story.
//
//  Coverage/battery design - change detection, not time throttles (the
//  datacollection-build pattern: capture on a fast cadence, diff, and skip
//  the expensive work when the screen hasn't changed):
//  - Ticks come from app-focus changes (1s dwell) and a 2s resample timer
//    while the user is active - the datacollection cadence - so new content
//    INSIDE one app (scrolling, navigating) is captured, not just switches.
//  - Every tick pays only a window frame grab (~10-20 ms). The SCWindow is
//    resolved once per app and cached (the SCShareableContent enumeration is
//    an XPC round-trip that would dominate at this cadence), re-resolved on
//    grab failure or staleness.
//  - The grab is downscaled and diffed against the last MINED capture of
//    that app with `ImageDifferenceDetector` (GPU tile diff, ±1px shift
//    tolerant). OCR (~100-400 ms of Vision compute) runs ONLY when tiles
//    actually changed - a static screen costs frame grabs and nothing else.
//  - The AX-tree-walk source (no screen-recording permission) dedupes the
//    same way with a text hash: identical tree text → no re-mining.
//  - Skips when input has been idle >2 min, in Low Power Mode, during secure
//    input (password fields), and for Onit itself.
//
//  Privacy: same contract as the rest of term memory - captured pixels/text
//  are reduced to mined terms immediately and discarded; only terms + counts
//  + app bundle ids are stored, behind its own opt-in dev flag.
//

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Defaults
import Foundation
import ScreenCaptureKit

// MARK: - Dedupe decisions (pure, testable)

enum AmbientCaptureDedupe {

    /// Minimum changed tiles for a screen to count as "new content".
    /// One tile tolerates an isolated repainter (clock, spinner, caret);
    /// real content changes light up several.
    static let minChangedTiles = 2

    /// Per-tile changed-pixel ratio below which a tile is ignored (anti-
    /// aliasing shimmer, video-frame noise at the sampled stride).
    static let minTileChangeRatio = 0.02

    static func isMeaningfulChange(_ regions: [ImageDifferenceRegion]) -> Bool {
        regions.filter { $0.changedRatio >= minTileChangeRatio }.count >= minChangedTiles
    }

    /// Session-stable content hash for the AX text dedupe (FNV-1a).
    static func textFingerprint(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return hash
    }
}

// MARK: - Service

final class AmbientTermCaptureService: @unchecked Sendable {
    static let shared = AmbientTermCaptureService()

    private let queue = DispatchQueue(label: "inc.onit.term-memory.ambient", qos: .utility)
    private let ocr = WindowCaptureOCR()

    private var observerToken: NSObjectProtocol?
    private var resampleTimer: DispatchSourceTimer?
    private var pendingDwell: DispatchWorkItem?
    /// One capture at a time; a tick landing mid-capture is dropped (the next
    /// timer tick re-covers it).
    private var captureInFlight = false
    /// Floor between ticks - event-storm insurance only, not a content limit.
    private var lastTick = -Double.infinity

    /// Per-app downscaled copy of the last capture that was OCR'd, so the
    /// diff always compares against what we last MINED (slow drift across
    /// several unchanged-looking ticks still accumulates and triggers).
    /// Downscaled to ≤512px wide (~650 KB each), LRU-capped - ~5 MB worst
    /// case, vs ~25 MB per full-res window capture.
    private var lastMinedImage: [String: CGImage] = [:]
    private var lastMinedOrder: [String] = []
    private static let maxRememberedApps = 8

    /// Per-app fingerprint of the last mined AX tree text.
    private var lastAXFingerprint: [String: UInt64] = [:]

    /// Cheap running counters so the power cost is measurable, not guessed.
    private var tickCount = 0
    private var ocrCount = 0
    private var skippedUnchanged = 0
    private var cumulativeMs = 0.0

    private static let dwellSeconds = 1.0
    private static let resampleSeconds = 2.0
    private static let minTickSpacing = 1.0
    private static let inputIdleCutoff = 120.0
    /// Re-resolve the cached SCWindow at least this often even without a
    /// grab failure (frame drift, window replaced by a same-app window).
    private static let windowCacheMaxAge = 30.0
    /// Cap on every AX round-trip the walk makes into the target app, same
    /// value as `TranscriptionInsertService`: a hung app must not park this
    /// queue on the multi-second default timeout every 2 s. The timeout is
    /// per-AXUIElementRef (AXUIElement.h), so it is set on each element the
    /// walk is about to message, not once on an ancestor.
    private static let axMessagingTimeout: Float = 0.2

    private init() {}

    static var isEnabled: Bool {
        TermMemoryService.isEnabled
            && Defaults[Defaults.Keys.TranscriptionConfigKeys.asrTermMemoryAmbientEnabled]
    }

    /// Arm the focus-change observer. Called once at app launch; the observer
    /// is event-driven, so it costs nothing while the flags are off. The 2s
    /// resample timer is armed lazily by `syncResampleTimer()` - a repeating
    /// timer is NOT free, and it must not wake the machine for a feature
    /// nobody switched on. Every focus change re-syncs it, so the settings
    /// toggle still needs no restart.
    func start() {
        guard observerToken == nil else { return }
        observerToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.focusChanged()
        }
        syncResampleTimer()
    }

    /// Arms the resample timer while the feature is on, tears it down when it
    /// is off. Idempotent; safe to call on every focus change.
    private func syncResampleTimer() {
        guard Self.isEnabled else {
            resampleTimer?.cancel()
            resampleTimer = nil
            return
        }
        guard resampleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.resampleSeconds,
                       repeating: Self.resampleSeconds, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        resampleTimer = timer
    }

    private func focusChanged() {
        // Dwell debounce: only capture an app the user actually settled in.
        pendingDwell?.cancel()
        syncResampleTimer()
        guard Self.isEnabled else { return }
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        pendingDwell = work
        queue.asyncAfter(deadline: .now() + Self.dwellSeconds, execute: work)
    }

    /// Runs on `queue`. Shared entry for dwell-settled focus changes and the
    /// resample timer - always captures whatever is frontmost NOW.
    private func tick() {
        guard Self.isEnabled, !captureInFlight else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastTick >= Self.minTickSpacing else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        guard !IsSecureEventInputEnabled() else { return }
        guard Self.secondsSinceLastUserInput() < Self.inputIdleCutoff else { return }
        lastTick = now
        tickCount += 1

        // Frontmost app + permission are main-actor reads; hop, then come
        // back to the capture queue with plain values.
        Task { @MainActor [weak self] in
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            // Same gate the rest of the app honours (AccessibilityParsingManager): a standing
            // capture posture must not be the one path that ignores it.
            guard !PrivacyManager.shared.shouldBlockDataCollection() else { return }
            let useOCR = ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
                && !Defaults[Defaults.Keys.TranscriptionConfigKeys.asrOnScreenTermsUseAccessibility]
            let pid = app.processIdentifier
            let bundleId = app.bundleIdentifier
            let appName = app.localizedName
            self?.queue.async {
                if useOCR {
                    self?.captureViaOCR(bundleId: bundleId, appName: appName)
                } else {
                    self?.captureViaAX(pid: pid, bundleId: bundleId)
                }
            }
        }
    }

    /// Seconds since any keyboard/mouse/scroll input - an unattended machine
    /// (meeting, lunch, overnight) must cost nothing.
    private static func secondsSinceLastUserInput() -> Double {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    // MARK: - OCR path (frame grab always, Vision only on change)

    /// Resolved SCWindow for the app being sampled - resolving costs an XPC
    /// window enumeration, the grab itself ~10-20 ms. One entry: the 2s
    /// cadence only ever samples the frontmost app.
    private var cachedWindow: (appKey: String, window: SCWindow, resolvedAt: Double)?

    /// Off `queue` (async). Cached-window grab with resolve fallback.
    private func grabWindow(appKey: String, appName: String) async throws -> CGImage {
        let now = Date().timeIntervalSince1970
        let cached: SCWindow? = queueSync {
            guard let entry = cachedWindow, entry.appKey == appKey,
                  now - entry.resolvedAt < Self.windowCacheMaxAge else { return nil }
            return entry.window
        }
        if let cached, let image = try? await ScreenRecordingManager.captureResolvedWindow(cached) {
            return image
        }
        // Miss, stale, or the window went away - resolve fresh and recache.
        let window = try await ScreenRecordingManager.resolveWindow(for: appName)
        queueSync { cachedWindow = (appKey, window, now) }
        return try await ScreenRecordingManager.captureResolvedWindow(window)
    }

    /// Runs on `queue`.
    private func captureViaOCR(bundleId: String?, appName: String?) {
        guard let appName else { return }
        let appKey = bundleId ?? appName
        captureInFlight = true
        let started = Date()
        Task { [weak self] in
            defer { self?.queue.async { self?.captureInFlight = false } }
            guard let self else { return }
            do {
                let image = try await self.grabWindow(appKey: appKey, appName: appName)
                guard let thumb = Self.downscaled(image) else { return }

                // Diff against the last capture we actually mined for this app.
                let changed: Bool = self.queueSync {
                    guard let previous = self.lastMinedImage[appKey] else { return true }
                    guard previous.width == thumb.width, previous.height == thumb.height
                    else { return true }  // window resized - treat as new content
                    let regions = (try? ImageDifferenceDetector.computeChangedRegions(
                        before: previous, after: thumb,
                        tileSize: 64, tileOverlapX: 0, tileOverlapY: 0,
                        sampleStride: 2, pixelDiffThreshold: 24,
                        tileChangeRatioThreshold: AmbientCaptureDedupe.minTileChangeRatio
                    ))?.0 ?? []
                    return AmbientCaptureDedupe.isMeaningfulChange(regions)
                }
                guard changed else {
                    self.queueSync { self.skippedUnchanged += 1 }
                    return
                }

                let observations = try await self.ocr.recognizeText(
                    in: image, usesLanguageCorrection: false)
                let text = observations.map(\.text).joined(separator: "\n")
                let terms = CapsTermSelector.shared.selectCapsTerms(text)
                self.queue.async {
                    self.remember(thumb, for: appKey)
                    self.finish(terms: terms, bundleId: bundleId, source: "OCR",
                                chars: text.count, started: started)
                }
            } catch {
                log.debug("[TermMemory] ambient OCR capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func queueSync<T>(_ body: () -> T) -> T {
        // The Task above runs off `queue`; state reads/writes hop back on.
        queue.sync(execute: body)
    }

    /// Runs on `queue`.
    private func remember(_ thumb: CGImage, for appKey: String) {
        if lastMinedImage[appKey] == nil {
            lastMinedOrder.append(appKey)
            if lastMinedOrder.count > Self.maxRememberedApps {
                lastMinedImage.removeValue(forKey: lastMinedOrder.removeFirst())
            }
        }
        lastMinedImage[appKey] = thumb
    }

    /// Low-quality downscale for diffing only - content changes survive,
    /// memory drops ~40× vs the full-res capture.
    static func downscaled(_ image: CGImage, maxWidth: Int = 512) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let scale = Double(maxWidth) / Double(image.width)
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: maxWidth, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage()
    }

    // MARK: - AX path (tree walk always - it's ~ms - text-hash dedupe)

    /// Runs on `queue`.
    private func captureViaAX(pid: pid_t, bundleId: String?) {
        let started = Date()
        guard let window = pid.firstMainWindow else { return }
        let text = Self.staticText(in: window)
        guard !text.isEmpty else { return }
        let appKey = bundleId ?? String(pid)
        let fingerprint = AmbientCaptureDedupe.textFingerprint(text)
        guard lastAXFingerprint[appKey] != fingerprint else {
            skippedUnchanged += 1
            return
        }
        lastAXFingerprint[appKey] = fingerprint
        let terms = CapsTermSelector.shared.selectCapsTerms(text)
        finish(terms: terms, bundleId: bundleId, source: "AX",
               chars: text.count, started: started)
    }

    /// Runs on `queue`.
    private func finish(terms: [String], bundleId: String?, source: String,
                        chars: Int, started: Date) {
        let ms = Date().timeIntervalSince(started) * 1000
        ocrCount += 1
        cumulativeMs += ms
        guard !terms.isEmpty else { return }
        TermMemoryService.shared.recordAmbientSightings(terms: terms, appBundle: bundleId)
        log.info("[TermMemory] ambient \(source) capture: \(terms.count) term(s) from "
            + "\(chars) chars in \(Int(ms))ms (session: \(tickCount) ticks, "
            + "\(ocrCount) mined, \(skippedUnchanged) unchanged-skips, "
            + "\(Int(cumulativeMs))ms total)")
    }

    // MARK: - AX tree walk

    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextFieldRole, kAXTextAreaRole, "AXLink",
    ]

    /// Collect the static text of a window's accessibility tree, bounded in
    /// nodes, depth, and characters so a pathological tree (giant web app)
    /// can't turn the cheap path into an expensive one. Values are read for
    /// text-bearing roles; titles for everything (buttons, tabs, headers).
    static func staticText(in window: AXUIElement,
                           maxNodes: Int = 1_500, maxDepth: Int = 16,
                           maxChars: Int = 30_000) -> String {
        var pieces: [String] = []
        var visited = 0
        var chars = 0

        func visit(_ element: AXUIElement, depth: Int) {
            guard visited < maxNodes, chars < maxChars, depth < maxDepth else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
            let role = element.role()
            if let role, textRoles.contains(role),
               let value = element.value(), !value.isEmpty, value.count <= 4_096 {
                pieces.append(value)
                chars += value.count
            }
            if let title = element.title(), !title.isEmpty, title.count <= 256 {
                pieces.append(title)
                chars += title.count
            }
            for child in element.children() ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(window, depth: 0)
        return pieces.joined(separator: "\n")
    }
}
