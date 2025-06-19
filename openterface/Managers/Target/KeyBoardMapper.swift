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

import Darwin
import AppKit
import Carbon.HIToolbox

class KeyboardMapper {
    let spm = SerialPortManager.shared
    
    let keyCodeMapping: [UInt16: UInt8] = [
        // 字母键
        UInt16(kVK_ANSI_A): 0x04, // a
        UInt16(kVK_ANSI_B): 0x05, // b
        UInt16(kVK_ANSI_C): 0x06, // c
        UInt16(kVK_ANSI_D): 0x07, // d
        UInt16(kVK_ANSI_E): 0x08, // e
        UInt16(kVK_ANSI_F): 0x09, // f
        UInt16(kVK_ANSI_G): 0x0A, // g
        UInt16(kVK_ANSI_H): 0x0B, // h
        UInt16(kVK_ANSI_I): 0x0C, // i
        UInt16(kVK_ANSI_J): 0x0D, // j
        UInt16(kVK_ANSI_K): 0x0E, // k
        UInt16(kVK_ANSI_L): 0x0F, // l
        UInt16(kVK_ANSI_M): 0x10, // m
        UInt16(kVK_ANSI_N): 0x11, // n
        UInt16(kVK_ANSI_O): 0x12, // o
        UInt16(kVK_ANSI_P): 0x13, // p
        UInt16(kVK_ANSI_Q): 0x14, // q
        UInt16(kVK_ANSI_R): 0x15, // r
        UInt16(kVK_ANSI_S): 0x16, // s
        UInt16(kVK_ANSI_T): 0x17, // t
        UInt16(kVK_ANSI_U): 0x18, // u
        UInt16(kVK_ANSI_V): 0x19, // v
        UInt16(kVK_ANSI_W): 0x1A, // w
        UInt16(kVK_ANSI_X): 0x1B, // x
        UInt16(kVK_ANSI_Y): 0x1C, // y
        UInt16(kVK_ANSI_Z): 0x1D, // z
        
        // 数字键
        UInt16(kVK_ANSI_1): 0x1E, UInt16(kVK_ANSI_Keypad1): 0x59, // 1
        UInt16(kVK_ANSI_2): 0x1F, UInt16(kVK_ANSI_Keypad2): 0x5A, // 2
        UInt16(kVK_ANSI_3): 0x20, UInt16(kVK_ANSI_Keypad3): 0x5B, // 3
        UInt16(kVK_ANSI_4): 0x21, UInt16(kVK_ANSI_Keypad4): 0x5C, // 4
        UInt16(kVK_ANSI_5): 0x22, UInt16(kVK_ANSI_Keypad5): 0x5D, // 5
        UInt16(kVK_ANSI_6): 0x23, UInt16(kVK_ANSI_Keypad6): 0x5E, // 6
        UInt16(kVK_ANSI_7): 0x24, UInt16(kVK_ANSI_Keypad7): 0x5F, // 7
        UInt16(kVK_ANSI_8): 0x25, UInt16(kVK_ANSI_Keypad8): 0x60, // 8
        UInt16(kVK_ANSI_9): 0x26, UInt16(kVK_ANSI_Keypad9): 0x61, // 9
        UInt16(kVK_ANSI_0): 0x27, UInt16(kVK_ANSI_Keypad0): 0x62, // 0

        
        // 功能键和特殊键
        UInt16(kVK_Return): 0x28, UInt16(kVK_ANSI_KeypadEnter): 0x58, // enter
        UInt16(kVK_Escape): 0x29, // esc
        UInt16(kVK_Delete): 0x2A, // backspace
        UInt16(kVK_Tab): 0x2B,  // tab
        UInt16(kVK_Space): 0x2C, // space
        UInt16(kVK_ANSI_Minus): 0x2D, // -
        UInt16(kVK_ANSI_Equal): 0x2E, // =
        UInt16(kVK_ANSI_LeftBracket): 0x2F, // [
        UInt16(kVK_ANSI_RightBracket): 0x30, // ]
        UInt16(kVK_ANSI_Backslash): 0x31, // \
        UInt16(kVK_ANSI_Semicolon): 0x33, // ;
        UInt16(kVK_ANSI_Quote): 0x34, // '
        UInt16(kVK_ANSI_Grave): 0x35, // `
        UInt16(kVK_ANSI_Comma): 0x36, // ,
        UInt16(kVK_ANSI_Period): 0x37, UInt16(kVK_ANSI_KeypadDecimal): 0x63, // .
        UInt16(kVK_ANSI_Slash): 0x38, // /
        UInt16(kVK_CapsLock): 0x39, // caps lock
        
        // F键
        UInt16(kVK_F1): 0x3A, // f1
        UInt16(kVK_F2): 0x3B, // f2
        UInt16(kVK_F3): 0x3C, // f3
        UInt16(kVK_F4): 0x3D, // f4
        UInt16(kVK_F5): 0x3E, // f5
        UInt16(kVK_F6): 0x3F, // f6
        UInt16(kVK_F7): 0x40, // f7
        UInt16(kVK_F8): 0x41, // f8
        UInt16(kVK_F9): 0x42, // f9
        UInt16(kVK_F10): 0x43, // f10
        UInt16(kVK_F11): 0x44, // f11
        UInt16(kVK_F12): 0x45, // f12
        
        // 编辑键和导航键
        UInt16(kVK_Help): 0x49, // Insert/Help
        UInt16(kVK_Home): 0x4A, // Home
        UInt16(kVK_PageUp): 0x4B, // Page Up
        UInt16(kVK_ForwardDelete): 0x4C, // Forward Delete
        UInt16(kVK_End): 0x4D, // End
        UInt16(kVK_PageDown): 0x4E, // Page Down
        UInt16(kVK_RightArrow): 0x4F, // Right Arrow
        UInt16(kVK_LeftArrow): 0x50, // Left Arrow
        UInt16(kVK_DownArrow): 0x51, // Down Arrow
        UInt16(kVK_UpArrow): 0x52, // Up Arrow
        
        // 数字键盘
        UInt16(kVK_ANSI_KeypadClear): 0x53, // Numlock/Clear
        UInt16(kVK_ANSI_KeypadDivide): 0x54, // Keypad /
        UInt16(kVK_ANSI_KeypadMultiply): 0x55, // Keypad *
        UInt16(kVK_ANSI_KeypadMinus): 0x56, // Keypad -
        UInt16(kVK_ANSI_KeypadPlus): 0x57, // Keypad +
        
        // 其他功能键
        UInt16(kVK_F13): 0x46, // Print Screen (映射到F13)
        UInt16(kVK_F14): 0x65, // App (映射到F14)
        
        // 修饰键
        UInt16(kVK_Shift): 0xE1, // Left Shift
        UInt16(kVK_RightShift): 0xE5, // Right Shift
        UInt16(kVK_Control): 0xE0, // Left Ctrl
        UInt16(kVK_RightControl): 0xE4, // Right Ctrl
        UInt16(kVK_Option): 0xE2, // Left Option, Left Alt
        UInt16(kVK_RightOption): 0xE6, // Right Option, Right Alt
        UInt16(kVK_Command): 0xE3, // Left Command, Left Win
        UInt16(kVK_RightCommand): 0xE7,  // Right Command, Right Win
        
        //
        UInt16(kVK_ISO_Section): 0x64, // ISO Section

    ]

