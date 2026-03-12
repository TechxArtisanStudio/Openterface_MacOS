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
import ORSSerial

// MARK: - CH32V208 Control Chipset Implementation

class CH32V208ControlChipset: BaseControlChipset {
    private static let VENDOR_ID = 0x1A86
    private static let PRODUCT_ID = 0xFE0C

    init?() {
        let info = ChipsetInfo(
            name: "CH32V208",
            vendorID: CH32V208ControlChipset.VENDOR_ID,
            productID: CH32V208ControlChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "WCH",
            chipsetType: .control(.ch32v208)
        )

        let capabilities = ChipsetCapabilities(
            supportsHDMI: false,
            supportsAudio: false,
            supportsHID: true,
            supportsFirmwareUpdate: true,
            supportsEEPROM: false,
            maxDataTransferRate: 115200,
            features: ["Direct Serial Communication", "HID Events", "Advanced Protocol", "Firmware Update"]
        )

        super.init(chipsetInfo: info, capabilities: capabilities)
    }

    override func validateConnection() -> Bool {
        // CH32V208 doesn't require command validation like CH9329
        // Connection is valid if serial port opens successfully
        return serialManager.serialPort?.isOpen ?? false
    }

    override func establishCommunication() -> Bool {
        // CH32V208 uses direct connection without baudrate detection
        serialManager.tryOpenSerialPortForCH32V208()

        currentBaudRate = serialManager.baudrate
        let success = currentBaudRate == CH32V208ControlChipset.LOWSPEED_BAUDRATE

        if success {
            serialManager.isDeviceReady = true
            logger.log(content: "✅ CH32V208 communication established at \(currentBaudRate) baud")
            // Trigger HAL integration with managers after successful communication
            HALIntegrationManager.shared.reintegrateControlChipset()
            //Get the hid info in order to know the current firmware version
            serialManager.getHidInfo()
            isConnected = true
        } else {
            logger.log(content: "❌ CH32V208 communication establishment failed. Expected baudrate: \(CH32V208ControlChipset.HIGHSPEED_BAUDRATE), got: \(currentBaudRate)")
            serialManager.isDeviceReady = false
        }

        return success
    }

    override func configureDevice(baudRate: Int, mode: UInt8) -> Bool {
        // CH32V208 configuration might be different from CH9329
        // For now, it operates with fixed settings
        if baudRate != CH32V208ControlChipset.HIGHSPEED_BAUDRATE {
            logger.log(content: "⚠️ CH32V208 only supports \(CH32V208ControlChipset.HIGHSPEED_BAUDRATE) baud rate")
            return false
        }

        return true
    }

    override func monitorHIDEvents() -> Bool {
        // CH32V208 reports HID events directly through serial communication
        // No separate monitoring required as events come through normal serial data
        logger.log(content: "📡 CH32V208 HID monitoring through direct serial communication")
        return true
    }

    override func getVersion() -> String? {
        // CH32V208 version reporting might be different
        serialManager.getHidInfo()
        return "CH32V208-v\(AppStatus.chipVersion)"
    }

    override func getDeviceStatus() -> ControlDeviceStatus {
        let baseStatus = super.getDeviceStatus()

        // SD card direction polling is handled by SerialPortManager's dedicated timer,
        // which sends a fire-and-forget query command every 3 seconds.
        // SerialResponseHandler publishes the result via @Published sdCardDirection
        // and SerialPortManager's Combine subscription updates AppStatus.
        // Nothing needs to be done here for SD card state.

        // CH32V208 treats target as connected for HID purposes
        let isTargetConnected = true

        return ControlDeviceStatus(
            isTargetConnected: isTargetConnected,
            isKeyboardConnected: baseStatus.isKeyboardConnected,
            isMouseConnected: baseStatus.isMouseConnected,
            lockStates: baseStatus.lockStates,
            chipVersion: baseStatus.chipVersion,
            communicationQuality: baseStatus.communicationQuality,
            lastResponseTime: baseStatus.lastResponseTime
        )
    }

    // MARK: - CH32V208 Specific Methods

    func supportsAdvancedFeatures() -> Bool {
        // CH32V208 may support features not available in CH9329
        return true
    }

    func getFirmwareUpdateCapabilities() -> [String] {
        return capabilities.supportsFirmwareUpdate ? ["Firmware Update", "Device Reset"] : []
    }
    
    /// Determines if the current chip version supports SD card operations
    /// - Parameter chipVersion: The chip version to check
    /// - Returns: true if SD card operations are supported, false otherwise
    private func supportsSDCardOperations(chipVersion: Int8) -> Bool {
        // Based on observed chip versions and SD card support
        // CH32V208 chips with certain versions support SD card functionality
        switch chipVersion {
        case -126, -125, -124: // Known CH32V208 versions that support SD card
            if logger.HalPrint {
                logger.log(content: "CH32V208: Chip version \(chipVersion) supports SD card operations")
            }
            return true
        case 1, 2, 3, 4: // CH9329 versions - no SD card support
            if logger.HalPrint {
                logger.log(content: "CH32V208: Chip version \(chipVersion) appears to be CH9329 - no SD card support")
            }
            return false
        case 0, -1: // Uninitialized or unknown versions
            if logger.HalPrint {
                logger.log(content: "CH32V208: Unknown chip version \(chipVersion) - disabling SD operations for safety")
            }
            return false
        default:
            // For unknown versions, conservatively disable SD operations
            // This prevents timeout issues on unsupported devices
            if logger.HalPrint {
                logger.log(content: "CH32V208: Unsupported chip version \(chipVersion) - disabling SD operations")
            }
            return false
        }
    }
}
