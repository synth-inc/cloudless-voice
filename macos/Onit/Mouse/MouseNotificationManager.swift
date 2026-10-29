// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MouseNotificationManager.swift
//  Onit
//
//  Created by Timothy Lenardo on 7/25/25.
//

import Foundation
import AppKit

// MARK: - Mouse Notification Manager
@MainActor
final class MouseNotificationManager: ObservableObject {

    // MARK: - Singleton instance

    static let shared = MouseNotificationManager()

    // MARK: - Properties

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var isMonitoring: Bool = false
    private var isDragging: Bool = false

    private var dragStartLocation: NSPoint = .zero
    
    // MARK: - Scroll Properties
    
    // Event Data Structure for scroll events
    private struct ScrollEventData {
        let type: CGEventType
        let deltaX: Double
        let deltaY: Double
        let scrollCount: Int64
        let isContinuous: Bool
        let momentumPhase: Int64
        let scrollPhase: Int64
        let magnification: Double?
        let rotation: Double?
        let timestamp: CFAbsoluteTime
        
        // Computed properties for phase enums
        var scrollPhaseEnum: ScrollPhase {
            switch scrollPhase {
            case 1: return .began
            case 2: return .changed
            case 3: return .ended
            case 4: return .cancelled
            case 5: return .mayBegin
            default: return .none
            }
        }
        
        var momentumPhaseEnum: MomentumPhase {
            switch momentumPhase {
            case 1: return .began
            case 2: return .changed
            case 3: return .ended
            default: return .none
            }
        }
    }
    
    // MARK: Momentum tracking
    private var lastMomentumPhase: MomentumPhase = .none
    private var lastScrollPhase: ScrollPhase = .none
    
    // MARK: Debouncing and filtering
    private var lastNotificationTime: CFAbsoluteTime = 0
    private var accumulatedDeltaX: Double = 0
    private var accumulatedDeltaY: Double = 0
    private var debounceTask: Task<Void, Never>?

    // MARK: - Delegates

    private var delegates = NSHashTable<AnyObject>.weakObjects()

    func addDelegate(_ delegate: MouseNotificationDelegate) {
        delegates.add(delegate)
    }

    func removeDelegate(_ delegate: MouseNotificationDelegate) {
        delegates.remove(delegate)
    }

    private func notifyDelegates(_ notification: (MouseNotificationDelegate) -> Void) {
        for case let delegate as MouseNotificationDelegate in delegates.allObjects {
            notification(delegate)
        }
    }

    // MARK: - Private initializer

    private init() {}
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    func startMonitoring() {
        guard !isMonitoring else { return }

        // Monitor mouse events
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        
        // Setup scroll monitoring with CGEventTap
        setupScrollMonitoring()

        isMonitoring = true
    }

    func stopMonitoring() {
        guard isMonitoring else {
            return
        }

        // Stop mouse monitoring
        if let localEventMonitor = localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor = globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        
        // Stop scroll monitoring
        stopScrollMonitoring()

        isMonitoring = false
    }

    // MARK: - Private Methods

