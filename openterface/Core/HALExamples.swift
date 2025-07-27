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

/// Example usage and demonstration of the Hardware Abstraction Layer
class HALUsageExamples {
    
    private let hal = HardwareAbstractionLayer.shared
    private let halIntegration = HALIntegrationManager.shared
    private let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    // MARK: - Basic HAL Usage
    
    /// Example: Initialize and check hardware
    func initializeHardwareExample() {
        print("🚀 HAL Usage Example: Hardware Initialization")
        
        // Initialize the HAL
        if hal.detectAndInitializeHardware() {
            print("✅ Hardware detected and initialized successfully")
            
            // Get system information
            let systemInfo = hal.getSystemInfo()
            print("📊 System Info:")
            print(systemInfo.description)
            
        } else {
            print("❌ No supported hardware detected")
        }
    }
    
    /// Example: Check video capabilities
    func checkVideoCapabilitiesExample() {
        print("\n🎥 HAL Usage Example: Video Capabilities")
        
        if let videoChipset = hal.getCurrentVideoChipset() {
            print("Video Chipset: \(videoChipset.chipsetInfo.name)")
            print("Manufacturer: \(videoChipset.chipsetInfo.manufacturer)")
            
            // Check supported resolutions
            print("Supported Resolutions:")
            for resolution in videoChipset.supportedResolutions {
                print("  - \(resolution.description)")
            }
            
            // Check capabilities
            let caps = videoChipset.capabilities
            print("Capabilities:")
            print("  - HDMI: \(caps.supportsHDMI ? "✅" : "❌")")
            print("  - Audio: \(caps.supportsAudio ? "✅" : "❌")")
            print("  - Firmware Update: \(caps.supportsFirmwareUpdate ? "✅" : "❌")")
            print("  - EEPROM: \(caps.supportsEEPROM ? "✅" : "❌")")
            
            // Get current video status
            let signalStatus = videoChipset.getSignalStatus()
            print("Signal Status:")
            print("  - Has Signal: \(signalStatus.hasSignal ? "✅" : "❌")")
            print("  - Signal Strength: \(signalStatus.signalStrength)")
            print("  - Is Stable: \(signalStatus.isStable ? "✅" : "❌")")
            
        } else {
            print("❌ No video chipset detected")
        }
    }
    
    /// Example: Check control capabilities
    func checkControlCapabilitiesExample() {
        print("\n🎮 HAL Usage Example: Control Capabilities")
        
        if let controlChipset = hal.getCurrentControlChipset() {
            print("Control Chipset: \(controlChipset.chipsetInfo.name)")
            print("Manufacturer: \(controlChipset.chipsetInfo.manufacturer)")
            
            // Check supported baud rates
            print("Supported Baud Rates:")
            for baudRate in controlChipset.supportedBaudRates {
                print("  - \(baudRate)")
            }
            
            // Check communication interface
            switch controlChipset.communicationInterface {
            case .serial(let baudRate):
                print("Communication: Serial (\(baudRate) baud)")
            case .hid(let reportSize):
                print("Communication: HID (\(reportSize)-byte reports)")
            case .hybrid(let serial, let hid):
                print("Communication: Hybrid (Serial: \(serial), HID: \(hid))")
            }
            
            // Check capabilities
            let caps = controlChipset.capabilities
            print("Capabilities:")
            print("  - HID Events: \(caps.supportsHID ? "✅" : "❌")")
            print("  - Firmware Update: \(caps.supportsFirmwareUpdate ? "✅" : "❌")")
            
            // Get device status
            let deviceStatus = controlChipset.getDeviceStatus()
            print("Device Status:")
            print("  - Target Connected: \(deviceStatus.isTargetConnected ? "✅" : "❌")")
            print("  - Keyboard Connected: \(deviceStatus.isKeyboardConnected ? "✅" : "❌")")
            print("  - Mouse Connected: \(deviceStatus.isMouseConnected ? "✅" : "❌")")
            print("  - Num Lock: \(deviceStatus.lockStates.numLock ? "✅" : "❌")")
            print("  - Caps Lock: \(deviceStatus.lockStates.capsLock ? "✅" : "❌")")
            print("  - Scroll Lock: \(deviceStatus.lockStates.scrollLock ? "✅" : "❌")")
            
        } else {
            print("❌ No control chipset detected")
        }
    }
    
    // MARK: - Advanced HAL Usage
    
