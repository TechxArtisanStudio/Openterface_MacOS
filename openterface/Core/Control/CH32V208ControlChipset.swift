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
    public static let HIGHSPEED_BAUDRATE = 115200

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

    override var communicationInterface: CommunicationInterface {
        return .serial(baudRate: currentBaudRate)
    }

    override var supportedBaudRates: [Int] {
        return [CH32V208ControlChipset.HIGHSPEED_BAUDRATE]
    }

    override func initialize() -> Bool {
        guard detectDevice() else {
            logger.log(content: "❌ CH32V208 device not detected")
            return false
        }

        if establishCommunication() {
            isConnected = true
            logger.log(content: "✅ CH32V208 chipset initialized successfully")
            return true
        }

        logger.log(content: "❌ CH32V208 chipset initialization failed")
        return false
    }

    override func detectDevice() -> Bool {
        // Check if CH32V208 device is connected via USB manager
        for device in AppStatus.USBDevices {
            if device.vendorID == CH32V208ControlChipset.VENDOR_ID &&
               device.productID == CH32V208ControlChipset.PRODUCT_ID {
                logger.log(content: "🔍 CH32V208 device detected: \(device.productName)")
                return true
            }
        }

        return false
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
        let success = currentBaudRate == CH32V208ControlChipset.HIGHSPEED_BAUDRATE

        if success {
            serialManager.isDeviceReady = true
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

        var isTargetConnected = baseStatus.isTargetConnected

        isTargetConnected = true

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
}
