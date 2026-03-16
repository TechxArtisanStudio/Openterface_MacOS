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

/// Contains all serial protocol commands and constants for communicating with Openterface Mini KVM devices.
/// Supports both CH9329 and CH32V208 control chipsets with their respective command protocols.
struct SerialProtocolCommands {
    
    // MARK: - Protocol Header
    
    /// Standard protocol header for all commands: [0x57, 0xAB, 0x00]
    static let HEADER: [UInt8] = [0x57, 0xAB, 0x00]
    
    // MARK: - Baudrate Constants
    
    /// Low speed baudrate (9600bps) - typically used after factory reset or for initial connection
    static let LOWSPEED_BAUDRATE = BaseControlChipset.LOWSPEED_BAUDRATE
    
    /// High speed baudrate (115200bps) - preferred for normal operation
    static let HIGHSPEED_BAUDRATE = BaseControlChipset.HIGHSPEED_BAUDRATE
    
    // MARK: - Keyboard Commands
    
    struct Keyboard {
        /// Keyboard data prefix: [HEAD, ADDR, CMD, LEN, 8 data bytes]
        /// CMD: 0x02 for keyboard HID data
        static let DATA_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x02, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        
        /// Multimedia/ACPI key data prefix: [HEAD, ADDR, CMD, LEN, ...]
        /// CMD: 0x03 for multimedia keys
        /// ACPI keys:       [0x57, 0xAB, 0x00, 0x03, 0x04, 0x01, DATA, 0, 0, checksum] - Report ID 0x01, 1 data byte
        /// Multimedia keys: [0x57, 0xAB, 0x00, 0x03, 0x04, 0x02, BYTE2, 0, 0, checksum] - Report ID 0x02, 3 data bytes
        static let MULTIMEDIA_CMD_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x03, 0x04]
    }
    
    // MARK: - Mouse Commands
    
    struct Mouse {
        /// Mouse absolute positioning command prefix
        /// CMD: 0x04, LEN: 0x07, Report ID: 0x02
        static let ABSOLUTE_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x04, 0x07, 0x02]
        
        /// Mouse relative movement command prefix  
        /// CMD: 0x05, LEN: 0x05, Report ID: 0x01
        static let RELATIVE_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x05, 0x05, 0x01]
    }
    
    // MARK: - Device Information Commands
    
    struct DeviceInfo {
        /// Get HID information command
        /// CMD: 0x01, LEN: 0x00 (no data)
        /// Response: 0x81 with chip version, target connection status, lock states
        static let GET_HID_INFO: [UInt8] = [0x57, 0xAB, 0x00, 0x01, 0x00]
        
        /// Get parameter configuration command
        /// CMD: 0x08, LEN: 0x00 (no data)
        /// Response: 0x88 with baudrate, mode, and other configuration parameters
        static let GET_PARA_CFG: [UInt8] = [0x57, 0xAB, 0x00, 0x08, 0x00]
    }
    
    // MARK: - Device Configuration Commands
    
    struct DeviceConfig {
        /// Set parameter configuration command prefix for 115200 baud
        /// CMD: 0x09, mode byte at index [5], baudrate at [8-11]
        static let SET_PARA_CFG_PREFIX_115200: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x01, 0xC2, 0x00]
        
        /// Set parameter configuration command prefix for 9600 baud
        /// CMD: 0x09, mode byte at index [5], baudrate at [8-11] 
        static let SET_PARA_CFG_PREFIX_9600: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x25, 0x80, 0x00]
        
        /// Set parameter configuration command postfix (common trailing data)
        static let SET_PARA_CFG_POSTFIX: [UInt8] = [0x08, 0x00, 0x00, 0x03, 0x86, 0x1A, 0x29, 0xE1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        
        /// Device reset command
        /// CMD: 0x0F, LEN: 0x00 (no data)
        /// Response: 0x8F with status
        static let RESET: [UInt8] = [0x57, 0xAB, 0x00, 0x0F, 0x00]
    }
    
    // MARK: - CH32V208 Specific Commands
    
    struct CH32V208 {
        /// SD card switch command prefix
        /// CMD: 0x17, LEN: 0x05, followed by 4 zero bytes + direction byte
        /// Direction: 0x00 = HOST, 0x01 = TARGET, 0x03 = QUERY
        /// Response: 0x97 with current direction
        static let SD_SWITCH_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x17, 0x05, 0x00, 0x00, 0x00, 0x00]
        
        struct SDCardDirection {
            static let HOST: UInt8 = 0x00
            static let TARGET: UInt8 = 0x01
            static let QUERY: UInt8 = 0x03
        }
    }
    
    // MARK: - Response Command Codes
    
    struct ResponseCodes {
        static let HID_INFO_RESPONSE: UInt8 = 0x81
        static let KEYBOARD_ACK: UInt8 = 0x82
        static let MULTIMEDIA_ACK: UInt8 = 0x83
        static let MOUSE_ABSOLUTE_ACK: UInt8 = 0x84
        static let MOUSE_RELATIVE_ACK: UInt8 = 0x85
        static let CUSTOM_HID_SEND_ACK: UInt8 = 0x86
        static let CUSTOM_HID_READ_ACK: UInt8 = 0x87
        static let PARA_CFG_RESPONSE: UInt8 = 0x88
        static let SET_PARA_CFG_ACK: UInt8 = 0x89
        static let RESET_ACK: UInt8 = 0x8F
        static let SD_DIRECTION_RESPONSE: UInt8 = 0x97
        static let CHECKSUM_ERROR: UInt8 = 0xC4
    }
    
    // MARK: - Helper Methods
    
    /// Calculates checksum for a command array
    /// - Parameter data: Command bytes (without checksum)
    /// - Returns: Calculated checksum byte
    static func calculateChecksum(for data: [UInt8]) -> UInt8 {
        return UInt8(data.reduce(0, { (sum, element) in sum + Int(element) }) & 0xFF)
    }
    
    /// Validates if data starts with the correct protocol header
    /// - Parameter data: Data to validate
    /// - Returns: true if data starts with [0x57, 0xAB, 0x00]
    static func hasValidHeader(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[0] == HEADER[0] && data[1] == HEADER[1] && data[2] == HEADER[2]
    }
    
    /// Creates a complete command with checksum
    /// - Parameter command: Command bytes without checksum
    /// - Returns: Complete command with appended checksum
    static func createCommand(from command: [UInt8]) -> [UInt8] {
        var mutableCommand = command
        let checksum = calculateChecksum(for: command)
        mutableCommand.append(checksum)
        return mutableCommand
    }
}

