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
import Combine

class DiagnosticsViewModel: NSObject, ObservableObject {
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var serialPortManager: SerialPortManagerProtocol = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)
    private var halIntegration = HALIntegrationManager.shared
    private var keyboardManager: KeyboardManagerProtocol = DependencyContainer.shared.resolve(KeyboardManagerProtocol.self)
    private var mouseManager: MouseManagerProtocol = DependencyContainer.shared.resolve(MouseManagerProtocol.self)
    
    @Published var isLoggingEnabled: Bool = false
    @Published var isSerialLoggingEnabled: Bool = false
    @Published var logFilePath: String = ""
    
    enum DiagnosticTestStep: Int, CaseIterable {
        case overallConnection = 0
        case targetBlackCableTest = 1
        case hostPlugAndPlayTest = 2
        case serialConnection = 3
        case resetFactoryBaudrate = 4
        case changeTo115200 = 5
        case stressTest = 6
        case targetPortChecking = 7
        
        var title: String {
            switch self {
            case .overallConnection: return "Overall Connection"
            case .serialConnection: return "Serial Connection"
            case .hostPlugAndPlayTest: return "Host Plug & Play"
            case .targetBlackCableTest: return "Target Plug & Play"
            case .resetFactoryBaudrate: return "Factory Reset"
            case .changeTo115200: return "High Baudrate"
            case .stressTest: return "Stress Test"
            case .targetPortChecking: return "Target Port Checking"
            }
        }
        
        var description: String {
            switch self {
            case .overallConnection: return "Verifying all cable connections (Orange USB-C, Black USB-C, and HDMI)"
            case .serialConnection: return "Detecting serial port baud rate and connection status"
            case .hostPlugAndPlayTest: return "Testing Orange USB-C hot-plug/unplug detection and reconnection (host side)"
            case .targetBlackCableTest: return "Testing Black USB-C hot-plug/unplug detection and reconnection (target side)"
            case .resetFactoryBaudrate: return "Resetting serial configuration to factory defaults"
            case .changeTo115200: return "Changing serial baudrate to 115200"
            case .stressTest: return "Running platform stress test for 30 seconds"
            case .targetPortChecking: return "Checking the target port healthness by host orange cable"
            }
        }
    }
    
    @Published var currentStep: DiagnosticTestStep = .overallConnection
    @Published var stepResults: [DiagnosticTestStep: Bool] = [:]
    @Published var isTestRunning: Bool = false
    @Published var isAutoChecking: Bool = false
    @Published var statusMessages: [String] = []
    @Published var currentBaudRate: Int = 0
    @Published var detectedBaudRate: Int? = nil
    @Published var stressTestProgress: Double = 0.0
    @Published var stressTestStatus: String = ""
    @Published var stressTestKeyboardSent: Int = 0
    @Published var stressTestMouseSent: Int = 0
    @Published var stressTestKeyboardAck: Int = 0
    @Published var stressTestMouseAck: Int = 0
    @Published var stressTestKeyboardRate: Double = 0.0
    @Published var stressTestMouseRate: Double = 0.0
    @Published var isDefectiveUnitDetected: Bool = false
    @Published var showDepthWarningAlert: Bool = false
    @Published var depthWarningMessage: String = ""
    @Published var hasCheckedDeviceDepth: Bool = false
    @Published var deviceDepthWarningActive: Bool = false
    
    // Connection state tracking for diagnostic images
    @Published var hostOrangeConnected: Bool = false  // H: Host orange cable connection state
    @Published var targetConnected: Bool = false       // T: Target connection state
    @Published var videoChecking: Bool = false         // V: Video checking state
    @Published var isTargetPortChecking: Bool = false  // Show H_to_T image during target port checking test
    
    private var stressTestTimer: Timer?
    private var stressTestStartTime: Date?
    private var stressTestStartKeyboardAckCount: Int = 0
    private var stressTestStartMouseAckCount: Int = 0
    private var autoCheckTimer: Timer?
    private var statusUpdateTimer: Timer?
    
    override init() {
        super.init()
        initializeResults()
        updateLogFilePath()
        // Initialize serial logging state from logger
        isSerialLoggingEnabled = logger.SerialDataPrint
    }
    
    private func initializeResults() {
        // Clear all previous test results
        stepResults.removeAll()
    }
    
    private func updateLogFilePath() {
        let fileManager = FileManager.default
        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logPath = documentsDirectory.appendingPathComponent(AppStatus.logFileName).path
            self.logFilePath = logPath
        }
    }
    
    func enableLogging() {
        if let logger = logger as? Logger {
            logger.createLogFile()
            logger.openLogFile()
            logger.logToFile = true
            isLoggingEnabled = true
            addStatusMessage("📝 Logging enabled: \(logFilePath)")
        }
    }
    
    func disableLogging() {
        if let logger = logger as? Logger {
            logger.logToFile = false
            logger.closeLogFile()
            isLoggingEnabled = false
        }
    }

    func enableSerialLogging() {
        logger.SerialDataPrint = true
        isSerialLoggingEnabled = true
        addStatusMessage("🔌 Serial logging enabled")
    }

    func disableSerialLogging() {
        logger.SerialDataPrint = false
        isSerialLoggingEnabled = false
        addStatusMessage("🔌 Serial logging disabled")
    }
    
    // MARK: - Device Depth Check
    
    func checkDeviceDepthOnViewAppear() {
        // Mark that we've performed the initial check
        hasCheckedDeviceDepth = true
        
        var maxDepth = 0
        var deepDevices: [String] = []
        
        // Check video chip
        if let videoChip = AppStatus.videoChipDevice {
            let depth = countHubsToRoot(locationID: videoChip.locationID)
            if depth > maxDepth {
                maxDepth = depth
            }
            if depth > 2 {
                deepDevices.append("Video Chip (depth: \(depth))")
            }
        }
        
        // Check control chip
        if let controlChip = AppStatus.controlChipDevice {
            let depth = countHubsToRoot(locationID: controlChip.locationID)
            if depth > maxDepth {
                maxDepth = depth
            }
            if depth > 2 {
                deepDevices.append("Control Chip (depth: \(depth))")
            }
        }
        
        // Show warning if any device has depth > 2
        if !deepDevices.isEmpty {
            deviceDepthWarningActive = true
            depthWarningMessage = """
            ⚠️ USB Hub Warning
            
            Detected device(s) with depth > 2:
            \(deepDevices.joined(separator: "\n"))
            
            An external USB hub is likely present between the device and computer.
            
            ⚠️ IMPORTANT: Please ensure the USB hub has external power, or diagnostic tests may fail due to insufficient power.
            
            It's recommended to connect the device directly to your computer for accurate diagnostic results.
            """
            showDepthWarningAlert = true
            
            addStatusMessage("⚠️ USB Hub detected with depth > 2")
            addStatusMessage("⚠️ This may cause diagnostic test failures")
            addStatusMessage("⚠️ Please ensure hub has external power or connect device directly")
        } else {
            deviceDepthWarningActive = false
            addStatusMessage("✅ Device connected directly or through powered hub (depth ≤ 2)")
        }
    }
    
    // MARK: - Helper Methods
    
    /// Check if device depth has been verified before allowing tests
    func canProceedWithTests() -> Bool {
        return hasCheckedDeviceDepth
    }
    
    private func addStatusMessage(_ message: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: Date())
        statusMessages.append("[\(timestamp)] \(message)")
    }
    
    /// Returns the connection state image name based on current connection states
    /// H0 = Host orange cable disconnected, H1 = Host orange cable connected
    /// T0 = Target disconnected, T1 = Target connected
    /// V0 = Video not checking, V1 = Video checking
    var connectionStateImageName: String {
        // Show H_to_T image when testing target port checking
        if isTargetPortChecking {
            return "H_to_T"
        }
        
        let h = hostOrangeConnected ? 1 : 0
        let t = targetConnected ? 1 : 0
        let v = videoChecking ? 1 : 0
        
        // Special case: if both disconnected, start with H0T0V0
        if h == 0 && t == 0 {
            return "H0T0V0"
        }
        
        // If target not connected, show H1T0V1 (host connected, target not connected, video checking)
        if h == 1 && t == 0 {
            return "H1T0V1"
        }
        
        // If all connected, show H1T1V1 (host connected, target connected, video checking)
        if h == 1 && t == 1 && v == 1 {
            return "H1T1V1"
        }
        
        // Intermediate states
        if h == 1 && t == 0 && v == 0 {
            return "H1T0V0"
        }
        
        if h == 1 && t == 1 && v == 0 {
            return "H1T1V0"
        }
        
        if h == 0 && t == 1 && v == 1 {
            return "H0T1V1"
        }
        
        // Default to H0T0V0 for any unhandled state
        return "H0T0V0"
    }
    
    // MARK: - Test Methods
    
    func checkConnectedDevices() {
        addStatusMessage("🔍 Checking overall connection status...")
        
        // Start with H0T0V0 (all disconnected)
        hostOrangeConnected = false
        targetConnected = false
        videoChecking = false
        
        let halStatus = halIntegration.getHALStatus()
        let videoConnected = halStatus.videoChipsetConnected
        let controlConnected = halStatus.controlChipsetConnected
        let hasHdmi = AppStatus.isHDMIConnected
        
        var allConnected = true
        
        // Check Orange USB-C cable (Video chipset)
        if videoConnected {
            addStatusMessage("✅ Orange USB-C cable detected (Video chipset)")
            hostOrangeConnected = true
        } else {
            addStatusMessage("❌ Orange USB-C cable not detected")
            allConnected = false
        }
        
        // Check Black USB-C cable (Control chipset)
        if controlConnected {
            addStatusMessage("✅ Black USB-C cable detected (Control chipset)")
            targetConnected = true
        } else {
            addStatusMessage("❌ Black USB-C cable not detected")
            allConnected = false
        }
        
        // Check HDMI cable
        if hasHdmi {
            addStatusMessage("✅ Black HDMI cable detected (HDMI signal)")
        } else {
            addStatusMessage("⚠️ HDMI cable not detected - please connect the black HDMI cable")
            allConnected = false
        }
        
        // When all connected, mark video as checking
        if allConnected {
            videoChecking = true
        }
        
        // Set result based on all connections
        stepResults[.overallConnection] = allConnected
        
        if allConnected {
            addStatusMessage("✅ All cables properly connected")
            // Auto-advance if all devices connected (only when not in auto-check mode)
            if !isAutoChecking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.moveToNextStep()
                }
            }
        } else {
            addStatusMessage("⚠️ Some cables are not properly connected")
            addStatusMessage("")
            addStatusMessage("OPTIONS:")
            addStatusMessage("1️⃣  Fix the connections and click 'Run Test' to check again")
            addStatusMessage("2️⃣  Click 'Next >' to jump to Factory Reset step to continue testing")
        }
    }
    
    func testSerialConnection() {
        isTestRunning = true
        addStatusMessage("🔍 Testing serial connection...")
        addStatusMessage("Attempting baudrate detection by sending info command...")
        
        // Set a timeout for the entire test (15 seconds max)
        let testTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isTestRunning else { return }
            
            DispatchQueue.main.async {
                self.addStatusMessage("⏱️ Serial connection test timeout - no device response within 15 seconds")
                self.isTestRunning = false
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Try connecting with priority to high speed, then low speed
            let baudRatesToTry = [115200, 9600]
            var detected = false
            
            for baudRate in baudRatesToTry {
                // Check if already completed or timeout occurred
                if !self.isTestRunning {
                    break
                }
                
                DispatchQueue.main.async {
                    self.addStatusMessage("  ⏳ Trying baudrate: \(baudRate)...")
                }
                
                // Open serial port with this baudrate
                if let serialPortMgr = self.serialPortManager as? SerialPortManager {
                    serialPortMgr.openSerialPort(baudrate: baudRate)
                    
                    // Wait a moment for connection
                    Thread.sleep(forTimeInterval: 0.5)
                    
                    if serialPortMgr.isDeviceReady {
                        // Send info command with sync (expecting 0x81 response)
                        let response = serialPortMgr.sendSyncCommand(
                            command: SerialProtocolCommands.DeviceInfo.GET_HID_INFO,
                            expectedResponseCmd: 0x81,
                            timeout: 2.0,
                            force: true
                        )
                        
                        // Validate response with checksum verification
                        if !response.isEmpty {
                            let responseBytes = [UInt8](response)
                            
                            // Basic validation: check header and response command
                            if responseBytes.count >= 4 && 
                               responseBytes[0] == 0x57 && responseBytes[1] == 0xAB && responseBytes[2] == 0x00 &&
                               responseBytes[3] == 0x81 {
                                
                                // Verify checksum
                                let receivedChecksum = responseBytes[responseBytes.count - 1]
                                let calculatedChecksum = serialPortMgr.calculateChecksum(data: Array(responseBytes[0..<responseBytes.count - 1]))
                                
                                if receivedChecksum == calculatedChecksum {
                                    DispatchQueue.main.async {
                                        self.detectedBaudRate = baudRate
                                        self.currentBaudRate = baudRate
                                        self.addStatusMessage("✅ Serial connection established at \(baudRate) baud")
                                        self.addStatusMessage("✅ Device responded to info command")
                                        self.addStatusMessage("✅ Response checksum verified (0x\(String(format: "%02X", calculatedChecksum)))")
                                        self.stepResults[.serialConnection] = true
                                    }
                                    detected = true
                                    break
                                } else {
                                    DispatchQueue.main.async {
                                        let checksumHex = String(format: "%02X", calculatedChecksum)
                                        let receivedHex = String(format: "%02X", receivedChecksum)
                                        self.addStatusMessage("⚠️ Checksum mismatch at \(baudRate): calculated 0x\(checksumHex), received 0x\(receivedHex)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            if !detected {
                DispatchQueue.main.async {
                    self.addStatusMessage("❌ Could not establish serial connection")
                    self.addStatusMessage("Device did not respond at 9600 or 115200 baud")
                    self.addStatusMessage("Please check:")
                    self.addStatusMessage("  • Device is powered on")
                    self.addStatusMessage("  • USB cables are properly connected")
                    self.addStatusMessage("  • Device drivers are installed")
                }
            }
            
            DispatchQueue.main.async {
                testTimeoutTimer.invalidate()
                self.isTestRunning = false
                
                // Auto-advance if test passed (only when not in auto-check mode)
                if self.stepResults[.serialConnection] == true && !self.isAutoChecking {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.moveToNextStep()
                    }
                }
            }
        }
    }
    
    func testHostPlugAndPlay() {
        isTestRunning = true
        addStatusMessage("🔌 Starting plug and play test...")
        addStatusMessage("Please unplug the Orange USB-C cable (host side), wait 3 seconds, then plug it back in")
        addStatusMessage("Monitoring for disconnection and reconnection events for 30 seconds...")
        
        var disconnectDetected = false
        var reconnectDetected = false
        let testStartTime = Date()
        let testTimeout: TimeInterval = 30.0 // 30 second timeout
        
        // Set target and video states correctly at the start and keep them constant
        targetConnected = true
        videoChecking = true
        
        // Create animation timer to toggle only host state between H1 and H0
        var animationTimer: Timer?
        var animationToggle = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                animationTimer?.invalidate()
                return
            }
            
            DispatchQueue.main.async {
                animationToggle = !animationToggle
                self.hostOrangeConnected = animationToggle
                // Don't touch target and video - keep them constant
            }
        }
        
        // Create a monitoring timer
        var monitoringTimer: Timer?
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(testStartTime)
            
            // Check HAL status for connection changes
            let halStatus = self.halIntegration.getHALStatus()
            let videoConnected = halStatus.videoChipsetConnected
            
            // Log state changes
            if !disconnectDetected && !videoConnected {
                disconnectDetected = true
                DispatchQueue.main.async {
                    animationTimer?.invalidate()  // Stop animation when actual disconnection detected
                    self.hostOrangeConnected = false  // Update connection state only
                    self.addStatusMessage("✅ Disconnection detected: Orange USB-C cable unplugged. Please plug it back in.")
                }
            }
            
            if disconnectDetected && !reconnectDetected && videoConnected {
                reconnectDetected = true
                DispatchQueue.main.async {
                    self.hostOrangeConnected = true  // Update connection state only
                    self.addStatusMessage("✅ Reconnection detected - Orange USB-C plugged back in")
                }
            }
            
            // Check if test should complete
            if reconnectDetected || elapsed >= testTimeout {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                
                DispatchQueue.main.async {
                    if reconnectDetected {
                        self.addStatusMessage("")
                        self.addStatusMessage("✅ Host plug and play test completed successfully")
                        self.stepResults[.hostPlugAndPlayTest] = true
                        
                        // Auto-advance on success (only when not in auto-check mode)
                        if !self.isAutoChecking {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.moveToNextStep()
                            }
                        }
                    } else {
                        self.addStatusMessage("")
                        self.addStatusMessage("⏱️ Plug and play test timeout - no reconnection detected within 30 seconds")
                        self.addStatusMessage("Please ensure you plugged the device back in")
                    }
                    self.isTestRunning = false
                }
            }
        }
    }
    
    func testTargetBlackCable() {
        isTestRunning = true
        addStatusMessage("🔌 Starting Black USB-C cable test...")
        addStatusMessage("Please unplug the Black USB-C cable (target side), wait 3 seconds, then plug it back in")
        addStatusMessage("Monitoring for disconnection and reconnection events for 30 seconds...")
        
        var disconnectDetected = false
        var reconnectDetected = false
        var hostSideAlsoDisconnected = false
        var videoWasConnected = true // Track if video was initially connected
        let testStartTime = Date()
        let testTimeout: TimeInterval = 30.0 // 30 second timeout
        
        // Create animation timer to toggle image between H1T1V1 and H1T0V1
        var animationTimer: Timer?
        var animationToggle = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                animationTimer?.invalidate()
                return
            }
            
            DispatchQueue.main.async {
                animationToggle = !animationToggle
                self.targetConnected = animationToggle
            }
        }
        
        // Create a monitoring timer
        var monitoringTimer: Timer?
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(testStartTime)
            
            // Check HAL status for connection changes
            let halStatus = self.halIntegration.getHALStatus()
            let controlConnected = halStatus.controlChipsetConnected
            let videoConnected = halStatus.videoChipsetConnected
            
            // Log state changes for target side disconnection
            if !disconnectDetected && !controlConnected {
                disconnectDetected = true
                DispatchQueue.main.async {
                    animationTimer?.invalidate()  // Stop animation when actual disconnection detected
                    self.targetConnected = false  // Update connection state
                    self.addStatusMessage("✅ Disconnection detected: Black USB-C cable unplugged. Please plug it back in.")
                }
            }
            
            // Additional check: if video was connected but suddenly disconnects during the test
            // (in case it wasn't caught at the initial disconnect moment)
            if disconnectDetected && !hostSideAlsoDisconnected && videoWasConnected && !videoConnected {
                hostSideAlsoDisconnected = true
                DispatchQueue.main.async {
                    self.addStatusMessage("")
                    self.addStatusMessage("⚠️ WARNING: Orange USB-C cable (host side) disconnected during test!")
                    self.addStatusMessage("❌ This indicates a hardware defect - the cables are internally shorted or damaged")
                    self.addStatusMessage("🔴 DEVICE MAY REQUIRE REPLACEMENT")
                }
            }
            
            // Update video connection state for next iteration
            videoWasConnected = videoConnected
            
            if disconnectDetected && !reconnectDetected && controlConnected {
                reconnectDetected = true
                DispatchQueue.main.async {
                    self.targetConnected = true  // Update connection state
                    self.addStatusMessage("✅ Reconnection detected - Black USB-C plugged back in")
                    if videoConnected {
                        self.addStatusMessage("✅ Orange USB-C remained connected (normal behavior)")
                    }
                }
            }
            
            // Check if test should complete
            if reconnectDetected || elapsed >= testTimeout {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                
                DispatchQueue.main.async {
                    if hostSideAlsoDisconnected {
                        // Device is defective
                        self.isDefectiveUnitDetected = true
                        self.addStatusMessage("")
                        self.addStatusMessage("❌ Black USB-C cable test FAILED - Device defective")
                        self.stepResults[.targetBlackCableTest] = false
                    } else if reconnectDetected {
                        self.addStatusMessage("")
                        self.addStatusMessage("✅ Black USB-C cable test completed successfully")
                        self.stepResults[.targetBlackCableTest] = true
                        
                        // Auto-advance on success (only when not in auto-check mode)
                        if !self.isAutoChecking {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.moveToNextStep()
                            }
                        }
                    } else {
                        self.addStatusMessage("")
                        self.addStatusMessage("⏱️ Black USB-C cable test timeout - no reconnection detected within 30 seconds")
                        self.addStatusMessage("❌ Black USB-C cable test FAILED - Test timeout")
                        self.stepResults[.targetBlackCableTest] = false
                    }
                    self.isTestRunning = false
                }
            }
        }
    }
    
    func resetToFactoryBaudrate() {
        isTestRunning = true
        addStatusMessage("🔄 Performing factory reset...")
        addStatusMessage("Pulling RTS signal low for 3.5 seconds...")
        
        if let serialPortMgr = self.serialPortManager as? SerialPortManager {
            serialPortMgr.resetHidChipToFactory { [weak self] success in
                guard let self = self else { return }
                
                if success {
                    // Start polling for HID info response every 2 seconds, timeout after 30 seconds
                    let resetStartTime = Date()
                    let maxWaitTime: TimeInterval = 30.0
                    
                    DispatchQueue.main.async {
                        self.addStatusMessage("🔍 Verifying factory reset with HID info command (polling every 2 seconds)...")
                    }
                    
                    var verificationTimer: Timer?
                    verificationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                        guard let self = self else {
                            verificationTimer?.invalidate()
                            return
                        }
                        
                        let elapsed = Date().timeIntervalSince(resetStartTime)
                        
                        // Check if timeout exceeded
                        if elapsed >= maxWaitTime {
                            verificationTimer?.invalidate()
                            DispatchQueue.main.async {
                                self.addStatusMessage("⏱️ Factory reset verification timeout (30 seconds)")
                                self.addStatusMessage("❌ No valid HID info response received within timeout")
                                self.addStatusMessage("")
                                self.addStatusMessage("Please disconnect all cables (Orange USB-C, Black USB-C, and HDMI)")
                                self.addStatusMessage("Showing animation until all cables are disconnected...")
                                
                                // Start cable reconnection workflow
                                self.handleFactoryResetCableReconnection()
                            }
                            return
                        }
                        
                        // Send HID info command to verify communication
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self = self else { return }
                            
                            if let serialPortMgr = self.serialPortManager as? SerialPortManager {
                                let response = serialPortMgr.sendSyncCommand(
                                    command: SerialProtocolCommands.DeviceInfo.GET_HID_INFO,
                                    expectedResponseCmd: 0x81,
                                    timeout: 2.0,
                                    force: true
                                )
                                
                                DispatchQueue.main.async {
                                    if !response.isEmpty {
                                        // Validate response
                                        let responseBytes = [UInt8](response)
                                        if responseBytes.count >= 4 &&
                                           responseBytes[0] == 0x57 && responseBytes[1] == 0xAB && responseBytes[2] == 0x00 &&
                                           responseBytes[3] == 0x81 {
                                            
                                            // Verify checksum
                                            let receivedChecksum = responseBytes[responseBytes.count - 1]
                                            let calculatedChecksum = serialPortMgr.calculateChecksum(data: Array(responseBytes[0..<responseBytes.count - 1]))
                                            
                                            if receivedChecksum == calculatedChecksum {
                                                verificationTimer?.invalidate()
                                                self.currentBaudRate = 9600
                                                self.addStatusMessage("✅ Factory reset complete")
                                                self.addStatusMessage("✅ Device reset to factory settings (9600 baud)")
                                                self.addStatusMessage("✅ HID info verified (checksum: 0x\(String(format: "%02X", calculatedChecksum)))")
                                                self.stepResults[.resetFactoryBaudrate] = true
                                                
                                                // Auto-advance on success (only when not in auto-check mode)
                                                if !self.isAutoChecking {
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                                        self.moveToNextStep()
                                                    }
                                                }
                                                
                                                self.isTestRunning = false
                                            }
                                        }
                                    } else {
                                        let elapsed = Date().timeIntervalSince(resetStartTime)
                                        self.addStatusMessage("⏳ Attempt at \(String(format: "%.1f", elapsed))s: No response yet, retrying...")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.addStatusMessage("❌ Factory reset failed")
                        self.addStatusMessage("Could not toggle RTS signal or complete reset sequence")
                        self.isTestRunning = false
                    }
                }
            }
        }
    }
    
    private func handleFactoryResetCableReconnection() {
        // Set initial states to H1T1V1 (all connected) for animation start
        hostOrangeConnected = true
        targetConnected = true
        videoChecking = true
        
        var disconnectDetected = false
        let cableReconnectionStartTime = Date()
        let maxWaitTime: TimeInterval = 60.0  // 1 minute timeout for cable reconnection
         
        // Create animation timer to blink between H1T1V1 and H0T0V0
        var animationTimer: Timer?
        var animationToggle = true
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                animationTimer?.invalidate()
                return
            }
            
            DispatchQueue.main.async {
                animationToggle = !animationToggle
                // Toggle all states: H, T, V
                self.hostOrangeConnected = animationToggle
                self.targetConnected = animationToggle
                self.videoChecking = animationToggle
            }
        }
        
        // Create a monitoring timer to detect when all cables are disconnected
        var monitoringTimer: Timer?
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(cableReconnectionStartTime)
            
            // Check timeout - if waiting too long, stop monitoring
            if elapsed >= maxWaitTime {
                monitoringTimer?.invalidate()
                animationTimer?.invalidate()
                
                DispatchQueue.main.async {
                    self.addStatusMessage("")
                    self.addStatusMessage("⏱️ Cable reconnection timeout (60 seconds)")
                    self.addStatusMessage("❌ Device was not reconnected within the timeout period")
                    self.addStatusMessage("⚠️ Factory reset may require manual intervention")
                    self.isTestRunning = false
                }
                return
            }
            
            // Check HAL status for cable disconnection
            let halStatus = self.halIntegration.getHALStatus()
            let videoConnected = halStatus.videoChipsetConnected
            let controlConnected = halStatus.controlChipsetConnected
            
            // Detect when all cables are fully disconnected (both chipsets false)
            if !disconnectDetected && !videoConnected && !controlConnected {
                disconnectDetected = true
                animationTimer?.invalidate()  // Stop animation when all cables disconnected
                
                DispatchQueue.main.async {
                    self.hostOrangeConnected = false
                    self.targetConnected = false
                    self.videoChecking = false
                    
                    self.addStatusMessage("✅ All cables disconnected successfully")
                    self.addStatusMessage("")
                    self.addStatusMessage("Please reconnect all cables (Orange USB-C, Black USB-C, and HDMI)")
                    self.addStatusMessage("Waiting for reconnection...")
                }
            }
            
            // Once disconnected, monitor for reconnection (both chipsets true)
            if disconnectDetected && videoConnected && controlConnected {
                monitoringTimer?.invalidate()
                
                DispatchQueue.main.async {
                    self.hostOrangeConnected = true
                    self.targetConnected = true
                    self.videoChecking = true
                    
                    self.addStatusMessage("✅ All cables reconnected successfully")
                    self.addStatusMessage("")
                    self.addStatusMessage("Retrying factory reset verification...")
                    
                    // Retry the factory reset verification after brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.retryFactoryResetVerification()
                    }
                }
            }
        }
    }
    
    private func retryFactoryResetVerification() {
        guard self.serialPortManager is SerialPortManager else {
            addStatusMessage("❌ Serial port manager not available")
            isTestRunning = false
            return
        }
        
        // Start polling for HID info response every 2 seconds, timeout after 30 seconds
        let resetStartTime = Date()
        let maxWaitTime: TimeInterval = 30.0
        
        addStatusMessage("🔍 Verifying factory reset with HID info command (polling every 2 seconds)...")
        
        var verificationTimer: Timer?
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else {
                verificationTimer?.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(resetStartTime)
            
            // Check if timeout exceeded
            if elapsed >= maxWaitTime {
                verificationTimer?.invalidate()
                DispatchQueue.main.async {
                    self.addStatusMessage("⏱️ Factory reset verification timeout (30 seconds)")
                    self.addStatusMessage("❌ No valid HID info response received within timeout")
                    self.addStatusMessage("⚠️ Device may require manual reset or replacement")
                    self.isTestRunning = false
                }
                return
            }
            
            // Send HID info command to verify communication
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                if let serialPortMgr = self.serialPortManager as? SerialPortManager {
                    let response = serialPortMgr.sendSyncCommand(
                        command: SerialProtocolCommands.DeviceInfo.GET_HID_INFO,
                        expectedResponseCmd: 0x81,
                        timeout: 2.0,
                        force: true
                    )
                    
                    DispatchQueue.main.async {
                        if !response.isEmpty {
                            // Validate response
                            let responseBytes = [UInt8](response)
                            if responseBytes.count >= 4 &&
                               responseBytes[0] == 0x57 && responseBytes[1] == 0xAB && responseBytes[2] == 0x00 &&
                               responseBytes[3] == 0x81 {
                                
                                // Verify checksum
                                let receivedChecksum = responseBytes[responseBytes.count - 1]
                                let calculatedChecksum = serialPortMgr.calculateChecksum(data: Array(responseBytes[0..<responseBytes.count - 1]))
                                
                                if receivedChecksum == calculatedChecksum {
                                    verificationTimer?.invalidate()
                                    self.currentBaudRate = 9600
                                    self.addStatusMessage("✅ Factory reset complete")
                                    self.addStatusMessage("✅ Device reset to factory settings (9600 baud)")
                                    self.addStatusMessage("✅ HID info verified (checksum: 0x\(String(format: "%02X", calculatedChecksum)))")
                                    self.stepResults[.resetFactoryBaudrate] = true
                                    
                                    // Auto-advance on success (only when not in auto-check mode)
                                    if !self.isAutoChecking {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                            self.moveToNextStep()
                                        }
                                    }
                                    
                                    self.isTestRunning = false
                                }
                            }
                        } else {
                            let elapsed = Date().timeIntervalSince(resetStartTime)
                            self.addStatusMessage("⏳ Attempt at \(String(format: "%.1f", elapsed))s: No response yet, retrying...")
                        }
                    }
                }
            }
        }
    }
    
    func changeBaudrateTo115200() {
        isTestRunning = true
        addStatusMessage("🔄 Changing baudrate to 115200...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if let serialPortMgr = self.serialPortManager as? SerialPortManager {
                serialPortMgr.resetDeviceToBaudrate(115200)
                
                // Poll isDeviceReady for up to 30 seconds
                let maxWaitTime: TimeInterval = 30.0
                let pollInterval: TimeInterval = 2.0
                let startTime = Date()
                var isReady = false
                
                while Date().timeIntervalSince(startTime) < maxWaitTime {
                    Thread.sleep(forTimeInterval: pollInterval)
                    if serialPortMgr.isDeviceReady {
                        isReady = true
                        break
                    }

                }
                
                DispatchQueue.main.async {
                    if isReady {
                        self.currentBaudRate = 115200
                        self.addStatusMessage("✅ Successfully changed baudrate to 115200")
                        self.stepResults[.changeTo115200] = true
                        
                        // Auto-advance on success (only when not in auto-check mode)
                        if !self.isAutoChecking {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.moveToNextStep()
                            }
                        }
                    } else {
                        let elapsedTime = Date().timeIntervalSince(startTime)
                        self.addStatusMessage("❌ Failed to change baudrate to 115200 after \(String(format: "%.1f", elapsedTime)) seconds")
                        self.addStatusMessage("Device did not become ready within the timeout period")
                    }
                    self.isTestRunning = false
                }
            }
        }
    }
    
    func runStressTest() {
        isTestRunning = true
        stressTestProgress = 0.0
        stressTestStatus = "Starting stress test..."
        stressTestKeyboardSent = 0
        stressTestMouseSent = 0
        stressTestKeyboardAck = 0
        stressTestMouseAck = 0
        stressTestKeyboardRate = 0.0
        stressTestMouseRate = 0.0
        addStatusMessage("⚙️ Running platform stress test (30 seconds)...")
        addStatusMessage("Sending high volume of keyboard and mouse data...")
        
        // Reset ACK counters before starting the test
        if let serialPortMgr = self.serialPortManager as? SerialPortManager {
            serialPortMgr.resetAckCounters()
            // Disable periodic reset during stress test to get accurate counts
            serialPortMgr.disablePeriodicAckReset = true
            
            // Capture starting ACK counts for delta calculation
            let startCounts = serialPortMgr.getCurrentAckCounts()
            self.stressTestStartKeyboardAckCount = startCounts.keyboard
            self.stressTestStartMouseAckCount = startCounts.mouse
        }
        
        stressTestStartTime = Date()
        let testDuration: TimeInterval = 30.0
        var commandsSent = 0
        var stressTestSendTimer: Timer?
        
        guard let serialPortMgr = self.serialPortManager as? SerialPortManager else { return }
        
        // Schedule command sending timer on main thread
        stressTestSendTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Alternate between keyboard and mouse commands
            if commandsSent % 2 == 0 {
                // Send keyboard command with random a-z, A-Z key
                let isUppercase = Bool.random()
                let randomLetter: String
                if isUppercase {
                    // A-Z: ASCII 65-90
                    let randomASCII = UInt8.random(in: 65...90)
                    randomLetter = String(UnicodeScalar(randomASCII))
                } else {
                    // a-z: ASCII 97-122
                    let randomASCII = UInt8.random(in: 97...122)
                    randomLetter = String(UnicodeScalar(randomASCII))
                }
                
                // Use keyboard manager to send the text
                if let keyboardMgr = self.keyboardManager as? KeyboardManager {
                    keyboardMgr.sendTextToKeyboard(text: randomLetter)
                    // Count as 3 sends since keyboard sends press+release which generates 3 ACKs
                    self.stressTestKeyboardSent += 3
                }
            } else {
                // Send mouse absolute position command
                if let mouseMgr = self.mouseManager as? MouseManager {
                    // Random X (0-1920) and Y (0-1080) coordinates
                    let xCoord = Int.random(in: 0...1920)
                    let yCoord = Int.random(in: 0...1080)
                    mouseMgr.enqueueAbsoluteMouseEvent(x: xCoord, y: yCoord)
                    self.stressTestMouseSent += 1
                }
            }
            
            commandsSent += 1
        }
        
        // Main stress test monitoring timer - on main thread
        stressTestTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(self.stressTestStartTime ?? Date())
            self.stressTestProgress = min(elapsed / testDuration, 1.0)
            
            // Get actual ACK counts from serial port manager and calculate delta
            let ackCounts = serialPortMgr.getCurrentAckCounts()
            self.stressTestKeyboardAck = max(0, ackCounts.keyboard - self.stressTestStartKeyboardAckCount)
            self.stressTestMouseAck = max(0, ackCounts.mouse - self.stressTestStartMouseAckCount)
            
            // Calculate success rates
            if self.stressTestKeyboardSent > 0 {
                self.stressTestKeyboardRate = (Double(self.stressTestKeyboardAck) / Double(self.stressTestKeyboardSent)) * 100.0
            }
            
            if self.stressTestMouseSent > 0 {
                self.stressTestMouseRate = (Double(self.stressTestMouseAck) / Double(self.stressTestMouseSent)) * 100.0
            }
            
            self.stressTestStatus = String(format: "⌨️ KB: %d→%d (%.1f%%) | 🖱️ MS: %d→%d (%.1f%%) | %.0f/30s",
                                           self.stressTestKeyboardSent,
                                           self.stressTestKeyboardAck,
                                           self.stressTestKeyboardRate,
                                           self.stressTestMouseSent,
                                           self.stressTestMouseAck,
                                           self.stressTestMouseRate,
                                           elapsed)
            
            if elapsed >= testDuration {
                timer.invalidate()
                stressTestSendTimer?.invalidate()
                self.stressTestTimer = nil
                self.completeStressTest()
            }
        }
    }
    
    private func completeStressTest() {
        stressTestProgress = 1.0
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Re-enable periodic ACK reset after test completes
            if let serialPortMgr = self.serialPortManager as? SerialPortManager {
                serialPortMgr.disablePeriodicAckReset = false
            }
            
            let totalSent = self.stressTestKeyboardSent + self.stressTestMouseSent
            let totalAck = self.stressTestKeyboardAck + self.stressTestMouseAck
            
            self.addStatusMessage("✅ Stress test completed successfully")
            self.addStatusMessage("")
            self.addStatusMessage("📊 Keyboard Messages:")
            self.addStatusMessage("   Sent: \(self.stressTestKeyboardSent) | Ack: \(self.stressTestKeyboardAck) | Rate: \(String(format: "%.1f%%", self.stressTestKeyboardRate))")
            self.addStatusMessage("")
            self.addStatusMessage("📊 Mouse Messages:")
            self.addStatusMessage("   Sent: \(self.stressTestMouseSent) | Ack: \(self.stressTestMouseAck) | Rate: \(String(format: "%.1f%%", self.stressTestMouseRate))")
            self.addStatusMessage("")
            self.addStatusMessage("📊 Total:")
            self.addStatusMessage("   Sent: \(totalSent) | Ack: \(totalAck)")
            
            if totalSent > 0 {
                let overallRate = (Double(totalAck) / Double(totalSent)) * 100.0
                self.addStatusMessage("   Overall Rate: \(String(format: "%.1f%%", overallRate))")
                
                if overallRate >= 90.0 && self.stressTestKeyboardRate >= 90.0 && self.stressTestMouseRate >= 90.0 {
                    self.addStatusMessage("")
                    self.addStatusMessage("✅ All systems performing normally")
                    self.stepResults[.stressTest] = true
                    self.addStatusMessage("🎉 All diagnostic tests passed! Device is ready for use.")
                } else {
                    self.addStatusMessage("")
                    self.addStatusMessage("⚠️ Some ACK rates are below 90% threshold")
                    self.addStatusMessage("❌ Stress test FAILED - Device may require replacement")
                    self.addStatusMessage("")
                    self.addStatusMessage("Performing additional USB device detection test...")
                    self.addStatusMessage("Please connect the Orange USB-C cable (host side) to the Black USB-C port (target side)")
                    self.stepResults[.stressTest] = false
                    self.isDefectiveUnitDetected = true
                    
                    // Auto-advance to USB device detection test (only when not in auto-check mode)
                    if !self.isAutoChecking {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.currentStep = .targetPortChecking
                        }
                    }
                }
            } else {
                self.addStatusMessage("❌ Stress test failed - no commands sent")
                self.stepResults[.stressTest] = false
            }
            
            self.isTestRunning = false
        }
    }
    
    func testtargetPortChecking() {
        // Only allow USB device detection test if stress test failed
        if stepResults[.stressTest] != false {
            addStatusMessage("⚠️ USB Device Detection test can only be run after Stress Test failure")
            addStatusMessage("This test helps diagnose the cause of stress test failure")
            return
        }
        
        isTestRunning = true
        isTargetPortChecking = true  // Show H_to_T image
        addStatusMessage("🔍 Checking for target port by orange cable")
        addStatusMessage("Context: Orange USB-C cable (host side) is connected to Black USB-C port (target side)")
        addStatusMessage("Looking for USB device (VID: 0x1a86, PID: 0xe329)")
        addStatusMessage("")
        addStatusMessage("Monitoring for 10 seconds...")
        
        let testStartTime = Date()
        let testTimeout: TimeInterval = 10.0
        let targetVID: UInt32 = 0x1a86
        let targetPID: UInt32 = 0xe329
        
        // Create a monitoring timer
        var monitoringTimer: Timer?
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isTestRunning else {
                monitoringTimer?.invalidate()
                return
            }
            
            let elapsed = Date().timeIntervalSince(testStartTime)
            
            // Check for USB device with specific VID and PID
            let deviceFound = self.checkUSBDeviceConnected(vendorID: targetVID, productID: targetPID)
            
            if deviceFound {
                monitoringTimer?.invalidate()
                DispatchQueue.main.async {
                    self.isTargetPortChecking = false  // Hide H_to_T image
                    self.addStatusMessage("")
                    self.addStatusMessage("✅ USB device detected (VID: 0x1a86, PID: 0xe329)")
                    self.addStatusMessage("✅ Target device is properly connected and responding")
                    self.addStatusMessage("")
                    self.addStatusMessage("Please prepare a defect report to send to support:")
                    self.addStatusMessage("📧 Click 'Send Defect Report to Support' button to prepare logs and email")
                    self.stepResults[.targetPortChecking] = true
                    self.isTestRunning = false
                }
            } else if elapsed >= testTimeout {
                monitoringTimer?.invalidate()
                DispatchQueue.main.async {
                    self.isTargetPortChecking = false  // Hide H_to_T image
                    self.addStatusMessage("")
                    self.addStatusMessage("⏱️ USB device (VID: 0x1a86, PID: 0xe329) not detected after 10 seconds")
                    self.addStatusMessage("⚠️ This indicates the target device is not properly connected or not responding")
                    self.addStatusMessage("")
                    self.addStatusMessage("Please prepare a defect report to send to support:")
                    self.addStatusMessage("📧 Click 'Send Defect Report to Support' button to prepare logs and email")
                    self.stepResults[.targetPortChecking] = false
                    self.isTestRunning = false
                }
            }
        }
    }
    
    private func checkUSBDeviceConnected(vendorID: UInt32, productID: UInt32) -> Bool {
        let matchingDict = [
            kUSBVendorID: vendorID,
            kUSBProductID: productID
        ] as [String: Any]
        
        let servicesToMatch = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        servicesToMatch.addEntries(from: matchingDict)
        
        var iterator: io_iterator_t = 0
        let kernelResult = IOServiceGetMatchingServices(kIOMainPortDefault, servicesToMatch as CFDictionary, &iterator)
        
        if kernelResult != KERN_SUCCESS {
            return false
        }
        
        defer {
            IOObjectRelease(iterator)
        }
        
        // Check if any matching device was found
        let device = IOIteratorNext(iterator)
        let found = device != IO_OBJECT_NULL
        
        if device != IO_OBJECT_NULL {
            IOObjectRelease(device)
        }
        
        return found
    }
    
    func moveToNextStep() {
        let currentIndex = currentStep.rawValue
        if currentIndex < DiagnosticTestStep.allCases.count - 1 {
            currentStep = DiagnosticTestStep.allCases[currentIndex + 1]
        }
    }
    
    func moveToPreviousStep() {
        let currentIndex = currentStep.rawValue
        if currentIndex > 0 {
            currentStep = DiagnosticTestStep.allCases[currentIndex - 1]
        }
    }
    
    func restartDiagnostics() {
        stopAutoCheck()
        initializeResults()
        currentStep = .overallConnection
        statusMessages.removeAll()
        currentBaudRate = 0
        detectedBaudRate = nil
        stressTestProgress = 0.0
        stressTestStatus = ""
        stressTestKeyboardSent = 0
        stressTestMouseSent = 0
        stressTestKeyboardAck = 0
        stressTestMouseAck = 0
        stressTestKeyboardRate = 0.0
        stressTestMouseRate = 0.0
        
        // Reset connection state tracking
        hostOrangeConnected = false
        targetConnected = false
        videoChecking = false
        stressTestStartKeyboardAckCount = 0
        stressTestStartMouseAckCount = 0
        stressTestTimer?.invalidate()
        stressTestTimer = nil
        
        // Re-enable periodic ACK reset
        if let serialPortMgr = self.serialPortManager as? SerialPortManager {
            serialPortMgr.disablePeriodicAckReset = false
        }
    }
    
    var visibleTestSteps: [DiagnosticTestStep] {
        return DiagnosticTestStep.allCases.filter { step in
            // Only hide Target Port Checking if Stress Test didn't fail
            if step == .targetPortChecking && stepResults[.stressTest] != false {
                return false
            }
            return true
        }
    }
    
    var allTestsCompleted: Bool {
        let visibleCount = visibleTestSteps.count
        let completedVisibleTests = stepResults.filter { visibleTestSteps.contains($0.key) && $0.value == true }
        return completedVisibleTests.count == visibleCount && completedVisibleTests.values.allSatisfy { $0 == true }
    }
    
    var completedTestCount: Int {
        return stepResults.filter { visibleTestSteps.contains($0.key) && $0.value == true }.count
    }
    
    // MARK: - Auto Checking Methods
    
    func startAutoCheck() {
        guard !isAutoChecking else { return }
        
        // Reset results to start fresh auto-check
        initializeResults()
        currentStep = .overallConnection
        
        isAutoChecking = true
        addStatusMessage("▶️ Starting auto-check sequence...")
        addStatusMessage("Each test will run with 2-second delays between them")
        
        performNextAutoCheck()
    }
    
    func stopAutoCheck() {
        isAutoChecking = false
        autoCheckTimer?.invalidate()
        autoCheckTimer = nil
        addStatusMessage("⏹️ Auto-check sequence stopped")
    }
    
    private func performNextAutoCheck() {
        // Check if we've completed all tests
        if allTestsCompleted {
            DispatchQueue.main.async {
                self.addStatusMessage("")
                self.addStatusMessage("✅ All tests passed! Auto-check complete.")
                self.isAutoChecking = false
            }
            return
        }
        
        // Run the current step's test
        DispatchQueue.main.async {
            self.addStatusMessage("")
            self.addStatusMessage("🔄 Running: \(self.currentStep.title)")
        }
        
        switch currentStep {
        case .overallConnection:
            checkConnectedDevices()
        case .serialConnection:
            testSerialConnection()
        case .hostPlugAndPlayTest:
            testHostPlugAndPlay()
        case .targetBlackCableTest:
            testTargetBlackCable()
        case .resetFactoryBaudrate:
            resetToFactoryBaudrate()
        case .changeTo115200:
            changeBaudrateTo115200()
        case .stressTest:
            runStressTest()
        case .targetPortChecking:
            testtargetPortChecking()
        }
        
        // Schedule next check after a delay
        autoCheckTimer?.invalidate()
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self, self.isAutoChecking else {
                timer.invalidate()
                return
            }
            
            // Wait for test to complete (isTestRunning becomes false)
            if !self.isTestRunning {
                timer.invalidate()
                
                // Check if current step passed
                if let result = self.stepResults[self.currentStep] {
                    if result {
                        // Test passed, move to next step
                        self.moveToNextStep()
                        
                        // Schedule next auto-check with 2-second delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            if self.isAutoChecking {
                                self.performNextAutoCheck()
                            }
                        }
                    } else {
                        // Test failed, stop auto-check
                        DispatchQueue.main.async {
                            self.addStatusMessage("")
                            self.addStatusMessage("❌ Test failed: \(self.currentStep.title)")
                            self.addStatusMessage("Auto-check stopped due to failure")
                            self.isAutoChecking = false
                        }
                    }
                } else {
                    // Result not available even though test is done - mark as failure
                    DispatchQueue.main.async {
                        self.addStatusMessage("")
                        self.addStatusMessage("❌ Test failed: \(self.currentStep.title) - no result")
                        self.addStatusMessage("Auto-check stopped due to failure")
                        self.isAutoChecking = false
                    }
                }
            }
        }
    }
    
    func sendDefectReportEmail() {
        addStatusMessage("")
        addStatusMessage("📋 Preparing defect report email...")
        
        // Run file I/O operations on a background thread to avoid blocking the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Prepare log content
            let statusAndResults = self.getStatusAndResultsLog()
            let diagnosticsLog = self.getApplicationLogContent()
            
            DispatchQueue.main.async {
                self.addStatusMessage("📝 Status and results log size: \(statusAndResults.count) bytes")
                self.addStatusMessage("📝 Application log size: \(diagnosticsLog.count) bytes")
            }
            
            // Create email subject and body
            let emailSubject = "Defective Unit Report - Device May Require Replacement"
            
            let emailBody = """
            Hello Openterface Support,
            
            I have detected a hardware defect during diagnostics testing. The device is not functioning properly and requires replacement.
            
            DEFECT DETECTED:
            ================
            When unplugging the Black USB-C cable (target side), the Orange USB-C cable (host side) also disconnected unexpectedly. This indicates the host side power supply component has internal hardware damage.
            
            TEST RESULT:
            ============
            ❌ Black USB-C Cable Test FAILED - Device Defective
            🔴 DEVICE MAY REQUIRES REPLACEMENT
            
            DEVICE INFORMATION:
            ===================
            - Openterface Version: \(self.getAppVersion())
            - macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)
            - Testing Date: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
            
            DIAGNOSTIC RESULTS:
            ===================
            \(statusAndResults)
            
            ATTACHED FILES:
            ===============
            • Openterface_Status_Results.log - Detailed diagnostic test results
            • Openterface_App.log - Application logs for troubleshooting
            
            Please review the diagnostic information above and advise on the replacement process. 
            
            Thank you,
            Openterface User
            """
            
            let fileManager = FileManager.default
            var reportDir: URL? = nil
            
            // Try multiple locations in order of preference
            DispatchQueue.main.async {
                self.addStatusMessage("🔍 Finding suitable location for report files...")
            }
            
            // 1. Try Downloads folder first (most user-friendly)
            if let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                DispatchQueue.main.async {
                    self.addStatusMessage("  📍 Trying Downloads folder")
                }
                let testDir = downloadsDir.appendingPathComponent("Openterface_Defect_Report_Test")
                do {
                    try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true, attributes: nil)
                    try fileManager.removeItem(at: testDir)
                    reportDir = downloadsDir.appendingPathComponent("Openterface_Defect_Report")
                    DispatchQueue.main.async {
                        self.addStatusMessage("  ✅ Downloads folder is writable")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.addStatusMessage("  ❌ Downloads folder not writable")
                    }
                }
            }
            
            // 2. Try Documents folder
            if reportDir == nil, let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                DispatchQueue.main.async {
                    self.addStatusMessage("  📍 Trying Documents folder")
                }
                let testDir = documentsDir.appendingPathComponent("Openterface_Defect_Report_Test")
                do {
                    try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true, attributes: nil)
                    try fileManager.removeItem(at: testDir)
                    reportDir = documentsDir.appendingPathComponent("Openterface_Defect_Report")
                    DispatchQueue.main.async {
                        self.addStatusMessage("  ✅ Documents folder is writable")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.addStatusMessage("  ❌ Documents folder not writable")
                    }
                }
            }
            
            // 3. Try temporary directory
            if reportDir == nil {
                DispatchQueue.main.async {
                    self.addStatusMessage("  📍 Using temporary folder as fallback")
                }
                reportDir = fileManager.temporaryDirectory.appendingPathComponent("Openterface_Defect_Report")
            }
            
            guard let finalReportDir = reportDir else {
                DispatchQueue.main.async {
                    self.addStatusMessage("❌ Could not find any writable location")
                }
                return
            }
            
            // Create report directory and files
            do {
                DispatchQueue.main.async {
                    self.addStatusMessage("")
                    self.addStatusMessage("📁 Creating report directory...")
                }
                try fileManager.createDirectory(at: finalReportDir, withIntermediateDirectories: true, attributes: nil)
                
                let statusLogPath = finalReportDir.appendingPathComponent("Openterface_Status_Results.log")
                let diagnosticsLogPath = finalReportDir.appendingPathComponent("Openterface_App.log")
                
                // Write logs to files
                DispatchQueue.main.async {
                    self.addStatusMessage("📝 Writing log files...")
                }
                try statusAndResults.write(toFile: statusLogPath.path, atomically: true, encoding: String.Encoding.utf8)
                DispatchQueue.main.async {
                    self.addStatusMessage("✅ Status and results log saved")
                }
                
                try diagnosticsLog.write(toFile: diagnosticsLogPath.path, atomically: true, encoding: String.Encoding.utf8)
                DispatchQueue.main.async {
                    self.addStatusMessage("✅ Application log saved")
                }
                
                DispatchQueue.main.async {
                    self.addStatusMessage("")
                    self.addStatusMessage("✅ Report files created successfully!")
                    self.addStatusMessage("📂 Location: \(finalReportDir.path)")
                    self.addStatusMessage("")
                }
                
                // Show dialog with email template on main thread (async to avoid blocking)
                DispatchQueue.main.async {
                    self.showDefectReportDialog(
                        emailSubject: emailSubject,
                        emailBody: emailBody,
                        reportDir: finalReportDir,
                        statusLogPath: statusLogPath,
                        diagnosticsLogPath: diagnosticsLogPath
                    )
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.addStatusMessage("❌ Error creating report files: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func showDefectReportDialog(emailSubject: String, emailBody: String, reportDir: URL, statusLogPath: URL, diagnosticsLogPath: URL) {
        _ = DefectReportDialog.show(
            emailSubject: emailSubject,
            emailBody: emailBody,
            reportDir: reportDir,
            statusLogPath: statusLogPath,
            diagnosticsLogPath: diagnosticsLogPath,
            onStatusMessage: { [weak self] message in
                self?.addStatusMessage(message)
            }
        )
        
        // Result contains action and orderID
        // The dialog has already handled the actions internally
    }
    
    func getStatusAndResultsLog() -> String {
        var log = "OPENTERFACE DIAGNOSTICS - STATUS AND RESULTS LOG\n"
        log += "=".repeated(50) + "\n"
        log += "Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))\n"
        log += "\n"
        
        // Add System Information section
        log += "SYSTEM INFORMATION:\n"
        log += "-".repeated(50) + "\n"
        log += getSystemInformationLog()
        log += "\n"
        
        log += "TEST RESULTS:\n"
        log += "-".repeated(50) + "\n"
        for step in DiagnosticTestStep.allCases {
            let result = stepResults[step] ?? false
            let status = result ? "✅ PASSED" : "❌ FAILED"
            log += "\(step.title): \(status)\n"
        }
        
        log += "\n"
        log += "STATUS MESSAGES:\n"
        log += "-".repeated(50) + "\n"
        for message in statusMessages {
            log += message + "\n"
        }
        
        log += "\n"
        log += "DEFECT DETECTION:\n"
        log += "-".repeated(50) + "\n"
        log += isDefectiveUnitDetected ? "⚠️ DEFECTIVE UNIT DETECTED\n" : "✅ No defects detected\n"
        
        return log
    }
    
    private func getSystemInformationLog() -> String {
        var info = ""
        
        // App Version
        info += "App Version: \(getAppVersion())\n"
        
        // macOS Version
        info += "macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        
        // Control Chip
        info += "Control Chip: \(getControlChipsetDisplayName())\n"
        
        // Video Chip
        info += "Video Chip: \(getVideoChipsetDisplayName())\n"
        
        // USB Hub Structure
        info += "\nUSB Hub Structure:\n"
        info += getUSBHubStructureLog()
        
        return info
    }
    
    private func getControlChipsetDisplayName() -> String {
        switch AppStatus.controlChipsetType {
        case .ch9329:
            return "CH9329 ✅"
        case .ch32v208:
            return "CH32V208 ✅"
        case .unknown:
            return "Unknown ⚠️"
        }
    }
    
    private func getVideoChipsetDisplayName() -> String {
        switch AppStatus.videoChipsetType {
        case .ms2109:
            return "MS2109 ✅"
        case .ms2109s:
            return "MS2109S ✅"
        case .ms2130s:
            return "MS2130S ✅"
        case .unknown:
            return "Unknown ⚠️"
        }
    }
    
    private func getUSBHubStructureLog() -> String {
        var usbLog = ""
        
        // Only show video and control chip devices
        var deviceList: [(device: USBDeviceInfo, type: String)] = []
        
        if let videoChip = AppStatus.videoChipDevice {
            deviceList.append((device: videoChip, type: "Video Chip"))
        }
        
        if let controlChip = AppStatus.controlChipDevice {
            deviceList.append((device: controlChip, type: "Control Chip"))
        }
        
        if deviceList.isEmpty {
            usbLog += "  No video or control chips detected\n"
            return usbLog
        }
        
        // Display each chip with location and hub count
        for (index, item) in deviceList.enumerated() {
            let device = item.device
            let chipType = item.type
            let isLast = (index == deviceList.count - 1)
            
            // Calculate device depth (number of hubs from device to root)
            let deviceDepth = countHubsToRoot(locationID: device.locationID)
            
            usbLog += "  \(isLast ? "└── " : "├── ")[\(chipType)] Device Info:\n"
            usbLog += "       Manufacturer: \(device.manufacturer)\n"
            usbLog += "       VID: \(String(format: "%04X", device.vendorID)), PID: \(String(format: "%04X", device.productID))\n"
            usbLog += "       Location ID: \(device.locationID)\n"
            usbLog += "       Device Depth: \(deviceDepth)\n"
            
            // Warning if device depth is greater than 2
            if deviceDepth > 2 {
                usbLog += "       ⚠️ WARNING: Device depth > 2 detected!\n"
                usbLog += "       An external USB hub is likely present between the device and computer.\n"
                usbLog += "       Please ensure the USB hub has external power, or tests may fail.\n"
            }
            
            usbLog += "       Speed: \(device.speed)\n"
            usbLog += "\n"
        }
        
        return usbLog
    }
    
    private func countHubsToRoot(locationID: String) -> Int {
        // Extract port numbers from location ID
        guard let ports = extractPortsFromLocationID(locationID) else {
            return 0
        }
        
        // The number of hubs is the number of port levels minus 1 (the last level is the device itself)
        // ports.count - 1 gives us the number of intermediate hubs
        return max(0, ports.count - 1)
    }
    
    private func buildUSBHierarchy(from locationID: String, allDevices: [USBDeviceInfo], chipType: String) -> [String] {
        var hierarchy: [String] = []
        
        // Parse the location ID to extract the port path
        // Location ID format: 0xAABBCCDD where each byte represents a port in the hierarchy
        guard locationID.hasPrefix("0x"), locationID.count >= 10 else {
            hierarchy.append("Root")
            return hierarchy
        }
        
        let hexString = String(locationID.dropFirst(2)) // Remove "0x"
        var bytes: [UInt8] = []
        
        // First, extract all bytes
        for i in stride(from: 0, to: hexString.count, by: 2) {
            let startIndex = hexString.index(hexString.startIndex, offsetBy: i)
            let endIndex = hexString.index(startIndex, offsetBy: 2)
            let byteString = String(hexString[startIndex..<endIndex])
            if let byte = UInt8(byteString, radix: 16) {
                if byte != 0 {
                    bytes.append(byte)
                }
            }
        }
        
        // Now extract port numbers: upper nibble from all bytes, lower nibble only from last byte
        var ports: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            let upperNibble = byte >> 4
            let lowerNibble = byte & 0x0F
            
            // Always add upper nibble
            ports.append(upperNibble)
            
            // Only add lower nibble from the LAST non-zero byte, and only if non-zero
            if index == bytes.count - 1 && lowerNibble != 0 {
                ports.append(lowerNibble)
            }
        }
        
        logger.log(content: "[USB Hierarchy] Building for \(chipType) at location \(locationID)")
        logger.log(content: "[USB Hierarchy] Extracted port numbers from \(hexString): \(ports)")
        
        // Build hierarchy showing Root -> Hub at Port X -> Hub at Port Y -> Device
        hierarchy.append("Root Hub")
        
        // For each port in the hierarchy, find matching hub or device
        for (portIndex, portNumber) in ports.enumerated() {
            let portString = "Port \(portNumber)"
            
            if portIndex < ports.count - 1 {
                // Build the hub port path - all ports up to and including this one
                let hubPortNumbers = Array(ports[0...portIndex])
                logger.log(content: "   🔎 Looking for hub at port numbers: \(hubPortNumbers)")
                
                var hubInfo = "Intermediate Hub"
                var hubFound = false
                var isOpenterfaceHub = false
                
                // Debug: list all devices and their extracted ports
                logger.log(content: "   Checking \(allDevices.count) devices:")
                for device in allDevices {
                    if let devicePortNumbers = extractPortsFromLocationID(device.locationID) {
                        let vid = String(format: "%04X", device.vendorID)
                        let pid = String(format: "%04X", device.productID)
                        logger.log(content: "      Device: \(device.manufacturer) (VID: \(vid), PID: \(pid)) at \(device.locationID) -> ports: \(devicePortNumbers)")
                        
                        // Check if device's port number path matches what we're looking for
                        let devicePrefix = Array(devicePortNumbers.prefix(hubPortNumbers.count))
                        if devicePrefix == hubPortNumbers {
                            hubFound = true
                            let vidStr = String(format: "%04X", device.vendorID)
                            let pidStr = String(format: "%04X", device.productID)
                            hubInfo = "\(device.manufacturer) (VID: \(vidStr), PID: \(pidStr))"
                            logger.log(content: "      [MATCH FOUND] port numbers: \(devicePrefix) == \(hubPortNumbers)")
                            
                            // Check if this hub is actually the Openterface hub
                            if device.vendorID == 0x1A40 && device.productID == 0x0101 {
                                isOpenterfaceHub = true
                                logger.log(content: "      [OPENTERFACE DETECTED] This is Openterface Hub: \(hubInfo)")
                            } else {
                                logger.log(content: "      [MATCH] Found hub: \(hubInfo)")
                            }
                            break
                        } else {
                            let devicePrefix = Array(devicePortNumbers.prefix(hubPortNumbers.count))
                            logger.log(content: "      [NO MATCH] port numbers: \(devicePrefix) != \(hubPortNumbers)")
                        }
                    }
                }
                
                if isOpenterfaceHub {
                    hierarchy.append("└─ \(portString) ([OPENTERFACE] \(hubInfo))")
                    logger.log(content: "   └─ \(portString): [OPENTERFACE] \(hubInfo)")
                } else if hubFound {
                    hierarchy.append("└─ \(portString) (\(hubInfo))")
                    logger.log(content: "   └─ \(portString): \(hubInfo)")
                } else {
                    hierarchy.append("└─ \(portString) (\(hubInfo) [NOT DETECTED])")
                    logger.log(content: "   └─ \(portString): [NOT DETECTED] - \(hubInfo)")
                }
                
                // Only show child devices for the LAST hub in the chain (immediate parent of target device)
                let isLastHub = (portIndex == ports.count - 2)
                if hubFound && isLastHub {
                    logger.log(content: "   Looking for devices connected to this hub...")
                    var childDevicesFound: [(device: USBDeviceInfo, portNumber: UInt8)] = []
                    
                    for device in allDevices {
                        if let devicePortNumbers = extractPortsFromLocationID(device.locationID) {
                            // A device is a child of this hub if:
                            // 1. It has exactly one more port level than the hub
                            // 2. Its port prefix matches the hub's port path
                            if devicePortNumbers.count == hubPortNumbers.count + 1 {
                                let devicePrefix = Array(devicePortNumbers.prefix(hubPortNumbers.count))
                                if devicePrefix == hubPortNumbers {
                                    let childPortNumber = devicePortNumbers[hubPortNumbers.count]
                                    childDevicesFound.append((device: device, portNumber: childPortNumber))
                                }
                            }
                        }
                    }
                    
                    // Display each child device
                    for child in childDevicesFound {
                        let childPortString = "  └─ Port \(child.portNumber)"
                        
                        let vid = String(format: "%04X", child.device.vendorID)
                        let pid = String(format: "%04X", child.device.productID)
                        let childInfo = "\(child.device.manufacturer) (VID: \(vid), PID: \(pid))"
                        
                        hierarchy.append("\(childPortString) (\(childInfo))")
                        logger.log(content: "      \(childPortString): \(childInfo)")
                    }
                }
            }
        }
        
        // If no ports found, just show root
        if ports.isEmpty {
            hierarchy.append("(Direct connection to Root)")
        }
        
        return hierarchy
    }
    
    private func isHubAtPathOpenterface(ports: [UInt8], allDevices: [USBDeviceInfo]) -> Bool {
        // Look for any device with the Openterface Hub VID/PID
        for device in allDevices {
            if device.vendorID == 0x1A40 && device.productID == 0x0101 {
                // Extract the port path from this hub's location ID
                if let hubPorts = extractPortsFromLocationID(device.locationID) {
                    // Debug: log what we're comparing
                    logger.log(content: "Openterface hub found at location: \(device.locationID), extracted ports: \(hubPorts), comparing with: \(ports)")
                    
                    // Check if this is the hub at the exact path (ignore trailing hub indicator byte)
                    // Hub ports might be [2, 18, 32] where 32 (0x20) is a hub indicator
                    // We match if hubPorts minus the last byte equals ports
                    var hubPathPorts = hubPorts
                    if hubPathPorts.count > ports.count && hubPathPorts.last == 32 {
                        // Remove the hub indicator byte
                        hubPathPorts.removeLast()
                    }
                    
                    if hubPathPorts == ports {
                        logger.log(content: "✅ Openterface Hub Match found!")
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    private func extractPortsFromLocationID(_ locationID: String) -> [UInt8]? {
        guard locationID.hasPrefix("0x"), locationID.count >= 10 else {
            return nil
        }
        
        let hexString = String(locationID.dropFirst(2)) // Remove "0x"
        var bytes: [UInt8] = []
        
        // First, extract all non-zero bytes
        for i in stride(from: 0, to: min(hexString.count, 8), by: 2) {
            let startIndex = hexString.index(hexString.startIndex, offsetBy: i)
            let endIndex = hexString.index(startIndex, offsetBy: 2)
            let byteString = String(hexString[startIndex..<endIndex])
            if let byte = UInt8(byteString, radix: 16) {
                if byte != 0 {
                    bytes.append(byte)
                }
            }
        }
        
        // Now extract port numbers: upper nibble from all bytes, lower nibble only from last byte
        var ports: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            let upperNibble = byte >> 4
            let lowerNibble = byte & 0x0F
            
            // Always add upper nibble
            ports.append(upperNibble)
            
            // Only add lower nibble from the LAST non-zero byte, and only if non-zero
            if index == bytes.count - 1 && lowerNibble != 0 {
                ports.append(lowerNibble)
            }
        }
        
        return ports.isEmpty ? nil : ports
    }
    
    private func buildLocationIDForPath(ports: [UInt8]) -> String {
        // USB location IDs are 4 bytes: 0xAABBCCDD
        // Each port in the hierarchy gets its own byte position
        // The byte after the last port should be 0x10 to indicate the hub itself
        var locationID = [UInt8](repeating: 0, count: 4)
        for (index, port) in ports.enumerated() {
            if index < 4 {
                locationID[index] = port
            }
        }
        // Set the next position to 0x10 to indicate this is the hub (not a device under it)
        if ports.count < 4 {
            locationID[ports.count] = 0x10
        }
        return String(format: "0x%02X%02X%02X%02X", locationID[0], locationID[1], locationID[2], locationID[3])
    }
    
    private func getApplicationLogContent() -> String {
        let fileManager = FileManager.default
        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logFilePath = documentsDirectory.appendingPathComponent(AppStatus.logFileName)
            
            if fileManager.fileExists(atPath: logFilePath.path) {
                do {
                    let logContent = try String(contentsOfFile: logFilePath.path, encoding: String.Encoding.utf8)
                    return logContent
                } catch {
                    return "Unable to read log file: \(error.localizedDescription)"
                }
            } else {
                return "Log file does not exist yet"
            }
        }
        return "Unable to access documents directory"
    }
    
    private func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (Build \(build))"
    }

}

extension String {
    func repeated(_ count: Int) -> String {
        return String(repeating: self, count: count)
    }
}
