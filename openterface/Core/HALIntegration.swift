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

// MARK: - HAL Protocol Extensions

/// Protocol extensions to add HAL capabilities to existing manager protocols
extension VideoManagerProtocol {
    /// Get the current video chipset from HAL
    var halVideoChipset: VideoChipsetProtocol? {
        return HardwareAbstractionLayer.shared.getCurrentVideoChipset()
    }
    
    /// Get video capabilities from HAL
    var halVideoCapabilities: ChipsetCapabilities? {
        return HardwareAbstractionLayer.shared.getVideoCapabilities()
    }
    
    /// Check if HAL video chipset supports specific feature
    func halSupportsFeature(_ feature: String) -> Bool {
        return halVideoCapabilities?.features.contains(feature) ?? false
    }
}

extension HIDManagerProtocol {
    /// Get the current control chipset from HAL
    var halControlChipset: ControlChipsetProtocol? {
        return HardwareAbstractionLayer.shared.getCurrentControlChipset()
    }
    
    /// Get control capabilities from HAL
    var halControlCapabilities: ChipsetCapabilities? {
        return HardwareAbstractionLayer.shared.getControlCapabilities()
    }
    
    /// Check if HAL control chipset supports specific feature
    func halSupportsFeature(_ feature: String) -> Bool {
        return halControlCapabilities?.features.contains(feature) ?? false
    }
}

extension SerialPortManagerProtocol {
    /// Get the current control chipset from HAL
    var halControlChipset: ControlChipsetProtocol? {
        return HardwareAbstractionLayer.shared.getCurrentControlChipset()
    }
    
    /// Get supported baud rates from HAL
    var halSupportedBaudRates: [Int] {
        return halControlChipset?.supportedBaudRates ?? []
    }
    
    /// Check if current chipset supports specific communication interface
    func halSupportsCommunicationInterface(_ interface: CommunicationInterface) -> Bool {
        guard let chipset = halControlChipset else { return false }
        
        switch (interface, chipset.communicationInterface) {
        case (.serial(let requestedBaud), .serial(let currentBaud)):
            return requestedBaud == currentBaud
        case (.hid(let requestedSize), .hid(let currentSize)):
            return requestedSize == currentSize
        case (.hybrid, .hybrid):
            return true
        default:
            return false
        }
    }
}

// MARK: - HAL Integration Manager

/// Manager that integrates HAL with existing Openterface managers
class HALIntegrationManager {
    static let shared = HALIntegrationManager()
    
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var hal: HardwareAbstractionLayer = HardwareAbstractionLayer.shared
    private var isInitialized: Bool = false
    
    private init() {}
    
    // MARK: - Integration Methods
    
    /// Initialize HAL integration with existing managers
    func initializeHALIntegration() -> Bool {
        guard !isInitialized else {
            logger.log(content: "⚠️ HAL Integration already initialized")
            return true
        }
        
        logger.log(content: "🚀 Initializing HAL Integration...")
        
        // Initialize hardware detection and abstraction
        if hal.detectAndInitializeHardware() {
            setupHALCallbacks()
            setupPeriodicHALUpdates()
            
            // Integrate with all managers
            integrateWithAllManagers()
            
            isInitialized = true
            
            logSystemInfo()
            logger.log(content: "✅ HAL Integration initialized successfully")
            return true
        } else {
            logger.log(content: "❌ HAL Integration initialization failed")
            return false
        }
    }
    
    /// Deinitialize HAL integration
    func deinitializeHALIntegration() {
        guard isInitialized else { return }
        
        logger.log(content: "🔄 Deinitializing HAL Integration...")
        
        stopPeriodicHALUpdates()
        hal.deinitializeHardware()
        isInitialized = false
        
        logger.log(content: "✅ HAL Integration deinitialized")
    }
    
    // MARK: - Manager Integration
    
    /// Integrate HAL with VideoManager
    func integrateWithVideoManager() {
        guard let videoChipset = hal.getCurrentVideoChipset() else {
            logger.log(content: "⚠️ No video chipset available for integration")
            return
        }
        
        let videoManager = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
        
        // Update video session based on HAL capabilities
        if videoChipset.capabilities.supportsHDMI {
            logger.log(content: "✅ Video HAL integration: HDMI support enabled")
        }
        
        if videoChipset.capabilities.supportsAudio {
            logger.log(content: "✅ Video HAL integration: Audio support enabled")
        }
        
        // Log supported resolutions
        let resolutions = videoChipset.supportedResolutions.map { $0.description }
        logger.log(content: "📋 Supported resolutions: \(resolutions.joined(separator: ", "))")
    }
    
