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
import Combine

/// Protocol for serial response handling delegates
protocol SerialResponseHandlerDelegate: AnyObject {
    /// Called when HID acknowledgment latency needs to be updated
    func updateKeyboardLatency(_ latency: Double, maxLatency: Double)
    func updateMouseLatency(_ latency: Double, maxLatency: Double)
    
    /// Called when acknowledgment rates need to be updated
    func updateAckRates()
    
    /// Called when device configuration changes
    func updateDeviceConfiguration(baudrate: Int, mode: UInt8)
    
    /// Called when device becomes ready
    func setDeviceReady(_ ready: Bool)
}

/// Handles serial data responses and routes them to appropriate handlers
class SerialResponseHandler: ObservableObject {
    
    // MARK: - Dependencies
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    weak var delegate: SerialResponseHandlerDelegate?
    
    // MARK: - Published SD card state
    /// Published so SerialPortManager can subscribe and push AppStatus updates
    /// without any callback/operationId machinery.
    @Published var sdCardDirection: SDCardDirection = .unknown
    
    // MARK: - Latency Tracking
    private var lastKeyboardSendTime: Date?
    private var lastMouseSendTime: Date?
    private let timestampQueue = DispatchQueue(label: "com.openterface.SerialResponseHandler.timestamps", qos: .userInteractive)
    
    // MARK: - SD Card Operations
    private var pendingSdOperations: [UInt8: (Bool) -> Void] = [:]
    private var pendingSdQueryOperations: [UInt8: (SDCardDirection?) -> Void] = [:]
    private let sdOperationQueue = DispatchQueue(label: "com.openterface.SerialResponseHandler.sdOperations") // Serial queue for thread safety
    
    // MARK: - Synchronous Response Handling  
    private let syncResponseQueue = DispatchQueue(label: "com.openterface.SerialResponseHandler.syncResponse")
    private var syncResponseData: Data?
    private var syncResponseExpectedCmd: UInt8?
    
    // MARK: - Device Capability Detection
    private var deviceCapabilities: DeviceCapabilities?
    
    init() {
        // Initialize handler
    }
    
    /// Records the timestamp when a command was sent for latency calculation
    func recordCommandSendTime(for commandType: UInt8) {
        let currentTime = Date()
        timestampQueue.async { [weak self] in
            switch commandType {
            case 0x02: // Keyboard command
                self?.lastKeyboardSendTime = currentTime
            case 0x04, 0x05: // Mouse commands (absolute or relative)
                self?.lastMouseSendTime = currentTime
            default:
                break
            }
        }
    }
    
    /// Registers a pending SD operation with callback
    func registerSdOperation(operationId: UInt8, completion: @escaping (Bool) -> Void) {
        sdOperationQueue.async {
            self.pendingSdOperations[operationId] = completion
        }
    }
    
    /// Registers a pending SD query operation with callback
    func registerSdQueryOperation(operationId: UInt8, completion: @escaping (SDCardDirection?) -> Void) {
        sdOperationQueue.async {
            self.pendingSdQueryOperations[operationId] = completion
        }
    }
    
    /// Timeout handler for SD operations
    func timeoutSdOperation(operationId: UInt8) {
        sdOperationQueue.async {
            if let completion = self.pendingSdOperations.removeValue(forKey: operationId) {
                DispatchQueue.main.async {
                    self.logger.log(content: "SD operation \(operationId) timed out")
                    completion(false)
                }
            }
        }
    }
    
    /// Timeout handler for SD query operations
    func timeoutSdQueryOperation(operationId: UInt8) {
        sdOperationQueue.async {
            if let completion = self.pendingSdQueryOperations.removeValue(forKey: operationId) {
                DispatchQueue.main.async {
                    self.logger.log(content: "SD query operation \(operationId) timed out")
                    completion(nil)
                }
            }
        }
    }
    
    /// Sets up synchronous response waiting
    func waitForSyncResponse(expectedCmd: UInt8) {
        syncResponseQueue.sync {
            self.syncResponseExpectedCmd = expectedCmd
            self.syncResponseData = nil
        }
    }
    
    /// Gets synchronous response data
    func getSyncResponseData() -> Data? {
        return syncResponseQueue.sync {
            let data = self.syncResponseData
            self.syncResponseData = nil
            self.syncResponseExpectedCmd = nil
            return data
        }
    }
}

// MARK: - Main Response Handling
extension SerialResponseHandler {
    
