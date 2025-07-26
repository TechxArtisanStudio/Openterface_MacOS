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
    func getHardwareConnetionStatus() -> Bool {
        return isOpen ?? false
    }
    
    /// Default implementation for USB switching
    func setUSBtoHost() {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Switching USB to host")
    }
    
    func setUSBtoTrager() {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Switching USB to target")
    }
}

extension SerialPortManagerProtocol {
    /// Default implementation with standard baudrate
    func tryOpenSerialPort() {
        tryOpenSerialPort(priorityBaudrate: 115200)
    }
    
    /// Default implementation for command sending without force
    func sendCommand(command: [UInt8]) {
        sendCommand(command: command, force: false)
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
