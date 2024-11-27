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

class KeyboardManager {
    static let SHIFT_KEYS = ["~", "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?"]
    static let shared = KeyboardManager()

    var escKeyDownCounts = 0
    var escKeyDownTimeStart = 0.0
    
    let kbm = KeyboardMapper()
    
    // 新增一个数组用于存储同时按下的键
    var pressedKeys: [UInt16] = [255,255,255,255,255,255]
    
    init() {
        monitorKeyboardEvents()
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
            let capsLockState = modifiers.contains(.capsLock) ? "ON" : "OFF"
            Logger.shared.log(content: "Modifier flags changed: \(modifierDescription), CapsLock: \(capsLockState)")
            
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
            if modifiers.contains(.capsLock) || modifiers.rawValue == 256 {
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
    
    func needShiftWhenPaste(char:Character) -> Bool {
        return char.isUppercase || KeyboardManager.SHIFT_KEYS.contains(String(char))
    }
    
    func sendTextToKeyboard(text:String) {
        // sent the text to keyboard
        let textArray = Array(text.utf8)
        for charString in textArray {
            let key:UInt16 = UInt16(kbm.fromCharToKeyCode(char: UInt16(charString)))
            let char = Character(String(UnicodeScalar(charString)))
            let modifiers: NSEvent.ModifierFlags = needShiftWhenPaste(char: char) ? [.shift] : []
            kbm.pressKey(keys: [key], modifiers: modifiers)
            Thread.sleep(forTimeInterval: 0.005) // 1 ms
            kbm.releaseKey(keys: self.pressedKeys)
            Thread.sleep(forTimeInterval: 0.01) // 5 ms
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
        }else{
            if let key = kbm.fromSpecialKeyToKeyCode(code: code) {
                kbm.pressKey(keys: [key], modifiers: [])
                Thread.sleep(forTimeInterval: 0.005) // 1 ms
                kbm.releaseKey(keys: self.pressedKeys)
                Thread.sleep(forTimeInterval: 0.01) // 5 ms
            }
        }
    }
}
