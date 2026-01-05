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

// MARK: - Control Chipset Base Class

/// Base class for control chipset implementations
class BaseControlChipset: ControlChipsetProtocol {
    public static let HIGHSPEED_BAUDRATE = 115200
    public static let LOWSPEED_BAUDRATE = 9600

    let chipsetInfo: ChipsetInfo
    let capabilities: ChipsetCapabilities
    var isConnected: Bool = false
    var currentBaudRate: Int = 0
    
    internal var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    internal var serialManager: SerialPortManagerProtocol = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)
    
    init(chipsetInfo: ChipsetInfo, capabilities: ChipsetCapabilities) {
        self.chipsetInfo = chipsetInfo
        self.capabilities = capabilities
    }
    
    // MARK: - Abstract Methods (to be overridden)
    
    var communicationInterface: CommunicationInterface {
        return .serial(baudRate: currentBaudRate)
    }
    
    var supportedBaudRates: [Int] {
        return [BaseControlChipset.LOWSPEED_BAUDRATE, BaseControlChipset.HIGHSPEED_BAUDRATE]
    }
    
    func establishCommunication() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    var isDeviceReady: Bool {
        return serialManager.isDeviceReady
    }
    
    func deinitialize() {
        isConnected = false
        logger.log(content: "🔄 Control Chipset \(chipsetInfo.name) deinitialized")
    }
    
    func detectDevice() -> Bool {
        // Check if device is connected via USB manager using chipset IDs
        for device in AppStatus.USBDevices {
            if device.vendorID == chipsetInfo.vendorID &&
               device.productID == chipsetInfo.productID {
                logger.log(content: "🔍 \(chipsetInfo.name) device detected: \(device.productName)")
                return true
            }
        }
        return false
    }
    
    func validateConnection() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func initialize() -> Bool {
        guard detectDevice() else {
            logger.log(content: "❌ \(chipsetInfo.name) device not detected")
            return false
        }

        if establishCommunication() && validateConnection() {
            logger.log(content: "✅ \(chipsetInfo.name) chipset initialized successfully")
            return true
        }

        logger.log(content: "❌ \(chipsetInfo.name) chipset initialization failed")
        return false
    }
    
    // MARK: - Common Control Operations
    
    func sendAsyncCommand(_ command: [UInt8], force: Bool = false) -> Bool {
        guard isDeviceReady || force else {
            logger.log(content: "⚠️ Device not ready, command ignored: \(command.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return false
        }
        
        serialManager.sendAsyncCommand(command: command, force: force)
        return true
    }
    
    func getDeviceStatus() -> ControlDeviceStatus {
        return ControlDeviceStatus(
            isTargetConnected: AppStatus.isTargetConnected,
            isKeyboardConnected: AppStatus.isKeyboardConnected ?? false,
            isMouseConnected: AppStatus.isMouseConnected ?? false,
            lockStates: KeyboardLockStates(
                numLock: AppStatus.isNumLockOn,
                capsLock: AppStatus.isCapLockOn,
                scrollLock: AppStatus.isScrollOn
            ),
            chipVersion: AppStatus.chipVersion,
            communicationQuality: 1.0, // Could be calculated based on response times
            lastResponseTime: 0.0
        )
    }
    
    func getVersion() -> String? {
        // This would send a version request command specific to each chipset
        return nil
    }
    
    func resetDevice() -> Bool {
        serialManager.resetHidChip()
        return true
    }
    
    func configureDevice(baudRate: Int, mode: UInt8) -> Bool {
        // Device configuration is chipset-specific
        return false
    }
    
    func monitorHIDEvents() -> Bool {
        // HID event monitoring is chipset-specific
        return false
    }
    
    func updateConnectionStatus(_ isConnected: Bool) {
        self.isConnected = isConnected
        logger.log(content: "Control chipset connection status updated: \(isConnected ? "connected" : "disconnected")")
    }
    
    // MARK: - Helper Methods
    
    internal func updateConnectionStatus() {
        let status = getDeviceStatus()
        AppStatus.isKeyboardConnected = status.isKeyboardConnected
        AppStatus.isMouseConnected = status.isMouseConnected
        AppStatus.chipVersion = status.chipVersion
    }
}
