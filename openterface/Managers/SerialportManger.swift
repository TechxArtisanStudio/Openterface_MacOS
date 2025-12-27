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

import SwiftUI
import Foundation
import ORSSerial
import os.log
import Combine

class SerialPortManager: NSObject, ORSSerialPortDelegate, SerialPortManagerProtocol, ObservableObject {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    static let shared = SerialPortManager()
    var tryOpenTimer: Timer?
    var receiveBuffer = Data()

    public static var MOUSE_ABS_ACTION_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x04, 0x07, 0x02]
    public static var MOUSE_REL_ACTION_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x05, 0x05, 0x01]
    public static let CMD_GET_HID_INFO: [UInt8] = [0x57, 0xAB, 0x00, 0x01, 0x00]
    public static let CMD_GET_PARA_CFG: [UInt8] = [0x57, 0xAB, 0x00, 0x08, 0x00]
    public static let KEYBOARD_DATA_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x02, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    
    // Multimedia/ACPI key data prefix: [HEAD, ADDR, CMD, LEN, ...]
    // CMD: 0x03 for multimedia keys
    // ACPI keys:       [0x57, 0xAB, 0x00, 0x03, 0x04, 0x01, DATA, 0, 0, checksum] - Report ID 0x01, 1 data byte
    // Multimedia keys: [0x57, 0xAB, 0x00, 0x03, 0x04, 0x02, BYTE2, 0, 0, checksum] - Report ID 0x02, 3 data bytes
    public static let MULTIMEDIA_KEY_CMD_PREFIX: [UInt8] = [0x57, 0xAB, 0x00, 0x03, 0x04]
    public static let CMD_SET_PARA_CFG_PREFIX_115200: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x01, 0xC2, 0x00]
    public static let CMD_SET_PARA_CFG_PREFIX_9600: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x25, 0x80, 0x00]
    public static let CMD_SET_PARA_CFG_POSTFIX: [UInt8] = [0x08, 0x00, 0x00, 0x03, 0x86, 0x1A, 0x29, 0xE1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    public static let CMD_RESET: [UInt8] = [0x57, 0xAB, 0x00, 0x0F, 0x00]
    
    // Baudrate constants
    public static let LOWSPEED_BAUDRATE = BaseControlChipset.LOWSPEED_BAUDRATE
    public static let HIGHSPEED_BAUDRATE = BaseControlChipset.HIGHSPEED_BAUDRATE
    
    @objc let serialPortManager = ORSSerialPortManager.shared()
    
    @objc dynamic var serialPort: ORSSerialPort? {
        didSet {
            oldValue?.close()
            oldValue?.delegate = nil
            serialPort?.delegate = self
        }
    }
    
    
    @Published var serialFile: Int32 = 0
    
    @Published var serialPorts : [ORSSerialPort] = []
    
    var lastHIDEventTime: Date?
    
    /// Stores the timestamp of the latest serial data received.
    /// 
    /// This property tracks when the most recent data was received from the serial port,
    /// allowing the application to monitor the activity and timing of serial communications.
    /// 
    /// **Usage:**
    /// - Initially set to `nil` to indicate no data has been received yet
    /// - Updated each time data is successfully received via `serialPort(_:didReceive:)`
    /// - Can be used to detect communication gaps or device inactivity
    /// - Useful for debugging and monitoring connection health
    var lastSerialData: Date?
    
    /// Stores the previous state of the CTS (Clear To Send) pin for change detection.
    /// 
    /// The CTS pin is connected to the CH340 data flip pin on the Openterface Mini KVM device.
    /// This connection allows the system to detect HID activity from the Target Screen:
    /// 
    /// **How it works:**
    /// - When the Target Screen sends HID data (keyboard/mouse input), the CH340 chip toggles its data flip pin
    /// - This causes the CTS pin state to change, which can be monitored through the serial port
    /// - By comparing the current CTS state with `lastCts`, we can detect when new HID events occur
    /// 
    /// **Usage:**
    /// - Initially set to `nil` to indicate no previous state has been recorded
    /// - Updated in `checkCTS()` method whenever a CTS state change is detected
    /// - When CTS state changes, it indicates HID activity and updates connection status:
    ///   - `AppStatus.isKeyboardConnected = true`
    ///   - `AppStatus.isMouseConnected = true`
    ///   - `lastHIDEventTime` is refreshed
    /// 
    /// This mechanism provides a hardware-level indication of Target Screen activity without
    /// relying solely on software-based communication protocols.
    var lastCts: Bool?
    
    var timer: Timer?
    
    @Published var baudrate:Int = 0
    
    // Synchronous command response handling
    private var syncResponseQueue = DispatchQueue(label: "com.openterface.SerialPortManager.syncResponse")
    private var syncResponseData: Data?
    private var syncResponseExpectedCmd: UInt8?
    
    // Acknowledgement latency tracking
    @Published var keyboardAckLatency: Double = 0.0  // in milliseconds
    @Published var mouseAckLatency: Double = 0.0     // in milliseconds
    @Published var keyboardMaxLatency: Double = 0.0  // max latency in last 10 seconds (milliseconds)
    @Published var mouseMaxLatency: Double = 0.0     // max latency in last 10 seconds (milliseconds)
    private var lastKeyboardSendTime: Date?
    private var lastMouseSendTime: Date?
    private var keyboardMaxLatencyTrackingStart: TimeInterval = Date().timeIntervalSince1970
    private var mouseMaxLatencyTrackingStart: TimeInterval = Date().timeIntervalSince1970
    
    // Acknowledgement rate tracking (ACK per second)
    @Published var keyboardAckRate: Double = 0.0  // ACK per second
    @Published var mouseAckRate: Double = 0.0     // ACK per second
    @Published var keyboardAckRateSmoothed: Double = 0.0  // Smoothed display value
    @Published var mouseAckRateSmoothed: Double = 0.0     // Smoothed display value
    private var keyboardAckCount: Int = 0
    private var mouseAckCount: Int = 0
    private var ackTrackingStartTime: TimeInterval = Date().timeIntervalSince1970
    private let ackTrackingInterval: TimeInterval = 5.0  // Calculate over 5 seconds
    private let ackRateSmoothingFactor: Double = 0.3  // EMA smoothing factor (0-1, lower = smoother)
    var disablePeriodicAckReset: Bool = false  // Set to true during stress tests to prevent periodic resets
    
    /// Tracks the number of complete retry cycles through all baudrates.
    /// Incremented after each full cycle through both 9600 and 115200 baudrates.
    /// After 2 complete cycles (trying both baudrates twice), triggers a factory reset.
    var retryCounter: Int = 0
    
    /// Indicates whether the Openterface Mini KVM device is properly connected, validated, and ready for communication.
    /// 
    /// This flag is set to `true` when:
    /// - The device responds with the correct protocol prefix [0x57, 0xAB, 0x00]
    /// - The device confirms proper baudrate (115200) and mode (0x82) configuration
    /// 
    /// This flag is set to `false` when:
    /// - The serial port is closed or disconnected
    /// - Initial connection state before device validation
    /// 
    /// Commands will only be sent when `isDeviceReady` is true, unless the `force` parameter is used.
    @Published public var isDeviceReady: Bool = false
    
    /// Indicates whether the serial port manager is currently attempting to establish a connection.
    /// 
    /// This flag is used to track the connection attempt state and prevent multiple concurrent connection attempts.
    /// 
    /// This flag is set to `true` when:
    /// - `tryOpenSerialPort()` method is called and connection process begins
    /// 
    /// This flag remains `true` during the entire connection attempt process, which includes:
    /// - Iterating through available serial ports
    /// - Trying different baudrates (115200 and 9600)
    /// - Waiting for device validation responses
    /// - Retrying connection attempts until `isDeviceReady` becomes true
    /// 
    /// The connection attempt loop continues until a successful connection is established
    /// (when `isDeviceReady` becomes true), at which point the background connection process exits.
    
    /// Indicates whether serial port configuration (baudrate or mode change) is in progress
    /// This flag is set to true when starting a configuration change and false when complete
    @Published var isConfiguring: Bool = false
    private let isTryingQueue = DispatchQueue(label: "com.openterface.SerialPortManager.isTryingQueue")
    private var _isTrying: Bool = false
    var isTrying: Bool {
        get {
            return isTryingQueue.sync { _isTrying }
        }
        set {
            isTryingQueue.sync { _isTrying = newValue }
        }
    }
    
    /// Indicates whether the serial port manager is paused and should not attempt any connections.
    /// 
    /// This flag is used to temporarily disable all connection attempts during critical operations
    /// such as factory reset or firmware updates to prevent interference.
    /// 
    /// When `isPaused` is `true`:
    /// - All connection attempts are blocked
    /// - Existing connection loops will exit
    /// - No new connection attempts will be started
    /// 
    /// This provides a more robust control mechanism than just stopping current attempts,
    /// as it prevents new attempts from being started automatically.
    private let pauseQueue = DispatchQueue(label: "com.openterface.SerialPortManager.pauseQueue")
    private var _isPaused: Bool = false
    var isPaused: Bool {
        get {
            return pauseQueue.sync { _isPaused }
        }
        set {
            pauseQueue.sync { _isPaused = newValue }
        }
    }
    
    /// Tracks whether an error alert has been shown to the user.
    /// This ensures error alerts are displayed only once to avoid redundant notifications.
    private let errorAlertQueue = DispatchQueue(label: "com.openterface.SerialPortManager.errorAlertQueue")
    private var _errorAlertShown: Bool = false
    private var errorAlertShown: Bool {
        get {
            return errorAlertQueue.sync { _errorAlertShown }
        }
        set {
            errorAlertQueue.sync { _errorAlertShown = newValue }
        }
    }

    override init(){
        super.init()
        
//        self.initializeSerialPort()
        self.observerSerialPortNotifications()
    }
    
    /// Normalizes control mode byte values to their canonical forms
    /// Mode equivalences: 0x80=0x00, 0x81=0x01, 0x82=0x02, 0x83=0x03
    /// - Parameter mode: The raw mode byte value
    /// - Returns: The normalized mode byte (uses lower value of equivalent pairs)
    private func normalizeMode(_ mode: UInt8) -> UInt8 {
        switch mode {
        case 0x80: return 0x00  // Normalize 0x80 to 0x00
        case 0x81: return 0x01  // Normalize 0x81 to 0x01
        case 0x82: return 0x02  // Normalize 0x82 to 0x02
        case 0x83: return 0x03  // Normalize 0x83 to 0x03
        default: return mode
        }
    }
    
    /// Checks if two mode bytes are equivalent after normalization
    /// - Parameters:
    ///   - mode1: First mode byte to compare
    ///   - mode2: Second mode byte to compare
    /// - Returns: true if modes are equivalent after normalization
    private func modesAreEquivalent(_ mode1: UInt8, _ mode2: UInt8) -> Bool {
        return normalizeMode(mode1) == normalizeMode(mode2)
    }
    
    func initializeSerialPort(){
        // If the usb device is connected, try to open the serial port
        if logger.SerialDataPrint { logger.log(content: "Initializing Serial Port") }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.tryConnectOpenterface()
        }
    }
    
    func tryConnectOpenterface(){
//        USBDevicesManager.shared.update()
        if USBDevicesManager.shared.isOpenterfaceConnected(){
            // Check the control chipset type and use appropriate connection method
            if AppStatus.controlChipsetType == .ch32v208 {
                logger.log(content: "CH32V208 detected - using direct serial port connection")
                self.tryOpenSerialPortForCH32V208()
            } else if AppStatus.controlChipsetType == .ch9329 {
                logger.log(content: "CH9329 detected - using standard serial port connection with validation")
                self.tryOpenSerialPort()
            } else {
                logger.log(content: "Unknown control chipset type: \(AppStatus.controlChipsetType) - using standard connection method")
                self.tryOpenSerialPort()
            }
        }
    }

    private func observerSerialPortNotifications() {
        print("observerSerialPortNotifications")
        let serialPortNtf = NotificationCenter.default
       
        serialPortNtf.addObserver(self, selector: #selector(serialPortsWereConnected(_:)), name: NSNotification.Name.ORSSerialPortsWereConnected, object: nil)
        serialPortNtf.addObserver(self, selector: #selector(serialPortsWereDisconnected(_:)), name: NSNotification.Name.ORSSerialPortsWereDisconnected, object: nil)
    }

    @objc func serialPortsWereConnected(_ notification: Notification) {
        if !self.isTrying && !self.isPaused {
            self.tryConnectOpenterface()
        } else if self.isPaused {
            logger.log(content: "Serial port connected but connection attempts are paused")
        }
    }
    
    @objc func serialPortsWereDisconnected(_ notification: Notification) {
        logger.log(content: "Serial port Disconnected")
        self.retryCounter = 0
        self.closeSerialPort()
    }

    func checkCTS() {
        // CTS monitoring only applies to CH9329 chipset
        if !USBDevicesManager.shared.isCH9329Connected() {
            return
        }
        
        if let cts = self.serialPort?.cts {
            if lastCts == nil {
                lastCts = cts
                lastHIDEventTime = Date()
            }
            if lastCts != cts {
                AppStatus.isKeyboardConnected = true
                AppStatus.isMouseConnected = true
                lastHIDEventTime = Date()
                lastCts = cts
            }
        }
        
        self.checkHIDEventTime()
    }

    func checkHIDEventTime() {
        // HID event time checking only applies to CH9329 chipset
        if !USBDevicesManager.shared.isCH9329Connected() {
            return
        }

        if _isPaused {
            return
        }
        
        // Check for stale CH9329 chip state
        // This occurs when lastSerialData is updated but lastHIDEventTime hasn't changed for 2+ seconds
        // indicating the CH9329 chip is receiving data but not processing HID events properly
        // if let serialDataTime = lastSerialData, let hidEventTime = lastHIDEventTime {
        //     let timeSinceLastHIDEvent = Date().timeIntervalSince(hidEventTime)
        //     let timeSinceLastSerialData = Date().timeIntervalSince(serialDataTime)
            
        //     // If serial data is recent but HID event is stale (2+ seconds), chip is in stale state
        //     if timeSinceLastSerialData < 1.0 && timeSinceLastHIDEvent > 10.0 {
        //         logger.log(content: "CH9329 chip detected in stale state: serial data updated but no HID events. Serial data age: \(String(format: "%.1f", timeSinceLastSerialData))s, HID event age: \(String(format: "%.1f", timeSinceLastHIDEvent))s")
                
        //         // Show alert to user and offer automatic recovery
        //         DispatchQueue.main.async { [weak self] in
        //             self?.promptUserForChipRecovery()
        //         }
                
        //         // Reset the check timer to avoid repeated alerts
        //         lastHIDEventTime = Date()
        //         return
        //     }
        // }
        
        if let lastTime = lastHIDEventTime {
            if Date().timeIntervalSince(lastTime) > 5 {

                // 5 seconds pass since last HID event
                if logger.SerialDataPrint {
                    logger.log(content: "No hid update more than 5 second, check the HID information")
                }
                // Rest the time, to avoide duplicated check
                lastHIDEventTime = Date()
                getHidInfo()
            }
        }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        if logger.SerialDataPrint { logger.log(content: "Serial opened") }
        
        // Start CTS monitoring for HID event detection
        self.startCTSMonitoring()
    }
    
    func serialPortWasClosed(_ serialPort: ORSSerialPort) {

        if logger.SerialDataPrint { logger.log(content: "Serial port was closed") }

    }
    
    /*
     * Receive data from serial
     */
    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        // Record the timestamp of this serial data reception
        lastSerialData = Date()
        
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        if logger.SerialDataPrint {
            logger.log(content: "[Baudrate:\(self.baudrate)] Rx: \(dataString)")
        }
        
        // Append new data to buffer
        receiveBuffer.append(data)
        
        // Process all complete messages in the buffer
        processBufferedMessages()
    }
    
    private func processBufferedMessages() {
        var bufferBytes = [UInt8](receiveBuffer)
        var processedBytes = 0
        
        if logger.SerialDataPrint { logger.log(content: "PROCESS: Buffer size=\(bufferBytes.count)") }
        
        while bufferBytes.count >= 6 { // Minimum message size: 5 bytes header + 1 byte checksum
            // Look for the next valid message start
            guard let prefixIndex = findNextMessageStart(in: bufferBytes, from: processedBytes) else {
                logger.log(content: "No valid message start found in buffer, discarding \(bufferBytes.count) bytes")
                // No valid message start found, keep remaining data in buffer
                if processedBytes > 0 {
                    receiveBuffer = Data(bufferBytes[processedBytes...])
                }
                return
            }
            
            // Adjust buffer if we skipped invalid data
            if prefixIndex > processedBytes {
                if logger.SerialDataPrint {
                    let skippedData = bufferBytes[processedBytes..<prefixIndex]
                    let skippedString = skippedData.map { String(format: "%02X", $0) }.joined(separator: " ")
                    logger.log(content: "Skipping invalid data: \(skippedString)")
                }
                bufferBytes = Array(bufferBytes[prefixIndex...])
                processedBytes = 0
            }
            
            // Check if we have enough bytes for a complete message
            if bufferBytes.count < 6 {
                logger.log(content: "Not enough data for complete message, waiting for more data")
                break
            }
            
            let len = bufferBytes[4]
            let expectedMessageLength = Int(len) + 6 // 5 bytes header + length + 1 byte checksum
            
            if bufferBytes.count < expectedMessageLength {
                logger.log(content: "Incomplete message in buffer, waiting for more data, expected length: \(expectedMessageLength), current length: \(bufferBytes.count)")
                break
            }
            
            // Extract the complete message
            let messageBytes = Array(bufferBytes[0..<expectedMessageLength])
            let messageData = Data(messageBytes)
            
            // Verify checksum
            let chksum = messageBytes[messageBytes.count - 1]
            let checksum = self.calculateChecksum(data: Array(messageBytes[0..<messageBytes.count - 1]))
            
            if chksum == checksum {
                self.isDeviceReady = true
                self.errorAlertShown = false  // Reset error alert flag on successful connection
                
                let msgString = messageBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                handleSerialData(data: messageData)
            } else {
                let errorDataString = messageBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                let checksumHex = String(format: "%02X", checksum)
                let chksumHex = String(format: "%02X", chksum)
                logger.log(content: "Checksum error, discard the message: \(errorDataString), calculated checksum: \(checksumHex), received checksum: \(chksumHex)")
            }
            
            // Move to the next message
            bufferBytes = Array(bufferBytes[expectedMessageLength...])
            processedBytes = 0
        }
        
        // Update the buffer with remaining data
        receiveBuffer = Data(bufferBytes)
    }
    
    private func findNextMessageStart(in bytes: [UInt8], from startIndex: Int) -> Int? {
        let prefix: [UInt8] = [0x57, 0xAB, 0x00]
        
        for i in startIndex..<(bytes.count - 2) {
            if bytes[i] == prefix[0] && bytes[i + 1] == prefix[1] && bytes[i + 2] == prefix[2] {
                return i
            }
        }
        return nil
    }

    func handleSerialData(data: Data) {
        let cmd = data[3]
        
        // Check if we're waiting for a synchronous response
        syncResponseQueue.sync {
            let expectedCmd = self.syncResponseExpectedCmd
            if let expectedCmd = expectedCmd, expectedCmd == cmd {
                self.syncResponseData = data
                let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                logger.log(content: "SYNC: Captured response for cmd 0x\(String(format: "%02X", cmd)): \(dataString)")
                return  // Exit early - don't process command normally for sync responses
            } else {
                if logger.SerialDataPrint {
                    logger.log(content: "SYNC: expectedCmd=\(expectedCmd?.description ?? "nil"), received cmd=0x\(String(format: "%02X", cmd))")
                }
            }
        }

        switch cmd {
        case 0x81:  // HID info
            let byteValue = data[5]
            let chipVersion: Int8 = Int8(bitPattern: byteValue)
            AppStatus.chipVersion = Int8(chipVersion)
            
            let isTargetConnected = data[6] == 0x01
            AppStatus.isTargetConnected = isTargetConnected
            
            AppStatus.isKeyboardConnected = isTargetConnected
            AppStatus.isMouseConnected = isTargetConnected

            
            logger.log(content: isTargetConnected ? "The Target Screen keyboard and mouse are connected" : "The Target Screen keyboard and mouse are disconnected")
            
            let isNumLockOn = (data[7] & 0x01) == 0x01
            AppStatus.isNumLockOn = isNumLockOn
            
            let isCapLockOn = (data[7] & 0x02) == 0x02
            AppStatus.isCapLockOn = isCapLockOn
            
            let isScrollOn = (data[7] & 0x04) == 0x04
            AppStatus.isScrollOn = isScrollOn
            
            // logger.log(content: "Receive HID info, chip version: \(chipVersion), target connected: \(isTargetConnected), NumLock: \(isNumLockOn), CapLock: \(isCapLockOn), Scroll: \(isScrollOn)")
            
        case 0x82:  //Keyboard hid execution status 0 - success
            let kbStatus = data[5]
            // Calculate keyboard acknowledgement latency
            if let sendTime = lastKeyboardSendTime {
                let latency = Date().timeIntervalSince(sendTime) * 1000  // Convert to milliseconds
                keyboardAckLatency = latency
                // Update max latency if current latency is higher
                if latency > keyboardMaxLatency {
                    keyboardMaxLatency = latency
                }
            }
            // Track keyboard ACK count
            keyboardAckCount += 1
            updateAckRates()
            
            if logger.SerialDataPrint  {
                logger.log(content: "Receive keyboard status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x83:  //multimedia data hid execution status 0 - success
            if logger.SerialDataPrint  {
                let kbStatus = data[5]
                logger.log(content: "Receive multi-meida status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x84, 0x85:  //Mouse hid execution status 0 - success
            let kbStatus = data[5]
            // Calculate mouse acknowledgement latency
            if let sendTime = lastMouseSendTime {
                let latency = Date().timeIntervalSince(sendTime) * 1000  // Convert to milliseconds
                mouseAckLatency = latency
                // Update max latency if current latency is higher
                if latency > mouseMaxLatency {
                    mouseMaxLatency = latency
                }
            }
            // Track mouse ACK count
            mouseAckCount += 1
            updateAckRates()
            if logger.SerialDataPrint {
                logger.log(content: "\(cmd == 0x84 ? "Absolute" : "Relative") mouse event sent, status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x86, 0x87:  //custom hid execution status 0 - success
            if logger.SerialDataPrint  {
                let kbStatus = data[5]
                logger.log(content: "Receive \(cmd == 0x86 ? "SEND" : "READ") custom hid status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x88:  // get para cfg
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
            self.baudrate = Int(baudrateInt32)
            let portPath = self.serialPort?.path ?? "Unknown"
            logger.log(content: "Serial Port: \(portPath), Baudrate: \(self.baudrate), Mode: \(String(format: "%02X", mode))")

            let preferredBaud = UserSettings.shared.preferredBaudrate.rawValue
            let preferredMode = UserSettings.shared.controlMode.modeByteValue
            
            // Check if mode matches user's preference using normalization
            // Mode equivalences: 0x80=0x00, 0x81=0x01, 0x82=0x02, 0x83=0x03
            let modeMatches = modesAreEquivalent(mode, preferredMode)
            
            if self.baudrate == preferredBaud && modeMatches {
                // Device matches the user's preferred baudrate and mode
                self.isDeviceReady = true
                self.errorAlertShown = false  // Reset error alert flag on successful connection
                AppStatus.serialPortBaudRate = self.baudrate
                AppStatus.isControlChipsetReady = true
            } else {
                // Device configuration differs from user preference - update user settings to match device configuration
                logger.log(content: "Device configuration detected. Expected: baudrate=\(preferredBaud) mode=0x\(String(format: "%02X", preferredMode)), Got: baudrate=\(self.baudrate) mode=0x\(String(format: "%02X", mode)). Updating user settings...")
                
                // Update preferred baudrate in user settings
                if let baudrateOption = BaudrateOption(rawValue: self.baudrate) {
                    UserSettings.shared.preferredBaudrate = baudrateOption
                    logger.log(content: "Updated user preferred baudrate to \(self.baudrate)")
                } else {
                    logger.log(content: "Warning: Detected baudrate \(self.baudrate) is not a valid BaudrateOption")
                }
                
                // Update control mode in user settings
                if let controlMode = ControlMode(rawValue: Int(mode)) {
                    UserSettings.shared.controlMode = controlMode
                    logger.log(content: "Updated user control mode to \(controlMode.displayName)")
                } else {
                    logger.log(content: "Warning: Detected mode 0x\(String(format: "%02X", mode)) is not a valid ControlMode, attempting normalization")
                    let normalizedMode = normalizeMode(mode)
                    if let controlMode = ControlMode(rawValue: Int(normalizedMode)) {
                        UserSettings.shared.controlMode = controlMode
                        logger.log(content: "Updated user control mode to \(controlMode.displayName) (normalized from 0x\(String(format: "%02X", mode)))")
                    }
                }
                
                // Mark device as ready with the current configuration
                self.isDeviceReady = true
                self.errorAlertShown = false
                AppStatus.serialPortBaudRate = self.baudrate
                AppStatus.isControlChipsetReady = true
                logger.log(content: "Device ready with detected configuration")
            }

        case 0x8F:
            if logger.SerialDataPrint {
                let status = data[5]
                logger.log(content: "Device reset command response status: \(String(format: "0x%02X", status))")
            }
        case 0x89:  // set para cfg
            if logger.SerialDataPrint {
                let status = data[5]
                logger.log(content: "Set para cfg status: \(String(format: "0x%02X", status))")
            }
        //Handle error command responses
        case 0xC4:  // checksum error
            if logger.SerialDataPrint {
                let errorCode = data[5]
                logger.log(content: "Checksum error response: \(String(format: "0x%02X", errorCode))")
            }
        default:
            let hexCmd = String(format: "%02hhX", cmd)
            let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.log(content: "Unknown command: \(hexCmd), full data: \(dataString)")
        }
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        self.serialPort = nil
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        if logger.SerialDataPrint { logger.log(content: "SerialPort \(serialPort) encountered an error: \(error)") }
        self.closeSerialPort()
        
        // // Show user-friendly error alert for serial communication issues
        // DispatchQueue.main.async {
        //     self.promptUserForSerialConnectionError(error: error)
        // }
    }

    func listSerialPorts() -> [ORSSerialPort] {
        self.serialPorts = serialPortManager.availablePorts
        return self.serialPorts
    }
    
    func tryOpenSerialPort( priorityBaudrate: Int? = nil) {

        // Use priority baudrate if provided, otherwise use preferred baudrate from user settings
        let effectivePriorityBaudrate = priorityBaudrate ?? UserSettings.shared.preferredBaudrate.rawValue
        
        // Check if connection attempts are paused
        if self.isPaused {
            logger.log(content: "Connection attempts are paused, returning early")
            return
        }
        
        // Check if already trying to prevent race conditions
        if self.isTrying {
            logger.log(content: "Already trying to connect, returning early")
            return
        }
        
        self.isTrying = true
        
        // get all available serial ports
        guard let availablePorts = serialPortManager.availablePorts as? [ORSSerialPort], !availablePorts.isEmpty else {
            logger.log(content: "No available serial ports found")
            self.isTrying = false
            return
        }
        self.serialPorts = availablePorts // Get the list of available serial ports
        
        let backgroundQueue = DispatchQueue(label: "background", qos: .background)
        backgroundQueue.async { [weak self] in
            guard let self = self else { 
                return 
            }

            while !self.isDeviceReady {
                // Check if connection attempts are paused
                if self.isPaused {
                    logger.log(content: "Connection attempts paused, exiting connection loop")
                    break
                }
                
                // Check if we should stop trying (in case of disconnection)
                if !self.isTrying {
                    break
                }
                
                // Try user's preferred baudrate first, then fall back to the other
                let preferredBaudrate = UserSettings.shared.preferredBaudrate.rawValue
                let otherBaudrate = preferredBaudrate == SerialPortManager.LOWSPEED_BAUDRATE ? 
                    SerialPortManager.HIGHSPEED_BAUDRATE : SerialPortManager.LOWSPEED_BAUDRATE
                let baudrates = [preferredBaudrate, otherBaudrate]
                    
                
                for baudrate in baudrates {
                    // Check pause status before each baudrate attempt
                    if self.isPaused {
                        logger.log(content: "Connection attempts paused during baudrate attempts, exiting")
                        self.isTrying = false
                        return
                    }
                    
                    if self.tryConnectWithBaudrate(baudrate) {
                        logger.log(content: "Connected successfully with baudrate: \(baudrate)")
                        // Save the successful baudrate to user settings
                        UserSettings.shared.lastBaudrate = baudrate
                        // Reset retry counter on successful connection
                        self.retryCounter = 0
                        self.isTrying = false
                        return // Connection successful, exit the loop
                    }
                    
                    // Check if we should stop trying between baudrate attempts
                    if !self.isTrying {
                        return
                    }
                    self.serialPort?.close()
                    Thread.sleep(forTimeInterval: 1)
                }
                
                // Completed a full cycle through all baudrates
                self.retryCounter += 1
                logger.log(content: "Completed baudrate retry cycle \(self.retryCounter) of 2")
                
                // After trying both baudrates twice (2 complete cycles), trigger factory reset
                if self.retryCounter >= 2 {
                    logger.log(content: "Maximum retry attempts reached (tried 9600 and 115200 twice each). Performing factory reset of HID chip...")
                    
                    // Reset the counter for potential future attempts
                    self.retryCounter = 0
                    
                    // Perform the factory reset
                    if self.performFactoryResetInline() {
                        logger.log(content: "Factory reset done, retrying connection attempts...")
                        continue
                    } else {
                        logger.log(content: "Factory reset failed, exiting connection attempts")
                        self.isTrying = false
                        return
                    }
                }
            }
            
            // Always set isTrying to false when exiting the background task
            self.isTrying = false
        }
        
        // Remove this line - it was causing the race condition
        // self.isTrying = false
    }

    
    // Helper method: Try to connect with specified baud rate
    private func tryConnectWithBaudrate(_ baudrate: Int) -> Bool {
        logger.log(content: "Trying to connect with baudrate: \(baudrate)")
        self.serialPort = getSerialPortPathFromUSBManager()
        AppStatus.serialPortBaudRate = baudrate

        if self.serialPort != nil {
            logger.log(content: "Trying to connect with baudrate: \(baudrate), path: \(self.serialPort?.path ?? "Unknown")")
            self.openSerialPort(baudrate: baudrate)
            
            // For CH32V208, device is ready once port is opened (no command-response validation needed)
            if AppStatus.controlChipsetType == .ch32v208 {
                if self.serialPort?.isOpen == true {
                    self.isDeviceReady = true
                    self.errorAlertShown = false
                    logger.log(content: "CH32V208: Port opened successfully, device ready")
                    return true
                }
            } else {
                // For CH9329, validate connection by getting HID info
                // Give device time to stabilize after port opens (CH9329 can be slow to wake up)
                Thread.sleep(forTimeInterval: 0.5)  // 500ms delay (on background queue, this is safe)
                
                // Send sync command to get HID info with longer timeout to account for device latency
                let hidInfoResponse = self.sendSyncCommand(
                    command: SerialPortManager.CMD_GET_HID_INFO,
                    expectedResponseCmd: 0x81,
                    timeout: 5.0,  // Increased timeout to 5 seconds
                    force: true
                )
                
                // Validate the HID info response
                if self.validateHidInfoResponse(hidInfoResponse) {
                    logger.log(content: "CH9329: Valid HID info received and validated at baudrate \(baudrate)")
                    // Now send async command to get full parameter configuration
                    self.getChipParameterCfg()
                    return true
                } else {
                    logger.log(content: "CH9329: Failed to validate HID info response at baudrate \(baudrate)")
                    self.isDeviceReady = false
                    return false
                }
            }
        }
        
        return false
    }
    
    /// Validates the HID info response from the device.
    /// Checks:
    /// - Response is not empty
    /// - Message has minimum required length (8 bytes)
    /// - Header prefix is correct [0x57, 0xAB, 0x00]
    /// - Command byte is 0x81 (HID info response)
    /// - Checksum is valid
    /// - Extracts and stores the chip version and baudrate
    ///
    /// - Parameter response: The response data from the device
    /// - Returns: true if response is valid and all checks pass, false otherwise
    private func validateHidInfoResponse(_ response: Data) -> Bool {
        // Check if response is empty or too short
        guard !response.isEmpty && response.count >= 8 else {
            logger.log(content: "Invalid HID info response: empty or too short (got \(response.count) bytes)")
            return false
        }
        
        let responseBytes = [UInt8](response)
        
        // Check header prefix [0x57, 0xAB, 0x00]
        guard responseBytes[0] == 0x57 && responseBytes[1] == 0xAB && responseBytes[2] == 0x00 else {
            logger.log(content: "Invalid HID info response: incorrect header prefix")
            return false
        }
        
        // Check command byte (should be 0x81 for HID info response)
        guard responseBytes[3] == 0x81 else {
            logger.log(content: "Invalid HID info response: command byte is 0x\(String(format: "%02X", responseBytes[3])), expected 0x81")
            return false
        }
        
        // Verify checksum
        let receivedChecksum = responseBytes[responseBytes.count - 1]
        let calculatedChecksum = self.calculateChecksum(data: Array(responseBytes[0..<responseBytes.count - 1]))
        
        guard receivedChecksum == calculatedChecksum else {
            let checksumHex = String(format: "%02X", calculatedChecksum)
            let receivedHex = String(format: "%02X", receivedChecksum)
            logger.log(content: "Invalid HID info response: checksum mismatch. Calculated: 0x\(checksumHex), Received: 0x\(receivedHex)")
            return false
        }
        
        // Extract and log chip version
        let chipVersion: Int8 = Int8(bitPattern: responseBytes[5])
        logger.log(content: "HID info validated - Chip version: \(chipVersion)")
        
        // Extract target connection status
        let isTargetConnected = responseBytes[6] == 0x01
        logger.log(content: "HID info - Target connected: \(isTargetConnected)")
        
        // Extract lock states
        let isNumLockOn = (responseBytes[7] & 0x01) == 0x01
        let isCapLockOn = (responseBytes[7] & 0x02) == 0x02
        let isScrollOn = (responseBytes[7] & 0x04) == 0x04
        logger.log(content: "HID info - NumLock: \(isNumLockOn), CapLock: \(isCapLockOn), Scroll: \(isScrollOn)")
        
        // Store baudrate if we have it (from the current connection)
        AppStatus.serialPortBaudRate = self.baudrate
        
        return true
    }
    
    /// NOTE: Removed blockMainThreadFor* functions
    /// These functions blocked the main RunLoop, which prevented ORSSerial delegate callbacks
    /// from ever firing. NEVER block the main thread's RunLoop when using async serial libraries.

    
    /// Performs a factory reset of the HID chip synchronously within the connection retry loop
    /// Uses the existing performFactoryReset method with synchronous blocking
    /// Ensures serial port is opened before attempting factory reset
    /// - Returns: true if reset succeeded, false if it failed
    private func performFactoryResetInline() -> Bool {
        // Ensure serial port is open before attempting factory reset
        if let port = serialPort, port.isOpen {
            // Port is already open, proceed with factory reset
            var resetSucceeded = false
            let semaphore = DispatchSemaphore(value: 0)
            
            // Call the async performFactoryReset and wait for completion
            performFactoryReset { success in
                resetSucceeded = success
                semaphore.signal()
            }
            
            // Block until the factory reset completes
            semaphore.wait()
            
            return resetSucceeded
        } else {
            // Port not open, try to open it
            logger.log(content: "Serial port not open for factory reset, attempting to open it first")
            
            // Try to open the serial port
            self.serialPort = getSerialPortPathFromUSBManager()
            guard let serialPort = self.serialPort else {
                logger.log(content: "Failed to get serial port for factory reset")
                return false
            }
            
            // Open with low baudrate (factory reset typically requires this)
            serialPort.baudRate = NSNumber(value: CH9329ControlChipset.LOWSPEED_BAUDRATE)
            serialPort.delegate = self
            serialPort.open()
            
            guard serialPort.isOpen else {
                logger.log(content: "Failed to open serial port for factory reset")
                return false
            }
            
            logger.log(content: "Serial port opened successfully for factory reset at \(CH9329ControlChipset.LOWSPEED_BAUDRATE) baud")
            
            var resetSucceeded = false
            let semaphore = DispatchSemaphore(value: 0)
            
            // Call the async performFactoryReset and wait for completion
            performFactoryReset { success in
                resetSucceeded = success
                semaphore.signal()
            }
            
            // Block until the factory reset completes
            semaphore.wait()
            
            return resetSucceeded
        }
    }
    
    func openSerialPort( baudrate: Int) {
        // Use user's preferred baudrate if none provided or invalid
        let effectiveBaudrate = baudrate > 0 ? baudrate : UserSettings.shared.preferredBaudrate.rawValue
        
        self.logger.log(content: "Opening serial port at baudrate: \(effectiveBaudrate)")
        self.serialPort?.baudRate = NSNumber(value: effectiveBaudrate)
        self.serialPort?.delegate = self
        
        if let port = self.serialPort {
            if port.isOpen {
                logger.log(content: "Serial is already opened. Previous baudrate: \(port.baudRate), new baudrate: \(baudrate)")
                
            }else{
                port.open()
                if port.isOpen {

                    // Successfully opened the serial port
                    print("Serial port opened successfully at \(port.baudRate)")
                    // update AppStatus info
                    let actualBaudRate = port.baudRate.intValue > 0 ? port.baudRate.intValue : effectiveBaudrate
                    AppStatus.serialPortBaudRate = actualBaudRate
                    if let portPath = port.path as String? {
                        AppStatus.serialPortName = portPath.components(separatedBy: "/").last ?? "Unknown"
                    }
                    
                    self.baudrate = actualBaudRate
                } else {
                    print("the serial port fail to open")
                }
            }
        } else {
            print("no serial port selected")
        }

    }

    
    func closeSerialPort() {
        self.isDeviceReady = false
        self.serialPort?.close()
//        self.serialPort = nil

        // Stop CTS monitoring timer
        self.timer?.invalidate()
        self.timer = nil

        AppStatus.isTargetConnected = false
        AppStatus.isKeyboardConnected = false
        AppStatus.isMouseConnected = false
    }
    
    func closeSerialPortAndResetRetry() {
        self.closeSerialPort()
        // Reset retry counter when explicitly closing port (not during retry loop)
        self.retryCounter = 0
    }
    
    /// Pause all connection attempts
    /// This method is useful during factory reset or firmware update to prevent
    /// connection attempts from interfering with the process
    func pauseConnectionAttempts() {
        logger.log(content: "Pausing all connection attempts")
        self.isPaused = true
        self.isTrying = false
    }
    
    /// Resume connection attempts after being paused
    /// This allows normal connection behavior to continue after critical operations
    func resumeConnectionAttempts() {
        logger.log(content: "Resuming connection attempts")
        self.isPaused = false
    }
    
    /// Opens the serial port specifically with low baudrate for factory reset operations
    /// This method ensures the serial port opens with the correct low baudrate setting
    /// that is typically required after a factory reset procedure
    func openSerialPortForFactoryReset() -> Bool {
        logger.log(content: "Opening serial port for factory reset with low baudrate: \(CH9329ControlChipset.LOWSPEED_BAUDRATE)")
        
        // Get the serial port from USB device manager
        self.serialPort = getSerialPortPathFromUSBManager()
        
        guard let serialPort = self.serialPort else {
            logger.log(content: "No serial port available for factory reset")
            return false
        }
        
        // Close any existing connection
        if serialPort.isOpen {
            serialPort.close()
        }
        
        // Configure and open with low baudrate
        serialPort.baudRate = NSNumber(value: CH9329ControlChipset.LOWSPEED_BAUDRATE)
        serialPort.delegate = self
        
        serialPort.open()
        
        if serialPort.isOpen {
            logger.log(content: "Serial port opened successfully for factory reset at \(CH9329ControlChipset.LOWSPEED_BAUDRATE) baud")
            
            // Update app status
            AppStatus.serialPortBaudRate = CH9329ControlChipset.LOWSPEED_BAUDRATE
            if let portPath = serialPort.path as String? {
                AppStatus.serialPortName = portPath.components(separatedBy: "/").last ?? "Unknown"
            }
            
            self.baudrate = CH9329ControlChipset.LOWSPEED_BAUDRATE
            
            // Set device ready to false initially - it will be set to true when proper communication is established
            self.isDeviceReady = false
            
            // Start CTS monitoring for HID event detection
            self.startCTSMonitoring()
            
            return true
        } else {
            logger.log(content: "Failed to open serial port for factory reset")
            return false
        }
    }
    
    /// Stop all connection attempts
    /// This method is useful during factory reset or firmware update to prevent
    /// connection attempts from interfering with the process
    /// @deprecated Use pauseConnectionAttempts() instead for better control
    func stopConnectionAttempts() {
        logger.log(content: "Stopping all connection attempts")
        self.isTrying = false
    }
    
    func sendAsyncCommand(command: [UInt8], force: Bool = false) {
        guard let serialPort = self.serialPort else {
            if logger.SerialDataPrint {
                logger.log(content: "No Serial port for send command...")
            }
            return
        }
        if !serialPort.isOpen {
            if logger.SerialDataPrint {
                logger.log(content: "[Async] Serial port is not open or not selected")
            }
            return
        }

    
        // Create a mutable command and append the checksum
        var mutableCommand = command
        let checksum = self.calculateChecksum(data: command)
        mutableCommand.append(checksum)
        
        // Convert [UInt8] to Data
        let data = Data(mutableCommand)
        
        // Record the sent data
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // Track send time for latency measurement
        let cmdType = command.count > 3 ? command[3] : 0
        if cmdType == 0x02 {  // Keyboard command
            lastKeyboardSendTime = Date()
        } else if cmdType == 0x04 || cmdType == 0x05 {  // Mouse commands (absolute or relative)
            lastMouseSendTime = Date()
        }

        if self.isDeviceReady || force {
            if logger.SerialDataPrint {
                logger.log(content: "[Baudrate:\(self.baudrate)] Tx: \(dataString)")
            }
            serialPort.send(data)
        } else {
            logger.log(content: "Serial port is not ready")
        }
    }
    
    /// Sends a command synchronously and waits for the response.
    /// 
    /// This method sends a command to the serial port and blocks until a response is received.
    /// It's useful for request-response type operations where you need the device to respond
    /// before continuing.
    /// 
    /// **Parameters:**
    /// - `command`: The command bytes to send (without checksum, will be added automatically)
    /// - `expectedResponseCmd`: The expected response command byte to wait for
    /// - `timeout`: Maximum time to wait for response in seconds (default: 5 seconds)
    /// - `force`: Whether to send even if device is not ready (default: false)
    /// 
    /// **Returns:**
    /// - The complete response data if a matching response is received within timeout
    /// - Empty Data if timeout occurs or no matching response is received
    /// - Logs errors if serial port is not available
    /// 
    /// **Example:**
    /// ```swift
    /// let response = sendSyncCommand(
    ///     command: SerialPortManager.CMD_GET_PARA_CFG,
    ///     expectedResponseCmd: 0x88
    /// )
    /// if !response.isEmpty {
    ///     // Process response
    ///     let baudrate = response[8...11]
    /// }
    /// ```
    func sendSyncCommand(command: [UInt8], expectedResponseCmd: UInt8, timeout: TimeInterval = 5.0, force: Bool = false) -> Data {
        guard let serialPort = self.serialPort else {
            if logger.SerialDataPrint {
                logger.log(content: "No Serial port for sync command...")
            }
            return Data()
        }
        
        if !serialPort.isOpen {
            if logger.SerialDataPrint {
                logger.log(content: "[Sync] Serial port is not open or not selected")
            }
            return Data()
        }
        
        // Prepare to receive response - set expected command BEFORE sending
        syncResponseQueue.sync {
            self.syncResponseData = nil
            self.syncResponseExpectedCmd = expectedResponseCmd
        }
        
        // Send command
        var mutableCommand = command
        let checksum = self.calculateChecksum(data: command)
        mutableCommand.append(checksum)
        
        let data = Data(mutableCommand)
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let threadName = Thread.current.isMainThread ? "main" : "background"
        
        // Track send time for latency measurement
        let cmdType = command.count > 3 ? command[3] : 0
        if cmdType == 0x02 {  // Keyboard command
            lastKeyboardSendTime = Date()
        } else if cmdType == 0x04 || cmdType == 0x05 {  // Mouse commands (absolute or relative)
            lastMouseSendTime = Date()
        }
        
        if self.isDeviceReady || force {
            if logger.SerialDataPrint {
                logger.log(content: "[Baudrate: \(self.baudrate)] Tx(sync): \(dataString)")
            }
            serialPort.send(data)
        } else {
            logger.log(content: "Serial port is not ready for sync command")
            return Data()
        }
        
        // Poll for response within timeout
        let startTime = Date()
        var response = Data()
        var pollCount = 0
        
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if we received a matching response
            let receivedData = syncResponseQueue.sync { self.syncResponseData }
            if let receivedData = receivedData {
                response = receivedData
                logger.log(content: "SYNC: Response received after \(pollCount) polls")
                logger.log(content: "[Baudrate: \(self.baudrate)] Rx(sync): \(response)")
                break
            }
            
            pollCount += 1
            // Small sleep to avoid busy waiting
            usleep(10000) // 10ms
        }
        
        if response.isEmpty {
            logger.log(content: "SYNC: Timeout after \(pollCount) polls (expected cmd 0x\(String(format: "%02X", expectedResponseCmd)))")
        }
        
        // Clean up
        syncResponseQueue.sync {
            self.syncResponseData = nil
            self.syncResponseExpectedCmd = nil
        }
        
        return response
    }
    
    func calculateChecksum(data: [UInt8]) -> UInt8 {
        return UInt8(data.reduce(0, { (sum, element) in sum + Int(element) }) & 0xFF)
    }

    /// Retrieves the current parameter configuration from the CH9329 HID chip.
    /// 
    /// This method sends a command to query the CH9329 chip's current configuration settings,
    /// including baudrate, communication mode, and other operational parameters.
    /// 
    /// **What it does:**
    /// - Sends `CMD_GET_PARA_CFG` command to the CH9329 chip
    /// - The chip responds with current configuration data (command 0x88)
    /// - Response includes baudrate (bytes 8-11) and mode (byte 5)
    /// 
    /// **When it's called:**
    /// - After successful device connection validation in `tryConnectWithBaudrate()`
    /// - Used to verify the chip is configured with correct settings (115200 baud, mode 0x82)
    /// - If settings are incorrect, triggers automatic reconfiguration
    /// 
    /// **Expected Response:**
    /// - Command: 0x88 (get parameter configuration)
    /// - Baudrate: Should be 115200 (HIGHSPEED_BAUDRATE)
    /// - Mode: Should be 0x82 for proper HID operation
    /// 
    /// **Note:** This method uses `force: true` to ensure the command is sent even if 
    /// `isDeviceReady` is false, as it's part of the device initialization process.
    func getChipParameterCfg(){
        self.sendAsyncCommand(command: SerialPortManager.CMD_GET_PARA_CFG, force: true)
    }
    
    /// Resets the device to the specified baudrate and user's preferred control mode.
    /// 
    /// This method reconfigures the CH9329 HID chip to use the preferred baudrate and
    /// control mode as specified in user settings.
    /// 
    /// For CH32V208, it simply changes the baudrate and reopens the connection.
    /// 
    /// **Parameters:**
    /// - `preferredBaud`: The target baudrate to configure (9600 or 115200)
    /// 
    /// **CH9329 Behavior:**
    /// - Low → High (9600 → 115200): Direct set command
    /// - High → Low (115200 → 9600): Factory reset required
    /// 
    /// **CH32V208 Behavior:**
    /// - Simply changes baudrate and reopens serial port
    /// 
    /// **Note:** This method also applies the user's preferred control mode from UserSettings.
    /// Uses `force: true` to ensure commands are sent during device reconfiguration.
    public func resetDeviceToBaudrate(_ preferredBaud: Int) {
        logger.log(content: "Reset to baudrate \(preferredBaud)")
        self.isConfiguring = true
        
        // Get user's preferred control mode
        let preferredMode = UserSettings.shared.controlMode
        
        // Check if this is CH32V208
        let isCH32V208 = (AppStatus.controlChipsetType == .ch32v208)
        
        if isCH32V208 {
            // For CH32V208, just close and reopen with new baudrate
            logger.log(content: "CH32V208 detected: changing baudrate directly to \(preferredBaud)")
            self.closeSerialPort()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.tryOpenSerialPort(priorityBaudrate: preferredBaud)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.isConfiguring = false
                }
            }
        } else {
            // For CH9329, check if high-to-low change requires factory reset
            let currentBaudrate = self.baudrate
            let targetBaudrate = preferredBaud
            let isHighToLow = (currentBaudrate == SerialPortManager.HIGHSPEED_BAUDRATE && 
                              targetBaudrate == SerialPortManager.LOWSPEED_BAUDRATE)
            
            if isHighToLow {
                // High speed to low speed requires factory reset for CH9329
                logger.log(content: "CH9329: High-to-Low baudrate change detected, performing factory reset")
                self.resetHidChipToFactory { [weak self] success in
                    if success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.tryOpenSerialPort(priorityBaudrate: targetBaudrate)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.isConfiguring = false
                            }
                        }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            self?.isConfiguring = false
                        }
                    }
                }
            } else {
                // Low to high or same baudrate: direct set for CH9329
                logger.log(content: "CH9329: Setting baudrate directly to \(preferredBaud) and mode to \(preferredMode.displayName)")
                
                // Determine the actual mode byte to use
                var modeByteToUse = preferredMode.modeByteValue
                
                // Build set-parameter command with preferred mode
                let prefix: [UInt8] = preferredBaud == SerialPortManager.LOWSPEED_BAUDRATE ? 
                    SerialPortManager.CMD_SET_PARA_CFG_PREFIX_9600 : 
                    SerialPortManager.CMD_SET_PARA_CFG_PREFIX_115200
                
                var command: [UInt8] = prefix
                // The mode byte is at index 5 in the prefix, so we replace it
                if command.count > 5 {
                    command[5] = modeByteToUse
                }
                command.append(contentsOf: SerialPortManager.CMD_SET_PARA_CFG_POSTFIX)
                
                self.sendAsyncCommand(command: command, force: true)
                logger.log(content: "Set param command: \(command.map { String(format: "%02X", $0) }.joined(separator: " "))")
                
                // Reset HID chip and restart serial port after 0.5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.resetHidChip()
                    
                    // Restart the serial port
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.closeSerialPort()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.tryOpenSerialPort(priorityBaudrate: targetBaudrate)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                self?.isConfiguring = false
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Software reset the CH9329 HID chip
    func resetHidChip(){
        self.sendAsyncCommand(command: SerialPortManager.CMD_RESET, force: true)
    }
    
    /// Resets ACK (acknowledgement) counters and tracking timestamp
    /// Call this before starting stress tests to ensure accurate ACK rate calculations
    public func resetAckCounters() {
        keyboardAckCount = 0
        mouseAckCount = 0
        ackTrackingStartTime = Date().timeIntervalSince1970
        keyboardAckRate = 0.0
        mouseAckRate = 0.0
        keyboardAckRateSmoothed = 0.0
        mouseAckRateSmoothed = 0.0
        logger.log(content: "ACK counters reset for new stress test")
    }
    
    /// Gets the current ACK counts for keyboard and mouse
    /// Returns a tuple of (keyboardAckCount, mouseAckCount)
    public func getCurrentAckCounts() -> (keyboard: Int, mouse: Int) {
        return (keyboard: keyboardAckCount, mouse: mouseAckCount)
    }
    
    /// Performs a factory reset on the HID chip by raising RTS for 3.5 seconds then lowering it
    /// This method ensures the serial port is open before performing the reset operation
    /// After the reset, it closes the port and resumes connection attempts
    /// - Parameter completion: Called with true if reset succeeded, false if it failed
    func resetHidChipToFactory(completion: @escaping (Bool) -> Void = { _ in }) {
        logger.log(content: "Starting factory reset of HID chip with RTS control")
        
        // Pause connection attempts during the reset process
        pauseConnectionAttempts()
        
        // Ensure serial port is open before performing reset
        guard let port = serialPort, port.isOpen else {
            logger.log(content: "Serial port not open, attempting to open it first")
            
            // Try to open the serial port
            tryOpenSerialPort(priorityBaudrate: nil)
            
            // Wait briefly for port to open
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, let port = self.serialPort, port.isOpen else {
                    self?.logger.log(content: "Failed to open serial port for factory reset")
                    self?.resumeConnectionAttempts()
                    completion(false)
                    return
                }
                self.performFactoryReset(completion: completion)
            }
            return
        }
        
        // Port is already open, proceed with reset
        performFactoryReset(completion: completion)
    }
    
    /// Internal method that performs the actual factory reset sequence
    /// - Parameter completion: Called with true if reset succeeded, false if it failed
    private func performFactoryReset(completion: @escaping (Bool) -> Void = { _ in }) {
        logger.log(content: "Performing factory reset: raising RTS for 3.5 seconds")
        
        // Set device ready to false during reset
        isDeviceReady = false
        
        // Raise RTS signal - check for failure
        guard raiseRTS() else {
            logger.log(content: "Factory reset failed: Unable to raise RTS signal")
            // Resume connection attempts since factory reset failed
            resumeConnectionAttempts()
            completion(false)
            return
        }
        
        // Wait for 3.5 seconds with RTS raised
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self else { 
                completion(false)
                return 
            }
            
            self.logger.log(content: "Factory reset: lowering RTS signal")
            
            // Lower RTS signal - check for failure
            guard self.lowerRTS() else {
                self.logger.log(content: "Factory reset failed: Unable to lower RTS signal")
                // Resume connection attempts since factory reset failed
                self.resumeConnectionAttempts()
                completion(false)
                return
            }
            
            // Close the serial port after a brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { 
                    completion(false)
                    return 
                }
                
                self.logger.log(content: "Factory reset: closing serial port")
                self.closeSerialPort()
                
                // Resume connection attempts after another brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { 
                        completion(false)
                        return 
                    }
                    
                    self.logger.log(content: "Factory reset complete: resuming connection attempts")
                    self.resumeConnectionAttempts()
                    
                    // Try to reopen with low baudrate (factory default)
                    self.tryOpenSerialPort(priorityBaudrate: CH9329ControlChipset.LOWSPEED_BAUDRATE)
                    
                    // Report success
                    completion(true)
                }
            }
        }
    }
            
    
    /// Update ACK rates (ACKs per second)
    private func updateAckRates() {
        let currentTime = Date().timeIntervalSince1970
        let elapsed = currentTime - ackTrackingStartTime
        
        // For CH32V208, always mark keyboard and mouse as connected
        if AppStatus.controlChipsetType == .ch32v208 {
            AppStatus.isKeyboardConnected = true
            AppStatus.isMouseConnected = true
        }
        
        // Calculate ACK rates
        if elapsed > 0 {
            keyboardAckRate = Double(keyboardAckCount) / elapsed
            mouseAckRate = Double(mouseAckCount) / elapsed
            
            // Apply exponential moving average smoothing for display
            keyboardAckRateSmoothed = keyboardAckRateSmoothed * (1 - ackRateSmoothingFactor) + keyboardAckRate * ackRateSmoothingFactor
            mouseAckRateSmoothed = mouseAckRateSmoothed * (1 - ackRateSmoothingFactor) + mouseAckRate * ackRateSmoothingFactor
        }
        
        // Reset counters and timestamp every 5 seconds for continuous calculation
        // (unless disabled for stress testing)
        if elapsed >= ackTrackingInterval && !disablePeriodicAckReset {
            keyboardAckCount = 0
            mouseAckCount = 0
            ackTrackingStartTime = currentTime
        }
        
        // Reset max latencies every 10 seconds
        let keyboardMaxElapsed = currentTime - keyboardMaxLatencyTrackingStart
        if keyboardMaxElapsed >= 10.0 {
            keyboardMaxLatency = 0.0
            keyboardMaxLatencyTrackingStart = currentTime
        }
        
        let mouseMaxElapsed = currentTime - mouseMaxLatencyTrackingStart
        if mouseMaxElapsed >= 10.0 {
            mouseMaxLatency = 0.0
            mouseMaxLatencyTrackingStart = currentTime
        }
    }
    
    func getHidInfo(){
        self.sendAsyncCommand(command: SerialPortManager.CMD_GET_HID_INFO)
    }

    // Use sync call to get keybaord and mouse is connected to target by HID info
    func getTargetConnectionStatusSync() -> (isKeyboardConnected: Bool, isMouseConnected: Bool)? {
        let response = self.sendSyncCommand(command: SerialPortManager.CMD_GET_HID_INFO, expectedResponseCmd: 0x81, timeout: 2.0, force: true)
        
        guard !response.isEmpty && response.count >= 8 else {
            logger.log(content: "Failed to get target connection status: empty or too short response")
            return nil
        }
        
        let responseBytes = [UInt8](response)
        
        // Extract target connection status
        let isTargetConnected = responseBytes[6] == 0x01
        logger.log(content: "HID info - Target connected: \(isTargetConnected)")
        
        // Extract lock states
        let isNumLockOn = (responseBytes[7] & 0x01) == 0x01
        let isCapLockOn = (responseBytes[7] & 0x02) == 0x02
        let isScrollOn = (responseBytes[7] & 0x04) == 0x04
        logger.log(content: "HID info - NumLock: \(isNumLockOn), CapLock: \(isCapLockOn), Scroll: \(isScrollOn)")
        
        // For CH32V208, always mark keyboard and mouse as connected
        if AppStatus.controlChipsetType == .ch32v208 {
            return (isKeyboardConnected: true, isMouseConnected: true)
        } else {
            return (isKeyboardConnected: isTargetConnected, isMouseConnected: isTargetConnected)
        }
    }
    
    /// Sets the control mode for the HID chip via the SET_PARA_CFG command
    /// When changing FROM non-compatibility mode TO compatibility mode, automatically uses 0x02 instead of 0x82
    /// - Parameter mode: The control mode to set
    public func setControlMode(_ mode: ControlMode) {
        logger.log(content: "Setting control mode to: \(mode.displayName) (0x\(String(format: "%02X", mode.rawValue)))")
        self.isConfiguring = true
        
        // Determine the actual mode byte to use
        var modeByteToUse = mode.modeByteValue
        
        // Special handling: if changing TO compatibility mode from a non-compatibility mode, use 0x02
        if mode == .compatibility && self.baudrate != 0 {
            // Check if current mode is not already compatibility mode
            let currentModeIsCompatibility = (AppStatus.controlChipsetType == .ch9329)
            if currentModeIsCompatibility {
                // User is switching FROM non-compatibility TO compatibility, use 0x02
                logger.log(content: "Switching to compatibility mode from non-compatibility - using mode byte 0x02 instead of 0x82")
                modeByteToUse = 0x02
            }
        }
        
        // Build the SET_PARA_CFG command with the appropriate prefix for user's preferred baudrate
        let preferredBaud = UserSettings.shared.preferredBaudrate.rawValue
        let prefix: [UInt8] = preferredBaud == SerialPortManager.LOWSPEED_BAUDRATE ? 
            SerialPortManager.CMD_SET_PARA_CFG_PREFIX_9600 : 
            SerialPortManager.CMD_SET_PARA_CFG_PREFIX_115200
        
        // Create command by combining prefix, mode byte, and postfix
        var command: [UInt8] = prefix
        // The mode byte is at index 5 in the prefix, so we replace it
        if command.count > 5 {
            command[5] = modeByteToUse
        }
        command.append(contentsOf: SerialPortManager.CMD_SET_PARA_CFG_POSTFIX)
        
        // Send the command
        self.sendAsyncCommand(command: command, force: true)
        
        let dataString = command.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.log(content: "Control mode command sent: \(dataString)")
        
        // After setting the mode, send a reset command and reconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resetHidChip()
            
            // Restart the serial port
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.closeSerialPort()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.tryOpenSerialPort()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.isConfiguring = false
                    }
                }
            }
        }
    }
    
    func setDTR(_ enabled: Bool) {
        if let port = self.serialPort {
            port.dtr = enabled
            logger.log(content: "Set DTR to: \(enabled)")
        } else {
            logger.log(content: "Cannot set DTR: Serial port not available")
        }
    }
    
    func lowerDTR() {
        setDTR(false)
    }
    
    func raiseDTR() {
        setDTR(true)
    }

    func setRTS(_ enabled: Bool) -> Bool {
        if let port = self.serialPort {
            port.rts = enabled
            logger.log(content: "Set RTS to: \(enabled)")
            return true
        } else {
            logger.log(content: "Cannot set RTS to: \(enabled): Serial port not available")
            return false
        }
    }
    
    func lowerRTS() -> Bool {
        return setRTS(false)
    }
    
    func raiseRTS() -> Bool {
        return setRTS(true)
    }
    
    /// Directly opens serial port for CH32V208 without baudrate detection
    /// CH32V208 doesn't require the command-response validation process
    func tryOpenSerialPortForCH32V208() {
        logger.log(content: "tryOpenSerialPortForCH32V208 - Direct connection mode")
        
        // Check if connection attempts are paused
        if self.isPaused {
            logger.log(content: "[CH32V208] Connection attempts are paused, returning early")
            return
        }
        
        // Check if already trying to prevent race conditions
        if self.isTrying {
            logger.log(content: "Already trying to connect, returning early")
            return
        }
        
        self.isTrying = true
        
        // get all available serial ports
        guard let availablePorts = serialPortManager.availablePorts as? [ORSSerialPort], !availablePorts.isEmpty else {
            logger.log(content: "No available serial ports found")
            self.isTrying = false
            return
        }
        self.serialPorts = availablePorts
        
        // Find the USB serial port using USB device manager
        self.serialPort = getSerialPortPathFromUSBManager()
        
        if let serialPort = self.serialPort {
            logger.log(content: "Opening CH32V208 serial port directly at default baudrate: \(CH9329ControlChipset.HIGHSPEED_BAUDRATE), path: \(serialPort.path)")
            
            // Open the serial port with default baudrate
            self.openSerialPort(baudrate: SerialPortManager.LOWSPEED_BAUDRATE)
            
            // For CH32V208, we don't need command validation - set device ready immediately
            if serialPort.isOpen {
                self.isDeviceReady = true
                self.errorAlertShown = false  // Reset error alert flag on successful connection
                logger.log(content: "CH32V208 serial port opened successfully and device is ready")
                
            } else {
                logger.log(content: "Failed to open CH32V208 serial port")
            }
        } else {
            logger.log(content: "No USB serial port found for CH32V208")
        }
        
        self.isTrying = false
        AppStatus.isKeyboardConnected = true
        AppStatus.isMouseConnected = true
    }
    
    /// Start CTS monitoring for HID event detection
    /// CTS monitoring is only needed for CH9329 chipset
    /// For CH32V208, HID events are detected through direct serial communication
    private func startCTSMonitoring() {
        // Only start CTS monitoring for CH9329 chipset
        if !USBDevicesManager.shared.isCH9329Connected() {
            logger.log(content: "Skipping CTS monitoring - only applicable to CH9329 chipset")
            return
        }
        
        // Start the timer for CTS checking if not already running
        if self.timer == nil {
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                self.checkCTS()
            }
            logger.log(content: "Started CTS monitoring for CH9329 HID event detection")
        }
    }
    
    /// Get the preferred serial port path from USB device manager
    /// This method tries to find the serial port path based on the detected control chip device
    /// or falls back to the default USB serial device identified during device grouping
    private func getSerialPortPathFromUSBManager() -> ORSSerialPort? {
        // Get the expected serial device path from USB device manager
        if let expectedPath = USBDevicesManager.shared.getExpectedSerialDevicePath() {
            logger.log(content: "USB device manager provided expected serial device path hint: \(expectedPath)")
        }
        
        // Log information about all device groups
        let groupsInfo = USBDevicesManager.shared.getDeviceGroupsInfo()
        if !groupsInfo.isEmpty {
            logger.log(content: "Found \(groupsInfo.count) device groups with total \(USBDevicesManager.shared.getTotalDeviceCount()) devices")
        }
        
        // First, try to find serial port based on control chip device location
        if let controlDevice = USBDevicesManager.shared.getControlChipDevice() {
            logger.log(content: "Looking for serial port matching control chip device: \(controlDevice.productName) at \(controlDevice.locationID)")
            
            if let groupIndex = USBDevicesManager.shared.findGroupContaining(device: controlDevice) {
                logger.log(content: "Control chip device found in group \(groupIndex)")
            }
            
            // Try to find a serial port that might be related to this USB device
            // This is challenging because ORSSerial doesn't provide direct USB device correlation
            // We'll use the existing filtering but prefer ports that might be related
            return findBestMatchingSerialPort(for: controlDevice)
        }
        
        // Fallback to default USB serial device if available
        if let defaultSerial = AppStatus.DefaultUSBSerial {
            logger.log(content: "Using default USB serial device: \(defaultSerial.productName) at \(defaultSerial.locationID)")
            
            if let groupIndex = USBDevicesManager.shared.findGroupContaining(device: defaultSerial) {
                logger.log(content: "Default serial device found in group \(groupIndex)")
            }
            
            return findBestMatchingSerialPort(for: defaultSerial)
        }
        
        // Final fallback to the old method
        logger.log(content: "No USB device manager info available, falling back to name-based search")
        return self.serialPorts.filter{ $0.path.contains("usbserial")}.first
    }
    
    /// Find the best matching serial port for a given USB device
    /// This method attempts to correlate USB device information with available serial ports
    /// 
    /// **Note:** The ORSSerial framework doesn't provide direct USB device correlation,
    /// so this method uses heuristics to find the most likely serial port match.
    /// The correlation is based on:
    /// 1. Filtering for "usbserial" devices (USB-to-serial adapters)
    /// 2. Preferring single matches when only one USB serial port is available
    /// 3. Providing logging for debugging multiple port scenarios
    /// 
    /// **Future Enhancement:** Could be improved with IOKit registry correlation
    /// to directly match USB device location IDs with serial port device paths.
    private func findBestMatchingSerialPort(for usbDevice: USBDeviceInfo) -> ORSSerialPort? {
        // Look for serial ports that contain "usbserial" (the typical pattern for USB serial devices)
        let usbSerialPorts = self.serialPorts.filter{ $0.path.contains("usbserial") || $0.path.contains("usbmodem")}
        
        if usbSerialPorts.count == 1 {
            // If there's only one USB serial port, it's likely the one we want
            logger.log(content: "Found single USB serial port: \(usbSerialPorts[0].path)")
            return usbSerialPorts.first
        } else if usbSerialPorts.count > 1 {
            // Multiple USB serial ports - try to find the best match
            logger.log(content: "Found \(usbSerialPorts.count) USB serial ports, attempting to find best match")
            
            // For now, return the first one as we don't have enough correlation info
            // This could be enhanced in the future with more sophisticated matching
            if let firstPort = usbSerialPorts.first {
                logger.log(content: "Selected first USB serial port: \(firstPort.path)")
                return firstPort
            }
        }
        
        // If no usbserial ports found, log and return nil
        logger.log(content: "No USB serial ports found for device: \(usbDevice.productName)")
        return nil
    }
    
    /// Prompts the user about a stale CH9329 chip state and offers automatic recovery
    /// 
    /// When the CH9329 chip is detected in a stale state (receiving data but not processing HID events),
    /// this method displays an alert to the user with options to:
    /// - Auto recover (perform factory reset)
    /// - Dismiss the alert
    /// 
    /// This ensures the user is aware of the issue while providing an automatic recovery path.
    private func promptUserForChipRecovery() {
        let alert = NSAlert()
        alert.messageText = "CH9329 Chip Stale State Detected"
        alert.informativeText = "The CH9329 control chip appears to be in a stale state and is not responding properly to HID events. Would you like to automatically recover by performing a factory reset?"
        alert.addButton(withTitle: "Auto Recover")
        alert.addButton(withTitle: "Dismiss")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // User chose to auto recover
            self.logger.log(content: "User initiated automatic CH9329 chip recovery")
            self.resetHidChipToFactory { [weak self] success in
                DispatchQueue.main.async {
                    if success {
                        self?.logger.log(content: "CH9329 chip factory reset completed successfully")
                        
                        // Show success message
                        let successAlert = NSAlert()
                        successAlert.messageText = "Recovery Successful"
                        successAlert.informativeText = "The CH9329 chip has been successfully recovered and reset to factory settings."
                        successAlert.addButton(withTitle: "OK")
                        successAlert.runModal()
                    } else {
                        self?.logger.log(content: "CH9329 chip factory reset failed")
                        
                        // Show failure message
                        let failureAlert = NSAlert()
                        failureAlert.messageText = "Recovery Failed"
                        failureAlert.informativeText = "Failed to recover the CH9329 chip. Please try manually resetting the device."
                        failureAlert.addButton(withTitle: "OK")
                        failureAlert.runModal()
                    }
                }
            }
        } else {
            self.logger.log(content: "User dismissed CH9329 chip stale state alert")
        }
    }
    
    /// Displays a user-friendly alert when a serial port communication error occurs.
    /// 
    /// This method detects various types of serial port errors and prompts the user to
    /// reconnect their USB serial device. Common errors include:
    /// - Invalid argument (Code 22, EINVAL): Often caused by USB disconnection/reconnection
    /// - Device not found (Code 2, ENOENT): Serial device path is no longer available
    /// - I/O error (Code 5, EIO): General communication failure
    /// 
    /// The alert provides clear guidance to the user about the USB connection issue.
    private func promptUserForSerialConnectionError(error: Error) {
        // Only show error alert once until a successful connection is made
        if self.errorAlertShown {
            return
        }
        
        self.errorAlertShown = true
        
        let alert = NSAlert()
        var messageText = "Serial Communication Error Detected"
        var informativeText = "We detected an error in serial communication, likely a USB serial connection issue.\n\nPlease try to reconnect the device and ensure the USB cable is properly connected."
        
        // Check for "Resource busy" error (POSIX error code 16)
        if let nsError = error as? NSError {
            self.logger.log(content: "Serial port error - Domain: \(nsError.domain), Code: \(nsError.code), Description: \(nsError.localizedDescription)")
            
            // Handle EBUSY (Resource busy) error - indicates port is occupied by another application
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 16 {
                messageText = "Serial Port Occupied"
                informativeText = "The serial port is currently occupied by another application.\n\nPlease check and close any other applications that might be using this serial port (e.g., other KVM software, serial monitors, or terminal applications), then try reconnecting the device."
            }
        }
        
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        alert.runModal()
    }
}

