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

class MouseManager: MouseManagerProtocol {

    // 添加共享单例实例
    static let shared = MouseManager()
    
    // Protocol-based dependencies
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    let mouserMapper = MouseMapper()
    
    var isRelativeMouseControlEnabled: Bool = false
    var accumulatedDeltaX = 0
    var accumulatedDeltaY = 0
    var recordCount = 0
    var dragging = false
    var skipMoveBack = false
    
    // 控制鼠标循环的变量
    private var isMouseLoopRunning = false
    
    // HID event monitoring variables
    private var hidEventMonitor: Any?
    private var isHIDMonitoringActive = false
    private var lastHIDPosition = CGPoint.zero
    private var isHIDMouseCaptured = false
    private var lastCenterTime: TimeInterval = 0
    private var centeringCooldown: TimeInterval = 0.1 // Minimum time between centering operations
    
    // Private initializer for dependency injection
    private init() {
        // Dependencies are now lazy and will be resolved when first accessed
    }
    
    deinit {
        stopHIDMouseMonitoring()
    }
    
    // MARK: - HID Mouse Event Monitoring
    
    func startHIDMouseMonitoring() {
        guard !isHIDMonitoringActive else {
            logger.log(content: "HID mouse monitoring already active")
            return
        }
        
        logger.log(content: "Starting HID mouse monitoring for Relative (HID) mode")
        
        let eventMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        
        hidEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask, handler: { [weak self] event in
            self?.handleHIDMouseEvent(event)
        })
        
