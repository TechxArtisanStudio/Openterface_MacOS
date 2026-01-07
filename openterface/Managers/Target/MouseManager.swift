/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import Foundation
import AppKit
import IOKit
import IOKit.hid

// MARK: - Mouse Event Queue Structure
struct MouseEventQueueItem {
    let deltaX: Int
    let deltaY: Int
    let mouseEvent: UInt8
    let wheelMovement: Int
    let isDragged: Bool
    let timestamp: TimeInterval
    let isAbsolute: Bool
    let absoluteX: Int?
    let absoluteY: Int?
}

class MouseManager: MouseManagerProtocol {
    static let shared = MouseManager()
    
    // Protocol-based dependencies
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    let mouserMapper = MouseMapper()
    
    var isRelativeMouseControlEnabled: Bool = false
    var accumulatedDeltaX = 0
    var accumulatedDeltaY = 0
    // Track last sent deltas for display purposes
    var lastSentDeltaX = 0
    var lastSentDeltaY = 0
    /// Counter for tracking accumulated mouse movement events in Events mode.
    /// Used in conjunction with `skipMoveBack` to prevent erratic cursor movement
    /// when transitioning from a dragging state (button held down) to non-dragging state.
    /// NOTE: This counter is currently set to 0 but never incremented in the code,
    /// making it potentially vestigial. It may have been intended for rate-limiting
    /// or filtering consecutive mouse events.
    var recordCount = 0
    var dragging = false
    var skipMoveBack = false
    
    private var isMouseLoopRunning = false
    
    // Mouse event queue system
    private let mouseEventQueue = DispatchQueue(label: "mouse", qos: .userInteractive)
    private var pendingMouseEvents: [MouseEventQueueItem] = []
    private let maxQueueSize = 10
    private var isProcessingQueue = false
    
    // Queue monitoring (size tracking - metrics calculated and displayed in InputMonitorManager)
    private var peakQueueSize: Int = 0
    
    // Event drop tracking (counter only - rate calculated in InputMonitorManager)
    private var droppedEventCount: Int = 0
    
    // Output event tracking (counter only - rate calculated in InputMonitorManager)
    private var outputEventCount: Int = 0
    
    // Mouse event throttling properties - thread-safe with lock to prevent race conditions
    private var lastEventProcessTime: TimeInterval = 0.0
    private let throttleLock = NSLock() // Synchronizes access to throttle timer across threads
    private var throttledEventDropCount: Int = 0
    
    // Overflow accumulation for smooth movement preservation
    private var overflowAccumulatedDeltaX = 0
    private var overflowAccumulatedDeltaY = 0
    private var adaptiveAccumulationEnabled = false
    
    // IOKit HID Manager properties
    private var hidManager: IOHIDManager?
    private var hidDevices: [IOHIDDevice] = []
    private var isHIDMonitoringActive = false
    private var lastHIDPosition = CGPoint.zero
    private var isHIDMouseCaptured = false
    private var lastCenterTime: TimeInterval = 0
    private var centeringCooldown: TimeInterval = 0.1 // Minimum time between centering operations
    private var hidEventQueue = DispatchQueue(label: "com.openterface.hidEventQueue", qos: .userInteractive)
    
    // ESC key escape mechanism for HID mode
    private var escapeKeyPressCount = 0
    private var lastEscapeKeyTime: TimeInterval = 0
    private var longPressTimer: Timer?
    private let escapeKeyTimeout: TimeInterval = 2.0 // Reset count after 2 seconds
    private let longPressThreshold: TimeInterval = 1.0 // Long press threshold in seconds

    // Private initializer for dependency injection
    private init() {
        // Dependencies are now lazy and will be resolved when first accessed
    }
    
    deinit {
        stopHIDMouseMonitoring()
    }
    
    // MARK: - Mouse Event Queue Management
    
    /// Public method to enqueue absolute mouse events (called from UI layers)
    func enqueueAbsoluteMouseEvent(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        // Skip mouse events if in keyboard only mode
        if UserSettings.shared.controlMode == .keyboardOnly {
            return
        }
        
        let queueItem = MouseEventQueueItem(
            deltaX: 0,
            deltaY: 0,
            mouseEvent: mouseEvent,
            wheelMovement: wheelMovement,
            isDragged: false,
            timestamp: CACurrentMediaTime(),
            isAbsolute: true,
            absoluteX: x,
            absoluteY: y
        )
        enqueueMouseEvent(queueItem)
    }
    
    /// Public method to enqueue relative mouse events
    func enqueueRelativeMouseEvent(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00, isDragged: Bool = false) {
        // Skip mouse events if in keyboard only mode
        if UserSettings.shared.controlMode == .keyboardOnly {
            return
        }
        
        let queueItem = MouseEventQueueItem(
            deltaX: dx,
            deltaY: dy,
            mouseEvent: mouseEvent,
            wheelMovement: wheelMovement,
            isDragged: isDragged,
            timestamp: CACurrentMediaTime(),
            isAbsolute: false,
            absoluteX: nil,
            absoluteY: nil
        )
        enqueueMouseEvent(queueItem)
    }
    
    /// Public method to enqueue mouse events (called from UI or other managers)
    func enqueueMouseEventPublic(_ event: MouseEventQueueItem) {
        enqueueMouseEvent(event)
    }
    
