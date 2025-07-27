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
    let chipsetInfo: ChipsetInfo
    let capabilities: ChipsetCapabilities
    var isConnected: Bool = false
    var isDeviceReady: Bool = false
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
    
    func initialize() -> Bool {
        fatalError("Must be implemented by subclass")
    }
    
    func deinitialize() {
        isConnected = false
        isDeviceReady = false
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

// MARK: - CH9329 Control Chipset Implementation

class CH9329ControlChipset: BaseControlChipset {
    private static let VENDOR_ID = 0x1A86
    private static let PRODUCT_ID = 0x7523
    private static let DEFAULT_BAUDRATE = 115200
    private static let ORIGINAL_BAUDRATE = 9600
    
    private var lastCTSState: Bool?
    private var ctsMonitoringTimer: Timer?
    
    init?() {
        let info = ChipsetInfo(
            name: "CH9329",
            vendorID: CH9329ControlChipset.VENDOR_ID,
            productID: CH9329ControlChipset.PRODUCT_ID,
            firmwareVersion: nil,
            manufacturer: "WCH",
            chipsetType: .control(.ch9329)
        )
        
        let capabilities = ChipsetCapabilities(
            supportsHDMI: false,
            supportsAudio: false,
            supportsHID: true,
            supportsFirmwareUpdate: false,
            supportsEEPROM: false,
            maxDataTransferRate: 115200,
            features: ["Serial Communication", "HID Events", "CTS Monitoring", "Baudrate Detection"]
        )
        
        super.init(chipsetInfo: info, capabilities: capabilities)
    }
    
    override var communicationInterface: CommunicationInterface {
        return .serial(baudRate: currentBaudRate)
    }
    
    override var supportedBaudRates: [Int] {
        return [CH9329ControlChipset.ORIGINAL_BAUDRATE, CH9329ControlChipset.DEFAULT_BAUDRATE]
    }
    
    override func initialize() -> Bool {
        guard detectDevice() else {
            logger.log(content: "❌ CH9329 device not detected")
            return false
        }
        
        if establishCommunication() {
            isConnected = true
            startCTSMonitoring()
            logger.log(content: "✅ CH9329 chipset initialized successfully")
            return true
        }
        
        logger.log(content: "❌ CH9329 chipset initialization failed")
        return false
    }
    
    override func deinitialize() {
        stopCTSMonitoring()
        super.deinitialize()
    }
    
    override func detectDevice() -> Bool {
        // Check if CH9329 device is connected via USB manager
        for device in AppStatus.USBDevices {
            if device.vendorID == CH9329ControlChipset.VENDOR_ID && 
               device.productID == CH9329ControlChipset.PRODUCT_ID {
                logger.log(content: "🔍 CH9329 device detected: \(device.productName)")
                return true
            }
        }
        
        return false
    }
    
    override func validateConnection() -> Bool {
        // Validate by sending a parameter configuration request
        serialManager.getChipParameterCfg()
        
        // Wait briefly for response and check if device is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isDeviceReady = self?.serialManager.isDeviceReady ?? false
        }
        
        return true
    }
    
    override func establishCommunication() -> Bool {
        // CH9329 requires baudrate detection and validation
        serialManager.tryOpenSerialPort(priorityBaudrate: CH9329ControlChipset.DEFAULT_BAUDRATE)
        
        // Check if communication was established
        currentBaudRate = serialManager.baudrate
        return currentBaudRate > 0
    }
    
    override func configureDevice(baudRate: Int, mode: UInt8) -> Bool {
        // CH9329-specific configuration command
        // Command format: [0x57, 0xAB, 0x00, 0x09, 0x32, mode, baudrate_bytes..., checksum]
        var command: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, mode]
        
        // Add baudrate bytes (big-endian format)
        let baudRateBytes = withUnsafeBytes(of: UInt32(baudRate).bigEndian) { Array($0) }
        command.append(contentsOf: baudRateBytes)
        
        // Add remaining configuration bytes
        command.append(contentsOf: [0x01, 0xC2, 0x00])
        
        // Add padding to reach the expected command length
        while command.count < 32 {
            command.append(0x00)
        }
        
        return sendCommand(command, force: true)
    }
    
    override func monitorHIDEvents() -> Bool {
        // CH9329 uses CTS monitoring for HID event detection
        return startCTSMonitoring()
    }
    
    override func getVersion() -> String? {
        // CH9329 reports version through chip parameter configuration
        serialManager.getChipParameterCfg()
        return "CH9329-v\(AppStatus.chipVersion)"
    }
    
    // MARK: - CH9329 Specific Methods
    
    private func startCTSMonitoring() -> Bool {
        guard ctsMonitoringTimer == nil else {
            return true // Already monitoring
        }
        
        ctsMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkCTSState()
        }
        
        logger.log(content: "🔄 Started CTS monitoring for CH9329 HID event detection")
        return true
    }
    
    private func stopCTSMonitoring() {
        ctsMonitoringTimer?.invalidate()
        ctsMonitoringTimer = nil
        logger.log(content: "⏹️ Stopped CTS monitoring for CH9329")
    }
    
    private func checkCTSState() {
        guard let serialPort = serialManager.serialPort else { return }
        
        let currentCTS = serialPort.cts
        
        if lastCTSState == nil {
            lastCTSState = currentCTS
            return
        }
        
        if lastCTSState != currentCTS {
            // CTS state changed - indicates HID activity
            AppStatus.isKeyboardConnected = true
            AppStatus.isMouseConnected = true
            lastCTSState = currentCTS
            
            logger.log(content: "📡 CH9329 HID activity detected via CTS change")
        }
    }
}

// MARK: - CH32V208 Control Chipset Implementation

class CH32V208ControlChipset: BaseControlChipset {
    private static let VENDOR_ID = 0x1A86
    private static let PRODUCT_ID = 0xFE0C
    private static let DEFAULT_BAUDRATE = 115200
    
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
        return [CH32V208ControlChipset.DEFAULT_BAUDRATE]
    }
    
    override func initialize() -> Bool {
        guard detectDevice() else {
            logger.log(content: "❌ CH32V208 device not detected")
            return false
        }
        
        if establishCommunication() {
            isConnected = true
            isDeviceReady = true // CH32V208 is ready immediately after connection
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
        return currentBaudRate == CH32V208ControlChipset.DEFAULT_BAUDRATE
    }
    
    override func configureDevice(baudRate: Int, mode: UInt8) -> Bool {
        // CH32V208 configuration might be different from CH9329
        // For now, it operates with fixed settings
        if baudRate != CH32V208ControlChipset.DEFAULT_BAUDRATE {
            logger.log(content: "⚠️ CH32V208 only supports \(CH32V208ControlChipset.DEFAULT_BAUDRATE) baud rate")
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
    
    // MARK: - CH32V208 Specific Methods
    
    func supportsAdvancedFeatures() -> Bool {
        // CH32V208 may support features not available in CH9329
        return true
    }
    
    func getFirmwareUpdateCapabilities() -> [String] {
        return capabilities.supportsFirmwareUpdate ? ["Firmware Update", "Device Reset"] : []
    }
}