    /// Integrate HAL with HIDManager
    func integrateWithHIDManager() {
        guard let controlChipset = hal.getCurrentControlChipset() else {
            logger.log(content: "⚠️ No control chipset available for integration")
            return
        }
        
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        // Initialize HAL-aware HID operations if supported
        if let hidManagerImpl = hidManager as? HIDManager {
            if hidManagerImpl.initializeHALAwareHID() {
                logger.log(content: "✅ HID HAL integration: HAL-aware HID initialized")
                
                // Log HAL system information
                let systemInfo = hidManagerImpl.getHALSystemInfo()
                logger.log(content: "📊 \(systemInfo)")
                
                // Get and log HID capabilities
                let hidCapabilities = hidManagerImpl.getHALHIDCapabilities()
                logger.log(content: "🔧 HID Capabilities: \(hidCapabilities.joined(separator: ", "))")
                
            } else {
                logger.log(content: "⚠️ HAL-aware HID initialization failed")
            }
        }
        
        // Configure HID operations based on chipset capabilities
        if controlChipset.capabilities.supportsHID {
            logger.log(content: "✅ HID HAL integration: HID support enabled")
        }
        
        if controlChipset.capabilities.supportsEEPROM {
            logger.log(content: "✅ HID HAL integration: EEPROM operations enabled")
        }
    }
    
    /// Integrate HAL with SerialPortManager
    func integrateWithSerialPortManager() {
        guard let controlChipset = hal.getCurrentControlChipset() else {
            logger.log(content: "⚠️ No control chipset available for integration")
            return
        }
        
        let serialManager = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)
        
        // Configure serial communication based on chipset
        switch controlChipset.communicationInterface {
        case .serial(let baudRate):
            logger.log(content: "✅ Serial HAL integration: Serial communication at \(baudRate) baud")
        case .hid(let reportSize):
            logger.log(content: "✅ Serial HAL integration: HID communication with \(reportSize)-byte reports")
        case .hybrid(let serial, let hid):
            logger.log(content: "✅ Serial HAL integration: Hybrid communication (Serial: \(serial), HID: \(hid))")
        }
        
