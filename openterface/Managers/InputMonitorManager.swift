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

import SwiftUI
import AppKit
import Foundation

class InputMonitorManager: ObservableObject {
    static let shared = InputMonitorManager()
    
    @Published var mouseLocation: NSPoint = .zero
    @Published var hostKeys: String = ""
    @Published var targetKeys: String = ""
    @Published var targetMouse: String = "(Abs)(0,0)"
    @Published var hostMouseButtons: String = ""
    @Published var targetMouseButtons: String = ""
    @Published var targetScanCodes: String = ""
    
    // Statistics - Events per second
    @Published var mouseEventsPerSecond: Double = 0.0
    @Published var mouseClicksPerSecond: Double = 0.0
    @Published var keyEventsPerSecond: Double = 0.0
    
    // Mouse queue and output event monitoring
    @Published var mouseEventQueueSize: Int = 0  // Current queue depth
    @Published var mouseEventQueuePeakSize: Int = 0  // Peak queue depth in last interval
    @Published var mouseOutputEventRate: Double = 0.0  // Output events per second (to serial)
    
    // Acknowledgement latencies (in milliseconds)
    @Published var keyboardAckLatency: Double = 0.0
    @Published var mouseAckLatency: Double = 0.0
    
    // Max latencies in last 10 seconds (in milliseconds)
    @Published var keyboardMaxLatency: Double = 0.0
    @Published var mouseMaxLatency: Double = 0.0
    
    // ACK rates (per second)
    @Published var keyboardAckRate: Double = 0.0
    @Published var mouseAckRate: Double = 0.0
    
    // Mouse event drop rate (per second)
    @Published var mouseEventDropRate: Double = 0.0
    
    private var mouseMonitor: Any?
    private var mouseButtonMonitor: Any?
    private var timer: Timer?
    private let keyboardManager = KeyboardManager.shared
    private let mouseManager = MouseManager.shared
    private let keyboardMapper = KeyboardMapper()
    private var leftMouseDown = false
    private var rightMouseDown = false
    private var middleMouseDown = false
    private var lastScanCodes: String = ""
    private var lastTargetKeys: String = ""
    
    // Event tracking for per-second calculation
    private var mouseEventCount: Int = 0
    private var mouseClickCount: Int = 0
    private var keyEventCount: Int = 0
    private var eventTrackingStartTime: TimeInterval = Date().timeIntervalSince1970
    private let eventTrackingInterval: TimeInterval = 1.0 // Calculate per second
    
    // Output event rate tracking (centralized calculation)
    private var outputTrackingStartTime: TimeInterval = Date().timeIntervalSince1970
    private let outputTrackingInterval: TimeInterval = 1.0 // Calculate per second
    
    // Drop rate tracking (centralized calculation)
    private var dropTrackingStartTime: TimeInterval = Date().timeIntervalSince1970
    private let dropTrackingInterval: TimeInterval = 1.0 // Calculate per second
    
    // Queue peak tracking (centralized calculation)
    private var queuePeakResetTime: TimeInterval = Date().timeIntervalSince1970
    private let queuePeakResetInterval: TimeInterval = 1.0 // Calculate per second
    
    private init() {
        startMonitoring()
        startPollingKeyboardState()
        setupMouseTracking()
        startStatsCalculation()
    }
    
    private func setupMouseTracking() {
        // No need for separate tracking - we'll calculate from mouseLocation in the update loop
    }
    
