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
        
        return descriptions.isEmpty ? "None" : descriptions.joined(separator: ", ")
    }

    
    func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        kbm.pressKey(keys: keys, modifiers: modifiers)
    }

    func releaseKey(keys: [UInt16]) {
        kbm.releaseKey(keys: self.pressedKeys)
    }

    func monitorKeyboardEvents() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let modifiers = event.modifierFlags
            
            let capsLockIsOn = event.modifierFlags.contains(.capsLock)
            
            print("✈️✈️✈️✈️✈️✈️")
            print(capsLockIsOn)
            if !capsLockIsOn {
                if let index = self.pressedKeys.firstIndex(of: 57) {
                    self.pressedKeys[index] = 255
                }
            }
            //print(event.keyCode)
            print("✈️✈️✈️✈️✈️✈️")
            
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
            
            
            // Logger.shared.log(content: "🔥🔥🔥key pressed: \(event.keyCode)")
            // 先判断是否功能键ctrl alt option command
            // 例如 keycode 为：56，60，59，62，58，55，54 都不处理
            let functionKeyCodes: [UInt16] = [56, 60, 59, 62, 58, 55, 54]
            if !functionKeyCodes.contains(event.keyCode) {
                // 先检查按键是否已经存在，如果按键不在数组中，则添加
                if !self.pressedKeys.contains(event.keyCode) {
                    // 记录按下的键
                    if let index = self.pressedKeys.firstIndex(of: 255) {
                        self.pressedKeys[index] = event.keyCode
                    }
                }
            }
            
            
            self.kbm.pressKey(keys: self.pressedKeys, modifiers: modifiers)
            return nil
        }

        NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { event in
            let modifiers = event.modifierFlags
            let modifierDescription = self.modifierFlagsDescription(modifiers)
            
            // 移除释放的键
            print("🤮🤮🤮\(event.keyCode)")
            if let index = self.pressedKeys.firstIndex(of: event.keyCode) {
                self.pressedKeys[index] = 255
            }
            print(self.pressedKeys)
            
            self.kbm.releaseKey(keys: self.pressedKeys)
            Logger.shared.log(content: "Modifiers: \(modifierDescription). Key release.")
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