    /// Example: Chipset-specific operations
    func chipsetSpecificOperationsExample() {
        print("\n🔧 HAL Usage Example: Chipset-Specific Operations")
        
        // Video chipset specific operations
        if let videoChipset = hal.getCurrentVideoChipset() {
            switch videoChipset.chipsetInfo.chipsetType {
            case .video(.ms2109):
                print("🖥️ MS2109 Specific Operations:")
                
                // MS2109 supports timing information
                if let timingInfo = videoChipset.getTimingInfo() {
                    print("  - Horizontal Total: \(timingInfo.horizontalTotal)")
                    print("  - Vertical Total: \(timingInfo.verticalTotal)")
                    print("  - Pixel Clock: \(timingInfo.pixelClock)")
                }
                
                // MS2109 supports pixel clock reading
                if let pixelClock = videoChipset.getPixelClock() {
                    print("  - Current Pixel Clock: \(pixelClock)")
                }
                
            case .video(.ms2130):
                print("🖥️ MS2130 Specific Operations:")
                print("  - Limited HID capabilities")
                print("  - Basic signal detection only")
                
            default:
                print("🖥️ Unknown video chipset type")
            }
        }
        
        // Control chipset specific operations
        if let controlChipset = hal.getCurrentControlChipset() {
            switch controlChipset.chipsetInfo.chipsetType {
            case .control(.ch9329):
                print("🎮 CH9329 Specific Operations:")
                print("  - CTS monitoring for HID events")
                print("  - Baudrate detection and configuration")
                
                if controlChipset.monitorHIDEvents() {
                    print("  - HID event monitoring started")
                }
                
            case .control(.ch32v208):
                print("🎮 CH32V208 Specific Operations:")
                print("  - Direct serial communication")
                print("  - Advanced features available")
                
                if let ch32v208 = controlChipset as? CH32V208ControlChipset {
                    if ch32v208.supportsAdvancedFeatures() {
                        print("  - Advanced features enabled")
                    }
                    
                    let firmwareCapabilities = ch32v208.getFirmwareUpdateCapabilities()
                    print("  - Firmware capabilities: \(firmwareCapabilities.joined(separator: ", "))")
                }
                
            default:
                print("🎮 Unknown control chipset type")
            }
        }
    }
    
    /// Example: Feature availability checking
    func featureAvailabilityExample() {
        print("\n✨ HAL Usage Example: Feature Availability")
        
        let features = [
            "HDMI Input",
            "Audio Capture", 
            "Hardware Scaling",
            "EEPROM Access",
            "Firmware Update",
            "HID Events",
            "CTS Monitoring",
            "Baudrate Detection"
        ]
        
        print("Feature Availability Check:")
        for feature in features {
            let available = halIntegration.isFeatureAvailable(feature)
            print("  - \(feature): \(available ? "✅" : "❌")")
        }
    }
    
    /// Example: HAL integration status
    func halIntegrationStatusExample() {
        print("\n📊 HAL Usage Example: Integration Status")
        
        // Initialize HAL integration
        if halIntegration.initializeHALIntegration() {
            print("✅ HAL Integration initialized")
            
            // Get HAL status
            let status = halIntegration.getHALStatus()
            print("HAL Status:")
            print(status.description)
            
            // Check specific chipset info
            if let videoInfo = halIntegration.getChipsetInfo(type: .video(.ms2109)) {
                print("Video Chipset Details:")
                print("  - Name: \(videoInfo.name)")
                print("  - Vendor: \(videoInfo.manufacturer)")
                print("  - Version: \(videoInfo.firmwareVersion ?? "Unknown")")
            }
            
            if let controlInfo = halIntegration.getChipsetInfo(type: .control(.ch9329)) {
                print("Control Chipset Details:")
                print("  - Name: \(controlInfo.name)")
                print("  - Vendor: \(controlInfo.manufacturer)")
                print("  - Version: \(controlInfo.firmwareVersion ?? "Unknown")")
            }
            
        } else {
            print("❌ HAL Integration initialization failed")
        }
    }
    