    func startMonitoring() {
        // Monitor mouse button events
        let buttonMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: buttonMask) { [weak self] event in
            self?.handleMouseButtonEvent(event)
            return event
        }
    }
    
    private func handleMouseButtonEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            leftMouseDown = true
            mouseClickCount += 1
        case .leftMouseUp:
            leftMouseDown = false
        case .rightMouseDown:
            rightMouseDown = true
            mouseClickCount += 1
        case .rightMouseUp:
            rightMouseDown = false
        case .otherMouseDown:
            middleMouseDown = true
            mouseClickCount += 1
        case .otherMouseUp:
            middleMouseDown = false
        default:
            break
        }
        updateMouseButtonDisplay()
    }
    
    private func updateMouseButtonDisplay() {
        var hostButtons: [String] = []
        if leftMouseDown { hostButtons.append("Left") }
        if rightMouseDown { hostButtons.append("Right") }
        if middleMouseDown { hostButtons.append("Middle") }
        
        let newHostMouseButtons = hostButtons.isEmpty ? "" : hostButtons.joined(separator: " + ")
        if newHostMouseButtons != hostMouseButtons {
            hostMouseButtons = newHostMouseButtons
        }
        
        // For target, mouse buttons remain the same but with different naming
        var targetButtons: [String] = []
        if leftMouseDown { targetButtons.append("Left") }
        if rightMouseDown { targetButtons.append("Right") }
        if middleMouseDown { targetButtons.append("Middle") }
        
        let newTargetMouseButtons = targetButtons.isEmpty ? "" : targetButtons.joined(separator: " + ")
        if newTargetMouseButtons != targetMouseButtons {
            targetMouseButtons = newTargetMouseButtons
        }
    }
    
    // Poll KeyboardManager state to update display
    private func startPollingKeyboardState() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateKeysFromKeyboardManager()
            self?.updateAcknowledgementLatencies()
        }
    }
    
    private func updateAcknowledgementLatencies() {
        let serialPort = SerialPortManager.shared
        let mouseManager = MouseManager.shared
        keyboardAckLatency = serialPort.keyboardAckLatency
        mouseAckLatency = serialPort.mouseAckLatency
        keyboardMaxLatency = serialPort.keyboardMaxLatency
        mouseMaxLatency = serialPort.mouseMaxLatency
        keyboardAckRate = serialPort.keyboardAckRateSmoothed  // Use smoothed value for display
        mouseAckRate = serialPort.mouseAckRateSmoothed        // Use smoothed value for display
        mouseEventQueueSize = mouseManager.getCurrentQueueSize()
        // Note: mouseEventQueuePeakSize, mouseEventDropRate, and mouseOutputEventRate are calculated locally in calculateAndResetStats()
    }
    
    private func updateKeysFromKeyboardManager() {
        // Get host input (raw modifiers from state)
        var hostModifiers: [String] = []
        if keyboardManager.isLeftCtrlHeld { hostModifiers.append("LCtrl") }
        if keyboardManager.isRightCtrlHeld { hostModifiers.append("RCtrl") }
        if keyboardManager.isLeftAltHeld { hostModifiers.append("LAlt") }
        if keyboardManager.isRightAltHeld { hostModifiers.append("RAlt") }
        if keyboardManager.isLeftShiftHeld { hostModifiers.append("LShift") }
        if keyboardManager.isRightShiftHeld { hostModifiers.append("RShift") }
        if keyboardManager.isCapsLockOn { hostModifiers.append("CapsLock") }
        
        // Get regular keys
        var regularKeys: [String] = []
        var scanCodes: [String] = []
        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        for keyCode in keyboardManager.pressedKeys where keyCode != 255 && !modifierKeyCodes.contains(keyCode) {
            let desc = keyboardMapper.keyDescription(forKeyCode: keyCode)
            regularKeys.append(desc)
            if let scanCode = keyCodeToScanCode(keyCode) {
                scanCodes.append(String(format: "0x%02X", scanCode))
            }
        }
        
        // Combine for host display
        let allHostKeys = hostModifiers + regularKeys
        let newHostKeys = allHostKeys.isEmpty ? "" : allHostKeys.joined(separator: " + ")
        
        // Get target output (after remapping)
        var targetModifiers: [String] = []
        var targetRegularKeys: [String] = []
        
        let currentLayout = keyboardManager.currentKeyboardLayout
        
        // Add remapped modifiers
        if keyboardManager.isLeftCtrlHeld || keyboardManager.isRightCtrlHeld {
            if currentLayout == .windows {
                targetModifiers.append("Win")
            } else {
                targetModifiers.append("Ctrl")
            }
        }
        if keyboardManager.isLeftAltHeld || keyboardManager.isRightAltHeld {
            targetModifiers.append("Alt")
        }
        if keyboardManager.isLeftShiftHeld || keyboardManager.isRightShiftHeld {
            targetModifiers.append("Shift")
        }
        if keyboardManager.isCapsLockOn {
            targetModifiers.append("CapsLock")
        }
        
        // Add command keys (they get remapped in Windows mode)
        for keyCode in keyboardManager.pressedKeys where keyCode != 255 {
            if keyCode == 54 || keyCode == 55 { // Command keys
                if currentLayout == .windows {
                    targetModifiers.append("Ctrl")
                } else {
                    targetModifiers.append("Cmd")
                }
                break
            }
        }
        
        // Regular keys remain the same
        targetRegularKeys = regularKeys
        
        // Combine for target display
        let allTargetKeys = targetModifiers + targetRegularKeys
        let newTargetKeys = allTargetKeys.isEmpty ? "" : allTargetKeys.joined(separator: " + ")
        
        // Get mouse mode and state for target output
        let mouseMode = UserSettings.shared.MouseControl
        var mouseDisplay = ""
        
        switch mouseMode {
        case .absolute:
            // Calculate mapped position from current mouse location
            if let window = NSApp.mainWindow {
                let windowWidth = window.frame.width
                let windowHeight = window.frame.height
                let mappedX = Int(mouseLocation.x * 4096.0 / windowWidth)
                let mappedY = Int(mouseLocation.y * 4096.0 / windowHeight)
                mouseDisplay = "(Abs)(\(mappedX),\(mappedY))"
            } else {
                mouseDisplay = "(Abs)(0,0)"
            }
        case .relativeHID, .relativeEvents:
            let dx = mouseManager.lastSentDeltaX
            let dy = mouseManager.lastSentDeltaY
            mouseDisplay = "(Rel)(\(dx),\(dy))"
        }
        
        let newTargetMouse = mouseDisplay
        
        // Update published state
        if newHostKeys != hostKeys {
            hostKeys = newHostKeys
        }
        if newTargetKeys != targetKeys {
            targetKeys = newTargetKeys
            // Count key events when target keys change
            if !newTargetKeys.isEmpty && newTargetKeys != lastTargetKeys {
                keyEventCount += 1
            } else if newTargetKeys.isEmpty && !lastTargetKeys.isEmpty {
                // Key was released - also count this as an event
                keyEventCount += 1
            }
            lastTargetKeys = newTargetKeys
        }
        if newTargetMouse != targetMouse {
            targetMouse = newTargetMouse
        }
        
        // Update scan codes for target output
        let newTargetScanCodes = scanCodes.isEmpty ? lastScanCodes : scanCodes.joined(separator: " ")
        if newTargetScanCodes != targetScanCodes {
            targetScanCodes = newTargetScanCodes
        }
        // Keep track of the last scan codes when keys are released
        if !scanCodes.isEmpty {
            lastScanCodes = newTargetScanCodes
        }
    }
    
    private func keyCodeToScanCode(_ keyCode: UInt16) -> UInt8? {
        // Use the keyCodeMapping from KeyboardMapper
        return keyboardMapper.keyCodeMapping[keyCode]
    }
    
    private func startStatsCalculation() {
        // Calculate and publish stats every second
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.calculateAndResetStats()
        }
    }
    
    private func calculateAndResetStats() {
        let currentTime = Date().timeIntervalSince1970
        let elapsed = currentTime - eventTrackingStartTime
        
        // Calculate events per second
        if elapsed > 0 {
            mouseEventsPerSecond = Double(mouseEventCount) / elapsed
            mouseClicksPerSecond = Double(mouseClickCount) / elapsed
            keyEventsPerSecond = Double(keyEventCount) / elapsed
        }
        
        // Reset counters and timestamp every second for continuous calculation
        if elapsed >= eventTrackingInterval {
            mouseEventCount = 0
            mouseClickCount = 0
            keyEventCount = 0
            eventTrackingStartTime = currentTime
        }
        
        // Calculate output event rate (centralized)
        let outputElapsed = currentTime - outputTrackingStartTime
        if outputElapsed >= outputTrackingInterval {
            let outputCount = mouseManager.getAndResetOutputEventCount()
            mouseOutputEventRate = Double(outputCount) / outputElapsed
            outputTrackingStartTime = currentTime
        }
        
        // Calculate drop rate (centralized)
        let dropElapsed = currentTime - dropTrackingStartTime
        if dropElapsed >= dropTrackingInterval {
            let dropCount = mouseManager.getAndResetDropEventCount()
            mouseEventDropRate = Double(dropCount) / dropElapsed
            dropTrackingStartTime = currentTime
        }
        
        // Calculate and update queue peak (centralized)
        let peakElapsed = currentTime - queuePeakResetTime
        if peakElapsed >= queuePeakResetInterval {
            let peak = mouseManager.getAndResetPeakQueueSize()
            mouseEventQueuePeakSize = peak
            queuePeakResetTime = currentTime
        }
    }
    
    // MARK: - Public methods for tracking HID mode events
    /// Called by MouseManager to track HID mouse movement events
    func recordMouseMove() {
        mouseEventCount += 1
    }
    
    /// Called by MouseManager to track HID mouse click events
    func recordHIDMouseClick() {
        mouseClickCount += 1
    }
    
    deinit {
        timer?.invalidate()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseButtonMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