    let charMapping: [UInt16: UInt8] = [
        "a".utf16.first!: 0, "A".utf16.first!: 0,
        "b".utf16.first!: 11, "B".utf16.first!: 11,
        "c".utf16.first!: 8, "C".utf16.first!: 8,
        "d".utf16.first!: 2, "D".utf16.first!: 2,
        "e".utf16.first!: 14, "E".utf16.first!: 14,
        "f".utf16.first!: 3, "F".utf16.first!: 3,
        "g".utf16.first!: 5, "G".utf16.first!: 5,
        "h".utf16.first!: 4, "H".utf16.first!: 4,
        "i".utf16.first!: 34, "I".utf16.first!: 34,
        "j".utf16.first!: 38, "J".utf16.first!: 38,
        "k".utf16.first!: 40, "K".utf16.first!: 40,
        "l".utf16.first!: 37, "L".utf16.first!: 37,
        "m".utf16.first!: 46, "M".utf16.first!: 46,
        "n".utf16.first!: 45, "N".utf16.first!: 45,
        "o".utf16.first!: 31, "O".utf16.first!: 31,
        "p".utf16.first!: 35, "P".utf16.first!: 35,
        "q".utf16.first!: 12, "Q".utf16.first!: 12,
        "r".utf16.first!: 15, "R".utf16.first!: 15,
        "s".utf16.first!: 1, "S".utf16.first!: 1,
        "t".utf16.first!: 17, "T".utf16.first!: 17,
        "u".utf16.first!: 32, "U".utf16.first!: 32,
        "v".utf16.first!: 9, "V".utf16.first!: 9,
        "w".utf16.first!: 13, "W".utf16.first!: 13,
        "x".utf16.first!: 7, "X".utf16.first!: 7,
        "y".utf16.first!: 16, "Y".utf16.first!: 16,
        "z".utf16.first!: 6, "Z".utf16.first!: 6,
        "1".utf16.first!: 18, "!".utf16.first!: 18,
        "2".utf16.first!: 19, "@".utf16.first!: 19,
        "3".utf16.first!: 20, "#".utf16.first!: 20,
        "4".utf16.first!: 21, "$".utf16.first!: 21,
        "5".utf16.first!: 23, "%".utf16.first!: 23,
        "6".utf16.first!: 22, "^".utf16.first!: 22,
        "7".utf16.first!: 26, "&".utf16.first!: 26,
        "8".utf16.first!: 28, "*".utf16.first!: 28,
        "9".utf16.first!: 25, "(".utf16.first!: 25,
        "0".utf16.first!: 29, ")".utf16.first!: 29,
        "\r".utf16.first!: 36, "\n".utf16.first!: 36,
        "\t".utf16.first!: 48, 
        " ".utf16.first!: 49,
        "-".utf16.first!: 27, "_".utf16.first!: 27,
        "=".utf16.first!: 24, "+".utf16.first!: 24,
        "[".utf16.first!: 33, "{".utf16.first!: 33,
        "]".utf16.first!: 30, "}".utf16.first!: 30,
        "\\".utf16.first!: 42, "|".utf16.first!: 42,
        ";".utf16.first!: 41, ":".utf16.first!: 41,
        "'".utf16.first!: 39, "\"".utf16.first!: 39,
        "`".utf16.first!: 50, "~".utf16.first!: 50,
        ",".utf16.first!: 43, "<".utf16.first!: 43,
        ".".utf16.first!: 47, ">".utf16.first!: 47,
        "/".utf16.first!: 44 , "?".utf16.first!: 44
    ]
    
