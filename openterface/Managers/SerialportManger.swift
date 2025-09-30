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

    public static let CMD_SET_PARA_CFG_PREFIX_115200: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x01, 0xC2, 0x00]
    public static let CMD_SET_PARA_CFG_PREFIX_9600: [UInt8] = [0x57, 0xAB, 0x00, 0x09, 0x32, 0x82, 0x80, 0x00, 0x00, 0x25, 0x80, 0x00]
    public static let CMD_SET_PARA_CFG_POSTFIX: [UInt8] = [0x08, 0x00, 0x00, 0x03, 0x86, 0x1A, 0x29, 0xE1, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    public static let CMD_RESET: [UInt8] = [0x57, 0xAB, 0x00, 0x0F, 0x00]
    
    // Baudrate constants
    public static let LOWSPEED_BAUDRATE = CH9329ControlChipset.LOWSPEED_BAUDRATE
    public static let HIGHSPEED_BAUDRATE = CH9329ControlChipset.HIGHSPEED_BAUDRATE
    
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
    
    /// Stores the previous state of the CTS (Clear To Send) pin for change detection.
    /// 
    /// The CTS pin is connected to the CH340 data flip pin on the Openterface Mini KVM device.
    /// This connection allows the system to detect HID activity from the target computer:
    /// 
    /// **How it works:**
    /// - When the target computer sends HID data (keyboard/mouse input), the CH340 chip toggles its data flip pin
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
    /// This mechanism provides a hardware-level indication of target computer activity without
    /// relying solely on software-based communication protocols.
    var lastCts: Bool?
    
    var timer: Timer?
    
    @Published var baudrate:Int = 0
    
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

    override init(){
        super.init()
        
//        self.initializeSerialPort()
        self.observerSerialPortNotifications()
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
        USBDevicesManager.shared.update()
        if USBDevicesManager.shared.isOpenterfaceConnected(){
            // Check if CH32V208 is connected - if so, use direct connection
            if USBDevicesManager.shared.isCH32V208Connected() {
                logger.log(content: "CH32V208 detected - using direct serial port connection")
                self.tryOpenSerialPortForCH32V208()
            } else {
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
        if logger.SerialDataPrint {
            let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.log(content: "Serial port receive data: \(dataString)")
        }
        
        // Append new data to buffer
        receiveBuffer.append(data)
        
        // Process all complete messages in the buffer
        processBufferedMessages()
    }
    
    private func processBufferedMessages() {
        let prefix: [UInt8] = [0x57, 0xAB, 0x00]
        var bufferBytes = [UInt8](receiveBuffer)
        var processedBytes = 0
        
        while bufferBytes.count >= 6 { // Minimum message size: 5 bytes header + 1 byte checksum
            // Look for the next valid message start
            guard let prefixIndex = findNextMessageStart(in: bufferBytes, from: processedBytes) else {
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
                break
            }
            
            let len = bufferBytes[4]
            let expectedMessageLength = Int(len) + 6 // 5 bytes header + length + 1 byte checksum
            
            if bufferBytes.count < expectedMessageLength {
                // Incomplete message, wait for more data
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
        let len = data[4]

        switch cmd {
        case 0x81:  // HID info
            let byteValue = data[5]
            let chipVersion: Int8 = Int8(bitPattern: byteValue)
            AppStatus.chipVersion = Int8(chipVersion)
            
            let isTargetConnected = data[6] == 0x01
            AppStatus.isTargetConnected = isTargetConnected
            
            AppStatus.isKeyboardConnected = isTargetConnected
            AppStatus.isMouseConnected = isTargetConnected
            
            let isNumLockOn = (data[7] & 0x01) == 0x01
            AppStatus.isNumLockOn = isNumLockOn
            
            let isCapLockOn = (data[7] & 0x02) == 0x02
            AppStatus.isCapLockOn = isCapLockOn
            
            let isScrollOn = (data[7] & 0x04) == 0x04
            AppStatus.isScrollOn = isScrollOn
            
            // logger.log(content: "Receive HID info, chip version: \(chipVersion), target connected: \(isTargetConnected), NumLock: \(isNumLockOn), CapLock: \(isCapLockOn), Scroll: \(isScrollOn)")
            
        case 0x82:  //Keyboard hid execution status 0 - success
            let kbStatus = data[5]
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
            if logger.SerialDataPrint {
                logger.log(content: "\(cmd == 0x84 ? "Absolute" : "Relative") mouse event sent, status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x86, 0x87:  //custom hid execution status 0 - success
            if logger.SerialDataPrint  {
                let kbStatus = data[5]
                logger.log(content: "Receive \(cmd == 0x86 ? "SEND" : "READ") custom hid status: \(String(format: "0x%02X", kbStatus))")
            }
            
        case 0x88:  // get para cfg
            let baudrateData = Data(data[8...11])
            let mode = data[5]
            let baudrateInt32 = baudrateData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Int32 in
                let intPointer = pointer.bindMemory(to: Int32.self)
                return intPointer[0].bigEndian
            }
            self.baudrate = Int(baudrateInt32)
            logger.log(content: "Current serial port baudrate: \(self.baudrate), Mode: \(String(format: "%02X", mode))")

            // let preferredBaud = UserSettings.shared.preferredBaudrate.rawValue
            // if self.baudrate == preferredBaud && mode == 0x82 {
            //     // Device matches the user's preferred baudrate and expected mode
                self.isDeviceReady = true
                AppStatus.serialPortBaudRate = self.baudrate
                self.getHidInfo()
            // } else {
            //     self.resetDeviceToBaudrate(preferredBaud)
            // }
            
        case 0x89:  // set para cfg
            if logger.SerialDataPrint {
                let status = data[5]
                logger.log(content: "Set para cfg status: \(String(format: "0x%02X", status))")
            }
            
        default:
            let hexCmd = String(format: "%02hhX", cmd)
            logger.log(content: "Unknown command: \(hexCmd)")
        }
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        self.serialPort = nil
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        if logger.SerialDataPrint { logger.log(content: "SerialPort \(serialPort) encountered an error: \(error)") }
        self.closeSerialPort()
        
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
        
        let backgroundQueue = DispatchQueue(label: "com.openterface.background", qos: .background)
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
                
                // Try to connect with priority baudrate first
                let baudrates = effectivePriorityBaudrate == CH9329ControlChipset.LOWSPEED_BAUDRATE ? 
                    [CH9329ControlChipset.LOWSPEED_BAUDRATE, CH9329ControlChipset.HIGHSPEED_BAUDRATE] :
                    [CH9329ControlChipset.HIGHSPEED_BAUDRATE, CH9329ControlChipset.LOWSPEED_BAUDRATE]
                    
                
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
                        self.isTrying = false
                        return // Connection successful, exit the loop
                    }
                    
                    // Check if we should stop trying between baudrate attempts
                    if !self.isTrying {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.getChipParameterCfg()
            }
        }
        
        self.blockMainThreadFor2Seconds()
        
        if isDeviceReady { return true }
        
        self.closeSerialPort()
        self.blockMainThreadFor2Seconds()
        
        return false
    }
    
    func blockMainThreadFor2Seconds() {
        let expirationDate = Date(timeIntervalSinceNow: 2)
        while Date() < expirationDate {
            RunLoop.current.run(mode: .default, before: expirationDate)
        }
    }
    
    func openSerialPort( baudrate: Int) {
        self.logger.log(content: "Opening serial port at baudrate: \(baudrate)")
        self.serialPort?.baudRate = NSNumber(value: baudrate)
        self.serialPort?.delegate = self
        
        if let port = self.serialPort {
            if port.isOpen {
                logger.log(content: "Serial is already opened.")
                
            }else{
                port.open()
                if port.isOpen {

                    // Successfully opened the serial port
                    print("Serial port opened successfully")
                    // update AppStatus info
                    AppStatus.serialPortBaudRate = port.baudRate.intValue
                    if let portPath = port.path as String? {
                        AppStatus.serialPortName = portPath.components(separatedBy: "/").last ?? "Unknown"
                    }
                    
                    self.baudrate = port.baudRate.intValue
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
        self.serialPort = nil

        // Stop CTS monitoring timer
        self.timer?.invalidate()
        self.timer = nil

        AppStatus.isTargetConnected = false
        AppStatus.isKeyboardConnected = false
        AppStatus.isMouseConnected = false
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
    
    func sendCommand(command: [UInt8], force: Bool = false) {
        guard let serialPort = self.serialPort else {
            if logger.SerialDataPrint {
                logger.log(content: "No Serial port for send command...")
            }
            return
        }
        if !serialPort.isOpen {
            if logger.SerialDataPrint {
                logger.log(content: "Serial port is not open or not selected")
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

        if self.isDeviceReady || force {
            if logger.SerialDataPrint {
                logger.log(content: "Sending command: \(dataString)")
            }
            serialPort.send(data)
        } else {
            logger.log(content: "Serial port is not ready")
        }
        
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
        self.sendCommand(command: SerialPortManager.CMD_GET_PARA_CFG, force: true)
    }
    
    /// Resets the device to the specified baudrate with mode 0x82.
    /// 
    /// This method reconfigures the CH9329 HID chip to use the preferred baudrate while maintaining
    /// the required communication mode (0x82) for proper HID operation.
    /// 
    /// **Parameters:**
    /// - `preferredBaud`: The target baudrate to configure (9600 or 115200)
    /// 
    /// **What it does:**
    /// 1. Builds a set-parameter command with the new baudrate
    /// 2. Preserves existing configuration data from bytes 12-31
    /// 3. Sends the reconfiguration command
    /// 4. Resets the HID chip and restarts the serial port connection
    /// 
    /// **Timing sequence:**
    /// - Immediate: Send configuration command
    /// - +0.5s: Reset HID chip
    /// - +0.6s: Close serial port
    /// - +0.8s: Attempt to reopen serial port
    /// 
    /// **Note:** This method uses `force: true` to ensure commands are sent during device reconfiguration.
    public func resetDeviceToBaudrate(_ preferredBaud: Int) {
        logger.log(content: "Reset to baudrate \(preferredBaud) and mode 0x82...")
        
        // Build set-parameter command, inserting the preferred baudrate (big-endian)
        var command: [UInt8] = preferredBaud == SerialPortManager.LOWSPEED_BAUDRATE ? SerialPortManager.CMD_SET_PARA_CFG_PREFIX_9600 : SerialPortManager.CMD_SET_PARA_CFG_PREFIX_115200
        
        // Keep structure similar to original payload
        command.append(contentsOf: SerialPortManager.CMD_SET_PARA_CFG_POSTFIX)
        
        self.sendCommand(command: command, force: true)
        logger.log(content: command.map { String(format: "%02X", $0) }.joined(separator: " "))
        
        // Reset HID chip and restart serial port after 0.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.resetHidChip()
            
            // Restart the serial port
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.closeSerialPort()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.tryOpenSerialPort()
                }
            }
        }
    }
    
    // Software reset the CH9329 HID chip
    func resetHidChip(){
        self.sendCommand(command: SerialPortManager.CMD_RESET, force: true)
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
            
    
    func getHidInfo(){
        self.sendCommand(command: SerialPortManager.CMD_GET_HID_INFO)
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
        self.serialPorts = availablePorts
        
        // Find the USB serial port using USB device manager
        self.serialPort = getSerialPortPathFromUSBManager()
        
        if let serialPort = self.serialPort {
            logger.log(content: "Opening CH32V208 serial port directly at default baudrate: \(CH9329ControlChipset.HIGHSPEED_BAUDRATE), path: \(serialPort.path)")
            
            // Open the serial port with default baudrate
            self.openSerialPort(baudrate: CH9329ControlChipset.HIGHSPEED_BAUDRATE)
            
            // For CH32V208, we don't need command validation - set device ready immediately
            if serialPort.isOpen {
                self.isDeviceReady = true
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
}
