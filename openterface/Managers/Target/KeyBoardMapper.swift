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
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var serialPortManager: SerialPortManagerProtocol { DependencyContainer.shared.resolve(SerialPortManagerProtocol.self) }
    
    // macOS key code to character mapping based on Carbon.HIToolbox constants
    static let macOSKeyCodeMap: [UInt16: String] = [
        // Letters (kVK_ANSI_*)
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        
        // Numbers
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        
        // Symbols and special chars
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        
        // Function keys (kVK_F*)
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        
        // Special keys
        48: "\t", 49: " ", 51: "\u{08}", 36: "\n", 53: "Esc",
        
        // Navigation keys
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        123: "◀", 124: "▶", 125: "▼", 126: "▲",
        
        // Modifier keys
        56: "Shift", 60: "RightShift", 59: "Ctrl", 62: "RightCtrl", 58: "Alt", 61: "RightAlt", 55: "Win",
        
        // Keypad
        65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 82: "0", 83: "1",
        84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]
    
    let keyCodeMapping: [UInt16: UInt8] = [
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
        
        // Num keys
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

        
        // Function keys and special keys
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
        
        // Function keys
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
        
        // Editing and navigation keys
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
        
        // Numeric keypad
        UInt16(kVK_ANSI_KeypadClear): 0x53, // Numlock/Clear
        UInt16(kVK_ANSI_KeypadDivide): 0x54, // Keypad /
        UInt16(kVK_ANSI_KeypadMultiply): 0x55, // Keypad *
        UInt16(kVK_ANSI_KeypadMinus): 0x56, // Keypad -
        UInt16(kVK_ANSI_KeypadPlus): 0x57, // Keypad +
        
        // Other function keys
        UInt16(kVK_F13): 0x46, // Print Screen (映射到F13)
        UInt16(kVK_F14): 0x65, // App (映射到F14)
        
        // Modifier keys
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
        case sleep = "sleep"
        case power = "power"
        case wakeup = "wakeup"
        case volumeMute = "volumeMute"
        case volumeDown = "volumeDown"
        case volumeUp = "volumeUp"
        case mediaPlayPause = "mediaPlayPause"
        case mediaPrevious = "mediaPrevious"
        case mediaNext = "mediaNext"
        case mediaStop = "mediaStop"
        case mediaEject = "mediaEject"
        case refresh = "refresh"
        case wwwStop = "wwwStop"
        case wwwForward = "wwwForward"
        case wwwBack = "wwwBack"
        case wwwHome = "wwwHome"
        case wwwFavorites = "wwwFavorites"
        case wwwSearch = "wwwSearch"
        case email = "email"
        case media = "media"
        case explorer = "explorer"
        case calculator = "calculator"
        case screenSave = "screenSave"
        case myComputer = "myComputer"
        case minimize = "minimize"
        case record = "record"
        case rewind = "rewind"
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
    
    // Raw values for detecting left and right modifier keys
    private let RIGHT_SHIFT_VALUE: UInt = 0x00020104
    private let RIGHT_CONTROL_VALUE: UInt = 0x00042100
    private let RIGHT_COMMAND_VALUE: UInt = 0x00100110
    private let RIGHT_OPTION_VALUE: UInt = 0x00080140

    func pressKey(keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        sendKeyData(keyCode: keys, isRelease: false, modifiers: modifiers)
    }
    
    func releaseKey(keys: [UInt16]) {
        sendKeyData(keyCode: keys, isRelease: true, modifiers: [])
    }
    

    func sendKeyData(keyCode: [UInt16], isRelease: Bool, modifiers: NSEvent.ModifierFlags) {
        var keyDat: [UInt8] = SerialPortManager.KEYBOARD_DATA_PREFIX
        for (index, kc) in keyCode.prefix(6).enumerated() {
            if let mappedValue = keyCodeMapping[kc] {
                keyDat[7 + index] = mappedValue
            } else if (kc != 255) {
                logger.log(content: "Warning: \(kc) is not mapped.")
            }
        }

        let combinedModifiers = processModifierFlags(modifiers)
        keyDat[5] = combinedModifiers
        
        if isRelease {
            keyDat[7] = 0x00
        }
        
        keyDat[13] = calculateChecksum(data: keyDat)
        //
        // let _ = self.serialPortManager.writeByte(data:keyDat)
        //
        let _ = serialPortManager.sendAsyncCommand(command: keyDat)
    }
    
    /// Sends multimedia key data to the device
    /// Format for multimedia keys (Report ID 0x02):
    /// [HEAD, ADDR, CMD, LEN, REPORT_ID, BYTE2, BYTE3, BYTE4, checksum]
    /// Byte2: Bit0=Volume+, Bit1=Volume-, Bit2=Mute, Bit3=Play/Pause, Bit4=Next, Bit5=Prev, Bit6=CD Stop, Bit7=Eject
    /// Byte3: Bit0=E-Mail, Bit1=Search, Bit2=Favorites, Bit3=Home, Bit4=Back, Bit5=Forward, Bit6=Stop, Bit7=Refresh
    /// Byte4: Bit0=Media, Bit1=Explorer, Bit2=Calculator, Bit3=Screen Saver, Bit4=My Computer, Bit5=Minimize, Bit6=Record, Bit7=Rewind
    func sendMultimediaKeyData(byte2: UInt8, byte3: UInt8 = 0, byte4: UInt8 = 0, isPress: Bool) {
        var multimediaData: [UInt8] = Array(SerialPortManager.MULTIMEDIA_KEY_CMD_PREFIX)
        
        // Add Report ID for multimedia keys (0x02)
        multimediaData.append(0x02)
        
        if isPress {
            multimediaData.append(byte2)
            multimediaData.append(byte3)
            multimediaData.append(byte4)
        } else {
            multimediaData.append(0x00)  // All bits 0 (no keys pressed)
            multimediaData.append(0x00)
            multimediaData.append(0x00)
        }
        
        let checksum = calculateChecksum(data: multimediaData)
        multimediaData.append(checksum)
        
        let _ = serialPortManager.sendAsyncCommand(command: multimediaData)
    }
    
    /// Sends ACPI key data to the device
    /// Format for ACPI keys (Report ID 0x01):
    /// [HEAD, ADDR, CMD, LEN, REPORT_ID, DATA, checksum]
    /// Data: Bit0=Power, Bit1=Sleep, Bit2=Wake-up
    func sendACPIKeyData(powerBit: Bool = false, sleepBit: Bool = false, wakeupBit: Bool = false) {
        var acpiData: [UInt8] = Array(SerialPortManager.MULTIMEDIA_KEY_CMD_PREFIX)
        
        // Add Report ID for ACPI keys (0x01)
        acpiData.append(0x01)
        
        var dataByte: UInt8 = 0
        if powerBit { dataByte |= 0x01 }   // Bit 0
        if sleepBit { dataByte |= 0x02 }   // Bit 1
        if wakeupBit { dataByte |= 0x04 }  // Bit 2
        
        acpiData.append(dataByte)
        acpiData.append(0x00)  // Padding byte
        acpiData.append(0x00)  // Padding byte
        let checksum = calculateChecksum(data: acpiData)
        acpiData.append(checksum)
        
        let _ = serialPortManager.sendAsyncCommand(command: acpiData)
    }
    
    private func processModifierFlags(_ modifiers: NSEvent.ModifierFlags) -> UInt8 {
        var combinedModifiers: UInt8 = 0
        let rawValue = modifiers.rawValue

        // Process each modifier type using helper method
        combinedModifiers |= processModifier(.shift, rawValue: rawValue, modifiers: modifiers, 
                                           rightValue: RIGHT_SHIFT_VALUE, 
                                           leftKey: "LeftShift", rightKey: "RightShift")
        
        combinedModifiers |= processModifier(.control, rawValue: rawValue, modifiers: modifiers,
                                           rightValue: RIGHT_CONTROL_VALUE,
                                           leftKey: "LeftCtrl", rightKey: "RightCtrl")
        
        combinedModifiers |= processModifier(.option, rawValue: rawValue, modifiers: modifiers,
                                           rightValue: RIGHT_OPTION_VALUE,
                                           leftKey: "LeftAlt", rightKey: "RightAlt")
        
        combinedModifiers |= processModifier(.command, rawValue: rawValue, modifiers: modifiers,
                                           rightValue: RIGHT_COMMAND_VALUE,
                                           leftKey: "LeftWin", rightKey: "RightWin")
        
        return combinedModifiers
    }
    
    private func processModifier(_ flag: NSEvent.ModifierFlags, 
                               rawValue: UInt, 
                               modifiers: NSEvent.ModifierFlags,
                               rightValue: UInt,
                               leftKey: String,
                               rightKey: String) -> UInt8 {
        guard modifiers.contains(flag) else { return 0x00 }
        
        if isRightModifier(rawValue: rawValue, rightValue: rightValue) {
            return funcKeys[rightKey] ?? 0x00
        } else {
            return funcKeys[leftKey] ?? 0x00
        }
    }
    
    private func isRightModifier(rawValue: UInt, rightValue: UInt) -> Bool {
        return (rawValue & rightValue) == rightValue
    }
    
    func calculateChecksum(data: [UInt8]) -> UInt8 {
        return UInt8(data.reduce(0, { (sum, element) in sum + Int(element) }) & 0xFF)
    }
    
    func keyDescription(forKeyCode keyCode: UInt16) -> String {
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
            return 71
        } else if code == .esc {
            return 53
        } else if code == .sleep {
            return 71  // Sleep key
        } else if code == .volumeMute {
            return 74  // Mute key
        } else if code == .volumeDown {
            return 73  // Volume Down key
        } else if code == .volumeUp {
            return 72  // Volume Up key
        } else if code == .mediaPlayPause {
            return 75  // Play/Pause key
        } else if code == .mediaPrevious {
            return 67  // Previous Track key
        } else if code == .mediaNext {
            return 76  // Next Track key
        }
        
        // Multimedia-only keys that don't have standard HID key codes
        // These use the multimedia protocol instead
        if case .record = code { return nil }
        if case .media = code { return nil }
        if case .refresh = code { return nil }
        if case .wwwStop = code { return nil }
        if case .wwwForward = code { return nil }
        if case .wwwBack = code { return nil }
        if case .wwwHome = code { return nil }
        if case .wwwFavorites = code { return nil }
        if case .wwwSearch = code { return nil }
        if case .email = code { return nil }
        if case .rewind = code { return nil }
        if case .power = code { return nil }
        if case .wakeup = code { return nil }
        if case .explorer = code { return nil }
        if case .calculator = code { return nil }
        if case .screenSave = code { return nil }
        if case .myComputer = code { return nil }
        if case .minimize = code { return nil }

        logger.log(content: "Warning: \(code.rawValue) is not mapped to a key code.")
        return nil
    }
    
    /// Gets the multimedia key code for a special key
    /// Returns a tuple with (byte2, byte3, byte4) for multimedia keys
    /// Or returns nil if not a multimedia key
    func getMultimediaKeyCode(for code: SpecialKey) -> (byte2: UInt8, byte3: UInt8, byte4: UInt8)? {
        switch code {
        // Byte 2 keys (Volume, Play/Pause, Track)
        case .volumeUp:
            return (0x01, 0x00, 0x00)      // Byte2 Bit0
        case .volumeDown:
            return (0x02, 0x00, 0x00)      // Byte2 Bit1
        case .volumeMute:
            return (0x04, 0x00, 0x00)      // Byte2 Bit2
        case .mediaPlayPause:
            return (0x08, 0x00, 0x00)      // Byte2 Bit3
        case .mediaNext:
            return (0x10, 0x00, 0x00)      // Byte2 Bit4
        case .mediaPrevious:
            return (0x20, 0x00, 0x00)      // Byte2 Bit5
        case .mediaStop:
            return (0x40, 0x00, 0x00)      // Byte2 Bit6
        case .mediaEject:
            return (0x80, 0x00, 0x00)      // Byte2 Bit7
        
        // Byte 3 keys (Web/Email)
        case .email:
            return (0x00, 0x01, 0x00)      // Byte3 Bit0
        case .wwwSearch:
            return (0x00, 0x02, 0x00)      // Byte3 Bit1
        case .wwwFavorites:
            return (0x00, 0x04, 0x00)      // Byte3 Bit2
        case .wwwHome:
            return (0x00, 0x08, 0x00)      // Byte3 Bit3
        case .wwwBack:
            return (0x00, 0x10, 0x00)      // Byte3 Bit4
        case .wwwForward:
            return (0x00, 0x20, 0x00)      // Byte3 Bit5
        case .wwwStop:
            return (0x00, 0x40, 0x00)      // Byte3 Bit6
        case .refresh:
            return (0x00, 0x80, 0x00)      // Byte3 Bit7
        
        // Byte 4 keys (Application Control)
        case .media:
            return (0x00, 0x00, 0x01)      // Byte4 Bit0
        case .explorer:
            return (0x00, 0x00, 0x02)      // Byte4 Bit1
        case .calculator:
            return (0x00, 0x00, 0x04)      // Byte4 Bit2
        case .screenSave:
            return (0x00, 0x00, 0x08)      // Byte4 Bit3
        case .myComputer:
            return (0x00, 0x00, 0x10)      // Byte4 Bit4
        case .minimize:
            return (0x00, 0x00, 0x20)      // Byte4 Bit5
        case .record:
            return (0x00, 0x00, 0x40)      // Byte4 Bit6
        case .rewind:
            return (0x00, 0x00, 0x80)      // Byte4 Bit7
        
        default:
            return nil
        }
    }
    
    /// Checks if a special key is an ACPI key
    func getACPIKeyBits(for code: SpecialKey) -> (power: Bool, sleep: Bool, wakeup: Bool)? {
        switch code {
        case .power:
            return (true, false, false)    // Power bit
        case .sleep:
            return (false, true, false)    // Sleep bit
        case .wakeup:
            return (false, false, true)    // Wake-up bit
        default:
            return nil
        }
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