    /// Main entry point for handling serial data responses
    func handleSerialData(data: Data) {
        let cmd = data[3]
        
        // Check if we're waiting for a synchronous response
        let isSyncResponse = syncResponseQueue.sync {
            let expectedCmd = self.syncResponseExpectedCmd
            if let expectedCmd = expectedCmd, expectedCmd == cmd {
                self.syncResponseData = data
                let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                if logger.SerialDataPrint {
                    logger.log(content: "SYNC: Rx(0x\(String(format: "%02X", cmd))）: \(dataString)")
                }
                return true  // This is a sync response
            }
            return false  // Not a sync response
        }
        
        if isSyncResponse {
            return  // Exit early - don't process command normally for sync responses
        }
        
        // Route to appropriate handler based on command type
        switch cmd {
        case SerialProtocolCommands.ResponseCodes.HID_INFO_RESPONSE:
            handleHidInfoResponse(data)
        case SerialProtocolCommands.ResponseCodes.KEYBOARD_ACK:
            handleKeyboardAck(data)
        case SerialProtocolCommands.ResponseCodes.MULTIMEDIA_ACK:
            handleMultimediaAck(data)
        case SerialProtocolCommands.ResponseCodes.MOUSE_ABSOLUTE_ACK, 
             SerialProtocolCommands.ResponseCodes.MOUSE_RELATIVE_ACK:
            handleMouseAck(data, cmd: cmd)
        case SerialProtocolCommands.ResponseCodes.CUSTOM_HID_SEND_ACK, 
             SerialProtocolCommands.ResponseCodes.CUSTOM_HID_READ_ACK:
            handleCustomHidAck(data, cmd: cmd)
        case SerialProtocolCommands.ResponseCodes.PARA_CFG_RESPONSE:
            handleParaCfgResponse(data)
        case SerialProtocolCommands.ResponseCodes.RESET_ACK:
            handleResetAck(data)
        case SerialProtocolCommands.ResponseCodes.SET_PARA_CFG_ACK:
            handleSetParaCfgAck(data)
        case SerialProtocolCommands.ResponseCodes.SD_DIRECTION_RESPONSE:
            handleSdDirectionResponse(data)
        case SerialProtocolCommands.ResponseCodes.CHECKSUM_ERROR:
            handleChecksumError(data)
        default:
            handleUnknownCommand(data, cmd: cmd)
        }
    }
}

// MARK: - Individual Response Handlers
extension SerialResponseHandler {
    
    private func handleHidInfoResponse(_ data: Data) {
        let byteValue = data[5]
        var chipVersion: Int8 = Int8(bitPattern: byteValue)
        
        // Special handling for chip version based on initial value
        if chipVersion == 0x00 {
            // If chipVersion is 00, get the version from data[12]
            if data.count > 12 {
                chipVersion = Int8(bitPattern: data[12])
            }
        } else if chipVersion == 0x01 || chipVersion == 0x02 {
            // If chipVersion is 01 or 02, get the version from data[7]
            if data.count > 8 {
                chipVersion = Int8(bitPattern: data[8])
            }
        }
        // For other values, chipVersion remains as is
        SerialPortStatus.shared.chipVersion = chipVersion
        
        // Update device capabilities based on chip version
        deviceCapabilities = DeviceCapabilities.forChipVersion(chipVersion)
        
        let isTargetConnected = data[6] == 0x01
        SerialPortStatus.shared.isTargetConnected = isTargetConnected
        SerialPortStatus.shared.isKeyboardConnected = isTargetConnected
        SerialPortStatus.shared.isMouseConnected = isTargetConnected

        logger.log(content: isTargetConnected ? "The Target Screen keyboard and mouse are connected" : "The Target Screen keyboard and mouse are disconnected")

        let isNumLockOn = (data[7] & 0x01) == 0x01
        SerialPortStatus.shared.isNumLockOn = isNumLockOn

        let isCapLockOn = (data[7] & 0x02) == 0x02
        SerialPortStatus.shared.isCapLockOn = isCapLockOn

        let isScrollOn = (data[7] & 0x04) == 0x04
        SerialPortStatus.shared.isScrollOn = isScrollOn
    }
    
    private func handleKeyboardAck(_ data: Data) {
        let kbStatus = data[5]
        
        // Calculate keyboard acknowledgement latency on dedicated timestamp queue
        timestampQueue.async { [weak self] in
            guard let self = self else { return }
            if let sendTime = self.lastKeyboardSendTime {
                let latency = Date().timeIntervalSince(sendTime) * 1000  // Convert to milliseconds
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.updateKeyboardLatency(latency, maxLatency: 0.0)
                    self?.delegate?.updateAckRates()
                }
            }
        }
        
