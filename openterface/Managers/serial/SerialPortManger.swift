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

class SerialPortManager: NSObject, ORSSerialPortDelegate, SerialPortManagerProtocol, ObservableObject, SerialResponseHandlerDelegate {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    static let shared = SerialPortManager()

    private lazy var messageParser: SerialMessageParser = {
        let parser = SerialMessageParser(logger: logger)
        parser.onMessage = { [weak self] messageData in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isDeviceReady = true
                self.errorAlertShown = false
            }
            self.responseHandler.handleSerialData(data: messageData)
        }
        return parser
    }()

    // All protocol commands and constants moved to SerialProtocolCommands.swift
    // Use SerialProtocolCommands.* for all command references
    
    @objc let serialPortManager = ORSSerialPortManager.shared()
    
    @objc dynamic var serialPort: ORSSerialPort? {
        didSet {
            oldValue?.close()
            oldValue?.delegate = nil
            serialPort?.delegate = self
        }
    }
    
    
    @Published var serialPorts : [ORSSerialPort] = []
    
    var lastHIDEventTime: Date?
    var lastSerialData: Date?
    /// CTS pin state (CH340 data flip pin) used to detect HID activity from the Target Screen.
    var lastCts: Bool?
    
    var timer: Timer?
    
    @Published var baudrate:Int = 0
    
    // Response handling
    private let responseHandler = SerialResponseHandler()
    
    // Acknowledgement latency tracking
    @Published var keyboardAckLatency: Double = 0.0  // in milliseconds
    @Published var mouseAckLatency: Double = 0.0     // in milliseconds
    @Published var keyboardMaxLatency: Double = 0.0  // max latency in last 10 seconds (milliseconds)
    @Published var mouseMaxLatency: Double = 0.0     // max latency in last 10 seconds (milliseconds)
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
    
    // SD Card operation async tracking - now handled by response handler
    private var sdOperationIdCounter: UInt8 = 0
    
    // SD card direction polling timer (CH32V208 only)
    private var sdPollingTimer: DispatchSourceTimer?
    private let sdPollQueue = DispatchQueue(label: "com.openterface.SerialPortManager.sdPoll", qos: .utility)
    
    // Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    /// Tracks the number of complete retry cycles through all baudrates.
    /// Incremented after each full cycle through both 9600 and 115200 baudrates.
    /// After 2 complete cycles (trying both baudrates twice), triggers a factory reset.
    var retryCounter: Int = 0
    
    /// True once the device has been validated and is ready to receive commands.
    @Published public var isDeviceReady: Bool = false

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
        
        // Set up response handler delegation
        responseHandler.delegate = self
        
        // Subscribe to published SD card direction from the response handler.
        // Any 0x97 response (polled or unsolicited from physical button) flows here.
        responseHandler.$sdCardDirection
            .receive(on: DispatchQueue.main)
            .sink { direction in
                AppStatus.sdCardDirection = direction
                if direction != .unknown {
                    let toTarget = (direction == .target)
                    AppStatus.switchToTarget = toTarget
                    AppStatus.isUSBSwitchConnectToTarget = toTarget
                }
            }
            .store(in: &cancellables)
        
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
        if USBDevicesManager.shared.isOpenterfaceConnected(){
            // Check the control chipset type and use appropriate connection method
            if USBDevicesManager.shared.isCH32V208Connected() {
                logger.log(content: "CH32V208 detected - using direct serial port connection")
                self.tryOpenSerialPortForCH32V208()
            } else if USBDevicesManager.shared.isCH9329Connected() {
                logger.log(content: "CH9329 detected - using standard serial port connection with validation")
                self.tryOpenSerialPort()
            } else {
                logger.log(content: "Unknown control chipset type - using standard connection method")
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
            // Refresh USB device list so isCH32V208Connected() / isCH9329Connected() reflect
            // the newly connected device before tryConnectOpenterface() reads them.
            USBDevicesManager.shared.update()
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
                SerialPortStatus.shared.isKeyboardConnected = true
                SerialPortStatus.shared.isMouseConnected = true
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
        
        // Start CTS monitoring for HID event detection (CH9329 only)
        self.startCTSMonitoring()
        
        // Start SD card direction polling for CH32V208
        self.startSDCardPolling()
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
        
        // Parse and dispatch complete messages
        messageParser.append(data)
    }
    
    // MARK: - SerialResponseHandlerDelegate Implementation
    
    func updateKeyboardLatency(_ latency: Double, maxLatency: Double) {
        self.keyboardAckLatency = latency
        // Update max latency if current latency is higher
        if latency > self.keyboardMaxLatency {
            self.keyboardMaxLatency = latency
        }
        // Track keyboard ACK count
        keyboardAckCount += 1
    }
    
    func updateMouseLatency(_ latency: Double, maxLatency: Double) {
        self.mouseAckLatency = latency
        // Update max latency if current latency is higher
        if latency > self.mouseMaxLatency {
            self.mouseMaxLatency = latency
        }
        // Track mouse ACK count
        mouseAckCount += 1
    }
    
    func updateAckRates() {
        self.updateAckRatesInternal()
    }
    
    private func updateAckRatesInternal() {
        guard !disablePeriodicAckReset else { return }
        let now = Date().timeIntervalSince1970
        let elapsed = now - ackTrackingStartTime
        guard elapsed >= ackTrackingInterval else { return }

        let kbRate = Double(keyboardAckCount) / elapsed
        let mouseRate = Double(mouseAckCount) / elapsed
        keyboardAckRate = kbRate
        mouseAckRate = mouseRate
        keyboardAckRateSmoothed = ackRateSmoothingFactor * kbRate + (1.0 - ackRateSmoothingFactor) * keyboardAckRateSmoothed
        mouseAckRateSmoothed = ackRateSmoothingFactor * mouseRate + (1.0 - ackRateSmoothingFactor) * mouseAckRateSmoothed
        keyboardAckCount = 0
        mouseAckCount = 0
        ackTrackingStartTime = now
    }
    
    func updateDeviceConfiguration(baudrate: Int, mode: UInt8) {
        let portPath = self.serialPort?.path ?? "Unknown"
        logger.log(content: "Serial Port: \(portPath), Baudrate: \(baudrate), Mode: \(String(format: "%02X", mode))")

        let preferredBaud = UserSettings.shared.preferredBaudrate.rawValue
        let preferredMode = UserSettings.shared.controlMode.modeByteValue
        
        // Check if mode matches user's preference using normalization
        // Mode equivalences: 0x80=0x00, 0x81=0x01, 0x82=0x02, 0x83=0x03
        let modeMatches = modesAreEquivalent(mode, preferredMode)
        
        if baudrate == preferredBaud && modeMatches {
            // Device matches the user's preferred baudrate and mode
            self.setDeviceReady(true)
            self.baudrate = baudrate
            SerialPortStatus.shared.serialPortBaudRate = baudrate
            SerialPortStatus.shared.isControlChipsetReady = true
        } else {
            // Device configuration differs from user preference - update user settings to match device configuration
            logger.log(content: "Device configuration detected. Expected: baudrate=\(preferredBaud) mode=0x\(String(format: "%02X", preferredMode)), Got: baudrate=\(baudrate) mode=0x\(String(format: "%02X", mode)). Updating user settings...")
            
            // Update preferred baudrate in user settings
            if let baudrateOption = BaudrateOption(rawValue: baudrate) {
                UserSettings.shared.preferredBaudrate = baudrateOption
                logger.log(content: "Updated user preferred baudrate to \(baudrate)")
            } else {
                logger.log(content: "Warning: Detected baudrate \(baudrate) is not a valid BaudrateOption")
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
            self.setDeviceReady(true)
            self.baudrate = baudrate
            SerialPortStatus.shared.serialPortBaudRate = baudrate
            SerialPortStatus.shared.isControlChipsetReady = true
            logger.log(content: "Device ready with detected configuration")
        }
    }
    
    func setDeviceReady(_ ready: Bool) {
        self.isDeviceReady = ready
        self.errorAlertShown = !ready  // Reset error alert flag on successful connection
    }
    
    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        self.serialPort = nil
    }
    
    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        if logger.SerialDataPrint { logger.log(content: "SerialPort \(serialPort) encountered an error: \(error)") }
        
        // Instead of immediately closing, try to recover based on error type
        let errorDescription = error.localizedDescription.lowercased()
        
        // Only close for critical errors that can't be recovered
        if errorDescription.contains("device not configured") || 
           errorDescription.contains("device disconnected") ||
           errorDescription.contains("no such device") {
            logger.log(content: "Critical error detected, closing port and attempting recovery")
            self.closeSerialPort()
            
            // Attempt automatic recovery after a brief delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.tryConnectOpenterface()
            }
        } else {
            // For non-critical errors, just log and continue
            logger.log(content: "Non-critical serial error, maintaining connection: \(error)")
        }
    }

    func listSerialPorts() -> [ORSSerialPort] {
        self.serialPorts = serialPortManager.availablePorts
        return self.serialPorts
    }
    
    func tryOpenSerialPort( priorityBaudrate: Int? = nil) {

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
                
                // Use priority baudrate if provided, otherwise use preferred baudrate from user settings
                let preferredBaudrate = priorityBaudrate ?? UserSettings.shared.preferredBaudrate.rawValue
                let otherBaudrate = preferredBaudrate == SerialProtocolCommands.LOWSPEED_BAUDRATE ? 
                    SerialProtocolCommands.HIGHSPEED_BAUDRATE : SerialProtocolCommands.LOWSPEED_BAUDRATE
                let baudrates = priorityBaudrate != nil ? [preferredBaudrate] : [preferredBaudrate, otherBaudrate]
                    
                
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
        self.serialPort = getSerialPortPathFromUSBManager()
        DispatchQueue.main.async { SerialPortStatus.shared.serialPortBaudRate = baudrate }

        if self.serialPort != nil {
            logger.log(content: "Trying to connect with baudrate: \(baudrate), path: \(self.serialPort?.path ?? "Unknown")")
            self.openSerialPort(baudrate: baudrate)
            
            // For CH32V208, device is ready once port is opened (no command-response validation needed)
            if USBDevicesManager.shared.isCH32V208Connected() {
                if self.serialPort?.isOpen == true {
                    DispatchQueue.main.async { [weak self] in
                        self?.isDeviceReady = true
                        self?.errorAlertShown = false
                        SerialPortStatus.shared.isKeyboardConnected = true
                        SerialPortStatus.shared.isMouseConnected = true
                    }
                    logger.log(content: "CH32V208: Port opened successfully, device ready")
                    return true
                }
            } else {
                // For CH9329: avoid the blocking sendSyncCommand pattern entirely.
                // processReceivedData already validates the checksum of every incoming frame
                // and sets isDeviceReady = true on the main thread (line 433) when any valid
                // frame arrives.  Previously we used a 5-second sync command that raced with
                // spontaneous 0x81 responses that arrived during the 500 ms stabilisation
                // sleep — the response was consumed by the normal handler before the sync
                // listener was registered, so the sync command always timed out.
                //
                // New approach: reset isDeviceReady on the main thread, send GET_HID_INFO to
                // prompt a response, then poll (via main.sync round-trips) for up to 2 seconds.
                DispatchQueue.main.sync { self.isDeviceReady = false }

                Thread.sleep(forTimeInterval: 0.1)  // brief port-stabilisation delay

                // Prompt the device to reply
                if let port = self.serialPort, port.isOpen {
                    let cmd = SerialProtocolCommands.createCommand(from: SerialProtocolCommands.DeviceInfo.GET_HID_INFO)
                    port.send(Data(cmd))
                }

                let waitStart = Date()
                while Date().timeIntervalSince(waitStart) < 2.0 {
                    var ready = false
                    DispatchQueue.main.sync { ready = self.isDeviceReady }
                    if ready {
                        logger.log(content: "CH9329: Device responded at baudrate \(baudrate)")
                        self.getChipParameterCfg()
                        return true
                    }
                    Thread.sleep(forTimeInterval: 0.05)  // 50 ms between polls
                }
                logger.log(content: "CH9329: No valid response at baudrate \(baudrate)")
                return false
            }
        }
        
        return false
    }
    
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
                    let actualBaudRate = port.baudRate.intValue > 0 ? port.baudRate.intValue : effectiveBaudrate
                    let openedPortName = (port.path as String).components(separatedBy: "/").last ?? "Unknown"
                    DispatchQueue.main.async { [weak self] in
                        SerialPortStatus.shared.serialPortBaudRate = actualBaudRate
                        SerialPortStatus.shared.serialPortName = openedPortName
                        self?.baudrate = actualBaudRate
                    }
                } else {
                    print("the serial port fail to open")
                }
            }
        } else {
            print("no serial port selected")
        }

    }

    
    func closeSerialPort() {
        logger.log(content: "Close serial port..")
        self.isDeviceReady = false
        self.serialPort?.close()

        // Stop CTS monitoring timer
        self.timer?.invalidate()
        self.timer = nil
        
        // Stop SD card polling timer
        self.stopSDCardPolling()

        DispatchQueue.main.async {
            SerialPortStatus.shared.isTargetConnected = false
            SerialPortStatus.shared.isKeyboardConnected = false
            SerialPortStatus.shared.isMouseConnected = false
            SerialPortStatus.shared.isControlChipsetReady = false
        }
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
        logger.log(content: "Opening serial port for factory reset with low baudrate: \(SerialProtocolCommands.LOWSPEED_BAUDRATE)")
        
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
        serialPort.baudRate = NSNumber(value: SerialProtocolCommands.LOWSPEED_BAUDRATE)
        serialPort.delegate = self
        
        serialPort.open()
        
        if serialPort.isOpen {
            logger.log(content: "Serial port opened successfully for factory reset at \(SerialProtocolCommands.LOWSPEED_BAUDRATE) baud")
            
            // Update status
            let factoryPortName = (serialPort.path as String).components(separatedBy: "/").last ?? "Unknown"
            DispatchQueue.main.async {
                SerialPortStatus.shared.serialPortBaudRate = SerialProtocolCommands.LOWSPEED_BAUDRATE
                SerialPortStatus.shared.serialPortName = factoryPortName
            }

            self.baudrate = SerialProtocolCommands.LOWSPEED_BAUDRATE
            
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

    
        // Create command with checksum using SerialProtocolCommands helper
        let completeCommand = SerialProtocolCommands.createCommand(from: command)
        
        // Convert [UInt8] to Data
        let data = Data(completeCommand)
        
        // Record the sent data
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // Track send time for latency measurement based on command type
        let cmdType = command.count > 3 ? command[3] : 0
        responseHandler.recordCommandSendTime(for: cmdType)

        if self.isDeviceReady || force {
            if logger.SerialDataPrint {
                logger.log(content: "[Baudrate:\(self.baudrate)] Tx: \(dataString)")
            }
            serialPort.send(data)
        } else {
            // For HID commands (keyboard/mouse), attempt auto-recovery — but only if not already
            // recovering. Mouse events fire every ~18ms; without the isTrying guard, hundreds of
            // closures flood DispatchQueue.global(), starving the sendSyncCommand poll loop so
            // CH9329 validation always times out and isDeviceReady never becomes true.
            if cmdType == 0x02 || cmdType == 0x04 || cmdType == 0x05 {
                if !self.isTrying {
                    logger.log(content: "Serial port is not ready — HID command blocked, attempting auto-recovery")
                    DispatchQueue.global().async { [weak self] in
                        self?.tryConnectOpenterface()
                    }
                }
            }
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
    ///     command: SerialProtocolCommands.DeviceInfo.GET_PARA_CFG,
    ///     expectedResponseCmd: SerialProtocolCommands.ResponseCodes.PARA_CFG_RESPONSE
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
                logger.log(content: "[Sync] Serial port is not open, open it again")
            }
            serialPort.open()
        }
        
        // Prepare to receive response - set expected command BEFORE sending
        responseHandler.waitForSyncResponse(expectedCmd: expectedResponseCmd)
        
        // Send command with checksum using SerialProtocolCommands helper
        let completeCommand = SerialProtocolCommands.createCommand(from: command)
        
        let data = Data(completeCommand)
        let dataString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        
        // Track send time for latency measurement based on command type
        let cmdType = command.count > 3 ? command[3] : 0
        responseHandler.recordCommandSendTime(for: cmdType)
        
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
            let receivedData = responseHandler.getSyncResponseData()
            if let receivedData = receivedData {
                response = receivedData
                if logger.SerialDataPrint {
                    logger.log(content: "SYNC: Response received after \(pollCount) polls")
                    logger.log(content: "[Baudrate: \(self.baudrate)] Rx(sync): \(response)")
                }
                break
            }
            
            pollCount += 1
            // Small sleep to avoid busy waiting
            usleep(10000) // 10ms
        }
        
        if response.isEmpty {
            logger.log(content: "SYNC: Timeout after \(pollCount) polls (expected cmd 0x\(String(format: "%02X", expectedResponseCmd)))")
        }
        
        // Clean up - no longer needed as response handler manages sync state
        
        return response
    }
    
    func calculateChecksum(data: [UInt8]) -> UInt8 {
        return SerialProtocolCommands.calculateChecksum(for: data)
    }

    /// Retrieves the current parameter configuration from the CH9329 HID chip.
    /// 
    /// This method sends a command to query the CH9329 chip's current configuration settings,
    /// including baudrate, communication mode, and other operational parameters.
    /// 
    /// **What it does:**
    /// - Sends `SerialProtocolCommands.DeviceInfo.GET_PARA_CFG` command to the CH9329 chip
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
    /// - Baudrate: Should be 115200 (SerialProtocolCommands.HIGHSPEED_BAUDRATE)
    /// - Mode: Should be 0x82 for proper HID operation
    /// 
    /// **Note:** This method uses `force: true` to ensure the command is sent even if 
    /// `isDeviceReady` is false, as it's part of the device initialization process.
    func getChipParameterCfg(){
        self.sendAsyncCommand(command: SerialProtocolCommands.DeviceInfo.GET_PARA_CFG, force: true)
    }

    // MARK: - CH32V208 SD switch helpers (Async)
    
    /// Generates a unique operation ID for tracking SD operations
    private func generateSdOperationId() -> UInt8 {
        // Simple thread-safe counter increment
        sdOperationIdCounter = (sdOperationIdCounter &+ 1) % 255
        if sdOperationIdCounter == 0 { sdOperationIdCounter = 1 } // Avoid 0 as operation ID
        return sdOperationIdCounter
    }
    
    /// Set SD card to host (CH32V208) - Async version
    public func setSdToHost(force: Bool = false, completion: @escaping (Bool) -> Void) {
        let operationId = generateSdOperationId()
        
        responseHandler.registerSdOperation(operationId: operationId, completion: completion)
        
        // Set timeout for this operation
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.responseHandler.timeoutSdOperation(operationId: operationId)
        }
        
        // SD_SWITCH_PREFIX has LEN=0x05 (5 data bytes).
        // Appending only the direction byte completes the 5 data bytes exactly.
        // Do NOT append any extra bytes (e.g. operationId) — it shifts the checksum
        // position and causes the device to reject the command.
        var cmd = SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX
        cmd.append(SerialProtocolCommands.CH32V208.SDCardDirection.HOST)
        
        self.sendAsyncCommand(command: cmd, force: force)
    }
    
    /// Set SD card to target (CH32V208) - Async version
    public func setSdToTarget(force: Bool = false, completion: @escaping (Bool) -> Void) {
        let operationId = generateSdOperationId()
        
        responseHandler.registerSdOperation(operationId: operationId, completion: completion)
        
        // Set timeout for this operation
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.responseHandler.timeoutSdOperation(operationId: operationId)
        }
        
        var cmd = SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX
        cmd.append(SerialProtocolCommands.CH32V208.SDCardDirection.TARGET)
        
        self.sendAsyncCommand(command: cmd, force: force)
    }
    
    /// Query SD card direction - Async version
    public func querySdDirection(force: Bool = false, completion: @escaping (SDCardDirection?) -> Void) {
        let operationId = generateSdOperationId()
        
        responseHandler.registerSdQueryOperation(operationId: operationId, completion: completion)
        
        // Set timeout for this operation
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.responseHandler.timeoutSdQueryOperation(operationId: operationId)
        }
        
        var cmd = SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX
        cmd.append(SerialProtocolCommands.CH32V208.SDCardDirection.QUERY)
        
        self.sendAsyncCommand(command: cmd, force: force)
    }
    
    /// Legacy synchronous version - now wraps async version
    public func querySdDirectionSync(timeout: TimeInterval = 2.0, force: Bool = false) -> SDCardDirection? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SDCardDirection?
        
        querySdDirection(force: force) { direction in
            result = direction
            semaphore.signal()
        }
        
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        return waitResult == .success ? result : nil
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
        let isCH32V208 = USBDevicesManager.shared.isCH32V208Connected()
        
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
            let isHighToLow = (currentBaudrate == SerialProtocolCommands.HIGHSPEED_BAUDRATE && 
                              targetBaudrate == SerialProtocolCommands.LOWSPEED_BAUDRATE)
            
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
                let prefix: [UInt8] = preferredBaud == SerialProtocolCommands.LOWSPEED_BAUDRATE ? 
                    SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_9600 : 
                    SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_115200
                
                var command: [UInt8] = prefix
                // The mode byte is at index 5 in the prefix, so we replace it
                if command.count > 5 {
                    command[5] = modeByteToUse
                }
                command.append(contentsOf: SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_POSTFIX)
                
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
        self.sendAsyncCommand(command: SerialProtocolCommands.DeviceConfig.RESET, force: true)
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
                    self.tryOpenSerialPort(priorityBaudrate: SerialProtocolCommands.LOWSPEED_BAUDRATE)
                    
                    // Report success
                    completion(true)
                }
            }
        }
    }

    
    func getHidInfo(){
        self.sendAsyncCommand(command: SerialProtocolCommands.DeviceInfo.GET_HID_INFO)
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
            let currentModeIsCompatibility = USBDevicesManager.shared.isCH9329Connected()
            if currentModeIsCompatibility {
                // User is switching FROM non-compatibility TO compatibility, use 0x02
                logger.log(content: "Switching to compatibility mode from non-compatibility - using mode byte 0x02 instead of 0x82")
                modeByteToUse = 0x02
            }
        }
        
        // Build the SET_PARA_CFG command with the appropriate prefix for user's preferred baudrate
        let preferredBaud = UserSettings.shared.preferredBaudrate.rawValue
        let prefix: [UInt8] = preferredBaud == SerialProtocolCommands.LOWSPEED_BAUDRATE ? 
            SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_9600 : 
            SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_PREFIX_115200
        var command: [UInt8] = prefix
        // The mode byte is at index 5 in the prefix, so we replace it
        if command.count > 5 {
            command[5] = modeByteToUse
        }
        command.append(contentsOf: SerialProtocolCommands.DeviceConfig.SET_PARA_CFG_POSTFIX)
        
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
        tryOpenSerialPortForCH32V208WithRetry(attempt: 1)
    }
    
    private func tryOpenSerialPortForCH32V208WithRetry(attempt: Int) {
        logger.log(content: "tryOpenSerialPortForCH32V208 - Direct connection mode (attempt \(attempt))")
        
        // Check if connection attempts are paused
        if self.isPaused {
            logger.log(content: "[CH32V208] Connection attempts are paused, returning early")
            return
        }
        
        // Check if already trying to prevent race conditions (only for first attempt)
        if attempt == 1 && self.isTrying {
            logger.log(content: "Already trying to connect, returning early")
            return
        }
        
        if attempt == 1 {
            self.isTrying = true
        }
        
        // get all available serial ports
        guard let availablePorts = serialPortManager.availablePorts as? [ORSSerialPort], !availablePorts.isEmpty else {
            logger.log(content: "No available serial ports found")
            if attempt == 1 {
                self.isTrying = false
            }
            return
        }
        self.serialPorts = availablePorts
        
        // Find the USB serial port using USB device manager
        self.serialPort = getSerialPortPathFromUSBManager()
        
        if let serialPort = self.serialPort {
            let preferredBaudrate = UserSettings.shared.preferredBaudrate.rawValue
            logger.log(content: "Opening CH32V208 serial port at preferred baudrate: \(preferredBaudrate), path: \(serialPort.path)")
            
            // Open the serial port with the user's preferred baudrate
            self.openSerialPort(baudrate: preferredBaudrate)
            
            // For CH32V208, we don't need command validation - check if port opened successfully
            if serialPort.isOpen {
                logger.log(content: "CH32V208 serial port opened successfully and device is ready")
                
                if attempt == 1 {
                    self.isTrying = false
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.isDeviceReady = true
                    self?.errorAlertShown = false
                    SerialPortStatus.shared.isKeyboardConnected = true
                    SerialPortStatus.shared.isMouseConnected = true
                }
            } else {
                logger.log(content: "Failed to open CH32V208 serial port (attempt \(attempt))")
                
                // Retry logic for "Resource temporarily unavailable" errors
                if attempt < 3 {
                    let delay = Double(attempt) * 0.5  // 0.5, 1.0, 1.5 seconds
                    logger.log(content: "Retrying CH32V208 connection in \(delay) seconds...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.tryOpenSerialPortForCH32V208WithRetry(attempt: attempt + 1)
                    }
                } else {
                    logger.log(content: "Failed to open CH32V208 serial port after \(attempt) attempts")
                    
                    if attempt == 1 {
                        self.isTrying = false
                    }
                    
                    // Set default connection status even if port failed to open
                    DispatchQueue.main.async {
                        SerialPortStatus.shared.isKeyboardConnected = true
                        SerialPortStatus.shared.isMouseConnected = true
                    }
                }
            }
        } else {
            logger.log(content: "No USB serial port found for CH32V208")
            
            if attempt == 1 {
                self.isTrying = false
            }
            
            DispatchQueue.main.async {
                SerialPortStatus.shared.isKeyboardConnected = true
                SerialPortStatus.shared.isMouseConnected = true
            }
        }
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
    
    /// Starts a periodic timer that sends the SD direction query command every 3 seconds.
    /// The response is handled by SerialResponseHandler.handleSdDirectionResponse which
    /// publishes the result via @Published sdCardDirection — no callbacks needed.
    private func startSDCardPolling() {
        guard USBDevicesManager.shared.isCH32V208Connected() else { return }
        stopSDCardPolling()
        
        let timer = DispatchSource.makeTimerSource(queue: sdPollQueue)
        // First query after 1 second so the port is fully settled, then every 3 seconds.
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  self.isDeviceReady,
                  AppStatus.controlChipsetType == .ch32v208 else { return }
            var cmd = SerialProtocolCommands.CH32V208.SD_SWITCH_PREFIX
            cmd.append(SerialProtocolCommands.CH32V208.SDCardDirection.QUERY)
            self.sendAsyncCommand(command: cmd, force: true)
        }
        sdPollingTimer = timer
        timer.resume()
        logger.log(content: "Started SD card direction polling for CH32V208 (3 s interval)")
    }
    
    private func stopSDCardPolling() {
        sdPollingTimer?.cancel()
        sdPollingTimer = nil
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
        
        // Fallback to name-based search
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