    private func handleMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            handleMouseMoved(event: event)
        case .leftMouseDown, .rightMouseDown:
            handleMouseDown(event: event)
        case .leftMouseUp, .rightMouseUp:
            handleMouseUp(event: event)
        case .leftMouseDragged, .rightMouseDragged:
            handleMouseDragged(event: event)
        default:
            break
        }
    }
    
    private func handleMouseMoved(event: NSEvent) {
        notifyDelegates { delegate in
            delegate.mouseNotificationManager(self, didMove: event)
        }
    }

    private func handleMouseDown(event: NSEvent) {
        // Start tracking potential drag
        isDragging = false
        dragStartLocation = event.locationInWindow
        
        // Handle click events based on click count
        switch event.clickCount {
        case 1:
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didReceiveSingleClick: event)
            }
        case 2:
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didReceiveDoubleClick: event)
            }
        case 3:
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didReceiveTripleClick: event)
            }
        default:
            // For clicks beyond triple, treat as single click
            break
        }
    }

    private func handleMouseUp(event: NSEvent) {
        if isDragging {
            // End drag operation
            isDragging = false
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didEndDrag: event)
            }
        }
    }

    private func handleMouseDragged(event: NSEvent) {
        let dragDistance = hypot(event.locationInWindow.x - dragStartLocation.x, 
                               event.locationInWindow.y - dragStartLocation.y)
        
        // Start drag if we've moved more than 3 points
        if !isDragging && dragDistance > 3.0 {
            isDragging = true
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didStartDrag: event)
            }
        }
        
        // Update drag if already dragging
        if isDragging {
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didUpdateDrag: event)
            }
        }
    }

    // MARK: - Utility Methods

    func getCurrentDragState() -> Bool {
        return isDragging
    }
    
    // MARK: - Scroll Monitoring Methods
    
    private func setupScrollMonitoring() {
        stopScrollMonitoring()

        let scrollWheelMask = (1 << CGEventType.scrollWheel.rawValue)
        let mask = CGEventMask(scrollWheelMask)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                guard let manager = Unmanaged<MouseNotificationManager>.fromOpaque(refcon!).takeUnretainedValue() as MouseNotificationManager? else {
                    return Unmanaged.passUnretained(event)
                }
                
                // Re-enable event tap if disabled by system
                if let result = type.reenableIfDisabled(event: event, eventTap: manager.eventTap) {
                    return result
                }
                
                let eventData = manager.extractEventDataFast(type: type, event: event)

                Task { @MainActor in
                    manager.processScrollEventData(eventData)
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource = runLoopSource else {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            return
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    
    private func stopScrollMonitoring() {
        debounceTask?.cancel()
        
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        lastNotificationTime = 0
        
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }
    
    private func extractEventDataFast(type: CGEventType, event: CGEvent) -> ScrollEventData {
        let timestamp = CFAbsoluteTimeGetCurrent()
        
        // For now, we only handle scrollWheel events reliably
        // Other gesture events would need NSEvent monitoring instead of CGEventTap
        if type == .scrollWheel {
            let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let scrollCount = event.getIntegerValueField(.scrollWheelEventScrollCount)
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            
            return ScrollEventData(
                type: type,
                deltaX: deltaX,
                deltaY: deltaY,
                scrollCount: scrollCount,
                isContinuous: isContinuous,
                momentumPhase: momentumPhase,
                scrollPhase: scrollPhase,
                magnification: nil,
                rotation: nil,
                timestamp: timestamp
            )
        }
        
        // Fallback for unsupported event types
        return ScrollEventData(
            type: type,
            deltaX: 0,
            deltaY: 0,
            scrollCount: 0,
            isContinuous: false,
            momentumPhase: 0,
            scrollPhase: 0,
            magnification: nil,
            rotation: nil,
            timestamp: timestamp
        )
    }
    
    @MainActor
    private func processScrollEventData(_ eventData: ScrollEventData) {
        handleMomentumAndScrollPhases(eventData)
        
        let hasSignificantMovement = abs(eventData.deltaX) > 0.0 || abs(eventData.deltaY) > 0.0
        
        if hasSignificantMovement {
            processScrollWithDebouncing(eventData)
        }
    }
    
    @MainActor
    private func processScrollWithDebouncing(_ eventData: ScrollEventData) {
        let currentTime = eventData.timestamp
        let debounceInterval: CFAbsoluteTime = 0.008 // 8ms debounce window
        
        accumulatedDeltaX += eventData.deltaX
        accumulatedDeltaY += eventData.deltaY
        
        let timeSinceLastNotification = currentTime - lastNotificationTime
        
        if timeSinceLastNotification >= debounceInterval {
            sendScrollNotifications(
                deltaX: accumulatedDeltaX,
                deltaY: accumulatedDeltaY
            )
            
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            lastNotificationTime = currentTime
            
            debounceTask?.cancel()
        } else {
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(8))
                
                guard !Task.isCancelled else { return }
                
                if accumulatedDeltaX != 0 || accumulatedDeltaY != 0 {
                    sendScrollNotifications(
                        deltaX: accumulatedDeltaX,
                        deltaY: accumulatedDeltaY
                    )
                    
                    accumulatedDeltaX = 0
                    accumulatedDeltaY = 0
                    lastNotificationTime = CFAbsoluteTimeGetCurrent()
                }
            }
        }
    }
    
    @MainActor
    private func sendScrollNotifications(deltaX: Double, deltaY: Double) {
        notifyDelegates { delegate in
            delegate.mouseNotificationManager(self, didScroll: deltaX, deltaY: deltaY, event: CGEvent(source: nil)!)
        }
        
        if abs(deltaY) > abs(deltaX) {
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didScrollVertically: deltaY, deltaX: deltaX, event: CGEvent(source: nil)!)
            }
        } else if abs(deltaX) > 0 {
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didScrollHorizontally: deltaX, deltaY: deltaY, event: CGEvent(source: nil)!)
            }
        }
    }
    
    // MARK: - Momentum and Phase Management
    @MainActor
    private func handleMomentumAndScrollPhases(_ eventData: ScrollEventData) {
        let currentScrollPhase = eventData.scrollPhaseEnum
        let currentMomentumPhase = eventData.momentumPhaseEnum
        
        if currentScrollPhase != lastScrollPhase {
            lastScrollPhase = currentScrollPhase
            
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didChangeScrollPhase: currentScrollPhase, event: CGEvent(source: nil)!)
            }
        }
        
        if currentMomentumPhase != lastMomentumPhase {
            let previousMomentumPhase = lastMomentumPhase
            lastMomentumPhase = currentMomentumPhase
            
            notifyDelegates { delegate in
                delegate.mouseNotificationManager(self, didChangeMomentumPhase: currentMomentumPhase, event: CGEvent(source: nil)!)
            }
            
            if previousMomentumPhase == .none && currentMomentumPhase == .began {
                notifyDelegates { delegate in
                    delegate.mouseNotificationManager(self, didBeginInertiaScroll: CGEvent(source: nil)!)
                }
            }
            
            if previousMomentumPhase != .none && currentMomentumPhase == .none {
                notifyDelegates { delegate in
                    delegate.mouseNotificationManager(self, didEndInertiaScroll: CGEvent(source: nil)!)
                }
            }
        }
    }
}
