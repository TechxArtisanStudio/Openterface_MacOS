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
import AVFoundation
import IOKit
import IOKit.hid

// MARK: - MS2109 Video Chipset Implementation

class MS2109VideoChipset: BaseVideoChipset {
    private static let VENDOR_ID = 0x534D
    private static let PRODUCT_ID = 0x2109

    init?() {
        let info = ChipsetInfo(
            name: "MS2109",
            vendorID: MS2109VideoChipset.VENDOR_ID,
            productID: MS2109VideoChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "MacroSilicon",
            chipsetType: .video(.ms2109)
        )

        let capabilities = ChipsetCapabilities(
            supportsHDMI: true,
            supportsAudio: true,
            supportsHID: true,
            supportsFirmwareUpdate: true,
            supportsEEPROM: true,
            maxDataTransferRate: 480_000_000, // USB 2.0 High Speed
            features: ["HDMI Input", "Audio Capture", "Hardware Scaling", "EEPROM Access"]
        )

        super.init(chipsetInfo: info, capabilities: capabilities)
    }

    override var supportedResolutions: [VideoResolution] {
        return [
            VideoResolution(width: 1920, height: 1080, refreshRate: 60.0),
            VideoResolution(width: 1920, height: 1080, refreshRate: 30.0),
            VideoResolution(width: 1280, height: 720, refreshRate: 60.0),
            VideoResolution(width: 1024, height: 768, refreshRate: 60.0),
            VideoResolution(width: 800, height: 600, refreshRate: 60.0),
            VideoResolution(width: 640, height: 480, refreshRate: 60.0)
        ]
    }

    override var maxFrameRate: Float {
        return 60.0
    }

    override func initialize() -> Bool {
        guard detectDevice() else {
            return false
        }

        // Initialize MS2109-specific settings
        if validateConnection() {
            isConnected = true
            logger.log(content: "✅ MS2109 chipset initialized successfully")
            return true
        }

        logger.log(content: "❌ MS2109 chipset initialization failed")
        return false
    }

    override func detectDevice() -> Bool {
        _ = DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)

        // Check if MS2109 device is connected
        for device in AppStatus.USBDevices {
            if device.vendorID == MS2109VideoChipset.VENDOR_ID &&
               device.productID == MS2109VideoChipset.PRODUCT_ID {
                logger.log(content: "🔍 MS2109 device detected: \(device.productName)")
                return true
            }
        }

        return false
    }

    override func validateConnection() -> Bool {
        // Validate MS2109 connection by checking HID communication
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)

        if let version = hidManager.getVersion() {
            logger.log(content: "📋 MS2109 version: \(version)")
            return true
        }

        return false
    }

    override func getPixelClock() -> UInt32? {
        // MS2109-specific pixel clock reading
        // This would use specific HID commands for MS2109
        return AppStatus.hidReadPixelClock
    }
}

// MARK: - MS2109 HID Register Configuration

extension MS2109VideoChipset: VideoChipsetHIDRegisters {
    // MARK: - Resolution Registers
    var inputResolutionWidthHigh: UInt16 { 0xC6AF }
    var inputResolutionWidthLow: UInt16 { 0xC6B0 }
    var inputResolutionHeightHigh: UInt16 { 0xC6B1 }
    var inputResolutionHeightLow: UInt16 { 0xC6B2 }

    // MARK: - Frame Rate Registers
    var fpsHigh: UInt16 { 0xC6B5 }
    var fpsLow: UInt16 { 0xC6B6 }

    // MARK: - Pixel Clock Registers
    var pixelClockHigh: UInt16 { 0xC73C }
    var pixelClockLow: UInt16 { 0xC73D }

    // MARK: - Timing Registers
    var inputHTotalHigh: UInt16 { 0xC734 }
    var inputHTotalLow: UInt16 { 0xC735 }
    var inputVTotalHigh: UInt16 { 0xC736 }
    var inputVTotalLow: UInt16 { 0xC737 }
    var inputHstHigh: UInt16 { 0xC740 }
    var inputHstLow: UInt16 { 0xC741 }
    var inputVstHigh: UInt16 { 0xC742 }
    var inputVstLow: UInt16 { 0xC743 }
    var inputHwHigh: UInt16 { 0xC744 }
    var inputHwLow: UInt16 { 0xC745 }
    var inputVwHigh: UInt16 { 0xC746 }
    var inputVwLow: UInt16 { 0xC747 }

    // MARK: - Version Registers
    var version1: UInt16 { 0xCBDC }
    var version2: UInt16 { 0xCBDD }
    var version3: UInt16 { 0xCBDE }
    var version4: UInt16 { 0xCBDF }

    // MARK: - Status Registers
    var hdmiConnectionStatus: UInt16 { 0xFA8C }

    // MARK: - Chipset Capabilities
    var supportsHIDCommands: Bool { true }
    var supportsEEPROM: Bool { true }
}