        // Also monitor local events within the app
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask, handler: { [weak self] event in
            self?.handleHIDMouseEvent(event)
            return event
        })
        
        if let localMonitor = localMonitor {
            // Store both monitors - we'll need to remove both later
            if hidEventMonitor == nil {
                hidEventMonitor = [localMonitor]
            } else if var monitors = hidEventMonitor as? [Any] {
                monitors.append(localMonitor)
                hidEventMonitor = monitors
            } else {
                hidEventMonitor = [hidEventMonitor!, localMonitor]
            }
        }
        
        isHIDMonitoringActive = true
        isHIDMouseCaptured = false
        
        logger.log(content: "HID monitoring setup complete, waiting for first mouse interaction")
        
        // Hide cursor in HID mode
        NSCursor.hide()
        
        // Force capture after a short delay to ensure we get mouse events
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if !self.isHIDMouseCaptured && UserSettings.shared.MouseControl == .relativeHID {
                self.logger.log(content: "Force capturing mouse for HID mode")
                self.isHIDMouseCaptured = true
                self.centerMouseCursor()
            }
        }
    }
    
    func stopHIDMouseMonitoring() {
        guard isHIDMonitoringActive else { return }
        
        logger.log(content: "Stopping HID mouse monitoring")
        
        if let monitor = hidEventMonitor {
            if let monitors = monitor as? [Any] {
                // Remove all monitors
                for mon in monitors {
                    NSEvent.removeMonitor(mon)
                }
            } else {
                NSEvent.removeMonitor(monitor)
            }
        }
        
        hidEventMonitor = nil
        isHIDMonitoringActive = false
        isHIDMouseCaptured = false
        
        // Show cursor when stopping HID monitoring
        NSCursor.unhide()
    }
    
    private func handleHIDMouseEvent(_ event: NSEvent) {
        // Only process HID events when in relativeHID mode
        guard UserSettings.shared.MouseControl == .relativeHID else { 
            logger.log(content: "HID Event ignored - not in relativeHID mode, current mode: \(UserSettings.shared.MouseControl)")
            return 
        }
        
        logger.log(content: "HID Event received: type=\(event.type.rawValue), location=\(event.locationInWindow)")
        
        // Check if the event is from our application window
        let isFromOurApp = isEventFromOurApplication(event)
        logger.log(content: "Event from our app: \(isFromOurApp)")
        
        if !isHIDMouseCaptured && isFromOurApp {
            // First mouse interaction with our app - start capturing
            isHIDMouseCaptured = true
            logger.log(content: "HID mouse capture started")
            
            // Center the mouse cursor
            centerMouseCursor()
            return
        }
        
        // Only process events when mouse is captured
        guard isHIDMouseCaptured else { 
            logger.log(content: "HID Event ignored - mouse not captured yet")
            return 
        }
        
        // For movement events, use the event's deltaX and deltaY instead of position calculations
        // This is more accurate for HID events
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
                
                // Send to KVM using scaled HID deltas
                handleRelativeMouseActionInternal(dx: scaledDeltaX, dy: scaledDeltaY, mouseEvent: mouseEvent, wheelMovement: 0, dragged: isDragEvent(event))
                
                // Only re-center occasionally, not on every movement
                let currentTime = CACurrentMediaTime()
                if currentTime - lastCenterTime > centeringCooldown {
                    logger.log(content: "Re-centering cursor after cooldown")
                    centerMouseCursor()
                    lastCenterTime = currentTime
                }
            } else {
                logger.log(content: "HID Event ignored - deltas too small: dx=\(deltaX), dy=\(deltaY)")
            }
        } else {
            // Handle click and scroll events
            let mouseEvent = convertHIDMouseEvent(event)
            let wheelMovement = event.type == .scrollWheel ? Int(event.scrollingDeltaY) : 0
            
            logger.log(content: "Processing HID Click/Scroll: event=\(mouseEvent), wheel=\(wheelMovement)")
            
            // Send click/scroll events without movement
            handleRelativeMouseActionInternal(dx: 0, dy: 0, mouseEvent: mouseEvent, wheelMovement: UInt8(scrollWheelEventDeltaMapping(delta: wheelMovement)), dragged: isDragEvent(event))
        }
    }
    
    private func isEventFromOurApplication(_ event: NSEvent) -> Bool {
        // For HID mode, we want to capture ALL mouse events once monitoring starts
        // Check if we're in our main window area
        if let mainWindow = NSApplication.shared.mainWindow {
            let mouseLocation = NSEvent.mouseLocation
            let windowFrame = mainWindow.frame
            let isInWindow = windowFrame.contains(mouseLocation)
            logger.log(content: "Mouse location: \(mouseLocation), Window frame: \(windowFrame), In window: \(isInWindow)")
            return isInWindow
        }
        
        // If no main window, check if the event window belongs to our application
        if let window = event.window {
            let belongsToApp = NSApplication.shared.windows.contains(window)
            logger.log(content: "Event from window, belongs to app: \(belongsToApp)")
            return belongsToApp
        }
        
        // Fallback: if we're in HID mode and monitoring is active, assume it's from our app
        // This is more aggressive but necessary for HID mode
        logger.log(content: "No window info, assuming event is from our app for HID mode")
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
    
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00) {
        mouserMapper.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
    }
    
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        // Check the current mouse control mode
        if UserSettings.shared.MouseControl == .relativeHID {
            // For HID mode, the events should be handled by the HID monitor
            // This method should not be called directly for HID events
            logger.log(content: "Warning: handleRelativeMouseAction called in HID mode - this should be handled by HID monitor")
            return
        }
        
        // Handle Events mode (the original logic)
        handleRelativeMouseActionInternal(dx: dx, dy: dy, mouseEvent: mouseEvent, wheelMovement: wheelMovement, dragged: dragged)
    }
    
    private func handleRelativeMouseActionInternal(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        logger.log(content: "handleRelativeMouseActionInternal called with dx=\(dx), dy=\(dy), mouseEvent=\(mouseEvent)")
        
        // Skip the complex accumulation logic for HID mode as it handles deltas directly
        if UserSettings.shared.MouseControl == .relativeHID {
            logger.log(content: "HID mode: sending deltas directly to MouseMapper")
            mouserMapper.handleRelativeMouseAction(dx: dx, dy: dy, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
            return
        }
        
        // Original Events mode logic with accumulation
        accumulatedDeltaX += dx
        accumulatedDeltaY += dy
        
        logger.log(content: "Accumulated deltas: X=\(accumulatedDeltaX), Y=\(accumulatedDeltaY)")
        
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
            recordCount = 0
            logger.log(content: "Reset mouse move counter - sending accumulated deltas")
            mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
        }
        self.dragging = dragged

        logger.log(content: "Sending to MouseMapper: dx=\(accumulatedDeltaX), dy=\(accumulatedDeltaY), mouseEvent=\(mouseEvent), wheelMovement=\(wheelMovement)")
        mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)

        // Reset the accumulated delta and the record count
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        recordCount = 0
        
        logger.log(content: "handleRelativeMouseActionInternal completed - deltas reset")
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
                        self.handleRelativeMouseActionInternal(dx: 0, dy: -50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move down
                        self.handleRelativeMouseActionInternal(dx: 0, dy: 50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move left
                        self.handleRelativeMouseActionInternal(dx: -50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move right
                        self.handleRelativeMouseActionInternal(dx: 50, dy: 0)
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
                
                // Update mouse position
                self.handleAbsoluteMouseAction(x: x, y: y)
                
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
}