// MARK: - Legacy Compatibility

/// Legacy constants for backward compatibility (deprecated - use SerialProtocolCommands instead)
extension SerialPortManager {
    @available(*, deprecated, message: "Use SerialProtocolCommands.Mouse.ABSOLUTE_PREFIX instead")
    static var MOUSE_ABS_ACTION_PREFIX: [UInt8] { SerialProtocolCommands.Mouse.ABSOLUTE_PREFIX }
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.Mouse.RELATIVE_PREFIX instead")
    static var MOUSE_REL_ACTION_PREFIX: [UInt8] { SerialProtocolCommands.Mouse.RELATIVE_PREFIX }
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceInfo.GET_HID_INFO instead")
    static let CMD_GET_HID_INFO: [UInt8] = SerialProtocolCommands.DeviceInfo.GET_HID_INFO
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceInfo.GET_PARA_CFG instead")
    static let CMD_GET_PARA_CFG: [UInt8] = SerialProtocolCommands.DeviceInfo.GET_PARA_CFG
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.Keyboard.DATA_PREFIX instead")
    static let KEYBOARD_DATA_PREFIX: [UInt8] = SerialProtocolCommands.Keyboard.DATA_PREFIX
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.Keyboard.MULTIMEDIA_CMD_PREFIX instead")
    static let MULTIMEDIA_KEY_CMD_PREFIX: [UInt8] = SerialProtocolCommands.Keyboard.MULTIMEDIA_CMD_PREFIX
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_115200 instead")
    static let CMD_SET_PARA_CFG_PREFIX_115200: [UInt8] = SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_115200
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_9600 instead")
    static let CMD_SET_PARA_CFG_PREFIX_9600: [UInt8] = SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_9600
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_POSTFIX instead")
    static let CMD_SET_PARA_CFG_POSTFIX: [UInt8] = SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_POSTFIX
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.DeviceConfig.RESET instead")
    static let CMD_RESET: [UInt8] = SerialProtocolCommands.DeviceConfig.RESET
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX instead")
    static let CMD_SD_SWITCH_PREFIX: [UInt8] = SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.LOWSPEED_BAUDRATE instead")
    static let LOWSPEED_BAUDRATE = SerialProtocolCommands.LOWSPEED_BAUDRATE
    
    @available(*, deprecated, message: "Use SerialProtocolCommands.HIGHSPEED_BAUDRATE instead")
    static let HIGHSPEED_BAUDRATE = SerialProtocolCommands.HIGHSPEED_BAUDRATE
}