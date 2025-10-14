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

// MARK: - MS2130S Video Chipset Implementation

class MS2130SVideoChipset: BaseVideoChipset {
    public static let VENDOR_ID = 0x345F
    public static let PRODUCT_ID = 0x2132

    init?() {
        let info = ChipsetInfo(
            name: "MS2130S",
            vendorID: MS2130SVideoChipset.VENDOR_ID,
            productID: MS2130SVideoChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "MacroSilicon",
            chipsetType: .video(.ms2130s)
        )

        let capabilities = ChipsetCapabilities(
            supportsHDMI: true,
            supportsAudio: true,
            supportsHID: false, // MS2130S has different HID capabilities
            supportsFirmwareUpdate: false,
            supportsEEPROM: false,
            maxDataTransferRate: 480_000_000, // USB 2.0 High Speed
            features: ["HDMI Input", "Audio Capture", "Hardware Scaling"]
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

        // Initialize MS2130SS-specific settings
        if validateConnection() {
            isConnected = true
            logger.log(content: "✅ MS2130S chipset initialized successfully")
            return true
        }

        logger.log(content: "❌ MS2130S chipset initialization failed")
        return false
    }

    override func detectDevice() -> Bool {
        _ = DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)

        // Check if MS2130S device is connected
        for device in AppStatus.USBDevices {
            if device.vendorID == MS2130SVideoChipset.VENDOR_ID &&
               device.productID == MS2130SVideoChipset.PRODUCT_ID {
                logger.log(content: "🔍 MS2130S device detected: \(device.productName)")
                return true
            }
        }

        return false
    }

    override func validateConnection() -> Bool {
        // MS2130S validation differs from MS2109
        // May not have full HID capabilities, so use different validation
        let videoDevices = getVideoDevices()
        return !videoDevices.isEmpty
    }

    override func getSignalStatus() -> VideoSignalStatus {
        // MS2130S may have different signal detection methods
        // For now, check if we have video devices available
        let hasDevices = !getVideoDevices().isEmpty

        return VideoSignalStatus(
            hasSignal: hasDevices,
            signalStrength: hasDevices ? 1.0 : 0.0,
            isStable: hasDevices,
            errorRate: 0.0,
            lastUpdate: Date()
        )
    }
}

// MARK: - MS2130S HID Register Configuration

extension MS2130SVideoChipset: VideoChipsetHIDRegisters {
    // MARK: - Resolution Registers
    // MS2130 uses different register addresses than MS2109
    var inputResolutionWidthHigh: UInt16 { 0x1CFC }
    var inputResolutionWidthLow: UInt16 { 0x1CFD }
    var inputResolutionHeightHigh: UInt16 { 0x1CFE }
    var inputResolutionHeightLow: UInt16 { 0x1CFF }

    // MARK: - Frame Rate Registers
    var fpsHigh: UInt16 { 0x1D02 }
    var fpsLow: UInt16 { 0x1D03 }

    // MARK: - Pixel Clock Registers
    var pixelClockHigh: UInt16 { 0x1D00 }
    var pixelClockLow: UInt16 { 0x1D01 }

    // MARK: - Timing Registers
    var inputHTotalHigh: UInt16 { 0x1CF8 }
    var inputHTotalLow: UInt16 { 0x1CF9 }
    
    var inputVTotalHigh: UInt16 { 0x1CFA }
    var inputVTotalLow: UInt16 { 0x1CFB }
    
    var inputHActiveHigh: UInt16 { 0x1CFC }
    var inputHActiveLow: UInt16 { 0x1CFD }
    
    var inputVActiveHigh: UInt16 { 0x1CFE }
    var inputVActiveLow: UInt16 { 0x1CFF }
    
    var inputHstHigh: UInt16 { 0x1CFC }
    var inputHstLow: UInt16 { 0x1CFD }
    
    var inputVstHigh: UInt16 { 0x1CFE }
    var inputVstLow: UInt16 { 0x1CFF }
    
    var inputHwHigh: UInt16 { 0x1CFC }
    var inputHwLow: UInt16 { 0x1CFD }
    var inputVwHigh: UInt16 { 0x1CFE }
    var inputVwLow: UInt16 { 0x1CFF }

    // MARK: - Version Registers
    var version1: UInt16 { 0x1FC0 }
    var version2: UInt16 { 0x1FC1 }
    var version3: UInt16 { 0x1FC2 }
    var version4: UInt16 { 0x1FC3 }

    // MARK: - Status Registers
    var hdmiConnectionStatus: UInt16 { 0xFA8D } // Different from MS2109

    // MARK: - Chipset Capabilities
    var supportsHIDCommands: Bool { true }
    var supportsEEPROM: Bool { false } // MS2130S doesn't support EEPROM
}
