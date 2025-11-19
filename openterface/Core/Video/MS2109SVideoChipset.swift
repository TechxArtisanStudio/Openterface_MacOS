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

// MARK: - MS2109S Video Chipset Implementation

class MS2109SVideoChipset: BaseVideoChipset {
    public static let VENDOR_ID = 0x345F
    public static let PRODUCT_ID = 0x2109

    init?() {
        let info = ChipsetInfo(
            name: "MS2109S",
            vendorID: MS2109SVideoChipset.VENDOR_ID,
            productID: MS2109SVideoChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "MacroSilicon",
            chipsetType: .video(.ms2109s)
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

        // Initialize MS2109S-specific settings
        if validateConnection() {
            isConnected = true
            logger.log(content: "✅ MS2109S chipset initialized successfully")


            return true
        }

        logger.log(content: "❌ MS2109S chipset initialization failed")
        return false
    }

    override func detectDevice() -> Bool {
        _ = DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)

        // Check if MS2109S device is connected
        for device in AppStatus.USBDevices {
            if device.vendorID == MS2109SVideoChipset.VENDOR_ID &&
               device.productID == MS2109SVideoChipset.PRODUCT_ID {
                logger.log(content: "🔍 MS2109S device detected: \(device.productName)")
                return true
            }
        }

        return false
    }

    override func validateConnection() -> Bool {
        // Validate MS2109S connection by checking HID communication
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)

        if let version = hidManager.getVersion() {
            logger.log(content: "📋 MS2109S version: \(version)")
            
            // Read video name from EEPROM once device is connected
            if let videoName = hidManager.readVideoNameFromEeprom() {
                logger.log(content: "📝 Video name from EEPROM: \(videoName)")
                
                // Only update USBDeviceInfo if video name is valid (not just spaces)
                let trimmedName = videoName.trimmingCharacters(in: .whitespaces)
                if !trimmedName.isEmpty {
                    if var defaultDevice = AppStatus.DefaultVideoDevice {
                        // Update the matching device in AppStatus.USBDevices array so the tree view reflects the change
                        if let index = AppStatus.USBDevices.firstIndex(where: { device in
                            device.vendorID == defaultDevice.vendorID &&
                            device.productID == defaultDevice.productID &&
                            device.locationID == defaultDevice.locationID
                        }) {
                            let existingDevice = AppStatus.USBDevices[index]
                            let updatedDevice = USBDeviceInfo(
                                productName: videoName,
                                manufacturer: existingDevice.manufacturer,
                                vendorID: existingDevice.vendorID,
                                productID: existingDevice.productID,
                                locationID: existingDevice.locationID,
                                speed: existingDevice.speed
                            )
                            AppStatus.USBDevices[index] = updatedDevice
                            logger.log(content: "✅ Updated USBDevices array with new product name for tree view")
                        }
                        
                        // Also update DefaultVideoDevice
                        defaultDevice = USBDeviceInfo(
                            productName: videoName,
                            manufacturer: defaultDevice.manufacturer,
                            vendorID: defaultDevice.vendorID,
                            productID: defaultDevice.productID,
                            locationID: defaultDevice.locationID,
                            speed: defaultDevice.speed
                        )
                        AppStatus.DefaultVideoDevice = defaultDevice
                        logger.log(content: "✅ Updated DefaultVideoDevice productName with EEPROM video name")
                    }
                } else {
                    logger.log(content: "⚠️ Video name is empty or contains only spaces, skipping update")
                }
            } else {
                logger.log(content: "⚠️ Failed to read video name from EEPROM")
            }
            
            return true
        }

        return false
    }

    override func getPixelClock() -> UInt32? {
        // MS2109S-specific pixel clock reading
        // This would use specific HID commands for MS2109S
        return AppStatus.hidReadPixelClock
    }
}

// MARK: - MS2109S HID Register Configuration

extension MS2109SVideoChipset: VideoChipsetHIDRegisters {
    // MARK: - Resolution Registers
    var inputResolutionWidthHigh: UInt16 { 0xC703 }
    var inputResolutionWidthLow: UInt16 { 0xC704 }
    var inputResolutionHeightHigh: UInt16 { 0xC705 }
    var inputResolutionHeightLow: UInt16 { 0xC706 }

    // MARK: - Frame Rate Registers
    var fpsHigh: UInt16 { 0xC6B5 }
    var fpsLow: UInt16 { 0xC6B6 }

    // MARK: - Pixel Clock Registers
    var pixelClockHigh: UInt16 { 0xC6F2 }
    var pixelClockLow: UInt16 { 0xC6F3 }

    // MARK: - Timing Registers
    var inputHTotalHigh: UInt16 { 0xC6F2 }
    var inputHTotalLow: UInt16 { 0xC6F3 }
    var inputVTotalHigh: UInt16 { 0xC6F4 }
    var inputVTotalLow: UInt16 { 0xC6F5 }
    var inputHstHigh: UInt16 { 0xC6F6 }
    var inputHstLow: UInt16 { 0xC700 }
    var inputVstHigh: UInt16 { 0xC701 }
    var inputVstLow: UInt16 { 0xC702 }
    var inputHwHigh: UInt16 { 0xC703 }
    var inputHwLow: UInt16 { 0xC704 }
    var inputVwHigh: UInt16 { 0xC705 }
    var inputVwLow: UInt16 { 0xC706 }

    // MARK: - Version Registers
    var version1: UInt16 { 0xCBDC }
    var version2: UInt16 { 0xCBDD }
    var version3: UInt16 { 0xCBDE }
    var version4: UInt16 { 0xCBDF }

    // MARK: - Status Registers
    var hdmiConnectionStatus: UInt16 { 0xFD9C }

    // MARK: - Chipset Capabilities
    var supportsHIDCommands: Bool { true }
    var supportsEEPROM: Bool { true }
}
