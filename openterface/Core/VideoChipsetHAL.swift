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
            _ = try AVCaptureDeviceInput(device: device)
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
        // Check if this chipset supports HID commands for timing info
        guard let hidRegisters = self as? VideoChipsetHIDRegisters,
              hidRegisters.supportsHIDCommands else {
            logger.log(content: "⚠️ Chipset \(chipsetInfo.name) does not support HID timing commands")
            return nil
        }
        
        // Use HIDManager to read timing information with chipset-specific registers
        let hTotal = hidManager.getInputHTotal()
        let vTotal = hidManager.getInputVTotal()
        let hst = hidManager.getInputHst()
        let vst = hidManager.getInputVst()
        let hsw = hidManager.getInputHsyncWidth()
        let vsw = hidManager.getInputVsyncWidth()
        let pixelClock = hidManager.getPixelClock()
        
        // Return timing info if we have valid data
        if let hTotal = hTotal, let vTotal = vTotal, let hst = hst, 
           let vst = vst, let hsw = hsw, let vsw = vsw, let pixelClock = pixelClock {
            return VideoTimingInfo(
                horizontalTotal: UInt32(hTotal),
                verticalTotal: UInt32(vTotal),
                horizontalSyncStart: UInt32(hst),
                verticalSyncStart: UInt32(vst),
                horizontalSyncWidth: UInt32(hsw),
                verticalSyncWidth: UInt32(vsw),
                pixelClock: UInt32(pixelClock)
            )
        }
        
        logger.log(content: "⚠️ Failed to read complete timing info for \(chipsetInfo.name)")
        return nil
    }
    
    func updateConnectionStatus(_ isConnected: Bool) {
        let previousStatus = self.isConnected
        self.isConnected = isConnected
        
        if previousStatus != isConnected {
            if logger.HalPrint {
                logger.log(content: "📺 Video chipset \(chipsetInfo.name) connection status: \(isConnected ? "Connected" : "Disconnected")")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func matchesChipset(device: AVCaptureDevice) -> Bool {
        // Check if device matches this chipset's vendor/product ID
        // This is chipset-specific and would be implemented in subclasses
        return true
    }
}
