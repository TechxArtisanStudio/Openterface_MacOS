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

// MARK: - Video Chipset Base Class

/// Base class for video chipset implementations
class BaseVideoChipset: VideoChipsetProtocol {
    let chipsetInfo: ChipsetInfo
    let capabilities: ChipsetCapabilities
    var isConnected: Bool = false
    var currentResolution: VideoResolution?
    var currentFrameRate: Float = 0.0
    
    internal var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    internal var hidManager: HIDManagerProtocol = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
    
    init(chipsetInfo: ChipsetInfo, capabilities: ChipsetCapabilities) {
        self.chipsetInfo = chipsetInfo
        self.capabilities = capabilities
    }
    
    // MARK: - Abstract Methods (to be overridden)
    
    var supportedResolutions: [VideoResolution] {
        fatalError("Must be implemented by subclass")
    }
    
    var maxFrameRate: Float {
        fatalError("Must be implemented by subclass")
    }
    
    func initialize() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func deinitialize() {
        isConnected = false
        logger.log(content: "🔄 Video Chipset \(chipsetInfo.name) deinitialized")
    }
    
    func detectDevice() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func validateConnection() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    // MARK: - Common Video Operations
    
    func getVideoDevices() -> [AVCaptureDevice] {
        let videoDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        
        return discoverySession.devices.filter { device in
            // Filter for devices matching this chipset
            return matchesChipset(device: device)
        }
    }
    
    func setupVideoCapture(device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            // Additional setup logic would go here
            logger.log(content: "✅ Video capture setup successful for \(chipsetInfo.name)")
            isConnected = true
            return true
        } catch {
            logger.log(content: "❌ Video capture setup failed: \(error.localizedDescription)")
            return false
        }
    }
    
    func getResolution() -> (width: Int, height: Int)? {
        // Use HID manager to get resolution from hardware
        return hidManager.getResolution()
    }
    
    func getFrameRate() -> Float? {
        // Use HID manager to get frame rate from hardware
        return hidManager.getFps()
    }
    
    func getPixelClock() -> UInt32? {
        // This would be implemented based on chipset-specific HID commands
        return nil
    }
    
    func getSignalStatus() -> VideoSignalStatus {
        let hasSignal = hidManager.getHDMIStatus()
        
        return VideoSignalStatus(
            hasSignal: hasSignal,
            signalStrength: hasSignal ? 1.0 : 0.0,
            isStable: hasSignal,
            errorRate: 0.0,
            lastUpdate: Date()
        )
    }
    
    func getTimingInfo() -> VideoTimingInfo? {
        // This would use HID commands to get detailed timing information
        return nil
    }
    
    // MARK: - Helper Methods
    
    private func matchesChipset(device: AVCaptureDevice) -> Bool {
        // Check if device matches this chipset's vendor/product ID
        // This is chipset-specific and would be implemented in subclasses
        return false
    }
}

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
        let usbManager = DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)
        
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
    
    override func getTimingInfo() -> VideoTimingInfo? {
        return VideoTimingInfo(
            horizontalTotal: AppStatus.hidInputHTotal,
            verticalTotal: AppStatus.hidInputVTotal,
            horizontalSyncStart: AppStatus.hidInputHst,
            verticalSyncStart: AppStatus.hidInputVst,
            horizontalSyncWidth: AppStatus.hidInputHsyncWidth,
            verticalSyncWidth: AppStatus.hidInputVsyncWidth,
            pixelClock: AppStatus.hidReadPixelClock
        )
    }
}

// MARK: - MS2130 Video Chipset Implementation

class MS2130VideoChipset: BaseVideoChipset {
    private static let VENDOR_ID = 0x345F
    private static let PRODUCT_ID = 0x2130
    
    init?() {
        let info = ChipsetInfo(
            name: "MS2130",
            vendorID: MS2130VideoChipset.VENDOR_ID,
            productID: MS2130VideoChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "MacroSilicon",
            chipsetType: .video(.ms2130)
        )
        
        let capabilities = ChipsetCapabilities(
            supportsHDMI: true,
            supportsAudio: true,
            supportsHID: false, // MS2130 has different HID capabilities
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
        
        // Initialize MS2130-specific settings
        if validateConnection() {
            isConnected = true
            logger.log(content: "✅ MS2130 chipset initialized successfully")
            return true
        }
        
        logger.log(content: "❌ MS2130 chipset initialization failed")
        return false
    }
    
    override func detectDevice() -> Bool {
        let usbManager = DependencyContainer.shared.resolve(USBDevicesManagerProtocol.self)
        
        // Check if MS2130 device is connected
        for device in AppStatus.USBDevices {
            if device.vendorID == MS2130VideoChipset.VENDOR_ID && 
               device.productID == MS2130VideoChipset.PRODUCT_ID {
                logger.log(content: "🔍 MS2130 device detected: \(device.productName)")
                return true
            }
        }
        
        return false
    }
    
    override func validateConnection() -> Bool {
        // MS2130 validation differs from MS2109
        // May not have full HID capabilities, so use different validation
        let videoDevices = getVideoDevices()
        return !videoDevices.isEmpty
    }
    
    override func getSignalStatus() -> VideoSignalStatus {
        // MS2130 may have different signal detection methods
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
    
    override func getTimingInfo() -> VideoTimingInfo? {
        // MS2130 may not support detailed timing info via HID
        // Return basic timing info if available
        if let resolution = getResolution() {
            return VideoTimingInfo(
                horizontalTotal: UInt32(resolution.width),
                verticalTotal: UInt32(resolution.height),
                horizontalSyncStart: 0,
                verticalSyncStart: 0,
                horizontalSyncWidth: 0,
                verticalSyncWidth: 0,
                pixelClock: 0
            )
        }
        return nil
    }
}
