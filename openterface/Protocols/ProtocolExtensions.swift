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

// MARK: - HAL Data Structure Forward Declarations

/// Forward declarations for HAL data structures to avoid circular dependencies
/// The actual definitions are in HardwareAbstractionLayer.swift

struct VideoSignalStatus {
    let hasSignal: Bool
    let signalStrength: Float
    let isStable: Bool
    let errorRate: Float
    let lastUpdate: Date
}

struct VideoTimingInfo {
    let horizontalTotal: UInt32
    let verticalTotal: UInt32
    let horizontalSyncStart: UInt32
    let verticalSyncStart: UInt32
    let horizontalSyncWidth: UInt32
    let verticalSyncWidth: UInt32
    let pixelClock: UInt32
}

// MARK: - Protocol Extensions with Default Implementations

extension VideoManagerProtocol {
    /// Default implementation for video authorization check
    func checkAuthorization() {
        // This can be overridden by concrete implementations
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Checking video authorization...")
    }
}

extension HIDManagerProtocol {
    /// Default implementation for basic HID status
    func getSoftwareSwitchStatus() -> Bool {
        return isOpen ?? false
    }
    
    /// Default implementation for USB switching
    func setUSBtoHost() {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Switching USB to host")
    }
    
    func setUSBtoTarget() {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Switching USB to target")
    }
    
    // MARK: - HAL Integration Default Implementations
    
    /// Default implementation returns nil - only concrete implementations with HAL support provide this
    func getHALVideoSignalStatus() -> VideoSignalStatus? {
        return nil
    }
    
    /// Default implementation returns nil - only concrete implementations with HAL support provide this
    func getHALVideoTimingInfo() -> VideoTimingInfo? {
        return nil
    }
    
    /// Default implementation returns false - no HAL features available by default
    func halSupportsHIDFeature(_ feature: String) -> Bool {
        return false
    }
    
    /// Default implementation returns empty array - no HAL capabilities by default
    func getHALHIDCapabilities() -> [String] {
        return []
    }
    
    /// Default implementation returns false - no HAL initialization by default
    func initializeHALAwareHID() -> Bool {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "HAL-aware HID not supported in this implementation")
        return false
    }
    
    /// Default implementation returns basic information
    func getHALSystemInfo() -> String {
        return "HAL information not available in this implementation"
    }
}

extension SerialPortManagerProtocol {
    /// Default implementation using last successful baudrate from user settings
    func tryOpenSerialPort() {
        tryOpenSerialPort(priorityBaudrate: nil)
    }
    
    /// Default implementation for command sending without force
    func sendAsyncCommand(command: [UInt8]) {
        sendAsyncCommand(command: command, force: false)
    }
}

extension AudioManagerProtocol {
    /// Default implementation for audio device management
    func setAudioEnabled(_ enabled: Bool) {
        if enabled {
            startAudioSession()
        } else {
            stopAudioSession()
        }
    }
}

extension USBDevicesManagerProtocol {
    /// Default implementation for device info
    func getDeviceGroupsInfo() -> [String] {
        return []
    }
}

extension LoggerProtocol {
    /// Default implementation for log level setting
    func setLogLevel(_ level: LogLevel) {
        // Default implementation - can be overridden
    }
    
    /// Default implementation for clearing logs
    func clearLogs() {
        // Default implementation - can be overridden
    }
}

extension OCRManagerProtocol {
    /// Default implementation for OCR with basic error handling
    func performOCR(on image: CGImage, completion: @escaping (OCRResult) -> Void) {
        completion(.failed(OCRError.visionFrameworkError("OCR not available on this system")))
    }
    
    /// Default implementation for area selection OCR
    func performOCROnSelectedArea(completion: @escaping (OCRResult) -> Void) {
        completion(.failed(OCRError.visionFrameworkError("OCR not available on this system")))
    }
    
    /// Default implementation for area selection completion
    func handleAreaSelectionComplete() {
        // Default implementation - do nothing
    }
    
    /// Default implementation for starting area selection
    func startAreaSelection() {
        // Default implementation - do nothing
    }
    
    /// Default implementation for cancelling area selection
    func cancelAreaSelection() {
        // Default implementation - do nothing
    }
    
    /// Default implementation for area selection status
    var isAreaSelectionActive: Bool {
        return false
    }
}