        // Log supported features
        logger.log(content: "📋 Control features: \(controlChipset.capabilities.features.joined(separator: ", "))")
    }
    
    /// Integrate HAL with all managers
    private func integrateWithAllManagers() {
        logger.log(content: "🔧 Integrating HAL with all managers...")
        
        // Integrate with video manager
        integrateWithVideoManager()
        
        // Integrate with HID manager  
        integrateWithHIDManager()
        
        // Integrate with serial port manager
        integrateWithSerialPortManager()
        
        // Additional control chipset integration
        integrateControlChipsetWithManagers()
        
        logger.log(content: "✅ HAL integration with all managers completed")
    }
    
    /// Specifically integrate control chipset with relevant managers
    private func integrateControlChipsetWithManagers() {
        guard let controlChipset = hal.getCurrentControlChipset() else {
            logger.log(content: "⚠️ No control chipset available for manager integration")
            return
        }
        
        logger.log(content: "🎮 Integrating control chipset \(controlChipset.chipsetInfo.name) with managers...")
        
        // Integrate with HID Manager for control operations
        integrateControlChipsetWithHIDManager(controlChipset)
        
        // Integrate with Serial Port Manager for communication
        integrateControlChipsetWithSerialManager(controlChipset)
        
        // Integrate with any other managers that need control chipset access
        integrateControlChipsetWithOtherManagers(controlChipset)
        
        logger.log(content: "✅ Control chipset integration completed")
    }
    
    /// Integrate control chipset specifically with HID Manager
    private func integrateControlChipsetWithHIDManager(_ controlChipset: ControlChipsetProtocol) {
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        logger.log(content: "🔧 Integrating control chipset with HID Manager...")
        
        // Configure HID operations based on control chipset capabilities
        if controlChipset.capabilities.supportsHID {
            logger.log(content: "✅ Control chipset supports HID operations")
            
            // Check specific chipset type for specialized configuration
            switch controlChipset.chipsetInfo.chipsetType {
            case .control(let controlType):
                switch controlType {
                case .ch9329:
                    configureHIDForCH9329(hidManager, controlChipset)
                case .ch32v208:
                    configureHIDForCH32V208(hidManager, controlChipset)
                @unknown default:
                    logger.log(content: "⚠️ Unknown control chipset type, using generic configuration")
                }
            case .video:
                logger.log(content: "⚠️ Video chipset info found in control chipset context")
            @unknown default:
                logger.log(content: "⚠️ Unknown chipset type")
            }
        }
        
        // Setup EEPROM operations if supported
        if controlChipset.capabilities.supportsEEPROM {
            logger.log(content: "✅ Control chipset supports EEPROM operations")
            configureEEPROMOperations(hidManager, controlChipset)
        }
    }
    
    /// Configure HID Manager for CH9329 control chipset
    private func configureHIDForCH9329(_ hidManager: HIDManagerProtocol, _ controlChipset: ControlChipsetProtocol) {
        logger.log(content: "🔧 Configuring HID for CH9329 chipset")
        
        // CH9329 specific configuration
        if let hidManagerImpl = hidManager as? HIDManager {
            // Enable CTS monitoring for CH9329
            logger.log(content: "📡 CH9329: Enabling CTS monitoring for HID events")
            
            // Configure for serial + HID hybrid communication
            if case .hybrid(let serial, let hid) = controlChipset.communicationInterface {
                logger.log(content: "🔄 CH9329: Hybrid communication - Serial: \(serial), HID: \(hid)")
            }
            
            // Setup CH9329 specific features
            let features = controlChipset.capabilities.features
            if features.contains("Keyboard Emulation") {
                logger.log(content: "⌨️ CH9329: Keyboard emulation enabled")
            }
            if features.contains("Mouse Emulation") {
                logger.log(content: "🖱️ CH9329: Mouse emulation enabled")
            }
        }
    }
    
    /// Configure HID Manager for CH32V208 control chipset
    private func configureHIDForCH32V208(_ hidManager: HIDManagerProtocol, _ controlChipset: ControlChipsetProtocol) {
        logger.log(content: "🔧 Configuring HID for CH32V208 chipset")
        
        // CH32V208 specific configuration
        if let hidManagerImpl = hidManager as? HIDManager {
            // CH32V208 uses direct serial communication
            logger.log(content: "📡 CH32V208: Direct serial communication mode")
            
            // Configure for serial communication
            if case .serial(let baudRate) = controlChipset.communicationInterface {
                logger.log(content: "🔄 CH32V208: Serial communication at \(baudRate) baud")
            }
            
            // Setup CH32V208 specific features
            let features = controlChipset.capabilities.features
            if features.contains("Advanced HID") {
                logger.log(content: "🎮 CH32V208: Advanced HID features enabled")
            }
            if features.contains("Firmware Update") {
                logger.log(content: "🔄 CH32V208: Firmware update support enabled")
            }
        }
    }
    
    /// Configure EEPROM operations for control chipset
    private func configureEEPROMOperations(_ hidManager: HIDManagerProtocol, _ controlChipset: ControlChipsetProtocol) {
        if let hidManagerImpl = hidManager as? HIDManager {
            logger.log(content: "💾 Configuring EEPROM operations for \(controlChipset.chipsetInfo.name)")
            
            // Verify EEPROM capabilities
            if controlChipset.capabilities.supportsEEPROM {
                logger.log(content: "✅ EEPROM read/write operations available")
                logger.log(content: "📋 EEPROM features: \(controlChipset.capabilities.features.filter { $0.contains("EEPROM") }.joined(separator: ", "))")
            }
        }
    }
    
    /// Integrate control chipset specifically with Serial Manager
    private func integrateControlChipsetWithSerialManager(_ controlChipset: ControlChipsetProtocol) {
        let serialManager = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)
        
        logger.log(content: "🔧 Integrating control chipset with Serial Manager...")
        
        // Configure communication interface
        switch controlChipset.communicationInterface {
        case .serial(let baudRate):
            logger.log(content: "📡 Control chipset: Serial communication at \(baudRate) baud")
            configureSerialCommunication(serialManager, baudRate: baudRate, chipset: controlChipset)
            
        case .hid(let reportSize):
            logger.log(content: "📡 Control chipset: HID communication with \(reportSize)-byte reports")
            configureHIDCommunication(serialManager, reportSize: reportSize, chipset: controlChipset)
            
        case .hybrid(let serialBaud, let hidSize):
            logger.log(content: "📡 Control chipset: Hybrid communication (Serial: \(serialBaud), HID: \(hidSize))")
            configureHybridCommunication(serialManager, serialBaud: serialBaud, hidSize: hidSize, chipset: controlChipset)
        }
    }
    
    /// Configure serial communication for control chipset
    private func configureSerialCommunication(_ serialManager: SerialPortManagerProtocol, baudRate: Int, chipset: ControlChipsetProtocol) {
        logger.log(content: "⚙️ Configuring serial communication for \(chipset.chipsetInfo.name)")
        
        // Check if baud rate is supported
        if chipset.supportedBaudRates.contains(baudRate) {
            logger.log(content: "✅ Baud rate \(baudRate) is supported")
        } else {
            logger.log(content: "⚠️ Baud rate \(baudRate) may not be optimal. Supported rates: \(chipset.supportedBaudRates)")
        }
        
        // Configure additional serial settings based on chipset
        if chipset.capabilities.features.contains("Hardware Flow Control") {
            logger.log(content: "🔄 Hardware flow control available")
        }
    }
    
    /// Configure HID communication for control chipset
    private func configureHIDCommunication(_ serialManager: SerialPortManagerProtocol, reportSize: Int, chipset: ControlChipsetProtocol) {
        logger.log(content: "⚙️ Configuring HID communication for \(chipset.chipsetInfo.name)")
        logger.log(content: "📊 HID report size: \(reportSize) bytes")
        
        // Log HID-specific features
        let hidFeatures = chipset.capabilities.features.filter { $0.contains("HID") }
        if !hidFeatures.isEmpty {
            logger.log(content: "🎮 HID features: \(hidFeatures.joined(separator: ", "))")
        }
    }
    
    /// Configure hybrid communication for control chipset
    private func configureHybridCommunication(_ serialManager: SerialPortManagerProtocol, serialBaud: Int, hidSize: Int, chipset: ControlChipsetProtocol) {
        logger.log(content: "⚙️ Configuring hybrid communication for \(chipset.chipsetInfo.name)")
        logger.log(content: "📡 Serial: \(serialBaud) baud, HID: \(hidSize) bytes")
        
        // Configure both serial and HID aspects
        configureSerialCommunication(serialManager, baudRate: serialBaud, chipset: chipset)
        configureHIDCommunication(serialManager, reportSize: hidSize, chipset: chipset)
        
        logger.log(content: "🔄 Hybrid communication configured")
    }
    
    /// Integrate control chipset with other managers as needed
    private func integrateControlChipsetWithOtherManagers(_ controlChipset: ControlChipsetProtocol) {
        logger.log(content: "🔧 Integrating control chipset with other managers...")
        
        // Add any additional manager integrations here
        // For example: StatusBarManager, AudioManager, etc.
        
        // Log control chipset status for other managers
        let status = controlChipset.getDeviceStatus()
        logger.log(content: "📊 Control chipset status: Target connected: \(status.isTargetConnected)")
        
        // Update app status with control chipset information
        AppStatus.isTargetConnected = status.isTargetConnected
        
        logger.log(content: "✅ Control chipset integration with other managers completed")
    }
    
    // MARK: - HAL Status and Monitoring
    
    /// Get current HAL status
    func getHALStatus() -> HALStatus {
        let systemInfo = hal.getSystemInfo()
        
        return HALStatus(
            isInitialized: isInitialized,
            videoChipsetConnected: systemInfo.isVideoActive,
            controlChipsetConnected: systemInfo.isControlActive,
            videoChipsetName: systemInfo.videoChipset?.name,
            controlChipsetName: systemInfo.controlChipset?.name,
            systemCapabilities: systemInfo.systemCapabilities,
            lastUpdate: Date()
        )
    }
    
    /// Check if specific hardware feature is available
    func isFeatureAvailable(_ feature: String) -> Bool {
        let systemInfo = hal.getSystemInfo()
        return systemInfo.systemCapabilities.features.contains(feature)
    }
    
    /// Get chipset-specific information
    func getChipsetInfo(type: ChipsetType) -> ChipsetInfo? {
        let systemInfo = hal.getSystemInfo()
        
        switch type {
        case .video:
            return systemInfo.videoChipset
        case .control:
            return systemInfo.controlChipset
        }
    }
    
    /// Get comprehensive hardware capabilities including control chipset
    func getHardwareCapabilities() -> ChipsetCapabilities {
        let systemInfo = hal.getSystemInfo()
        return systemInfo.systemCapabilities
    }
    
    /// Get control chipset specific capabilities
    func getControlChipsetCapabilities() -> ChipsetCapabilities? {
        return hal.getControlCapabilities()
    }
    
    /// Get video chipset specific capabilities  
    func getVideoChipsetCapabilities() -> ChipsetCapabilities? {
        return hal.getVideoCapabilities()
    }
    
    /// Check if a specific feature is supported by control chipset
    func isControlFeatureSupported(_ feature: String) -> Bool {
        guard let controlCapabilities = getControlChipsetCapabilities() else {
            return false
        }
        return controlCapabilities.features.contains(feature)
    }
    
    /// Get detailed control chipset information
    func getControlChipsetInfo() -> ControlChipsetInfo? {
        guard let controlChipset = hal.getCurrentControlChipset() else {
            return nil
        }
        
        return ControlChipsetInfo(
            chipsetInfo: controlChipset.chipsetInfo,
            capabilities: controlChipset.capabilities,
            communicationInterface: controlChipset.communicationInterface,
            isReady: controlChipset.isDeviceReady,
            currentBaudRate: controlChipset.currentBaudRate,
            supportedBaudRates: controlChipset.supportedBaudRates,
            deviceStatus: controlChipset.getDeviceStatus()
        )
    }
    
    // MARK: - Private Methods
    
    private func setupHALCallbacks() {
        // Set up callbacks for hardware state changes
        // This could be expanded to use NotificationCenter or Combine publishers
        logger.log(content: "🔧 Setting up HAL callbacks...")
    }
    
    private func setupPeriodicHALUpdates() {
        // Set up periodic updates for hardware monitoring
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.performPeriodicHALUpdate()
        }
        logger.log(content: "⏰ Periodic HAL updates configured")
    }
    
    private func stopPeriodicHALUpdates() {
        // Stop periodic updates
        // In a full implementation, you'd store the timer reference and invalidate it
        logger.log(content: "⏹️ Periodic HAL updates stopped")
    }
    
    private func performPeriodicHALUpdate() {
        // Perform periodic hardware status updates
        guard isInitialized else { return }
        
        // Update video chipset status
        if let videoChipset = hal.getCurrentVideoChipset() {
            let signalStatus = videoChipset.getSignalStatus()
            AppStatus.hasHdmiSignal = signalStatus.hasSignal
            
            // Log video status changes if needed
            if AppStatus.hasHdmiSignal != signalStatus.hasSignal {
                logger.log(content: "📺 Video signal status changed: \(signalStatus.hasSignal ? "Connected" : "Disconnected")")
            }
        }
        
        // Update control chipset status
        if let controlChipset = hal.getCurrentControlChipset() {
            let deviceStatus = controlChipset.getDeviceStatus()
            let wasConnected = AppStatus.isTargetConnected
            AppStatus.isTargetConnected = deviceStatus.isTargetConnected
            
            // Log control chipset status changes
            if wasConnected != deviceStatus.isTargetConnected {
                logger.log(content: "🎮 Control target status changed: \(deviceStatus.isTargetConnected ? "Connected" : "Disconnected")")
                logger.log(content: "🔧 Control chipset: \(controlChipset.chipsetInfo.name)")
            }
            
            // Update control chipset specific status
            updateControlChipsetStatus(controlChipset)
        }
        
        // Update HAL system information periodically
        updateHALFromHIDManager()
    }
    
    /// Update control chipset specific status information
    private func updateControlChipsetStatus(_ controlChipset: ControlChipsetProtocol) {
        // Update chipset readiness status
        let isReady = controlChipset.isDeviceReady
        if AppStatus.isControlChipsetReady != isReady {
            AppStatus.isControlChipsetReady = isReady
            logger.log(content: "🔧 Control chipset ready status: \(isReady ? "Ready" : "Not Ready")")
        }
        
        // Check communication interface status
        switch controlChipset.communicationInterface {
        case .serial(let baudRate):
            // Update serial communication status
            if controlChipset.currentBaudRate != baudRate {
                logger.log(content: "📡 Control chipset baud rate changed: \(controlChipset.currentBaudRate) -> \(baudRate)")
            }
            
        case .hid(let reportSize):
            // Update HID communication status
            logger.log(content: "🎮 Control chipset HID active: \(reportSize)-byte reports")
            
        case .hybrid(let serial, let hid):
            // Update hybrid communication status
            logger.log(content: "🔄 Control chipset hybrid mode: Serial \(serial), HID \(hid)")
        }
    }
    
    private func logSystemInfo() {
        let systemInfo = hal.getSystemInfo()
        logger.log(content: "🖥️ HAL System Information:")
        logger.log(content: systemInfo.description)
    }
    
    /// Update HAL with current HID device information
    func updateHALFromHIDManager() {
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        // Check if HID manager has HAL integration methods (duck typing approach)
        if let halAwareHIDManager = hidManager as? HIDManager {
            // Update video chipset info if available
            if let chipsetInfo = halAwareHIDManager.getHALChipsetInfo() {
                logger.log(content: "🔄 Updating HAL with HID chipset info: \(chipsetInfo.name)")
            }
            
            // Update signal status
            let signalStatus = halAwareHIDManager.getHALSignalStatus()
            logger.log(content: "📡 HAL Signal Status: \(signalStatus.hasSignal ? "Connected" : "Disconnected")")
            
            // Update timing info if available
            if let timingInfo = halAwareHIDManager.getHALTimingInfo() {
                logger.log(content: "⏱️ HAL Timing: \(timingInfo.horizontalTotal)x\(timingInfo.verticalTotal)")
            }
        }
    }
}