    /// Example: Enhanced HID Manager HAL integration
    func enhancedHIDManagerExample() {
        print("\n🔧 HAL Usage Example: Enhanced HID Manager Integration")
        
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        // Test HAL-aware HID operations
        if hidManager.initializeHALAwareHID() {
            print("✅ HAL-aware HID initialized")
            
            // Get HAL system information
            let systemInfo = hidManager.getHALSystemInfo()
            print("System Info: \(systemInfo)")
            
            // Get HAL HID capabilities
            let capabilities = hidManager.getHALHIDCapabilities()
            print("HID Capabilities: \(capabilities.joined(separator: ", "))")
            
            // Test feature support
            let testFeatures = ["HDMI Input", "EEPROM Access", "CTS Monitoring"]
            for feature in testFeatures {
                let supported = hidManager.halSupportsHIDFeature(feature)
                print("  - \(feature): \(supported ? "✅" : "❌")")
            }
            
            // Get enhanced video signal status
            if let signalStatus = hidManager.getHALVideoSignalStatus() {
                print("Enhanced Signal Status:")
                print("  - Has Signal: \(signalStatus.hasSignal ? "✅" : "❌")")
                print("  - Signal Strength: \(signalStatus.signalStrength)")
                print("  - Is Stable: \(signalStatus.isStable ? "✅" : "❌")")
                print("  - Error Rate: \(signalStatus.errorRate)")
            }
            
            // Get detailed timing information
            if let timingInfo = hidManager.getHALVideoTimingInfo() {
                print("Detailed Timing Info:")
                print("  - H Total: \(timingInfo.horizontalTotal)")
                print("  - V Total: \(timingInfo.verticalTotal)")
                print("  - H Sync Start: \(timingInfo.horizontalSyncStart)")
                print("  - V Sync Start: \(timingInfo.verticalSyncStart)")
                print("  - Pixel Clock: \(timingInfo.pixelClock)")
            }
            
        } else {
            print("⚠️ HAL-aware HID initialization failed or not supported")
        }
    }
    
    // MARK: - Error Handling Examples
    
    /// Example: Graceful error handling
    func errorHandlingExample() {
        print("\n⚠️ HAL Usage Example: Error Handling")
        
        // Test with no hardware connected (simulation)
        hal.deinitializeHardware()
        
        // Check how HAL handles missing hardware
        if let videoChipset = hal.getCurrentVideoChipset() {
            print("Unexpected: Video chipset available after deinitialization")
        } else {
            print("✅ Gracefully handled missing video chipset")
        }
        
        if let controlChipset = hal.getCurrentControlChipset() {
            print("Unexpected: Control chipset available after deinitialization")
        } else {
            print("✅ Gracefully handled missing control chipset")
        }
        
        // Test system info with no hardware
        let systemInfo = hal.getSystemInfo()
        print("System info with no hardware:")
        print("  - Video Active: \(systemInfo.isVideoActive)")
        print("  - Control Active: \(systemInfo.isControlActive)")
        print("  - Features: \(systemInfo.systemCapabilities.features.count)")
        
        // Reinitialize for other examples
        _ = hal.detectAndInitializeHardware()
    }
    
    // MARK: - Running All Examples
    
    /// Run all HAL usage examples
    func runAllExamples() {
        print("==================================================")
        print("         Hardware Abstraction Layer Examples      ")
        print("==================================================")
        
        initializeHardwareExample()
        checkVideoCapabilitiesExample()
        checkControlCapabilitiesExample()
        advancedControlChipsetExample()
        chipsetSpecificOperationsExample()
        featureAvailabilityExample()
        halIntegrationStatusExample()
        errorHandlingExample()
        
        print("\n==================================================")
        print("            HAL Examples Completed               ")
        print("==================================================")
    }
    
    /// Example: Advanced control chipset integration
    func advancedControlChipsetExample() {
        print("\n🔧 HAL Usage Example: Advanced Control Chipset Integration")
        
        // Get detailed control chipset information
        if let controlInfo = halIntegration.getControlChipsetInfo() {
            print("📊 Detailed Control Chipset Information:")
            print(controlInfo.description)
            
            // Test specific control features
            testControlFeatures(controlInfo)
            
            // Test communication interfaces
            testCommunicationInterfaces(controlInfo)
            
            // Monitor control chipset status
            monitorControlChipsetStatus(controlInfo)
            
        } else {
            print("❌ No control chipset available for advanced integration")
        }
    }
    
    /// Test control chipset features
    private func testControlFeatures(_ controlInfo: ControlChipsetInfo) {
        print("\n🧪 Testing Control Features:")
        
        // Test HID capabilities
        if halIntegration.isControlFeatureSupported("HID Communication") {
            print("✅ HID Communication: Supported")
        } else {
            print("❌ HID Communication: Not supported")
        }
        
        // Test EEPROM operations
        if halIntegration.isControlFeatureSupported("EEPROM Access") {
            print("✅ EEPROM Operations: Supported")
            print("  💾 Can read/write firmware data")
        } else {
            print("❌ EEPROM Operations: Not supported")
        }
        
        // Test keyboard emulation
        if halIntegration.isControlFeatureSupported("Keyboard Emulation") {
            print("✅ Keyboard Emulation: Supported")
        }
        
        // Test mouse emulation
        if halIntegration.isControlFeatureSupported("Mouse Emulation") {
            print("✅ Mouse Emulation: Supported")
        }
        
        // Test firmware update capability
        if halIntegration.isControlFeatureSupported("Firmware Update") {
            print("✅ Firmware Update: Supported")
        }
    }
    
