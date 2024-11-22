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

class KeyboardMapper {
    let spm = SerialPortManager.shared
    
    let keyCodeMapping: [UInt16: UInt8] = [
        // First ones are **keycode** from the controlling unit
        // Second ones are for the controlled unit (to keyboard simulating chip)
         0: 0x04, // a
        11: 0x05, // b
         8: 0x06, // c
         2: 0x07, // d
        14: 0x08, // e
         3: 0x09, // f
         5: 0x0A, // g
         4: 0x0B, // h
        34: 0x0C, // i
        38: 0x0D, // j
        40: 0x0E, // k
        37: 0x0F, // l
        46: 0x10, // m
        45: 0x11, // n
        31: 0x12, // o
        35: 0x13, // p
        12: 0x14, // q
        15: 0x15, // r
         1: 0x16, // s
        17: 0x17, // t
        32: 0x18, // u
         9: 0x19, // v
        13: 0x1A, // w
         7: 0x1B, // x
        16: 0x1C, // y
         6: 0x1D, // z
        18: 0x1E, 83: 0x59, // 1
        19: 0x1F, 84: 0x5A, // 2
        20: 0x20, 85: 0x5B, // 3
        21: 0x21, 86: 0x5C, // 4
        23: 0x22, 87: 0x5D, // 5
        22: 0x23, 88: 0x5E, // 6
        26: 0x24, 89: 0x5F, // 7
        28: 0x25, 91: 0x60, // 8
        25: 0x26, 92: 0x61, // 9
        29: 0x27, 82: 0x62, // 0
        36: 0x28, 76: 0x58, // enter
        53: 0x29, // esc
        51: 0x2A, // backspace
        48: 0x2B,  // tab
        49: 0x2C, // space
        27: 0x2D, // -
        24: 0x2E, // =
        33: 0x2F, // [
        30: 0x30, // ]
        42: 0x31, // \
//        ??: 0x32, // \
        41: 0x33, // ;
        39: 0x34, // '
        50: 0x35, // `
        43: 0x36, // ,
        47: 0x37, 65: 0x37, // .
        44: 0x38, //
        57: 0x39, // caps lock
        122: 0x3A, // f1
        120: 0x3B, // f2
        99: 0x3C, // f3
        118: 0x3D, // f4
        96: 0x3E, // f5
        97: 0x3F, // f6
        98: 0x40, // f7
        100: 0x41, // f8
        101: 0x42, // f9
        109: 0x43, // f10
        103: 0x44, // f11
        111: 0x45, // f12
//        "Print Scr": 0x46,
//        "ScrollLock": 0x47,
//        "Pause Break": 0x48,
        114:0x49,//   "Insert": 0x49,
        115:0x4A, // "Home": 0x4A,
        116:0x4B,//   "Page Up": 0x4B,
        117: 0x4C, // Right Del
        119: 0x4D, //"End": 0x4D,
        121: 0x4E, // "Page Down": 0x4E,
        124: 0x4F, // Keyboard right arrow
        123: 0x50, // Keyboard left arrow
        125: 0x51, // Keyboard down arrow
        126: 0x52, // Keyboard up arrow
         71: 0x53,//        "Numlock": 0x53,
         75:0x54, // "Numpad / divide": 0x54,
         67:0x55, //  "Numpad * multiply": 0x55,
         78:0x56, //"Numpad - subtract": 0x56,
         69:0x57, //        "Numpad + add": 0x57,
//        "Numpad enter": 0x58,
//        "Numpad End": 0x59,
//        "Numpad down arrow": 0x5A,
//        "Numpad Page Down": 0x5B,
//        "Numpad left arrow": 0x5C,
//        "Numpad Clear": 0x5D,
//        "Numpad right arrow": 0x5E,
//        "Numpad Home": 0x5F,
//        "Numpad up arrow": 0x60,
//        "Numpad Page Up": 0x61,
//        ??: 0x62, // Numpad Insert
//        ??: 0x63, // Numpad Delete
//        ??: 0x65, // Numpad Apps
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
        case del = "del"
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
        print(keyCode)
        for (index, kc) in keyCode.prefix(6).enumerated() {
            if let mappedValue = keyCodeMapping[kc] {
                keyDat[7 + index] = mappedValue
            } else {
                Logger.shared.log(content: "Warning: \(kc) is not mapped.")
            }
        }

        var combinedModifiers: UInt8 = 0

        if modifiers.contains(.shift) {
            if modifiers.rawValue & 0x20004 == 0x20004 {  // Right Shift
                combinedModifiers |= funcKeys["RightShift"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftShift"] ?? 0x00
            }
        }
        if modifiers.contains(.control) {
            if modifiers.rawValue & 0x20000 == 0x20000 {  // Right Control
                combinedModifiers |= funcKeys["RightCtrl"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftCtrl"] ?? 0x00
            }
        }
        if modifiers.contains(.option) { // For "alt" key
            if modifiers.rawValue & 0x20002 == 0x20002 {  // Right Option/Alt
                combinedModifiers |= funcKeys["RightAlt"] ?? 0x00
            } else {
                combinedModifiers |= funcKeys["LeftAlt"] ?? 0x00
            }
        }
        if modifiers.contains(.command) { // For "win" key
            if modifiers.rawValue & 0x20008 == 0x20008 {  // Right Command
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
        
        let _ = self.spm.writeByte(data:keyDat)
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
        } else if code == .del {
            return 117
        }
        return nil
    }
}