    enum SpecialKey: String {
        case F1 = "F1"
        case F2 = "F2"
        case F3 = "F3"
        case F4 = "F4"
        case F5 = "F5"
        case F6 = "F6"
        case F7 = "F7"
        case F8 = "F8"
        case F9 = "F9"
        case F10 = "F10"
        case F11 = "F11"
        case F12 = "F12"
        case CtrlAltDel = "CAD"
        case delete = "delete"
        case windowsWin = "Win"
        case CmdSpace = "CmdSpace"
        case esc = "esc"
        case space = "space"
        case enter = "enter"
        case leftShift = "leftShift"
        case rightShift = "rightShift"
        case leftCtrl = "leftCtrl"
        case rightCtrl = "rightCtrl"
        case leftAlt = "leftAlt"
        case rightAlt = "rightAlt"
        case win = "win"
        case tab = "tab"
        case backspace = "backspace"
        case capsLock = "capsLock"
        case insert = "insert"
        case home = "home"
        case pageUp = "pageUp"
        case forwardDelete = "forwardDelete"
        case end = "end"
        case pageDown = "pageDown"
        case arrowRight = "arrowRight"
        case arrowLeft = "arrowLeft"
        case arrowDown = "arrowDown"
        case arrowUp = "arrowUp"
        case numLock = "numLock"
    }
    
    var charToKeyCode: [UInt16: UInt8] = [:]

    init() {
        for (key, value) in keyCodeMapping {
            if let unicodeScalar = UnicodeScalar(key) {
                charToKeyCode[UInt16(unicodeScalar.value)] = value
            }
        }
    }

    func fromCharToKeyCode(char: UInt16) -> UInt8{
        // map the char to keycode
        return charMapping[char] ?? 0x00
    }
    
    let funcKeys: [String: UInt8] = [
        "LeftCtrl": 0x01,
        "LeftShift": 0x02,
        "LeftAlt": 0x04,
        "LeftWin": 0x08,
        
        "RightAlt": 0x40,
        "RightShift": 0x20,
        "RightCtrl": 0x10,
        "RightWin": 0x80,
    ]