        if logger.SerialDataPrint {
            logger.log(content: "Receive keyboard status: \(String(format: "0x%02X", kbStatus))")
        }
    }
    
    private func handleMultimediaAck(_ data: Data) {
        if logger.SerialDataPrint {
            let kbStatus = data[5]
            logger.log(content: "Receive multimedia status: \(String(format: "0x%02X", kbStatus))")
        }
    }
    
    private func handleMouseAck(_ data: Data, cmd: UInt8) {
        let mouseStatus = data[5]
        
        // Calculate mouse acknowledgement latency on dedicated timestamp queue
        timestampQueue.async { [weak self] in
            guard let self = self else { return }
            if let sendTime = self.lastMouseSendTime {
                let latency = Date().timeIntervalSince(sendTime) * 1000  // Convert to milliseconds
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.updateMouseLatency(latency, maxLatency: 0.0)
                    self?.delegate?.updateAckRates()
                }
            }
        }
        
        if logger.SerialDataPrint {
            let actionType = cmd == SerialProtocolCommands.ResponseCodes.MOUSE_ABSOLUTE_ACK ? "Absolute" : "Relative"
            logger.log(content: "\(actionType) mouse event sent, status: \(String(format: "0x%02X", mouseStatus))")
        }
    }
    
    private func handleCustomHidAck(_ data: Data, cmd: UInt8) {
        if logger.SerialDataPrint {
            let status = data[5]
            let actionType = cmd == SerialProtocolCommands.ResponseCodes.CUSTOM_HID_SEND_ACK ? "SEND" : "READ"
            logger.log(content: "Receive \(actionType) custom hid status: \(String(format: "0x%02X", status))")
        }
    }
    
    private func handleParaCfgResponse(_ data: Data) {
        guard data.count >= 12 else {
            logger.log(content: "Invalid data length for get para cfg command. Expected >= 12 bytes, got \(data.count)")
            return
        }
        
        let baudrateData = Data(data[8...11])
        let mode = data[5]
        let baudrateInt32 = baudrateData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Int32 in
            let intPointer = pointer.bindMemory(to: Int32.self)
            return intPointer[0].bigEndian
        }
        let baudrate = Int(baudrateInt32)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.updateDeviceConfiguration(baudrate: baudrate, mode: mode)
        }
    }
    
    private func handleResetAck(_ data: Data) {
        if logger.SerialDataPrint {
            let status = data[5]
            logger.log(content: "Device reset command response status: \(String(format: "0x%02X", status))")
        }
    }
    
    private func handleSetParaCfgAck(_ data: Data) {
        if logger.SerialDataPrint {
            let status = data[5]
            logger.log(content: "Set para cfg status: \(String(format: "0x%02X", status))")
        }
    }
    
    private func handleSdDirectionResponse(_ data: Data) {
        guard data.count >= 6 else {
            logger.log(content: "Invalid SD direction response length: \(data.count)")
            return
        }
        
        let dir = data[5]
        
        // Resolve direction value
        let resolvedDirection: SDCardDirection
        switch dir {
        case 0x00: resolvedDirection = .host
        case 0x01: resolvedDirection = .target
        default:
            resolvedDirection = .unknown
            logger.log(content: "CH32V208: SD card direction unknown (0x\(String(format: "%02X", dir)))")
        }
        
        // Update shared status and publish on main thread.
        // SerialPortManager subscribes to $sdCardDirection and pushes AppStatus
        // from there, so AppStatus is NOT modified here.
        SerialPortStatus.shared.sdCardDirection = resolvedDirection
        let captured = resolvedDirection
        DispatchQueue.main.async {
            self.sdCardDirection = captured
        }
        
        // Drain pending set-operation callbacks (setSdToHost / setSdToTarget).
        sdOperationQueue.async(flags: .barrier) {
            let setCompletions = Array(self.pendingSdOperations.values)
            self.pendingSdOperations.removeAll()
            let queryCompletions = Array(self.pendingSdQueryOperations.values)
            self.pendingSdQueryOperations.removeAll()
            DispatchQueue.main.async {
                setCompletions.forEach { $0(true) }
                queryCompletions.forEach { $0(captured) }
            }
        }
    }
    
    private func handleChecksumError(_ data: Data) {
        if logger.SerialDataPrint {
            let errorCode = data[5]
            logger.log(content: "Checksum error response: \(String(format: "0x%02X", errorCode))")
        }
    }
    
    private func handleUnknownCommand(_ data: Data, cmd: UInt8) {
        let hexCmd = String(format: "%02hhX", cmd)
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.log(content: "Unknown command: \(hexCmd), full data: \(dataString)")
    }
}

// MARK: - Device Capability Detection
extension SerialResponseHandler {
    
    /// Returns whether the current device supports SD card operations
    func supportsSDCardOperations() -> Bool {
        return deviceCapabilities?.supportsSDCard ?? false
    }
    
    /// Returns the device capabilities if available
    func getDeviceCapabilities() -> DeviceCapabilities? {
        return deviceCapabilities
    }
}

/// Defines capabilities for different device versions
struct DeviceCapabilities {
    let supportsSDCard: Bool
    let supportsAdvancedHID: Bool
    let chipVersion: Int8
    
    static func forChipVersion(_ version: Int8) -> DeviceCapabilities {
        // Define capability mappings based on chip versions
        // This can be expanded as more device capabilities are discovered
        switch version {
        case -126, -125, -124: // CH32V208 versions that support SD card
            return DeviceCapabilities(supportsSDCard: true, supportsAdvancedHID: true, chipVersion: version)
        case 1, 2, 3, 4: // CH9329 versions - no SD card support
            return DeviceCapabilities(supportsSDCard: false, supportsAdvancedHID: true, chipVersion: version)
        default:
            // Conservative default: assume basic functionality only
            return DeviceCapabilities(supportsSDCard: false, supportsAdvancedHID: false, chipVersion: version)
        }
    }
}