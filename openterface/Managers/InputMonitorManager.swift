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

class InputMonitorManager: ObservableObject {
    @Published var mouseLocation: NSPoint = .zero
    @Published var hostKeys: String = ""
    @Published var targetKeys: String = ""
    @Published var targetMouse: String = "(Abs)(0,0)"
    @Published var hostMouseButtons: String = ""
    @Published var targetMouseButtons: String = ""
    @Published var targetScanCodes: String = ""
    
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
    
    init() {
        startMonitoring()
        startPollingKeyboardState()
        setupMouseTracking()
    }
    
    private func setupMouseTracking() {
        // No need for separate tracking - we'll calculate from mouseLocation in the update loop
    }
    
    func startMonitoring() {
        // Monitor mouse position
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.mouseLocation = event.locationInWindow
            return event
        }
        
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
        case .leftMouseUp:
            leftMouseDown = false
        case .rightMouseDown:
            rightMouseDown = true
        case .rightMouseUp:
            rightMouseDown = false
        case .otherMouseDown:
            middleMouseDown = true
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
        }
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
            let desc = keyDescription(forKeyCode: keyCode)
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
    
    private func keyDescription(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        // Modifier keys
        case 54: return "Right Cmd"
        case 55: return "Left Cmd"
        case 56: return "Left Shift"
        case 57: return "CapsLock"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Function"
        // Special keys
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        // Function keys
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        // Number keys
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        // Letter keys
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        // Symbol keys
        case 24: return "="
        case 27: return "-"
        case 30: return "]"
        case 33: return "["
        case 39: return "'"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 50: return "`"
        default:
            return "Key(\(keyCode))"
        }
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