    /// Test communication interfaces
    private func testCommunicationInterfaces(_ controlInfo: ControlChipsetInfo) {
        print("\n📡 Testing Communication Interfaces:")
        
        switch controlInfo.communicationInterface {
        case .serial(let baudRate):
            print("🔌 Serial Communication:")
            print("  📊 Current Baud Rate: \(baudRate)")
            print("  📋 Supported Rates: \(controlInfo.supportedBaudRates)")
            testSerialCommunication(baudRate: baudRate, controlInfo: controlInfo)
            
        case .hid(let reportSize):
            print("🎮 HID Communication:")
            print("  📊 Report Size: \(reportSize) bytes")
            testHIDCommunication(reportSize: reportSize, controlInfo: controlInfo)
            
        case .hybrid(let serialBaud, let hidSize):
            print("🔄 Hybrid Communication:")
            print("  📡 Serial: \(serialBaud) baud")
            print("  🎮 HID: \(hidSize) bytes")
            testHybridCommunication(serialBaud: serialBaud, hidSize: hidSize, controlInfo: controlInfo)
        }
    }
    
    /// Test serial communication
    private func testSerialCommunication(baudRate: Int, controlInfo: ControlChipsetInfo) {
        print("  🧪 Testing Serial Communication...")
        
        // Check if device is ready for serial communication
        if controlInfo.isReady {
            print("  ✅ Device ready for serial communication")
        } else {
            print("  ⚠️ Device not ready for serial communication")
        }
        
        // Check target connection
        if controlInfo.deviceStatus.isTargetConnected {
            print("  ✅ Target device connected via serial")
        } else {
            print("  ❌ No target device connected")
        }
    }
    
    /// Test HID communication
    private func testHIDCommunication(reportSize: Int, controlInfo: ControlChipsetInfo) {
        print("  🧪 Testing HID Communication...")
        
        if reportSize > 0 {
            print("  ✅ HID reports configured: \(reportSize) bytes")
        }
        
        // Test HID-specific features
        if controlInfo.capabilities.supportsHID {
            print("  ✅ HID operations supported")
        }
        
        if controlInfo.capabilities.supportsEEPROM {
            print("  ✅ EEPROM access via HID supported")
        }
    }
    
    /// Test hybrid communication
    private func testHybridCommunication(serialBaud: Int, hidSize: Int, controlInfo: ControlChipsetInfo) {
        print("  🧪 Testing Hybrid Communication...")
        
        // Test both serial and HID components
        testSerialCommunication(baudRate: serialBaud, controlInfo: controlInfo)
        testHIDCommunication(reportSize: hidSize, controlInfo: controlInfo)
        
        print("  🔄 Hybrid mode allows both serial and HID operations")
    }
    
    /// Monitor control chipset status
    private func monitorControlChipsetStatus(_ controlInfo: ControlChipsetInfo) {
        print("\n📊 Control Chipset Status Monitoring:")
        
        print("Device Ready: \(controlInfo.isReady ? "✅" : "❌")")
        print("Target Connected: \(controlInfo.deviceStatus.isTargetConnected ? "✅" : "❌")")
        print("Current Baud Rate: \(controlInfo.currentBaudRate)")
        
        // Log chipset type specific information
        switch controlInfo.chipsetInfo.chipsetType {
        case .control(let controlType):
            switch controlType {
            case .ch9329:
                print("🔧 CH9329 Specific Features:")
                print("  - CTS line monitoring for HID events")
                print("  - Hybrid serial + HID communication")
                print("  - Hardware keyboard/mouse emulation")
                
            case .ch32v208:
                print("🔧 CH32V208 Specific Features:")
                print("  - Direct serial communication")
                print("  - Advanced HID capabilities")
                print("  - Firmware update support")
                
            @unknown default:
                print("🔧 Unknown Control Chipset Type")
                print("  - Generic control features available")
            }
        case .video:
            print("⚠️ Video chipset info found in control chipset context")
        @unknown default:
            print("⚠️ Unknown chipset type")
        }
    }
}

// MARK: - Usage Function

/// Function to demonstrate HAL usage - can be called from anywhere in the app
func demonstrateHALUsage() {
    let examples = HALUsageExamples()
    examples.runAllExamples()
}
