// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarController.swift
//  Onit
//
//  Created by Loyd Kim on 9/19/25.
//

import AppKit
import Combine
import Defaults
import Observation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    // MARK: - Singleton
    
    static let shared = MenuBarController()
    
    // MARK: - Properties
    
    private let menuBarOnit: NSStatusItem
    private var menu: NSMenu

    // MARK: - Initializer
    
    override init() {
        /// Adding Onit to the menu bar.
        self.menuBarOnit = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        
        self.menu = NSMenu()
        
        super.init()
        
        self.menu.delegate = self
        self.addWindowChangeDelegate()
        self.shouldShowCheckForPermissionsItem = self.anyPermissionMissing
        self.addOnitEntryPointToMenuBar()
        self.populateMenu()
        
        // Observer for status changes
        NotificationCenter.default.publisher(for: AppState.statusDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusDot()
                self?.populateMenu()
            }
            .store(in: &self.cancellables)
        
        self.accessibilityPermissionManager.$accessibilityPermissionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.shouldShowCheckForPermissionsItem = self?.anyPermissionMissing ?? false
            }
            .store(in: &self.cancellables)
        
        self.microphoneInputManager.$hasPermission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.shouldShowCheckForPermissionsItem = self?.anyPermissionMissing ?? false
            }
            .store(in: &self.cancellables)

        /// Commented out for now until non-AX becomes the default state.
//        ScreenRecordingPermissionManager.shared.$isScreenRecordingEnabled
//            .receive(on: DispatchQueue.main)
//            .sink { [weak self] _ in
//                self?.shouldShowCheckForPermissionsItem = self?.anyPermissionMissing ?? false
//            }
//            .store(in: &self.cancellables)

        LastTranscriptionState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      !self.isMenuOpen
                else {
                    return
                }

                self.populateMenu()
            }
            .store(in: &self.cancellables)
    }
    
    // MARK: - Conformance to `NSMenuDelegate`
    
    func menuWillOpen(_ menu: NSMenu) {
        self.isMenuOpen = true
        self.shouldShowCheckForPermissionsItem = self.anyPermissionMissing
        self.microphoneInputManager.refreshAvailableDevicesAndAutoSelectIfNeeded(
            autoSelectInputDevice: Defaults[.transcriptionInputDevice] == nil
        )
        self.populateMenu()
        self.updateStatusDot()
    }

    func menuDidClose(_ menu: NSMenu) {
        self.isMenuOpen = false
        self.appStatusItemRef?.removeSubscriptions()
        self.appStatusItemRef = nil
        self.hintSnoozeStatusItemRef?.removeSubscriptions()
        self.hintSnoozeStatusItemRef = nil
        self.hintSnoozeItemRef?.removeSubscriptions()
        self.hintSnoozeItemRef = nil
        self.stopDownloadProgressTimer()
    }
    
    // MARK: - States: Defaults
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - States
    
    private weak var appStatusItemRef: MenuBarAppStatus? = nil
    private weak var hintSnoozeStatusItemRef: MenuBarHintSnoozeStatus? = nil
    private weak var hintSnoozeItemRef: MenuBarHintSnooze? = nil
    private var downloadProgressItemRefs: [MenuBarDownloadProgress] = []
    private var downloadProgressTimer: Timer? = nil
    private var isMenuOpen: Bool = false

    private var windowChangeDelegate: AccessibilityNotificationsDelegate? = nil
    private var foregroundWindow: TrackedWindow? = nil
    private var shouldShowCheckForPermissionsItem: Bool? = nil
    
    private var statusDot: CAShapeLayer? = nil
    
    // MARK: - Private Variables
    
    private let accessibilityNotificationsManager = AccessibilityNotificationsManager.shared
    private let accessibilityPermissionManager = AccessibilityPermissionManager.shared
    private let microphoneInputManager = MicrophoneInputManager.shared
    
    private var accessibilityNotGranted: Bool {
        return self.accessibilityPermissionManager.accessibilityPermissionStatus != .granted
    }
    
    private var microphoneNotGranted: Bool {
        return Defaults[.transcriptionEnabled] && !self.microphoneInputManager.hasPermission
    }

    /// Commented out for now until non-AX becomes the default state.
