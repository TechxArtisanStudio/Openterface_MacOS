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

class KeyboardManager: ObservableObject {
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
    
    // Keyboard layout enumeration for modifier key behavior
    enum KeyboardLayout: String, CaseIterable {
        case windows = "windows"
        case mac = "mac"
    }
    
    // Current keyboard layout
    @Published var currentKeyboardLayout: KeyboardLayout = .mac
    
    // Function to toggle between Windows and Mac keyboard layouts
    func toggleKeyboardLayout() {
        switch currentKeyboardLayout {
        case .mac:
            currentKeyboardLayout = .windows
        case .windows:
            currentKeyboardLayout = .mac
        }
        Logger.shared.log(content: "Keyboard layout switched to: \(currentKeyboardLayout.rawValue)")
    }
    
    // Function to get modifier key labels based on layout
    func getModifierKeyLabel() -> String {
        switch currentKeyboardLayout {
        case .windows:
            return "Ctrl"
        case .mac:
            return "⌘"
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

    
    func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        kbm.pressKey(keys: keys, modifiers: modifiers)
    }

    func releaseKey(keys: [UInt16]) {
        kbm.releaseKey(keys: self.pressedKeys)
    }

    func monitorKeyboardEvents() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let modifiers = event.modifierFlags
            let modifierDescription = self.modifierFlagsDescription(modifiers)
            Logger.shared.log(content: "Modifier flags changed: \(modifierDescription), CapsLock toggle: \(modifiers.contains(.capsLock))")
            
            // Handle Shift keys
            if modifiers.contains(.shift) {
                let rawValue = modifiers.rawValue
                if rawValue & 0x102 == 0x102 { // Left Shift
                    if !self.pressedKeys.contains(56) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 56
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                } else if (rawValue & 0x104 == 0x104) { // Right Shift
                    if !self.pressedKeys.contains(60) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 60
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                }
            } else {
                // Release Shift keys
                if self.pressedKeys.contains(56) {
                    if let index = self.pressedKeys.firstIndex(of: 56) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
                if self.pressedKeys.contains(60) {
                    if let index = self.pressedKeys.firstIndex(of: 60) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
            }
            
            // Handle Control keys
            if modifiers.contains(.control) {
                let rawValue = modifiers.rawValue
                if (rawValue & 0x101) == 0x101 { // Left Control
                    if !self.pressedKeys.contains(59) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 59
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                } else if (rawValue & 0x2100) == 0x2100 { // Right Control
                    if !self.pressedKeys.contains(62) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 62
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                }
            } else {
                // Release Control keys
                if self.pressedKeys.contains(59) {
                    if let index = self.pressedKeys.firstIndex(of: 59) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
                if self.pressedKeys.contains(62) {
                    if let index = self.pressedKeys.firstIndex(of: 62) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
            }
            
            // Handle Option/Alt keys
            if modifiers.contains(.option) {
                let rawValue = modifiers.rawValue
                if (rawValue & 0x120) == 0x120 { // Left Option
                    if !self.pressedKeys.contains(58) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 58
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                } else if (rawValue & 0x140) == 0x140 { // Right Option
                    if !self.pressedKeys.contains(61) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 61
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                }
            } else {
                // Release Option keys
                if self.pressedKeys.contains(58) {
                    if let index = self.pressedKeys.firstIndex(of: 58) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
                if self.pressedKeys.contains(61) {
                    if let index = self.pressedKeys.firstIndex(of: 61) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
            }
            
            // Handle Command keys
            if modifiers.contains(.command) {
                let rawValue = modifiers.rawValue
                if (rawValue & 0x108) == 0x108 { // Left Command
                    if !self.pressedKeys.contains(55) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 55
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                } else if (rawValue & 0x110) == 0x110 { // Right Command
                    if !self.pressedKeys.contains(54) {
                        if let index = self.pressedKeys.firstIndex(of: 255) {
                            self.pressedKeys[index] = 54
                            self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])
                        }
                    }
                }
            } else {
                // Release Command keys
                if self.pressedKeys.contains(55) {
                    if let index = self.pressedKeys.firstIndex(of: 55) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
                if self.pressedKeys.contains(54) {
                    if let index = self.pressedKeys.firstIndex(of: 54) {
                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
            }
            
            // Handle capsLock keys
            if modifiers.contains(.capsLock) {
                if !self.pressedKeys.contains(57) {
                    if let index = self.pressedKeys.firstIndex(of: 255) {
                        self.pressedKeys[index] = 57
                        self.kbm.pressKey(keys: self.pressedKeys, modifiers: [])

                        self.pressedKeys[index] = 255
                        self.kbm.releaseKey(keys: self.pressedKeys)
                    }
                }
            }
            return nil
        }
        
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags
            let modifierDescription = self.modifierFlagsDescription(modifiers)
            
            // Log the key press with its keycode
            Logger.shared.log(content: "Key pressed: keyCode=\(event.keyCode), modifiers=\(modifierDescription)")
            
            if event.keyCode == 53 {
                for w in NSApplication.shared.windows.filter({ $0.title == "Area Selector".local }) {
                    w.close()
                    AppStatus.isAreaOCRing = false
                }
                
                if self.escKeyDownCounts == 0 {
                    self.escKeyDownTimeStart = event.timestamp
                    self.escKeyDownCounts = self.escKeyDownCounts + 1
                }
                else
                {
                    if self.escKeyDownCounts >= 2 {
                        if event.timestamp - self.escKeyDownTimeStart < 2 {

                            AppStatus.isExit = true
                            AppStatus.isCursorHidden = false
                            AppStatus.isFouceWindow = false
                            NSCursor.unhide()

                            if let handler = AppStatus.eventHandler {
                                NSEvent.removeMonitor(handler)
                                eventHandler = nil
                                // AppStatus.isExit = true
                            }
                        }
                        self.escKeyDownCounts = 0
                    }
                    else
                    {
                        self.escKeyDownCounts = self.escKeyDownCounts + 1
                    }
                }
            }
            
            if !self.pressedKeys.contains(event.keyCode) {
                if let index = self.pressedKeys.firstIndex(of: 255) {
                    self.pressedKeys[index] = event.keyCode
                }
            }
            
            self.kbm.pressKey(keys: self.pressedKeys, modifiers: modifiers)
            return nil
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { event in
            let modifiers = event.modifierFlags
            let modifierDescription = self.modifierFlagsDescription(modifiers)
            
            // Log the key release with its keycode
            Logger.shared.log(content: "Key released: keyCode=\(event.keyCode), modifiers=\(modifierDescription)")
            
            // 移除释放的键
            if let index = self.pressedKeys.firstIndex(of: event.keyCode) {
                self.pressedKeys[index] = 255
            }
            
            self.kbm.releaseKey(keys: self.pressedKeys)
            return nil
        }
    }
    
    // Helper function to get all currently active modifiers for a character
    // Includes held Ctrl/Alt keys and adds shift if the character requires it
    func getCurrentModifiersForCharacter(_ char: Character) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        
        // Add Ctrl modifiers if held
        if isLeftCtrlHeld || isRightCtrlHeld {
            modifiers.insert(.control)
        }
        
        // Add Alt modifiers if held
        if isLeftAltHeld || isRightAltHeld {
            modifiers.insert(.option)
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
        
        // Add Ctrl modifiers if held
        if isLeftCtrlHeld || isRightCtrlHeld {
            modifiers.insert(.control)
        }
        
        // Add Alt modifiers if held
        if isLeftAltHeld || isRightAltHeld {
            modifiers.insert(.option)
        }
        
        // Add Shift modifiers if held
        if isLeftShiftHeld || isRightShiftHeld {
            modifiers.insert(.shift)
        }
        
        return modifiers
    }
    
    func sendTextToKeyboard(text:String) {
        Logger.shared.log(content: "Sending text to keyboard: \(text)")
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
                kbm.pressKey(keys: [key], modifiers: [.option, .control])
                Thread.sleep(forTimeInterval: 0.005) // 1 ms
                kbm.releaseKey(keys: self.pressedKeys)
                Thread.sleep(forTimeInterval: 0.01) // 5 ms
            }
        
        } else if code == KeyboardMapper.SpecialKey.CmdSpace {
            if let key = kbm.fromSpecialKeyToKeyCode(code: code) {
                kbm.pressKey(keys: [key] , modifiers: [.command])
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