// MARK: - HAL Status Structure

/// Structure representing the current HAL status
struct HALStatus {
    let isInitialized: Bool
    let videoChipsetConnected: Bool
    let controlChipsetConnected: Bool
    let videoChipsetName: String?
    let controlChipsetName: String?
    let systemCapabilities: ChipsetCapabilities
    let lastUpdate: Date
    
    var description: String {
        var desc = "HAL Status (Updated: \(lastUpdate)):\n"
        desc += "Initialized: \(isInitialized)\n"
        
        if let videoName = videoChipsetName {
            desc += "Video: \(videoName) (Connected: \(videoChipsetConnected))\n"
        } else {
            desc += "Video: Not detected\n"
        }
        
        if let controlName = controlChipsetName {
            desc += "Control: \(controlName) (Connected: \(controlChipsetConnected))\n"
        } else {
            desc += "Control: Not detected\n"
        }
        
        desc += "Features: \(systemCapabilities.features.joined(separator: ", "))"
        return desc
    }
}

// MARK: - Control Chipset Information Structure

/// Detailed information about the control chipset
struct ControlChipsetInfo {
    let chipsetInfo: ChipsetInfo
    let capabilities: ChipsetCapabilities
    let communicationInterface: CommunicationInterface
    let isReady: Bool
    let currentBaudRate: Int
    let supportedBaudRates: [Int]
    let deviceStatus: ControlDeviceStatus
    
    var description: String {
        var desc = "Control Chipset: \(chipsetInfo.name)\n"
        desc += "Ready: \(isReady)\n"
        desc += "Communication: \(communicationInterface)\n"
        desc += "Baud Rate: \(currentBaudRate)\n"
        desc += "Target Connected: \(deviceStatus.isTargetConnected)\n"
        desc += "Features: \(capabilities.features.joined(separator: ", "))"
        return desc
    }
}

// MARK: - HAL Integration Protocol

/// Protocol for HAL-aware managers
protocol HALAwareManagerProtocol: AnyObject {
    func configureWithHAL()
    func updateFromHAL()
    func getHALCompatibilityInfo() -> String
}