//    private var screenRecordingNotGranted: Bool {
//        return Defaults[.quickEditConfig].isEnabled && !ScreenRecordingPermissionManager.shared.isScreenRecordingEnabled
//    }

    private var anyPermissionMissing: Bool {
        return
            self.accessibilityNotGranted ||
        /// Commented out for now until non-AX becomes the default state.
//            self.screenRecordingNotGranted ||
            self.microphoneNotGranted
    }
    
    // MARK: - Private Functions: Status Dot
    
    private func cropIconForStatusDot(
        icon: NSImage,
        cropSize: CGFloat
    ) -> NSImage {
        let croppedIconSize = NSSize(
            width: 16,
            height: 16
        )
        
        let croppedIcon = NSImage(
            size: croppedIconSize,
            flipped: false
        ) { rect in
            var drawRect = rect
            let iconSize = icon.size
            
            if iconSize.width > 0 && iconSize.height > 0 {
                let iconAspectRatio = iconSize.width / iconSize.height
                let canvasAspectRatio = rect.width / rect.height
                
                if iconAspectRatio > canvasAspectRatio {
                    let width = rect.width
                    let height = width / iconAspectRatio
                    
                    drawRect = CGRect(
                        x: rect.minX,
                        y: rect.midY - height / 2,
                        width: width,
                        height: height
                    )
                } else {
                    let height = rect.height
                    let width = height * iconAspectRatio
                    
                    drawRect = CGRect(
                        x: rect.midX - width / 2,
                        y: rect.minY,
                        width: width,
                        height: height
                    )
                }
            }
            
            NSGraphicsContext.current?.imageInterpolation = .high

            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // Draw the mark rotated 15° counter-clockwise (about its center).
            // y-up context, so a positive angle is CCW. The notch/dot below stay
            // at the fixed lower-right corner.
            context.saveGState()
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: 25 * .pi / 180)
            context.translateBy(x: -rect.midX, y: -rect.midY)
            icon.draw(in: drawRect)
            context.restoreGState()

            context.saveGState()
            context.setBlendMode(.clear)

            let inset: CGFloat = 2

            // Lower-right corner (+1px right to match the status dot offset).
            let centerPosition = CGPoint(
                x: rect.maxX - inset + 1,
                y: rect.minY + inset
            )
            
            let cropRect = CGRect(
                x: centerPosition.x - cropSize / 2,
                y: centerPosition.y - cropSize / 2,
                width: cropSize,
                height: cropSize
            )
            
            context.fillEllipse(in: cropRect)
            context.restoreGState()
            return true
        }
        
        croppedIcon.isTemplate = icon.isTemplate
        return croppedIcon
    }
    
    private func determineStatusDotColor() -> NSColor {
        return AppState.shared.statusDotColor.nsColor
    }
    
    private func ensureStatusDotExists() {
        guard let iconButton = self.menuBarOnit.button else { return }
        
        if iconButton.layer == nil {
            iconButton.wantsLayer = true
        }
        iconButton.layer?.isOpaque = false
        
        if self.statusDot == nil {
            let dot = CAShapeLayer()
            dot.fillColor = self.determineStatusDotColor().cgColor
            dot.zPosition = 1
            iconButton.layer?.addSublayer(dot)
            self.statusDot = dot
        }
    }
    
    private func drawStatusDot() {
        guard let iconButton = self.menuBarOnit.button,
              let statusDot = self.statusDot
        else {
            return
        }
        
        /// Static values
        let iconSize: CGFloat = 16
        let statusDotSize: CGFloat = 5
        let spacingBeforeTitleText: CGFloat = iconButton.title.isEmpty ? 0 : 2
        let font = iconButton.font ?? NSFont.systemFont(ofSize: 11, weight: .semibold)
        
        let titleTextWidth: CGFloat = iconButton.title.isEmpty ? 0 : (iconButton.title as NSString).size(
            withAttributes: [.font: font]
        ).width
        
        let totalMenuIconWidth: CGFloat = iconSize + (iconButton.title.isEmpty ? 0 : spacingBeforeTitleText + titleTextWidth)
        
        /// Positioning
        let statusDotXPositionBase: CGFloat = (iconButton.bounds.midX - totalMenuIconWidth / 2)  + iconSize
        let statusDotYPositionBase: CGFloat = (iconButton.bounds.height - iconSize) * 2
        let inset: CGFloat = 2
        let statusDotRadius = statusDotSize / 2

        let statusDotXPosition = statusDotXPositionBase - inset + 1
        let statusDotYPosition = statusDotYPositionBase + inset + statusDotRadius
        
        let statusDotPosition = CGPoint(
            x: statusDotXPosition,
            y: statusDotYPosition
        )
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        statusDot.bounds = CGRect(
            x: 0,
            y: 0,
            width: statusDotSize,
            height: statusDotSize
        )
        
        statusDot.path = CGPath(
            ellipseIn: CGRect(
                origin: .zero,
                size: statusDot.bounds.size
            ),
            transform: nil
        )
        
        statusDot.position = statusDotPosition
        
        CATransaction.commit()
    }
    
    func updateStatusDot() {
        self.ensureStatusDotExists()
        self.statusDot?.fillColor = self.determineStatusDotColor().cgColor
        self.drawStatusDot()
    }
    
    // MARK: - Private Functions: Window Delegate
    
    private func onWindowChange(info: WindowChangeInfo) {
        self.foregroundWindow = info.trackedWindow
    }
    
    private func addWindowChangeDelegate() {
        let windowChangeDelegate = WindowChangeDelegate(
            onWindowChange: self.onWindowChange
        )
        accessibilityNotificationsManager.addDelegate(windowChangeDelegate)
        self.windowChangeDelegate = windowChangeDelegate
    }
    
    // MARK: - Private Functions: Menu Bar Items
    
    private func addOnitEntryPointToMenuBar() {
        #if ONIT_BETA
        let iconName = "noodle-beta"
        #else
        let iconName = "noodle"
        #endif

        if  let button = self.menuBarOnit.button,
            let icon = NSImage(named: iconName)?.copy() as? NSImage
        {
            let iconWithStatusDotCrop = self.cropIconForStatusDot(icon: icon, cropSize: 9)
            button.image = iconWithStatusDotCrop
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            button.wantsLayer = true
            self.updateStatusDot()
        }
    }
    
    private func addMenuItem(
        _ item: NSMenuItem,
        target: AnyObject? = nil
    ) {
        item.target = target ?? item /// Falling back to `item` here because most menu bar items are designed to be self-contained, so th   ey should target themselves.
        
        self.menu.addItem(item)
    }
    
    private func addMenuDivider() {
        self.menu.addItem(.separator())
    }
    
    private func addAppStatusItem() {
        let appStatusItem = MenuBarAppStatus()
        self.appStatusItemRef = appStatusItem
        self.addMenuItem(appStatusItem)
        appStatusItem.runPostInitilizationSetup()
    }
    
    private func addMicrophoneItem() {
        let microphoneItem = MenuBarMicrophone()
        self.addMenuItem(microphoneItem)
        microphoneItem.runPostInitilizationSetup()
    }
    
    private func showOrHideCheckForPermissionsItem() {
        if let shouldShowCheckForPermissionsItem = self.shouldShowCheckForPermissionsItem,
           shouldShowCheckForPermissionsItem == true
        {
            let checkForPermissionsItem = MenuBarCheckForPermissions()
            self.addMenuItem(checkForPermissionsItem)
            checkForPermissionsItem.runPostInitilizationSetup()
            self.addMenuDivider()
        }
    }
    
    /// A running snooze shows its countdown (click to cancel), otherwise the menu offers to start
    ///     one. Never both. Hidden entirely while `alwaysHideHint` is on, where a snooze is a no-op.
    ///     `populateMenu()` runs on `menuWillOpen`, so reading the Defaults here is always current.
    /// Both rows are always added; each hides itself so exactly one is on screen. Picking one here
    ///     would freeze the choice until the next `menuWillOpen`, leaving a gap where neither shows
    ///     when a snooze lapses with the menu open.
    private func addHintSnoozeItem() {
        let snoozeItem = MenuBarHintSnooze()
        self.addMenuItem(snoozeItem)
        snoozeItem.runPostInitilizationSetup()
        self.hintSnoozeItemRef = snoozeItem

        let snoozeStatusItem = MenuBarHintSnoozeStatus()
        self.addMenuItem(snoozeStatusItem)
        snoozeStatusItem.runPostInitilizationSetup()
        self.hintSnoozeStatusItemRef = snoozeStatusItem
    }
    
    private func addDownloadProgressItems() {
        self.downloadProgressItemRefs.removeAll()

        // VAD (silero) is intentionally not surfaced: the model is ~1 MB and the download finishes
        // well before the user notices a progress bar. Failures still appear via
        // `failedProviders["vad"]` → status icon → retry button.

        // Surface a single row, reactively labeled for whichever model is downloading (dictation or
        // the Smart Cleanup stack). The shared `ModelDownloadIndicator` is the source of truth, so
        // this row stays in lock-step with the Hint pill + toast.
        guard ModelDownloadIndicator.current != nil else { return }

        let item = MenuBarDownloadProgress()
        self.addMenuItem(item)
        item.runPostInitilizationSetup()
        self.downloadProgressItemRefs.append(item)

        self.addMenuDivider()
        self.startDownloadProgressTimer()
    }

    private func addLastTranscriptButtonsIfNeeded() {
        guard LastTranscriptionState.shared.isActive else { return }

        let lastTranscriptionItem = MenuBarLastTranscription()
        self.addMenuItem(lastTranscriptionItem)
        lastTranscriptionItem.runPostInitilizationSetup()
    }

    // MARK: - Download Progress Timer

    /// Persistent timer that polls AtomicProgress values and updates the menu items.
    /// Uses target/selector + .common mode to work during both .default and .eventTracking.
    private func startDownloadProgressTimer() {
        guard self.downloadProgressTimer == nil else { return }

        let timer = Timer(
            timeInterval: 0.15,
            target: self,
            selector: #selector(pollDownloadProgress),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.downloadProgressTimer = timer
    }

    private func stopDownloadProgressTimer() {
        self.downloadProgressTimer?.invalidate()
        self.downloadProgressTimer = nil
    }

    @objc private func pollDownloadProgress() {
        // Refresh each row's reactive label + percentage from the shared indicator. Stop polling
        // once nothing is downloading (the row is rebuilt on the next status-driven `populateMenu`).
        for item in self.downloadProgressItemRefs {
            item.refresh()
        }

        if ModelDownloadIndicator.current == nil {
            self.stopDownloadProgressTimer()
        }
    }

    private func populateMenu() {
        self.menu.removeAllItems()

        self.addAppStatusItem()
        self.addMenuDivider()

        self.addDownloadProgressItems()

//        let versionItem = MenuBarVersion()
//        self.addMenuItem(versionItem)
//        versionItem.runPostInitilizationSetup()

        let appItem = MenuBarApp()
        self.addMenuItem(appItem)
        appItem.runPostInitilizationSetup()

        #if DEBUG && canImport(TranscriptionCleanup) // the scoring debug window shows Smart Cleanup decisions
        let debugItem = MenuBarDebug()
        self.addMenuItem(debugItem)
        debugItem.runPostInitilizationSetup()
        #endif

        let correctionModeItem = MenuBarCorrectionMode()
        self.addMenuItem(correctionModeItem)
        correctionModeItem.runPostInitilizationSetup()

        self.addMenuDivider()
        
        if Defaults[.transcriptionEnabled] {
            self.addLastTranscriptButtonsIfNeeded()
            self.addMicrophoneItem()
            self.addMenuDivider()
        }

//        self.addShortcutsItem()
//        self.addMenuDivider()

        self.showOrHideCheckForPermissionsItem()
        self.addHintSnoozeItem()
        self.addMenuDivider()
        
        let discordItem = MenuBarDiscord()
        self.addMenuItem(discordItem)
        discordItem.runPostInitilizationSetup()
        
        let checkForUpdatesItem = MenuBarCheckForUpdates()
        self.addMenuItem(checkForUpdatesItem)
        checkForUpdatesItem.runPostInitilizationSetup()
        
        self.addMenuDivider()

        let quitItem = MenuBarQuit()
        self.addMenuItem(quitItem)
        quitItem.runPostInitilizationSetup()

        self.menuBarOnit.menu = self.menu
    }
}
