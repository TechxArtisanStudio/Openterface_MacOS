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
        fatalError("Must be implemented by subclass")
    }
    
    var supportedBaudRates: [Int] {
        fatalError("Must be implemented by subclass")
    }
    
    var isDeviceReady: Bool {
        return serialManager.isDeviceReady
    }
    
    func initialize() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func deinitialize() {
        isConnected = false
        logger.log(content: "🔄 Control Chipset \(chipsetInfo.name) deinitialized")
    }
    
    func detectDevice() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func validateConnection() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func establishCommunication() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    // MARK: - Common Control Operations
    
    func sendCommand(_ command: [UInt8], force: Bool = false) -> Bool {
        guard isDeviceReady || force else {
            logger.log(content: "⚠️ Device not ready, command ignored: \(command.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return false
        }
        
        serialManager.sendCommand(command: command, force: force)
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
    
    // MARK: - Helper Methods
    
    internal func updateConnectionStatus() {
        let status = getDeviceStatus()
        AppStatus.isTargetConnected = status.isTargetConnected
        AppStatus.isKeyboardConnected = status.isKeyboardConnected
        AppStatus.isMouseConnected = status.isMouseConnected
        AppStatus.chipVersion = status.chipVersion
    }
}