    func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        sendKeyData(keyCode: keys, isRelease: false, modifiers: modifiers)
        Logger.shared.log(content: "Send Key Data: \(keys)")
    }
    
    func releaseKey(keys: [UInt16]) {
        sendKeyData(keyCode: keys, isRelease: true, modifiers: [])
    }
    

    func sendKeyData(keyCode: [UInt16], isRelease: Bool, modifiers: NSEvent.ModifierFlags) {
        var keyDat: [UInt8] = [0x57, 0xAB, 0x00, 0x02, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        for (index, kc) in keyCode.prefix(6).enumerated() {
            if let mappedValue = keyCodeMapping[kc] {
                keyDat[7 + index] = mappedValue
            } else {
                Logger.shared.log(content: "Warning: \(kc) is not mapped.")
            }
        }

        var combinedModifiers: UInt8 = 0

        // Actual specific rawValue for left and right modifiers
        // let leftShiftValue: UInt = 0x00020102
        let rightShiftValue: UInt = 0x00020104
        
        // let leftControlValue: UInt = 0x00040101
        let rightControlValue: UInt = 0x00042100
        
        // let leftCommandValue: UInt = 0x00100108
        let rightCommandValue: UInt = 0x00100110
        
        // let leftOptionValue: UInt = 0x00080120
        let rightOptionValue: UInt = 0x00080140
        
        let rawValue = modifiers.rawValue

        if modifiers.contains(.shift) {
            if (rawValue & rightShiftValue) == rightShiftValue {
                combinedModifiers |= funcKeys["RightShift"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftShift"] ?? 0x00
            }
        }
        
        if modifiers.contains(.control) {
            if (rawValue & rightControlValue) == rightControlValue {
                combinedModifiers |= funcKeys["RightCtrl"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftCtrl"] ?? 0x00
            }
        }
        
        if modifiers.contains(.option) {
            if (rawValue & rightOptionValue) == rightOptionValue {
                combinedModifiers |= funcKeys["RightAlt"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftAlt"] ?? 0x00
            }
        }
        
        if modifiers.contains(.command) {
            if (rawValue & rightCommandValue) == rightCommandValue {
                combinedModifiers |= funcKeys["RightWin"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftWin"] ?? 0x00
            }
        }

        keyDat[5] = combinedModifiers
        
        //        if isRelease {
        //            keyDat[7] = 0x00
        //        }
        
        keyDat[13] = calculateChecksum(data: keyDat)
        //
        // let _ = self.spm.writeByte(data:keyDat)
        //
        let _ = spm.sendCommand(command: keyDat)
    }
    
    func calculateChecksum(data: [UInt8]) -> UInt8 {
        return UInt8(data.reduce(0, { (sum, element) in sum + Int(element) }) & 0xFF)
    }

    func fromSpecialKeyToKeyCode(code: SpecialKey) -> UInt16? {
        if code == .F1 {
            return 122
        } else if code == .F2 {
            return 120
        } else if code == .F3 {
            return 99
        } else if code == .F4 {
            return 118
        } else if code == .F5 {
            return 96
        } else if code == .F6 {
            return 97
        } else if code == .F7 {
            return 98
        } else if code == .F8 {
            return 100
        } else if code == .F9 {
            return 101
        } else if code == .F10 {
            return 109
        } else if code == .F11 {
            return 103
        } else if code == .F12 {
            return 111
        } else if code == .CtrlAltDel {
            return 117
        } else if code == .delete {
            return 117
        } else if code == .windowsWin {
            return 55
        } else if code == .CmdSpace {
            return 49
        } else if code == .space {
            return 49
        } else if code == .enter {
            return 36
        } else if code == .leftShift {
            return 56
        } else if code == .rightShift {
            return 60
        } else if code == .leftCtrl {
            return 59
        } else if code == .rightCtrl {
            return 62
        } else if code == .leftAlt {
            return 58
        } else if code == .rightAlt {
            return 61
        } else if code == .win {
            return 55
        } else if code == .tab {
            return 48
        } else if code == .backspace {
            return 51
        } else if code == .capsLock {
            return 57
        } else if code == .insert {
            return 114
        } else if code == .home {
            return 115
        } else if code == .pageUp {
            return 116
        } else if code == .forwardDelete {
            return 117
        } else if code == .end {
            return 119
        } else if code == .pageDown {
            return 121
        } else if code == .arrowRight {
            return 124
        } else if code == .arrowLeft {
            return 123
        } else if code == .arrowDown {
            return 125
        } else if code == .arrowUp {
            return 126
        } else if code == .numLock {
            return 71 // Num Lock key, mapped to F13 for HID compatibility
        }
        return nil
    }
}

extension KeyboardMapper.SpecialKey {
    static func functionKey(_ index: Int) -> KeyboardMapper.SpecialKey? {
        switch index {
        case 1: return .F1
        case 2: return .F2
        case 3: return .F3
        case 4: return .F4
        case 5: return .F5
        case 6: return .F6
        case 7: return .F7
        case 8: return .F8
        case 9: return .F9
        case 10: return .F10
        case 11: return .F11
        case 12: return .F12
        default: return nil
        }
    }
}
