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
    
    // Private initializer for dependency injection
    private init() {
        // Dependencies are now lazy and will be resolved when first accessed
    }
    
    // Add a public method to get the mouse loop status
    func getMouseLoopRunning() -> Bool {
        return isMouseLoopRunning
    }
    
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00) {
        mouserMapper.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
    }
    
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        accumulatedDeltaX += dx
        accumulatedDeltaY += dy
        if self.skipMoveBack && recordCount > 0{
            if logger.MouseEventPrint {  logger.log(content: "Mouse event Skipped...") }
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            skipMoveBack = false
            return
        }
        
        // When mouse left up, relative will go back to prevous location, should avoid it
        if self.dragging && !dragged {
            skipMoveBack = true
            recordCount = 0
            if logger.MouseEventPrint {  logger.log(content: "Reset mouse move counter..") }
            mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
        }
        self.dragging = dragged

        if logger.MouseEventPrint {  logger.log(content: "Handled handleRelativeMouseAction, delta: (\(accumulatedDeltaX), \(accumulatedDeltaY)), accumulated records count: \(recordCount)") }
        mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)

        // Reset the accumulated delta and the record count
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        recordCount = 0
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
                        // Move in relative mode
                        // Move up
                        self.handleRelativeMouseAction(dx: 0, dy: -50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move down
                        self.handleRelativeMouseAction(dx: 0, dy: 50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move left
                        self.handleRelativeMouseAction(dx: -50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // Move right
                        self.handleRelativeMouseAction(dx: 50, dy: 0)
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
            break
        case .relative:
            // Set relative mouse mode
            break
        }
    }
    
    func forceStopAllMouseLoops() {
        // Stop all mouse loops forcefully
        stopMouseLoop()
        isMouseLoopRunning = false
    }
    
    func testMouseMonitor() {
        // Test mouse monitor functionality
        logger.log(content: "Testing mouse monitor functionality")
    }
}