    /// Enqueue a mouse event for processing
    /// Implements throttling based on Hz limit and strategic dropping when queue exceeds capacity
    private func enqueueMouseEvent(_ event: MouseEventQueueItem) {
        mouseEventQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.pendingMouseEvents.append(event)
            let currentSize = self.pendingMouseEvents.count
            
            // Track peak queue size (keep accumulating, don't reset here)
            if currentSize > self.peakQueueSize {
                self.peakQueueSize = currentSize
            }
            
            // Check if queue size exceeds maximum
            if currentSize > self.maxQueueSize {
                self.strategicDropEvents()
            }
            
            // Start processing if not already running
            if !self.isProcessingQueue {
                self.processMouseEventQueue()
            }
        }
    }
    
    /// Determine if an input event should be throttled based on the Hz limit
    /// Returns true if event should be dropped, false if it should be enqueued
    /// Uses NSLock to ensure thread-safe access to the throttle timer
    private func shouldThrottleInputEvent() -> Bool {
        let throttleHz = UserSettings.shared.mouseEventThrottleHz
        let minTimeBetweenInputs = 1.0 / Double(throttleHz)
        let currentTime = CACurrentMediaTime()
        
        throttleLock.lock()
        defer { throttleLock.unlock() }
        
        if lastEventProcessTime == 0.0 {
            // First event, always allow it
            lastEventProcessTime = currentTime
            return false
        }
        
        let timeSinceLastInput = currentTime - lastEventProcessTime
        
        if timeSinceLastInput >= minTimeBetweenInputs {
            lastEventProcessTime = currentTime
            return false
        }
        
        // Event should be throttled (logging disabled to reduce overhead)
        return true
    }
    
    /// Strategically drop events when queue is full while preserving movement continuity
    private func strategicDropEvents() {
        guard pendingMouseEvents.count > maxQueueSize else { return }
        
        let originalCount = pendingMouseEvents.count
        
        // Separate absolute and relative events
        var absoluteEvents: [MouseEventQueueItem] = []
        var relativeEvents: [MouseEventQueueItem] = []
        
        for event in pendingMouseEvents {
            if event.isAbsolute {
                absoluteEvents.append(event)
            } else {
                relativeEvents.append(event)
            }
        }
        if logger.MouseEventPrint {
            logger.log(content: "Queue overflow detected. Absolute: \(absoluteEvents.count), Relative: \(relativeEvents.count). Applying smooth dropping...")
        }
        
        // Strategy 1: Smart dropping for absolute events - prioritize dropping small deltas
        if absoluteEvents.count > maxQueueSize / 2 {
            let keepCount = maxQueueSize / 3
            let dropCount = absoluteEvents.count - keepCount
            
            // Separate small delta and large delta absolute events
            var smallDeltaEvents: [(index: Int, event: MouseEventQueueItem)] = []
            var largeDeltaEvents: [(index: Int, event: MouseEventQueueItem)] = []
            
            for (index, event) in absoluteEvents.enumerated() {
                guard let absX = event.absoluteX, let absY = event.absoluteY else {
                    largeDeltaEvents.append((index, event))
                    continue
                }
                
                // Calculate delta from previous event if available
                if index > 0, let prevX = absoluteEvents[index - 1].absoluteX, 
                   let prevY = absoluteEvents[index - 1].absoluteY {
                    let deltaX = abs(absX - prevX)
                    let deltaY = abs(absY - prevY)
                    
                    // Small delta: both x and y changes are less than 10 pixels
                    if deltaX < 10 && deltaY < 10 {
                        smallDeltaEvents.append((index, event))
                    } else {
                        largeDeltaEvents.append((index, event))
                    }
                } else {
                    // First event or can't calculate delta - treat as large
                    largeDeltaEvents.append((index, event))
                }
            }
            
            var eventsToKeep: [MouseEventQueueItem] = []
            var actualDropCount = 0
            
            // Drop small delta events first
            if smallDeltaEvents.count >= dropCount {
                // We have enough small delta events to drop
                let smallToKeep = smallDeltaEvents.count - dropCount
                eventsToKeep.append(contentsOf: smallDeltaEvents.suffix(smallToKeep).map { $0.event })
                eventsToKeep.append(contentsOf: largeDeltaEvents.map { $0.event })
                actualDropCount = dropCount
                if logger.MouseEventPrint {
                    logger.log(content: "Dropped \(dropCount) small-delta absolute events (Δ<10px), kept \(keepCount) events")
                }
            } else {
                // Drop all small delta events, then drop oldest large delta events
                let remainingDrops = dropCount - smallDeltaEvents.count
                let largeDeltasToKeep = max(0, largeDeltaEvents.count - remainingDrops)
                eventsToKeep.append(contentsOf: largeDeltaEvents.suffix(largeDeltasToKeep).map { $0.event })
                actualDropCount = smallDeltaEvents.count + (largeDeltaEvents.count - largeDeltasToKeep)
                if logger.MouseEventPrint {
                    logger.log(content: "Dropped \(smallDeltaEvents.count) small-delta + \(remainingDrops) oldest absolute events, kept \(keepCount) events")
                }
            }
            
            // Sort by timestamp to maintain order
            absoluteEvents = eventsToKeep.sorted { $0.timestamp < $1.timestamp }
            droppedEventCount += actualDropCount
        }
        
        // Strategy 2: Smart merging for relative movement events
        if relativeEvents.count > 1 {
            // Separate movement and action events
            var pureMovements: [MouseEventQueueItem] = []
            var actionEvents: [MouseEventQueueItem] = []
            
            for event in relativeEvents {
                if event.mouseEvent == 0x00 && event.wheelMovement == 0 {
                    pureMovements.append(event)
                } else {
                    actionEvents.append(event)
                }
            }
            
            var mergedRelatives: [MouseEventQueueItem] = []
            
            // If we have many pure movement events, use adaptive merging
            if pureMovements.count > maxQueueSize / 2 {
                // Calculate total movement delta
                var totalDX = 0
                var totalDY = 0
                for event in pureMovements {
                    totalDX += event.deltaX
                    totalDY += event.deltaY
                }
                
                // Calculate number of merged events we can afford
                let availableSlots = maxQueueSize - actionEvents.count - absoluteEvents.count
                let targetMovementEvents = max(2, availableSlots / 2) // Keep at least 2 movement events
                
                if pureMovements.count > targetMovementEvents {
                    // Distribute the total movement across fewer events for smooth interpolation
                    let deltaPerEvent = (
                        dx: totalDX / targetMovementEvents,
                        dy: totalDY / targetMovementEvents
                    )
                    let remainder = (
                        dx: totalDX % targetMovementEvents,
                        dy: totalDY % targetMovementEvents
                    )
                    
                    // Create interpolated movement events
                    for i in 0..<targetMovementEvents {
                        let extraDX = i < abs(remainder.dx) ? (remainder.dx > 0 ? 1 : -1) : 0
                        let extraDY = i < abs(remainder.dy) ? (remainder.dy > 0 ? 1 : -1) : 0
                        
                        let interpolatedEvent = MouseEventQueueItem(
                            deltaX: deltaPerEvent.dx + extraDX,
                            deltaY: deltaPerEvent.dy + extraDY,
                            mouseEvent: 0x00,
                            wheelMovement: 0,
                            isDragged: false,
                            timestamp: pureMovements[min(i * pureMovements.count / targetMovementEvents, pureMovements.count - 1)].timestamp,
                            isAbsolute: false,
                            absoluteX: nil,
                            absoluteY: nil
                        )
                        mergedRelatives.append(interpolatedEvent)
                    }
                    
                    let droppedMovements = pureMovements.count - targetMovementEvents
                    droppedEventCount += droppedMovements
                    logger.log(content: "Smooth interpolation: \(pureMovements.count) movements -> \(targetMovementEvents) events (dropped \(droppedMovements), preserved total Δ: (\(totalDX), \(totalDY)))")
                } else {
                    mergedRelatives.append(contentsOf: pureMovements)
                }
            } else {
                mergedRelatives.append(contentsOf: pureMovements)
            }
            
            // Add back all action events (clicks, drags, wheel) - these are never dropped
            mergedRelatives.append(contentsOf: actionEvents)
            
            // Sort by timestamp to maintain event order
            mergedRelatives.sort { $0.timestamp < $1.timestamp }
            
            relativeEvents = mergedRelatives
        }
        
        // Final safety check: if still over limit, use overflow buffer
        let totalEvents = absoluteEvents.count + relativeEvents.count
        if totalEvents > maxQueueSize {
            let excessCount = totalEvents - maxQueueSize
            
            // Separate action and movement events one more time
            let movements = relativeEvents.filter { $0.mouseEvent == 0x00 && $0.wheelMovement == 0 }
            let actions = relativeEvents.filter { $0.mouseEvent != 0x00 || $0.wheelMovement != 0 }
            
            if movements.count > excessCount {
                // Drop oldest movements but preserve their deltas in overflow buffer
                let movementsToDrop = movements.prefix(excessCount)
                for event in movementsToDrop {
                    overflowAccumulatedDeltaX += event.deltaX
                    overflowAccumulatedDeltaY += event.deltaY
                }
                
                let remainingMovements = Array(movements.dropFirst(excessCount))
                droppedEventCount += excessCount
                adaptiveAccumulationEnabled = true
                
                logger.log(content: "Overflow buffer: accumulated \(excessCount) movements → buffer: (Δx:\(overflowAccumulatedDeltaX), Δy:\(overflowAccumulatedDeltaY))")
                
                relativeEvents = remainingMovements + actions
            } else {
                // Not enough movements, accumulate all of them
                for event in movements {
                    overflowAccumulatedDeltaX += event.deltaX
                    overflowAccumulatedDeltaY += event.deltaY
                }
                droppedEventCount += movements.count
                adaptiveAccumulationEnabled = true
                
                logger.log(content: "All movements buffered: \(movements.count) events → buffer: (Δx:\(overflowAccumulatedDeltaX), Δy:\(overflowAccumulatedDeltaY))")
                
                relativeEvents = actions
            }
        }
        
        // Reconstruct queue
        pendingMouseEvents = absoluteEvents + relativeEvents
        let finalCount = pendingMouseEvents.count
        if logger.MouseEventPrint {
            logger.log(content: "Smooth drop completed: \(originalCount) → \(finalCount) events (peak reduction: \(originalCount - finalCount))")
        }
    }
    
    /// Record a filtered/dropped mouse event (pre-queue drop)
    func recordFilteredMouseEvent() {
        droppedEventCount += 1
    }
    
    /// Get and reset drop event count (called by InputMonitorManager for rate calculation)
    func getAndResetDropEventCount() -> Int {
        let count = droppedEventCount
        droppedEventCount = 0
        return count
    }
    
    /// Record an output mouse event (sent to serial/target)
    func recordOutputMouseEvent() {
        outputEventCount += 1
    }
    
    /// Get and reset output event count (called by InputMonitorManager for rate calculation)
    func getAndResetOutputEventCount() -> Int {
        let count = outputEventCount
        outputEventCount = 0
        return count
    }
    
    /// Get current queue size
    func getCurrentQueueSize() -> Int {
        return pendingMouseEvents.count
    }
    
    /// Get and reset peak queue size (called by InputMonitorManager for peak tracking)
    func getAndResetPeakQueueSize() -> Int {
        let peak = peakQueueSize
        peakQueueSize = 0
        return peak
    }
    
    /// Get and reset throttled event count (called by InputMonitorManager for throttling statistics)
    func getAndResetThrottledEventCount() -> Int {
        let count = throttledEventDropCount
        throttledEventDropCount = 0
        return count
    }
    
    /// Process queued mouse events
    private func processMouseEventQueue() {
        isProcessingQueue = true
        
        mouseEventQueue.async { [weak self] in
            guard let self = self else { return }
            
            while !self.pendingMouseEvents.isEmpty {
                let event = self.pendingMouseEvents.removeFirst()
                
                // Process events directly on the queue thread (not on main thread)
                if event.isAbsolute {
                    // Absolute mode handling
                    self.handleAbsoluteMouseAction(
                        x: event.absoluteX ?? 0,
                        y: event.absoluteY ?? 0,
                        mouseEvent: event.mouseEvent,
                        wheelMovement: event.wheelMovement
                    )
                } else {
                    // Relative mode handling - distinguish between HID and Events mode
                    let mouseMode = UserSettings.shared.MouseControl
                    if mouseMode == .relativeHID {
                        // HID mode: pass deltas directly without accumulation
                        self.handleRelativeMouseActionHID(
                            dx: event.deltaX,
                            dy: event.deltaY,
                            mouseEvent: event.mouseEvent,
                            wheelMovement: event.wheelMovement
                        )
                    } else {
                        self.handleRelativeMouseActionEvents(
                            dx: event.deltaX,
                            dy: event.deltaY,
                            mouseEvent: event.mouseEvent,
                            wheelMovement: event.wheelMovement,
                            dragged: event.isDragged
                        )
                    }
                }
                
                // Enforce throttle rate by sleeping after processing each event
                // This ensures we don't process events faster than the configured Hz
                let throttleHz = UserSettings.shared.mouseEventThrottleHz
                let minTimeBetweenEvents = 1.0 / Double(throttleHz)
                Thread.sleep(forTimeInterval: minTimeBetweenEvents)
            }
            
            self.isProcessingQueue = false
        }
    }
    
    func startHIDMouseMonitoring() {
        guard !isHIDMonitoringActive else {
            logger.log(content: "HID mouse monitoring already active")
            return
        }
        
        // Create IOKit HID Manager with no special options
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let manager = hidManager else {
            logger.log(content: "❌ Failed to create IOHIDManager")
            return
        }
        
        logger.log(content: "✓ IOHIDManager created successfully")
        
        // Set device matching for mouse/trackpad
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]
        
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        logger.log(content: "✓ Device matching configured for GenericDesktop/Mouse")
        
        // Register device matching callback
        let deviceMatchingContext = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { inContext, inResult, inSender, inDevice in
            let this = Unmanaged<MouseManager>.fromOpaque(inContext!).takeUnretainedValue()
            this.hidDeviceMatched(device: inDevice)
        }, deviceMatchingContext)
        logger.log(content: "✓ Device matching callback registered")
        
        // Register input value callback
        let inputValueContext = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { inContext, inResult, inSender, inValue in
            let this = Unmanaged<MouseManager>.fromOpaque(inContext!).takeUnretainedValue()
            this.hidInputValueReceived(value: inValue)
        }, inputValueContext)
        logger.log(content: "✓ Input value callback registered")
        
        // Schedule on run loop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        logger.log(content: "✓ HID Manager scheduled on main run loop")
        
        // Open the manager with no special options
        let ioReturnCode = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        
        if ioReturnCode == kIOReturnSuccess {
            isHIDMonitoringActive = true
            isHIDMouseCaptured = false
            logger.log(content: "✓ IOKit HID monitoring started successfully")
            logger.log(content: "════════════════════════════════════════")
        } else {
            logger.log(content: "❌ Failed to open IOHIDManager: error code \(ioReturnCode)")
            hidManager = nil
            return
        }
        
        // Force capture after a short delay to ensure we get mouse events
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if !self.isHIDMouseCaptured && UserSettings.shared.MouseControl == .relativeHID {
                self.logger.log(content: "Force capturing mouse for HID mode")
                self.captureMouseForHID()
            }
        }
    }
    
    private func hidDeviceMatched(device: IOHIDDevice) {
        logger.log(content: "✓ HID mouse device matched and connected")
        hidEventQueue.async { [weak self] in
            self?.hidDevices.append(device)
            self?.logger.log(content: "  → Total HID devices tracked: \(self?.hidDevices.count ?? 0)")
        }
    }
    
    private func hidInputValueReceived(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let intValue = IOHIDValueGetIntegerValue(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        
        logger.log(content: "HID event received - UsagePage: \(usagePage), Usage: \(usage), Value: \(intValue), MouseCaptured: \(isHIDMouseCaptured), Mode: \(UserSettings.shared.MouseControl)")
        
        guard isHIDMouseCaptured else {
            logger.log(content: "HID event ignored - mouse not captured")
            return
        }
        guard UserSettings.shared.MouseControl == .relativeHID else {
            logger.log(content: "HID event ignored - not in relativeHID mode")
            return
        }
        
        hidEventQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Handle mouse movement (X and Y axes)
            if usagePage == kHIDPage_GenericDesktop {
                if usage == kHIDUsage_GD_X {
                    let deltaX = Int(intValue)
                    self.logger.log(content: "✓ HID X movement captured: raw=\(deltaX)")
                    
                    // Enqueue mouse event with scaled delta
                    let scaledDeltaX = deltaX * 2
                    let queueItem = MouseEventQueueItem(
                        deltaX: scaledDeltaX,
                        deltaY: 0,
                        mouseEvent: 0x00,
                        wheelMovement: 0,
                        isDragged: false,
                        timestamp: CACurrentMediaTime(),
                        isAbsolute: false,
                        absoluteX: nil,
                        absoluteY: nil
                    )
                    self.enqueueMouseEvent(queueItem)
                    self.logger.log(content: "  → Enqueued X event: scaled=\(scaledDeltaX)")
                    InputMonitorManager.shared.recordMouseMove()
                    
                } else if usage == kHIDUsage_GD_Y {
                    let deltaY = Int(intValue)
                    self.logger.log(content: "✓ HID Y movement captured: raw=\(deltaY)")
                    
                    // Enqueue mouse event with scaled delta
                    let scaledDeltaY = deltaY * 2
                    let queueItem = MouseEventQueueItem(
                        deltaX: 0,
                        deltaY: scaledDeltaY,
                        mouseEvent: 0x00,
                        wheelMovement: 0,
                        isDragged: false,
                        timestamp: CACurrentMediaTime(),
                        isAbsolute: false,
                        absoluteX: nil,
                        absoluteY: nil
                    )
                    self.enqueueMouseEvent(queueItem)
                    self.logger.log(content: "  → Enqueued Y event: scaled=\(scaledDeltaY)")
                    InputMonitorManager.shared.recordMouseMove()
                    
                    // Re-center cursor occasionally
                    let currentTime = CACurrentMediaTime()
                    if currentTime - self.lastCenterTime > self.centeringCooldown {
                        self.logger.log(content: "  → Re-centering cursor (cooldown elapsed)")
                        self.centerMouseCursor()
                        self.lastCenterTime = currentTime
                    }
                }
            }
            // Handle mouse buttons
            else if usagePage == kHIDPage_Button {
                let mouseEvent = UInt8(usage == 1 ? 0x01 : (usage == 2 ? 0x02 : 0x04))
                let isPressed = intValue != 0
                let buttonName = (usage == 1) ? "Left" : ((usage == 2) ? "Right" : "Middle")
                
                self.logger.log(content: "✓ HID button event: \(buttonName) (code: \(mouseEvent)), Pressed: \(isPressed)")
                
                if isPressed {
                    let queueItem = MouseEventQueueItem(
                        deltaX: 0,
                        deltaY: 0,
                        mouseEvent: mouseEvent,
                        wheelMovement: 0,
                        isDragged: true,
                        timestamp: CACurrentMediaTime(),
                        isAbsolute: false,
                        absoluteX: nil,
                        absoluteY: nil
                    )
                    self.enqueueMouseEvent(queueItem)
                    self.logger.log(content: "  → Enqueued button event")
                    InputMonitorManager.shared.recordHIDMouseClick()
                }
            } else {
                self.logger.log(content: "⚠ Unhandled HID event - UsagePage: \(usagePage), Usage: \(usage)")
            }
        }
    }
    
    private func captureMouseForHID() {
        guard !isHIDMouseCaptured else { return }
        
        logger.log(content: "Capturing mouse for HID mode")
        
        // // Now add global monitor for capturing all mouse events
        // let eventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        
        // hidEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask, handler: { [weak self] event in
        //     self?.handleHIDMouseEvent(event)
        // })
        
        isHIDMouseCaptured = true
        NSCursor.hide()
        AppStatus.isFouceWindow = true
        AppStatus.isCursorHidden = true
        
        centerMouseCursor()
        logger.log(content: "HID mouse captured with global monitor")
    }
    
    private func releaseMouseFromHID() {
        guard isHIDMouseCaptured else { return }
        
        logger.log(content: "Releasing mouse from HID capture")
        
        isHIDMouseCaptured = false
        NSCursor.unhide()
        AppStatus.isFouceWindow = false
        AppStatus.isCursorHidden = false
        
        logger.log(content: "HID mouse released")
    }
    
    func stopHIDMouseMonitoring() {
        guard isHIDMonitoringActive else { return }
        
        logger.log(content: "════════════════════════════════════════")
        logger.log(content: "Stopping IOKit HID mouse monitoring")
        logger.log(content: "════════════════════════════════════════")
        
        // Close and clean up IOKit HID Manager
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            logger.log(content: "✓ HID Manager unscheduled from run loop")
            
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            logger.log(content: "✓ HID Manager closed")
        }
        
        hidManager = nil
        let devicesCount = hidDevices.count
        hidDevices.removeAll()
        logger.log(content: "✓ Cleared \(devicesCount) tracked HID devices")
        
        isHIDMonitoringActive = false
        isHIDMouseCaptured = false
        
        // Clean up escape mechanism
        longPressTimer?.invalidate()
        longPressTimer = nil
        escapeKeyPressCount = 0
        
        // Show cursor when stopping HID monitoring
        NSCursor.unhide()
        AppStatus.isFouceWindow = false
        AppStatus.isCursorHidden = false
        
        logger.log(content: "✓ IOKit HID monitoring stopped")
        logger.log(content: "════════════════════════════════════════")
    }
    
    // MARK: - ESC Key Escape Mechanism for HID Mode
    
    func handleEscapeKeyForHIDMode(isKeyDown: Bool) {
        guard UserSettings.shared.MouseControl == .relativeHID else { return }
        guard isHIDMonitoringActive else { return }
        
        let currentTime = CACurrentMediaTime()
        
        if isKeyDown {
            // Handle ESC key down
            if escapeKeyPressCount == 0 {
                // First ESC press - start timer for long press detection
                lastEscapeKeyTime = currentTime
                escapeKeyPressCount = 1
                
                logger.log(content: "ESC key pressed - starting long press timer")
                
                // Start long press timer
                longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
                    self?.triggerHIDEscape(reason: "Long press ESC detected")
                }
            } else {
                // Subsequent ESC presses - check if within timeout
                if currentTime - lastEscapeKeyTime < escapeKeyTimeout {
                    escapeKeyPressCount += 1
                    logger.log(content: "ESC key pressed \(escapeKeyPressCount) times")
                    
                    if escapeKeyPressCount >= 2 {
                        // Multiple ESC presses detected
                        triggerHIDEscape(reason: "Multiple ESC presses detected")
                        return
                    }
                } else {
                    // Timeout exceeded - reset counter
                    escapeKeyPressCount = 1
                    lastEscapeKeyTime = currentTime
                }
            }
        } else {
            // Handle ESC key up - cancel long press timer if still running
            longPressTimer?.invalidate()
            longPressTimer = nil
            
            // Reset counter after timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + escapeKeyTimeout) { [weak self] in
                guard let self = self else { return }
                if CACurrentMediaTime() - self.lastEscapeKeyTime >= self.escapeKeyTimeout {
                    self.escapeKeyPressCount = 0
                    self.logger.log(content: "ESC key press counter reset due to timeout")
                }
            }
        }
    }
    
    private func triggerHIDEscape(reason: String) {
        logger.log(content: "Triggering HID escape: \(reason)")
        
        // Clean up escape state
        longPressTimer?.invalidate()
        longPressTimer = nil
        escapeKeyPressCount = 0
        
        // Release mouse capture using the new method
        releaseMouseFromHID()
        
        // Stop centering the cursor so it can move freely
        lastCenterTime = 0
        
        logger.log(content: "HID mouse capture released - user can now use host mouse normally")
        
        NSCursor.unhide()

        // Post notification to inform UI about mouse escape
        NotificationCenter.default.post(name: .hidMouseEscapedNotification, object: nil)
    }
    
    func recaptureHIDMouse() {
        guard UserSettings.shared.MouseControl == .relativeHID else { return }
        guard isHIDMonitoringActive else { return }
        guard !isHIDMouseCaptured else { return }
        
        logger.log(content: "Re-capturing HID mouse")
        
        captureMouseForHID()
        
        logger.log(content: "HID mouse re-captured successfully")
    }
    
    private func handleHIDMouseEvent(_ event: NSEvent) {
        // Only process HID events when in relativeHID mode
        guard UserSettings.shared.MouseControl == .relativeHID else { 
            logger.log(content: "HID Event ignored - not in relativeHID mode, current mode: \(UserSettings.shared.MouseControl)")
            return 
        }
               
        if !isHIDMouseCaptured {
            // Mouse is not captured - only check for app window clicks to re-capture
            let isFromOurApp = isEventFromOurApplication(event)
            
            if isFromOurApp && (event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown) {
                logger.log(content: "Click detected in app window - capturing mouse")
                captureMouseForHID()
                return
            }
            
            // For all other events when not captured, do nothing (allow normal mouse behavior)
            logger.log(content: "HID Event ignored - mouse not captured and event not from app window")
            return
        }

        // For movement events, use the event's deltaX and deltaY
        if event.type == .mouseMoved || event.type == .leftMouseDragged || event.type == .rightMouseDragged || event.type == .otherMouseDragged {
            let deltaX = event.deltaX
            let deltaY = event.deltaY
            
            logger.log(content: "Using event deltas: dx=\(deltaX), dy=\(deltaY)")
            
            // Only process if there's actual movement
            if abs(deltaX) > 0.01 || abs(deltaY) > 0.01 {
                
                // Convert mouse button events to the expected format
                let mouseEvent = convertHIDMouseEvent(event)
                
                // Scale up the deltas to make movement more noticeable
                let scaledDeltaX = Int(deltaX * 2.0) // Scale factor of 2
                let scaledDeltaY = Int(deltaY * 2.0) // Don't invert Y on macOS
                
                logger.log(content: "Processing HID Mouse: original dx=\(deltaX), dy=\(deltaY), scaled dx=\(scaledDeltaX), dy=\(scaledDeltaY), event=\(mouseEvent)")
                
                // Enqueue the mouse event instead of processing directly
                let queueItem = MouseEventQueueItem(
                    deltaX: scaledDeltaX,
                    deltaY: scaledDeltaY,
                    mouseEvent: mouseEvent,
                    wheelMovement: 0,
                    isDragged: isDragEvent(event),
                    timestamp: CACurrentMediaTime(),
                    isAbsolute: false,
                    absoluteX: nil,
                    absoluteY: nil
                )
                enqueueMouseEvent(queueItem)
                
                // Track the HID mouse move event in InputMonitorManager
                InputMonitorManager.shared.recordMouseMove()
                
                // Only re-center occasionally, not on every movement
                let currentTime = CACurrentMediaTime()
                if currentTime - lastCenterTime > centeringCooldown {
                    logger.log(content: "Re-centering cursor after cooldown")
                    centerMouseCursor()
                    lastCenterTime = currentTime
                }
            } else {
                logger.log(content: "HID Event ignored - deltas too small: dx=\(deltaX), dy=\(deltaY)")
                // Count filtered events as drops
                recordFilteredMouseEvent()
            }
        } else {
            // Handle click and scroll events
            let mouseEvent = convertHIDMouseEvent(event)
            let wheelMovement = event.type == .scrollWheel ? Int(event.scrollingDeltaY) : 0
            
            logger.log(content: "Processing HID Click/Scroll: event=\(mouseEvent), wheel=\(wheelMovement)")
            
            // Track HID mouse click events
            if mouseEvent != 0x00 && (event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown) {
                InputMonitorManager.shared.recordHIDMouseClick()
            }
            
            // Enqueue the click/scroll event
            let queueItem = MouseEventQueueItem(
                deltaX: 0,
                deltaY: 0,
                mouseEvent: mouseEvent,
                wheelMovement: Int(scrollWheelEventDeltaMapping(delta: wheelMovement)),
                isDragged: isDragEvent(event),
                timestamp: CACurrentMediaTime(),
                isAbsolute: false,
                absoluteX: nil,
                absoluteY: nil
            )
            enqueueMouseEvent(queueItem)
        }
    }
    
    private func isEventFromOurApplication(_ event: NSEvent) -> Bool {
        // When mouse is not captured, be more strict about what constitutes an "app event"
        if !isHIDMouseCaptured {
            // Only consider clicks within the main window's content area (excluding title bar and chrome)
            if let mainWindow = NSApplication.shared.mainWindow {
                let mouseLocation = NSEvent.mouseLocation
                let windowFrame = mainWindow.frame
                
                // Get the actual content area frame in screen coordinates
                // Use contentLayoutRect which gives us the actual content area excluding title bar
                let contentLayoutRect = mainWindow.contentLayoutRect
                let titleBarHeight = windowFrame.height - contentLayoutRect.height
                
                // Content rect is the window frame minus the title bar height
                let contentRect = NSRect(
                    x: windowFrame.minX,
                    y: windowFrame.minY,
                    width: windowFrame.width,
                    height: contentLayoutRect.height
                )
                
                logger.log(content: "Window frame: \(windowFrame), Content layout rect: \(contentLayoutRect), Title bar height: \(titleBarHeight), Content rect calculated: \(contentRect)")
                
                // In macOS coordinate system (origin at bottom-left):
                // - windowFrame.maxY is the top of the window (including title bar)
                // - contentRect.maxY is the top of the content area (bottom of title bar)
                // - Title bar is between contentRect.maxY and windowFrame.maxY
                let isInContentArea = contentRect.contains(mouseLocation)
                let isInTitleBar = mouseLocation.y > contentRect.maxY && 
                                  mouseLocation.y <= windowFrame.maxY && 
                                  mouseLocation.x >= windowFrame.minX && 
                                  mouseLocation.x <= windowFrame.maxX
                
                logger.log(content: "Mouse not captured - Mouse location: \(mouseLocation), Window frame: \(windowFrame), Content rect: \(contentRect), In content area: \(isInContentArea), In title bar: \(isInTitleBar)")
                
                // For non-captured state, only return true for actual clicks within the content area
                // AND explicitly NOT in the title bar area - this prevents title bar clicks from triggering re-capture
                let shouldCapture = isInContentArea && !isInTitleBar && (event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown)

                return shouldCapture
            }
            return false
        }
        
        // When mouse is captured, use the original logic
        if let mainWindow = NSApplication.shared.mainWindow {
            let mouseLocation = NSEvent.mouseLocation
            let windowFrame = mainWindow.frame
            let isInWindow = windowFrame.contains(mouseLocation)
            logger.log(content: "Mouse captured - Mouse location: \(mouseLocation), Window frame: \(windowFrame), In window: \(isInWindow)")
            return isInWindow
        }
        
        // If no main window, check if the event window belongs to our application
        if let window = event.window {
            let belongsToApp = NSApplication.shared.windows.contains(window)
            logger.log(content: "Event from window, belongs to app: \(belongsToApp)")
            return belongsToApp
        }
        
        // Only when captured and no other info available, assume it's from our app
        logger.log(content: "Mouse captured, no window info - assuming event is from our app for HID mode")
        return true
    }
    
    private func centerMouseCursor() {
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let centerPoint = CGPoint(
                x: screenFrame.midX,
                y: screenFrame.midY
            )
            
            let currentPosition = NSEvent.mouseLocation
            logger.log(content: "Centering cursor from \(currentPosition) to \(centerPoint)")
            CGWarpMouseCursorPosition(centerPoint)
            // Don't update lastHIDPosition here since we're using event deltas now
            logger.log(content: "Cursor centered successfully")
        } else {
            logger.log(content: "Failed to get main screen for centering cursor")
        }
    }
    
    private func convertHIDMouseEvent(_ event: NSEvent) -> UInt8 {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged:
            return 0x01
        case .rightMouseDown, .rightMouseDragged:
            return 0x02
        case .otherMouseDown, .otherMouseDragged:
            return 0x04
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return 0x00
        default:
            return 0x00
        }
    }
    
    private func isDragEvent(_ event: NSEvent) -> Bool {
        return [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
    }
    
    private func scrollWheelEventDeltaMapping(delta: Int) -> UInt8 {
        // Add slowdown factor, larger value means slower scrolling
        let slowdownFactor = 2.5
        
        // Apply slowdown factor
        let slowedDelta = Int(Double(delta) / slowdownFactor)
        
        if slowedDelta == 0 {
            return 0
        } else if slowedDelta > 0 {
            return UInt8(min(slowedDelta, 127))  // 上滚：0x01-0x7F
        }
        return 0xFF - UInt8(abs(max(slowedDelta, -128))) + 1  // 下滚：0x81-0xFF
    }
    
    // Add a public method to get the mouse loop status
    func getMouseLoopRunning() -> Bool {
        return isMouseLoopRunning
    }
    
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        // Skip mouse events if in keyboard only mode
        if UserSettings.shared.controlMode == .keyboardOnly {
            return
        }
        
        // Apply throttling at output stage
        if shouldThrottleInputEvent() {
            throttledEventDropCount += 1
            return
        }
        
        recordOutputMouseEvent()
        
        // Apply zoom level mapping if user is in custom zoom mode
        var finalX = x
        var finalY = y
        
        // Try to resolve PlayerViewModel from DependencyContainer
        if DependencyContainer.shared.isRegistered(PlayerViewModel.self) {
            let playerViewModel = DependencyContainer.shared.resolve(PlayerViewModel.self)
            if playerViewModel.customZoom {
                let zoomLevel = playerViewModel.zoomLevel
                if zoomLevel != 1.0 {
                    // Apply inverse zoom transform around the zoom center point
                    // Formula: new_coord = center + (coord - center) / zoomLevel
                    let centerX = playerViewModel.zoomCenter.x
                    let centerY = playerViewModel.zoomCenter.y
                    
                    let fx = CGFloat(x)
                    let fy = CGFloat(y)
                    
                    let mappedX = centerX + (fx - centerX) / zoomLevel
                    let mappedY = centerY + (fy - centerY) / zoomLevel
                    
                    finalX = Int(mappedX)
                    finalY = Int(mappedY)
                    
                    logger.log(content: "Applied zoom mapping with center (\(String(format: "%.0f", centerX)), \(String(format: "%.0f", centerY))): zoom=\(String(format: "%.2f", zoomLevel))x, original=(\(x),\(y)), mapped=(\(finalX),\(finalY))")
                }
            }
        }
        
        mouserMapper.handleAbsoluteMouseAction(x: finalX, y: finalY, mouseEvent: mouseEvent, wheelMovement: self.scrollWheelEventDeltaMapping(delta: wheelMovement))
    }
    
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        // Skip mouse events if in keyboard only mode
        if UserSettings.shared.controlMode == .keyboardOnly {
            return
        }
        
        // Check the current mouse control mode
        if UserSettings.shared.MouseControl == .relativeHID {
            // For HID mode, the events should be handled by the HID monitor
            // This method should not be called directly for HID events
            logger.log(content: "Warning: handleRelativeMouseAction called in HID mode - this should be handled by HID monitor")
            return
        }
        
        // Enqueue relative mouse event instead of processing directly
        enqueueRelativeMouseEvent(dx: dx, dy: dy, mouseEvent: mouseEvent, wheelMovement: Int(wheelMovement), isDragged: dragged)
    }
    
    private func handleRelativeMouseActionEvents(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00, dragged:Bool = false) {
        // Apply overflow deltas from dropped events (if any)
        if adaptiveAccumulationEnabled && (overflowAccumulatedDeltaX != 0 || overflowAccumulatedDeltaY != 0) {
            accumulatedDeltaX += overflowAccumulatedDeltaX
            accumulatedDeltaY += overflowAccumulatedDeltaY
            logger.log(content: "✓ Applied overflow buffer: (Δx:\(overflowAccumulatedDeltaX), Δy:\(overflowAccumulatedDeltaY)) → accumulated: (\(accumulatedDeltaX), \(accumulatedDeltaY))")
            overflowAccumulatedDeltaX = 0
            overflowAccumulatedDeltaY = 0
            adaptiveAccumulationEnabled = false
        }
        
        // Events mode: always accumulate deltas first
        accumulatedDeltaX += dx
        accumulatedDeltaY += dy
        
        // Apply throttling at output stage - only send if rate limit not exceeded
        if shouldThrottleInputEvent() {
            throttledEventDropCount += 1
            // Deltas accumulated but not sent yet - will be sent in next non-throttled batch
            return
        }
        
        logger.log(content: "Events mode - Accumulated deltas: X=\(accumulatedDeltaX), Y=\(accumulatedDeltaY)")
        
        /// Prevents sending mouse events when skipMoveBack flag is set and recordCount > 0.
        /// This guards against unwanted cursor repositioning that can occur when the mouse
        /// button is released, as the relative positioning system may cause the cursor to
        /// revert to a previous location.
        if self.skipMoveBack && recordCount > 0{
            logger.log(content: "Mouse event Skipped due to skipMoveBack logic")
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            skipMoveBack = false
            return
        }
        
        // When mouse left up, relative will go back to prevous location, should avoid it
        if self.dragging && !dragged {
            skipMoveBack = true
            recordCount = 1  // Mark that we've just transitioned from dragging to non-dragging
            logger.log(content: "Reset mouse move counter - sending accumulated deltas, skipMoveBack enabled with recordCount=\(recordCount)")
            mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: self.scrollWheelEventDeltaMapping(delta: wheelMovement))
        }
        self.dragging = dragged

        logger.log(content: "Events mode - Sending to MouseMapper: dx=\(accumulatedDeltaX), dy=\(accumulatedDeltaY), mouseEvent=\(mouseEvent), wheelMovement=\(wheelMovement)")
        mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: self.scrollWheelEventDeltaMapping(delta: wheelMovement))
        recordOutputMouseEvent()

        // Store last sent deltas for display purposes
        lastSentDeltaX = accumulatedDeltaX
        lastSentDeltaY = accumulatedDeltaY
        
        // Reset the accumulated delta and the record count
        /// recordCount is preserved if skipMoveBack is true to allow the skip logic on the next event.
        /// It is only reset after the skip guard activates and clears skipMoveBack.
        /// This ensures the erratic cursor movement event (next event after button release) gets filtered out.
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        // Only reset recordCount if we're not in skip mode - preserve it for the skip guard check
        if !skipMoveBack {
            recordCount = 0
        }
        
        logger.log(content: "Events mode - deltas reset")
    }
    
    private func handleRelativeMouseActionHID(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: Int = 0x00) {
        // Apply throttling at output stage
        if shouldThrottleInputEvent() {
            throttledEventDropCount += 1
            return
        }
        
        // HID mode: pass deltas directly to serial without accumulation or complex logic
        logger.log(content: "HID mode - Direct relative mouse action: dx=\(dx), dy=\(dy), mouseEvent=\(mouseEvent), wheelMovement=\(wheelMovement)")
        mouserMapper.handleRelativeMouseAction(dx: dx, dy: dy, mouseEvent: mouseEvent, wheelMovement: self.scrollWheelEventDeltaMapping(delta: wheelMovement))
        recordOutputMouseEvent()
        logger.log(content: "[DEBUG] HID mode - Event recorded")
        // Store for display purposes
        lastSentDeltaX = dx
        lastSentDeltaY = dy
        
        logger.log(content: "HID mode - Event sent to serial")
    }
    
    func relativeMouse2TopLeft() {
        mouserMapper.relativeMouse2TopLeft()
    }

    func relativeMouse2BottomLeft() {
        mouserMapper.relativeMouse2BottomLeft()
    }

    func relativeMouse2TopRight() {
        mouserMapper.relativeMouse2TopRight()
    }
    
    func relativeMouse2BottomRight() {
        mouserMapper.relativeMouse2BottomRight()
    }
    
    func runMouseLoop() {
        // If already running, do not start again
        guard !isMouseLoopRunning else {
            logger.log(content: "Mouse loop already running")
            return
        }
        
        isMouseLoopRunning = true
        
        DispatchQueue.global().async {
            
            // Stop current loop
            self.isMouseLoopRunning = false
            
            // Call appropriate loop function
            if UserSettings.shared.MouseControl == .relativeHID || UserSettings.shared.MouseControl == .relativeEvents {
                self.isMouseLoopRunning = true
                DispatchQueue.global().async {
                    while self.isMouseLoopRunning {
                        // Move in relative mode - use internal method to bypass HID mode restrictions
                        // Move up
                        self.handleRelativeMouseActionEvents(dx: 0, dy: -50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move down
                        self.handleRelativeMouseActionEvents(dx: 0, dy: 50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move left
                        self.handleRelativeMouseActionEvents(dx: -50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move right
                        self.handleRelativeMouseActionEvents(dx: 50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                    }
                    
                    self.logger.log(content: "Mouse loop in relative mode stopped")
                }
            } else {
                // Start the bouncing ball mouse loop in absolute mode
                self.runBouncingBallMouseLoop()
            }
        }
    }
    
    func stopMouseLoop() {
        isMouseLoopRunning = false
        logger.log(content: "Request to stop mouse loop")
    }
    
    // Run the bouncing ball mouse movement
    func runBouncingBallMouseLoop() {
        // If already running, do not start again
        guard !isMouseLoopRunning else {
            logger.log(content: "Mouse loop already running")
            return
        }
        
        isMouseLoopRunning = true
        logger.log(content: "Start the bouncing ball mouse loop")
        
        DispatchQueue.global().async {
            // The boundary of absolute mode
            let maxX = 4096
            let maxY = 4096
            
            // Initial position and movement parameters
            var x = 50
            var y = 50
            var velocityX = 40
            var velocityY = 0
            let gravity = 5
            let energyLoss = 0.9 // Energy loss coefficient when colliding
            let framerate = 0.05 // 50ms per frame
            
            // Energy recovery parameters
            let minEnergyThreshold = 15  // When the vertical velocity is less than this value, it is considered that the energy is insufficient
            let boostVelocity = 500       // The additional上升速度
            let horizontalBoost = 1000     // The additional horizontal speed
            var lowEnergyCount = 0       // The counter of low energy state
            var boostDirection = 1       // The direction of horizontal boost (1 or -1)
            
            while self.isMouseLoopRunning {
                // Calculate new position
                x += velocityX
                velocityY += gravity
                y += velocityY
                
                // Detect energy state
                _ = abs(velocityX) + abs(velocityY)
                let isLowEnergy = abs(velocityY) < minEnergyThreshold && y > maxY * Int(0.8)
                
                if isLowEnergy {
                    lowEnergyCount += 1
                } else {
                    lowEnergyCount = 0
                }
                
                // If the continuous multiple frames are in the low energy state, give additional boost force
                if lowEnergyCount > 10 {
                    velocityY = -boostVelocity
                    boostDirection = (velocityX > 0) ? -1 : 1
                    velocityX = boostDirection * horizontalBoost
                    lowEnergyCount = 0
                }
                
                // Detect collision
                if x <= 0 {
                    x = 0
                    velocityX = Int(Double(-velocityX) * energyLoss)
                } else if x >= maxX {
                    x = maxX
                    velocityX = Int(Double(-velocityX) * energyLoss)
                }
                
                if y <= 0 {
                    y = 0
                    velocityY = Int(Double(-velocityY) * energyLoss)
                } else if y >= maxY {
                    y = maxY
                    velocityY = Int(Double(-velocityY) * energyLoss)
                    
                    // If the velocity is low after the collision at the bottom, give additional upward force
                    if abs(velocityY) < minEnergyThreshold {
                        velocityY = -boostVelocity
                        // Give a random horizontal push, making the movement more variable
                        velocityX += Int.random(in: -15...15)
                    }
                }
                
                // Update mouse position via queue
                let queueItem = MouseEventQueueItem(
                    deltaX: 0,
                    deltaY: 0,
                    mouseEvent: 0x00,
                    wheelMovement: 0,
                    isDragged: false,
                    timestamp: CACurrentMediaTime(),
                    isAbsolute: true,
                    absoluteX: x,
                    absoluteY: y
                )
                self.enqueueMouseEvent(queueItem)
                
                // Wait for the next frame
                Thread.sleep(forTimeInterval: framerate)
                
                // Check if the loop should terminate
                if !self.isMouseLoopRunning { break }
            }
            
            self.logger.log(content: "Bouncing ball mouse loop stopped")
        }
    }
}

// MARK: - MouseManagerProtocol Implementation

extension MouseManager {
    func sendMouseInput(_ input: MouseInput) {
        // Implementation would depend on existing mouse input methods
        // Convert protocol input to existing method calls
    }
    
    func setMouseMode(_ mode: MouseMode) {
        // Implementation for setting mouse mode (absolute/relative)
        switch mode {
        case .absolute:
            // Set absolute mouse mode
            stopHIDMouseMonitoring()
            break
        case .relative:
            // Set relative mouse mode - determine which type based on current setting
            if UserSettings.shared.MouseControl == .relativeHID {
                startHIDMouseMonitoring()
            } else {
                stopHIDMouseMonitoring()
            }
            break
        }
    }
    
    func forceStopAllMouseLoops() {
        // Stop all mouse loops forcefully
        stopMouseLoop()
        stopHIDMouseMonitoring()
        isMouseLoopRunning = false
    }
    
    func testMouseMonitor() {
        // Test mouse monitor functionality
        logger.log(content: "Testing mouse monitor functionality")
    }
    
    // Additional methods for HID control
    func enableHIDMouseMode() {
        startHIDMouseMonitoring()
    }
    
    func disableHIDMouseMode() {
        stopHIDMouseMonitoring()
    }
    
    func isHIDMouseModeActive() -> Bool {
        return isHIDMonitoringActive
    }
    
    var isMouseCaptured: Bool {
        return isHIDMouseCaptured
    }
}
