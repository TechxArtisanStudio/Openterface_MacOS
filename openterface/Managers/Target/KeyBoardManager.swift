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

import Cocoa
import SwiftUI

class KeyboardManager: ObservableObject, KeyboardManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    static let SHIFT_KEYS = ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?"]
    static let shared = KeyboardManager()

    var escKeyDownCounts = 0
    var escKeyDownTimeStart = 0.0
    
    let kbm = KeyboardMapper()
    
    // 新增一个数组用于存储同时按下的键
    var pressedKeys: [UInt16] = [255,255,255,255,255,255]
    
    // State variables for modifier keys
    @Published var isLeftShiftHeld = false
    @Published var isRightShiftHeld = false
    @Published var isLeftCtrlHeld = false
    @Published var isRightCtrlHeld = false
    @Published var isLeftAltHeld = false
    @Published var isRightAltHeld = false
    @Published var isCapsLockOn = false
    
    // MARK: - Keyboard Layout Management
    
    // Access keyboard layout from UserSettings
    var currentKeyboardLayout: KeyboardLayout {
        get {
            return UserSettings.shared.keyboardLayout
        }
        set {
            UserSettings.shared.keyboardLayout = newValue
            logger.log(content: "Keyboard layout switched to: \(newValue.rawValue)")
        }
    }
    
    // Function to toggle between Windows and Mac keyboard layouts
    func toggleKeyboardLayout() {
        let oldLayout = currentKeyboardLayout
        switch currentKeyboardLayout {
        case .mac:
            currentKeyboardLayout = .windows
        case .windows:
            currentKeyboardLayout = .mac
        }
        logger.log(content: "🔄 Keyboard layout toggled: \(oldLayout.rawValue) → \(currentKeyboardLayout.rawValue)")
    }
    
    // Function to get modifier key labels based on layout
    func getModifierKeyLabel() -> String {
        return currentKeyboardLayout.displayName
    }
    
    // MARK: - Key Remapping Functions
    
    // Get the remapped key code based on the current keyboard layout
    func getRemappedKeyCode(sourceKey: UInt16, sourceModifier: NSEvent.ModifierFlags, isLeft: Bool) -> UInt16 {
        let originalKey = sourceKey
        let remappedKey: UInt16
        
        switch currentKeyboardLayout {
        case .windows:
            remappedKey = getWindowsModeMapping(sourceKey: sourceKey, sourceModifier: sourceModifier, isLeft: isLeft)
        case .mac:
            remappedKey = sourceKey // In Mac mode, keep original key codes
        }
        
        logger.log(content: "🔑 Key Remapping: Layout=\(currentKeyboardLayout.rawValue), Source=\(originalKey), Target=\(remappedKey), Modifier=\(sourceModifier), IsLeft=\(isLeft)")
        
        return remappedKey
    }
    
    // Windows mode key mapping
    private func getWindowsModeMapping(sourceKey: UInt16, sourceModifier: NSEvent.ModifierFlags, isLeft: Bool) -> UInt16 {
        logger.log(content: "🪟 Windows Mode Mapping: SourceKey=\(sourceKey), Modifier=\(sourceModifier), IsLeft=\(isLeft)")
        
        switch sourceModifier {
        case .command:
            // Cmd (⌘) → Ctrl in Windows mode
            let targetKey: UInt16 = isLeft ? 59 : 62 // Map to Control keys (left/right)
            logger.log(content: "   Cmd → Ctrl: \(sourceKey) → \(targetKey)")
            return targetKey
        case .control:
            // Control (⌃) → Win Key in Windows mode
            let targetKey: UInt16 = isLeft ? 55 : 54 // Map to Command keys (left/right) which represent Win keys on target
            logger.log(content: "   Ctrl → Win: \(sourceKey) → \(targetKey)")
            return targetKey
        case .option:
            // Option (⌥) → Alt in Windows mode (keep as Alt)
            logger.log(content: "   Alt → Alt: \(sourceKey) → \(sourceKey) (no change)")
            return sourceKey // Keep original Alt key codes (58/61)
        default:
            logger.log(content: "   No mapping needed for modifier: \(sourceModifier)")
            return sourceKey
        }
    }

    // Computed property to check if any shift key is held
    var isShiftHeld: Bool {
        return isLeftShiftHeld || isRightShiftHeld
    }
    
    // Computed property to check if letters should be uppercase 
    // (Shift XOR Caps Lock - they cancel each other when both are active)
    var shouldShowUppercase: Bool {
        return isShiftHeld != isCapsLockOn  // XOR logic: uppercase when exactly one is active
    }
    
    // Function to get the shifted version of symbols and numbers
    func getShiftedKey(for key: String) -> String {
        guard isShiftHeld else { return key }
        
        let shiftMapping: [String: String] = [
            "~": "~",  // ~ is already shifted, ` when not shifted
            "`": "~",
            "1": "!",
            "2": "@", 
            "3": "#",
            "4": "$",
            "5": "%",
            "6": "^",
            "7": "&",
            "8": "*",
            "9": "(",
            "0": ")",
            "-": "_",
            "=": "+",
            "[": "{",
            "]": "}",
            "\\": "|",
            ";": ":",
            "'": "\"",
            ",": "<",
            ".": ">",
            "/": "?"
        ]
        
        return shiftMapping[key] ?? key
    }
    
    // Function to get the unshifted version of a key (for displaying on UI)
    func getDisplayKey(for originalKey: String) -> String {
        // Map shifted keys to their unshifted versions for display
        let unshiftedMapping: [String: String] = [
            "~": "`"  // Show ` instead of ~ when shift is not held
        ]
        
        if isShiftHeld {
            return getShiftedKey(for: originalKey)
        } else {
            return unshiftedMapping[originalKey] ?? originalKey
        }
    }
    
    init() {
        logger.log(content: "🎹 KeyboardManager initialized with layout: \(currentKeyboardLayout.rawValue)")
        monitorKeyboardEvents()
    }
    
    // MARK: - Modifier Key State Management
    func toggleLeftShift() {
        if isLeftShiftHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.leftShift)
        }
        isLeftShiftHeld.toggle()
    }
    
    func toggleRightShift() {
        if isRightShiftHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.rightShift)
        }
        isRightShiftHeld.toggle()
    }
    
    func toggleLeftCtrl() {
        if isLeftCtrlHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.leftCtrl)
        }
        isLeftCtrlHeld.toggle()
    }
    
    func toggleRightCtrl() {
        if isRightCtrlHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.rightCtrl)
        }
        isRightCtrlHeld.toggle()
    }
    
    func toggleLeftAlt() {
        if isLeftAltHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.leftAlt)
        }
        isLeftAltHeld.toggle()
    }
    
    func toggleRightAlt() {
        if isRightAltHeld {
            sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.rightAlt)
        }
        isRightAltHeld.toggle()
    }
    
    func toggleCapsLock() {
        isCapsLockOn.toggle()
        // For Caps Lock, we typically want to send the key press regardless of the state
        sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey.capsLock)
    }
    
    func modifierFlagsDescription(_ flags: NSEvent.ModifierFlags) -> String {
        var descriptions: [String] = []
        
        if flags.contains(.control) {
            descriptions.append("Ctrl")
        }
        if flags.contains(.option) {
            descriptions.append("Alt")
        }
        if flags.contains(.command) {
            descriptions.append("Cmd")
        }
        if flags.contains(.shift) {
            descriptions.append("Shift")
        }
        if flags.contains(.capsLock) {
            descriptions.append("CapsLock")
        }
        return descriptions.isEmpty ? "None" : descriptions.joined(separator: ", ")
    }
    
    // Helper function to show physical key interpretation
    private func getPhysicalKeyDescription(_ rawValue: UInt) -> String {
        var keys: [String] = []
        if (rawValue & 0x101) == 0x101 { keys.append("LeftCtrl") }
        if (rawValue & 0x2100) == 0x2100 { keys.append("RightCtrl") }
        if (rawValue & 0x108) == 0x108 { keys.append("LeftCmd") }
        if (rawValue & 0x110) == 0x110 { keys.append("RightCmd") }
        if (rawValue & 0x120) == 0x120 { keys.append("LeftOpt") }
        if (rawValue & 0x140) == 0x140 { keys.append("RightOpt") }
        if (rawValue & 0x102) == 0x102 { keys.append("LeftShift") }
        if (rawValue & 0x104) == 0x104 { keys.append("RightShift") }
        return keys.isEmpty ? "None" : keys.joined(separator: ", ")
    }
    
    // Helper function to log current pressed keys state
    private func logPressedKeysState() {
        let activeKeys = pressedKeys.filter { $0 != 255 }
        logger.log(content: "📋 Current pressed keys: \(activeKeys)")
    }
    
    // MARK: - Event Handling Helper Methods
    
    // Check if event should pass through to system windows (settings, text inputs, etc.)
    private func shouldPassThroughEvent(for event: NSEvent) -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        
        // Check for specific window identifiers
        if let identifier = keyWindow.identifier?.rawValue,
           (identifier.contains("edidNameWindow") || identifier.contains("firmwareUpdateWindow") || 
            identifier.contains("resetSerialToolWindow") || identifier.contains("settingsWindow") || 
            identifier.contains("macroCreatorDialog")) {
            return true
        }
        
        // Check if this is a sheet or modal dialog by examining the window level
        if keyWindow.level.rawValue > NSWindow.Level.normal.rawValue {
            return true
        }
        
        // Check if the first responder is a text input field
        if let firstResponder = keyWindow.firstResponder,
           (firstResponder.isKind(of: NSTextView.self) || firstResponder.isKind(of: NSTextField.self)) {
            return true
        }
        
        return false
    }
    
    // Log modifier changes
    private func logModifierChange(_ modifiers: NSEvent.ModifierFlags) {
        let modifierDescription = modifierFlagsDescription(modifiers)
        let physicalKeys = getPhysicalKeyDescription(modifiers.rawValue)
        logger.log(content: "🎛️ Modifier flags changed: \(modifierDescription), Raw=\(modifiers.rawValue), Physical=[\(physicalKeys)], CapsLock=\(modifiers.contains(.capsLock))")
    }
    
    // Handle shift key press/release (no remapping needed for Shift)
    private func handleShiftKeys(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            let rawValue = modifiers.rawValue
            if rawValue & 0x102 == 0x102 { // Left Shift
                pressAndUpdateModifierKey(keyCode: 56, isHeld: &isLeftShiftHeld)
            } else if rawValue & 0x104 == 0x104 { // Right Shift
                pressAndUpdateModifierKey(keyCode: 60, isHeld: &isRightShiftHeld)
            }
        } else {
            // Release Shift keys
            releaseAndUpdateModifierKey(keyCode: 56, isHeld: &isLeftShiftHeld)
            releaseAndUpdateModifierKey(keyCode: 60, isHeld: &isRightShiftHeld)
        }
    }
    
    // Handle control key press/release with layout-aware remapping
    private func handleControlKeys(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.control) {
            let rawValue = modifiers.rawValue
            if (rawValue & 0x101) == 0x101 { // Left Control
                let targetKeyCode = getRemappedKeyCode(sourceKey: 59, sourceModifier: .control, isLeft: true)
                logger.log(content: "⌃ Left Control pressed: Original=59, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKey(keyCode: targetKeyCode, isHeld: &isLeftCtrlHeld, showIndex: true)
            } else if (rawValue & 0x2100) == 0x2100 { // Right Control
                let targetKeyCode = getRemappedKeyCode(sourceKey: 62, sourceModifier: .control, isLeft: false)
                logger.log(content: "⌃ Right Control pressed: Original=62, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKey(keyCode: targetKeyCode, isHeld: &isRightCtrlHeld, showIndex: true)
            }
        } else {
            // Release Control keys
            if isLeftCtrlHeld {
                let leftCtrlRemapped = getRemappedKeyCode(sourceKey: 59, sourceModifier: .control, isLeft: true)
                releaseAndUpdateModifierKey(keyCode: leftCtrlRemapped, isHeld: &isLeftCtrlHeld, logMessage: "⌃ Released left control key")
            }
            if isRightCtrlHeld {
                let rightCtrlRemapped = getRemappedKeyCode(sourceKey: 62, sourceModifier: .control, isLeft: false)
                releaseAndUpdateModifierKey(keyCode: rightCtrlRemapped, isHeld: &isRightCtrlHeld, logMessage: "⌃ Released right control key")
            }
        }
    }
    
    // Handle option/alt key press/release with layout-aware remapping
    private func handleOptionKeys(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.option) {
            let rawValue = modifiers.rawValue
            if (rawValue & 0x120) == 0x120 { // Left Option
                let targetKeyCode = getRemappedKeyCode(sourceKey: 58, sourceModifier: .option, isLeft: true)
                logger.log(content: "⌥ Left Option pressed: Original=58, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKey(keyCode: targetKeyCode, isHeld: &isLeftAltHeld, showIndex: true)
            } else if (rawValue & 0x140) == 0x140 { // Right Option
                let targetKeyCode = getRemappedKeyCode(sourceKey: 61, sourceModifier: .option, isLeft: false)
                logger.log(content: "⌥ Right Option pressed: Original=61, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKey(keyCode: targetKeyCode, isHeld: &isRightAltHeld, showIndex: true)
            }
        } else {
            // Release Option keys
            if isLeftAltHeld {
                let leftAltRemapped = getRemappedKeyCode(sourceKey: 58, sourceModifier: .option, isLeft: true)
                releaseAndUpdateModifierKey(keyCode: leftAltRemapped, isHeld: &isLeftAltHeld, logMessage: "⌥ Released left option key")
            }
            if isRightAltHeld {
                let rightAltRemapped = getRemappedKeyCode(sourceKey: 61, sourceModifier: .option, isLeft: false)
                releaseAndUpdateModifierKey(keyCode: rightAltRemapped, isHeld: &isRightAltHeld, logMessage: "⌥ Released right option key")
            }
        }
    }
    
    // Handle command key press/release with layout-aware remapping
    private func handleCommandKeys(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            let rawValue = modifiers.rawValue
            if (rawValue & 0x108) == 0x108 { // Left Command
                let targetKeyCode = getRemappedKeyCode(sourceKey: 55, sourceModifier: .command, isLeft: true)
                logger.log(content: "⌘ Left Command pressed: Original=55, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKeyWithoutState(keyCode: targetKeyCode, showIndex: true)
            } else if (rawValue & 0x110) == 0x110 { // Right Command
                let targetKeyCode = getRemappedKeyCode(sourceKey: 54, sourceModifier: .command, isLeft: false)
                logger.log(content: "⌘ Right Command pressed: Original=54, Target=\(targetKeyCode), Layout=\(currentKeyboardLayout.rawValue)")
                pressAndUpdateModifierKeyWithoutState(keyCode: targetKeyCode, showIndex: true)
            }
        } else {
            // Release Command keys
            let leftCmdRemapped = getRemappedKeyCode(sourceKey: 55, sourceModifier: .command, isLeft: true)
            let rightCmdRemapped = getRemappedKeyCode(sourceKey: 54, sourceModifier: .command, isLeft: false)
            
            if pressedKeys.contains(leftCmdRemapped) {
                releaseAndUpdateModifierKeyWithoutState(keyCode: leftCmdRemapped, logMessage: "⌘ Released left command key")
            }
            if pressedKeys.contains(rightCmdRemapped) {
                releaseAndUpdateModifierKeyWithoutState(keyCode: rightCmdRemapped, logMessage: "⌘ Released right command key")
            }
        }
    }
    
    // Handle caps lock key press
    private func handleCapsLockKey(_ modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.capsLock) {
            if !pressedKeys.contains(57) {
                if let index = pressedKeys.firstIndex(of: 255) {
                    pressedKeys[index] = 57
                    kbm.pressKey(keys: pressedKeys, modifiers: [])
                    pressedKeys[index] = 255
                    kbm.releaseKey(keys: pressedKeys)
                }
            }
            isCapsLockOn = true
        } else {
            if isCapsLockOn {
                isCapsLockOn = false
            }
        }
    }
    
    // Generic helper to press a modifier key and update its state
    private func pressAndUpdateModifierKey(keyCode: UInt16, isHeld: inout Bool?, showIndex: Bool = false) {
        if !pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: 255) {
                pressedKeys[index] = keyCode
                kbm.pressKey(keys: pressedKeys, modifiers: [])
                if showIndex {
                    logger.log(content: "   Pressed key \(keyCode) at pressedKeys index \(index)")
                }
            }
        }
        if isHeld != nil && !isHeld! {
            isHeld = true
        }
    }
    
    // Overload for non-optional Bool
    private func pressAndUpdateModifierKey(keyCode: UInt16, isHeld: inout Bool, showIndex: Bool = false) {
        if !pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: 255) {
                pressedKeys[index] = keyCode
                kbm.pressKey(keys: pressedKeys, modifiers: [])
                if showIndex {
                    logger.log(content: "   Pressed key \(keyCode) at pressedKeys index \(index)")
                }
            }
        }
        if !isHeld {
            isHeld = true
        }
    }
    
    // Generic helper to release a modifier key and update its state
    private func releaseAndUpdateModifierKey(keyCode: UInt16, isHeld: inout Bool?, logMessage: String = "") {
        if pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: keyCode) {
                pressedKeys[index] = 255
                kbm.releaseKey(keys: pressedKeys)
                if !logMessage.isEmpty {
                    logger.log(content: "\(logMessage) \(keyCode) from index \(index)")
                }
                if logMessage.contains("left control") {
                    logPressedKeysState()
                }
            }
        }
        if isHeld != nil && isHeld! {
            isHeld = false
        }
    }
    
    // Overload for non-optional Bool
    private func releaseAndUpdateModifierKey(keyCode: UInt16, isHeld: inout Bool, logMessage: String = "") {
        if pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: keyCode) {
                pressedKeys[index] = 255
                kbm.releaseKey(keys: pressedKeys)
                if !logMessage.isEmpty {
                    logger.log(content: "\(logMessage) \(keyCode) from index \(index)")
                }
                if logMessage.contains("left control") {
                    logPressedKeysState()
                }
            }
        }
        if isHeld {
            isHeld = false
        }
    }
    
    // Helper for command keys (which don't track state variables)
    private func pressAndUpdateModifierKeyWithoutState(keyCode: UInt16, showIndex: Bool = false) {
        if !pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: 255) {
                pressedKeys[index] = keyCode
                kbm.pressKey(keys: pressedKeys, modifiers: [])
                if showIndex {
                    logger.log(content: "   Pressed key \(keyCode) at pressedKeys index \(index)")
                }
            }
        }
    }
    
    // Helper for command keys (which don't track state variables)
    private func releaseAndUpdateModifierKeyWithoutState(keyCode: UInt16, logMessage: String = "") {
        if pressedKeys.contains(keyCode) {
            if let index = pressedKeys.firstIndex(of: keyCode) {
                pressedKeys[index] = 255
                kbm.releaseKey(keys: pressedKeys)
                if !logMessage.isEmpty {
                    logger.log(content: "\(logMessage) \(keyCode) from index \(index)")
                }
            }
        }
    }

    
    func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        kbm.pressKey(keys: keys, modifiers: modifiers)
    }

    func releaseKey(keys: [UInt16]) {
        kbm.releaseKey(keys: self.pressedKeys)
    }

    func monitorKeyboardEvents() {
        logger.log(content: "🎯 Starting keyboard event monitoring with layout: \(currentKeyboardLayout.rawValue)")
        
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            // Check if event should pass through to system windows
            if self.shouldPassThroughEvent(for: event) {
                return event
            }
            
            let modifiers = event.modifierFlags
            self.logModifierChange(modifiers)
            
            // Handle each modifier key type
            self.handleShiftKeys(modifiers)
            self.handleControlKeys(modifiers)
            self.handleOptionKeys(modifiers)
            self.handleCommandKeys(modifiers)
            self.handleCapsLockKey(modifiers)
            
            return nil
        }
        
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Check if event should pass through to system windows
            if self.shouldPassThroughEvent(for: event) {
                return event
            }
            
            // Handle key down
            return self.handleKeyDown(event)
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { event in
            // Check if event should pass through to system windows
            if self.shouldPassThroughEvent(for: event) {
                return event
            }
            
            // Handle key up
            return self.handleKeyUp(event)
        }
    }
    
    // MARK: - Key Press Handling
    
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
        let modifierDescription = modifierFlagsDescription(modifiers)
        
        // Log the key press with its keycode and detailed modifier analysis
        logger.log(content: "⌨️ Key pressed: keyCode=\(event.keyCode), modifiers=\(modifierDescription)")
        logger.log(content: "   Raw modifier flags: \(modifiers.rawValue)")
        logger.log(content: "   Contains .control: \(modifiers.contains(.control))")
        logger.log(content: "   Contains .command: \(modifiers.contains(.command))")
        logger.log(content: "   Contains .option: \(modifiers.contains(.option))")
        logger.log(content: "   Contains .shift: \(modifiers.contains(.shift))")
        
        // Apply layout-aware modifier remapping for key combinations
        let adjustedModifiers = getAdjustedModifiersForKeyboard(modifiers)
        
        // Handle special key combinations
        if handleSpecialKeyCombinations(event: event, modifiers: modifiers) {
            return nil // Event was consumed
        }
        
        // Handle ESC key for area selection and exit
        if handleEscapeKey(event) {
            // ESC handling doesn't consume the event, continue processing
        }
        
        // Add key to pressed keys array
        if !pressedKeys.contains(event.keyCode) {
            if let index = pressedKeys.firstIndex(of: 255) {
                pressedKeys[index] = event.keyCode
            }
        }
        
        kbm.pressKey(keys: pressedKeys, modifiers: adjustedModifiers)
        logger.log(content: "   📤 Sent to target: keys=\(pressedKeys.filter { $0 != 255 }), modifiers=\(adjustedModifiers)")
        return nil
    }
    
    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
        let modifierDescription = modifierFlagsDescription(modifiers)
        
        // Log the key release with its keycode
        logger.log(content: "Key released: keyCode=\(event.keyCode), modifiers=\(modifierDescription)")
        
        // Remove released key
        if let index = pressedKeys.firstIndex(of: event.keyCode) {
            pressedKeys[index] = 255
        }
        
        kbm.releaseKey(keys: pressedKeys)
        return nil
    }
    
    // Get adjusted modifiers based on keyboard layout
    private func getAdjustedModifiersForKeyboard(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var adjustedModifiers = modifiers
        if currentKeyboardLayout == .windows {
            // In Windows mode, remap modifiers for key combinations
            if modifiers.contains(.command) {
                adjustedModifiers.remove(.command)
                adjustedModifiers.insert(.control)
                logger.log(content: "   🪟 Windows mode: Remapped Cmd → Ctrl for key combination")
            } else if modifiers.contains(.control) {
                adjustedModifiers.remove(.control)
                adjustedModifiers.insert(.command)
                logger.log(content: "   🪟 Windows mode: Remapped Ctrl → Win for key combination")
            }
        }
        return adjustedModifiers
    }
    
    // Handle special key combinations like Cmd+V
    private func handleSpecialKeyCombinations(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Detect Cmd+V (paste) combination - with layout awareness
        if event.keyCode == 9 && (modifiers.contains(.command) || (currentKeyboardLayout == .windows && modifiers.contains(.control))) { // 'v' key with Command or Ctrl in Windows mode
            logger.log(content: "📋 Paste key combination detected (Layout: \(currentKeyboardLayout.rawValue))")
            let clipboardManager = DependencyContainer.shared.resolve(ClipboardManagerProtocol.self)
            clipboardManager.handlePasteRequest()
            return true // Consume the event to prevent default paste behavior
        }
        return false
    }
    
    // Handle ESC key for area selection and exit functionality
    private func handleEscapeKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            // Handle ESC key - cancel area selection if active
            if #available(macOS 12.3, *) {
                let ocrManager = DependencyContainer.shared.resolve(OCRManagerProtocol.self)
                if ocrManager.isAreaSelectionActive {
                    ocrManager.cancelAreaSelection()
                    return true
                }
            }
            
            // Check if we're in HID mouse mode and delegate to MouseManager
            if UserSettings.shared.MouseControl == .relativeHID {
                let mouseManager = MouseManager.shared
                mouseManager.handleEscapeKeyForHIDMode(isKeyDown: event.type == .keyDown)
                
                // Still send the ESC key to the target as well
                return false // Don't consume the event so it can be processed normally
            }
            
            // Handle exit functionality for non-HID modes
            if escKeyDownCounts == 0 {
                escKeyDownTimeStart = event.timestamp
                escKeyDownCounts = escKeyDownCounts + 1
            } else {
                if escKeyDownCounts >= 2 {
                    if event.timestamp - escKeyDownTimeStart < 2 {
                        AppStatus.isExit = true
                        AppStatus.isCursorHidden = false
                        AppStatus.isFouceWindow = false
                        NSCursor.unhide()

                        if let handler = AppStatus.eventHandler {
                            NSEvent.removeMonitor(handler)
                            eventHandler = nil
                        }
                    }
                    escKeyDownCounts = 0
                } else {
                    escKeyDownCounts = escKeyDownCounts + 1
                }
            }
            return true
        }
        return false
    }
    
    // Helper function to get all currently active modifiers for a character
    // Includes held Ctrl/Alt keys and adds shift if the character requires it
    func getCurrentModifiersForCharacter(_ char: Character) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        
        // Add Ctrl modifiers if held (with remapping consideration)
        if isLeftCtrlHeld || isRightCtrlHeld {
            if currentKeyboardLayout == .windows {
                // In Windows mode, host Ctrl is mapped to target Ctrl (no change needed)
                modifiers.insert(.control)
            } else {
                modifiers.insert(.control)
            }
        }
        
        // Add Alt modifiers if held (with remapping consideration)
        if isLeftAltHeld || isRightAltHeld {
            if currentKeyboardLayout == .windows {
                // In Windows mode, host Option is mapped to target Alt (no change needed)
                modifiers.insert(.option)
            } else {
                modifiers.insert(.option)
            }
        }
        
        // Add shift modifier if needed for character (uppercase letters or special shifted symbols)
        if char.isUppercase || KeyboardManager.SHIFT_KEYS.contains(String(char)) {
            modifiers.insert(.shift)
        }
        
        return modifiers
    }
    
    // Helper function to get currently held modifier keys for special keys
    func getCurrentModifiersForSpecialKey() -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        
        // Add Ctrl modifiers if held (with remapping consideration)
        if isLeftCtrlHeld || isRightCtrlHeld {
            if currentKeyboardLayout == .windows {
                // In Windows mode, host Ctrl is mapped to target Ctrl (no change needed)
                modifiers.insert(.control)
            } else {
                modifiers.insert(.control)
            }
        }
        
        // Add Alt modifiers if held (with remapping consideration)
        if isLeftAltHeld || isRightAltHeld {
            if currentKeyboardLayout == .windows {
                // In Windows mode, host Option is mapped to target Alt (no change needed)
                modifiers.insert(.option)
            } else {
                modifiers.insert(.option)
            }
        }
        
        // Add Shift modifiers if held
        if isLeftShiftHeld || isRightShiftHeld {
            modifiers.insert(.shift)
        }
        
        return modifiers
    }
    
    // MARK: - Modifier Key Release for Paste Operations
    
    /// Releases all currently held modifier keys to ensure clean paste operations
    private func releaseAllModifierKeys() {
        logger.log(content: "🔓 Releasing all modifier keys before paste operation")
        
        // Release all currently held modifier keys
        if isLeftShiftHeld {
            releaseAndUpdateModifierKey(keyCode: 56, isHeld: &isLeftShiftHeld, logMessage: "Released left shift for paste")
        }
        if isRightShiftHeld {
            releaseAndUpdateModifierKey(keyCode: 60, isHeld: &isRightShiftHeld, logMessage: "Released right shift for paste")
        }
        if isLeftCtrlHeld {
            let leftCtrlRemapped = getRemappedKeyCode(sourceKey: 59, sourceModifier: .control, isLeft: true)
            releaseAndUpdateModifierKey(keyCode: leftCtrlRemapped, isHeld: &isLeftCtrlHeld, logMessage: "Released left ctrl for paste")
        }
        if isRightCtrlHeld {
            let rightCtrlRemapped = getRemappedKeyCode(sourceKey: 62, sourceModifier: .control, isLeft: false)
            releaseAndUpdateModifierKey(keyCode: rightCtrlRemapped, isHeld: &isRightCtrlHeld, logMessage: "Released right ctrl for paste")
        }
        if isLeftAltHeld {
            let leftAltRemapped = getRemappedKeyCode(sourceKey: 58, sourceModifier: .option, isLeft: true)
            releaseAndUpdateModifierKey(keyCode: leftAltRemapped, isHeld: &isLeftAltHeld, logMessage: "Released left alt for paste")
        }
        if isRightAltHeld {
            let rightAltRemapped = getRemappedKeyCode(sourceKey: 61, sourceModifier: .option, isLeft: false)
            releaseAndUpdateModifierKey(keyCode: rightAltRemapped, isHeld: &isRightAltHeld, logMessage: "Released right alt for paste")
        }
        
        // Release command keys if they're being held (they don't have state variables but might be in pressedKeys)
        let leftCmdRemapped = getRemappedKeyCode(sourceKey: 55, sourceModifier: .command, isLeft: true)
        let rightCmdRemapped = getRemappedKeyCode(sourceKey: 54, sourceModifier: .command, isLeft: false)
        
        if pressedKeys.contains(leftCmdRemapped) {
            releaseAndUpdateModifierKeyWithoutState(keyCode: leftCmdRemapped, logMessage: "Released left command for paste")
        }
        if pressedKeys.contains(rightCmdRemapped) {
            releaseAndUpdateModifierKeyWithoutState(keyCode: rightCmdRemapped, logMessage: "Released right command for paste")
        }
        
        // Send a general key release to ensure all modifiers are cleared on the target
        kbm.releaseKey(keys: pressedKeys)
        
        // Small delay to ensure the release events are processed
        Thread.sleep(forTimeInterval: 0.01)
        
        logger.log(content: "✅ All modifier keys released, ready for paste operation")
    }

    func sendTextToKeyboard(text:String) {
        logger.log(content: "Sending text to keyboard: \(text)")
        
        // Release all modifier keys before starting paste operation
        releaseAllModifierKeys()
        
        // Send text to keyboard
        let textArray = Array(text.utf8) // Convert string to UTF-8 byte array
        for charString in textArray { // Iterate through each character's UTF-8 encoding
            let key:UInt16 = UInt16(kbm.fromCharToKeyCode(char: UInt16(charString))) // Convert character to keyboard key code
            let char = Character(String(UnicodeScalar(charString))) // Convert UTF-8 encoding back to character
            
            // Get modifiers for character including currently held Ctrl/Alt and shift if needed
            let modifiers = getCurrentModifiersForCharacter(char)
            
            kbm.pressKey(keys: [key], modifiers: modifiers) // Press the corresponding key and modifier keys
            Thread.sleep(forTimeInterval: 0.005) // Wait for 5 milliseconds
            kbm.releaseKey(keys: self.pressedKeys) // Release all pressed keys
            Thread.sleep(forTimeInterval: 0.01) // Wait for 10 milliseconds
        }
    }


    func sendSpecialKeyToKeyboard(code: KeyboardMapper.SpecialKey) {
        if code == KeyboardMapper.SpecialKey.CtrlAltDel {
            if let key = kbm.fromSpecialKeyToKeyCode(code: code) {
                // In Windows mode, this should work as expected
                // In Mac mode, this combination might not be as useful, but send it anyway
                kbm.pressKey(keys: [key], modifiers: [.option, .control])
                Thread.sleep(forTimeInterval: 0.005) // 1 ms
                kbm.releaseKey(keys: self.pressedKeys)
                Thread.sleep(forTimeInterval: 0.01) // 5 ms
            }
        
        } else if code == KeyboardMapper.SpecialKey.CmdSpace {
            if let key = kbm.fromSpecialKeyToKeyCode(code: code) {
                // Apply keyboard layout remapping for this combination
                switch currentKeyboardLayout {
                case .windows:
                    // In Windows mode, Cmd should be sent as Ctrl (for Windows shortcuts)
                    kbm.pressKey(keys: [key], modifiers: [.control])
                case .mac:
                    // In Mac mode, keep as Command
                    kbm.pressKey(keys: [key], modifiers: [.command])
                }
                Thread.sleep(forTimeInterval: 0.005) // 1 ms
                kbm.releaseKey(keys: self.pressedKeys)
                Thread.sleep(forTimeInterval: 0.01) // 5 ms
            }
        }
        else{
            if let key = kbm.fromSpecialKeyToKeyCode(code: code) {
                // Get currently held modifier keys for special keys
                let modifiers = getCurrentModifiersForSpecialKey()
                kbm.pressKey(keys: [key], modifiers: modifiers)
                Thread.sleep(forTimeInterval: 0.005) // 1 ms
                kbm.releaseKey(keys: self.pressedKeys)
                Thread.sleep(forTimeInterval: 0.01) // 5 ms
            }
        }
    }
}

// MARK: - KeyboardManagerProtocol Implementation

extension KeyboardManager {
    func sendKeyboardInput(_ input: KeyboardInput) {
        // Convert protocol input to existing method call
        // Implementation would depend on existing keyboard input methods
    }
    
    func sendSpecialKey(_ key: SpecialKey) {
        // Convert protocol special key to existing method call
        // Implementation would depend on existing special key methods
    }
    
    func executeKeyboardMacro(_ macro: KeyboardMacro) {
        // Implementation for macro execution
        for input in macro.sequence {
            sendKeyboardInput(input)
            Thread.sleep(forTimeInterval: 0.01) // Small delay between keys
        }
    }
    
    func releaseAllModifierKeysForPaste() {
        // Call the private implementation method
        releaseAllModifierKeys()
    }
}
