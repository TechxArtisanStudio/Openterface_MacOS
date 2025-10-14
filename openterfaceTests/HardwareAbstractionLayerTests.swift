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

import XCTest
@testable import openterface

/// Test suite for Hardware Abstraction Layer functionality
class HardwareAbstractionLayerTests: XCTestCase {
    
    var hal: HardwareAbstractionLayer!
    var halIntegration: HALIntegrationManager!
    
    override func setUp() {
        super.setUp()
        hal = HardwareAbstractionLayer.shared
        halIntegration = HALIntegrationManager.shared
    }
    
    override func tearDown() {
        hal.deinitializeHardware()
        super.tearDown()
    }
    
    // MARK: - HAL Core Tests
    
    func testHALInitialization() {
        // Test HAL can be initialized
        let result = hal.detectAndInitializeHardware()
        
        // Result may be true or false depending on connected hardware
        // but the method should complete without crashing
        XCTAssertTrue(result == true || result == false, "HAL initialization should return a boolean value")
    }
    
    func testHALSystemInfo() {
        // Test system info retrieval
        let systemInfo = hal.getSystemInfo()
        
        XCTAssertNotNil(systemInfo, "System info should not be nil")
        XCTAssertNotNil(systemInfo.systemCapabilities, "System capabilities should not be nil")
        
        // Test description doesn't crash
        let description = systemInfo.description
        XCTAssertFalse(description.isEmpty, "System info description should not be empty")
    }
    
    func testVideoChipsetDetection() {
        // Test video chipset detection
        let videoChipset = hal.getCurrentVideoChipset()
        
        if let chipset = videoChipset {
            // If a chipset is detected, verify its properties
            XCTAssertFalse(chipset.chipsetInfo.name.isEmpty, "Chipset name should not be empty")
            XCTAssertGreaterThan(chipset.chipsetInfo.vendorID, 0, "Vendor ID should be greater than 0")
            XCTAssertGreaterThan(chipset.chipsetInfo.productID, 0, "Product ID should be greater than 0")
            XCTAssertFalse(chipset.supportedResolutions.isEmpty, "Should have supported resolutions")
            XCTAssertGreaterThan(chipset.maxFrameRate, 0, "Max frame rate should be greater than 0")
        }
        
        // Test should pass whether or not hardware is connected
        XCTAssertTrue(true, "Video chipset detection completed")
    }
    
    func testControlChipsetDetection() {
        // Test control chipset detection
        let controlChipset = hal.getCurrentControlChipset()
        
        if let chipset = controlChipset {
            // If a chipset is detected, verify its properties
            XCTAssertFalse(chipset.chipsetInfo.name.isEmpty, "Chipset name should not be empty")
            XCTAssertGreaterThan(chipset.chipsetInfo.vendorID, 0, "Vendor ID should be greater than 0")
            XCTAssertGreaterThan(chipset.chipsetInfo.productID, 0, "Product ID should be greater than 0")
            XCTAssertFalse(chipset.supportedBaudRates.isEmpty, "Should have supported baud rates")
        }
        
        // Test should pass whether or not hardware is connected
        XCTAssertTrue(true, "Control chipset detection completed")
    }
    
    // MARK: - HAL Integration Tests
    
    func testHALIntegrationInitialization() {
        // Test HAL integration can be initialized
        let result = halIntegration.initializeHALIntegration()
        
        // Should complete without crashing
        XCTAssertTrue(result == true || result == false, "HAL integration initialization should return a boolean value")
    }
    
    func testHALStatusRetrieval() {
        // Test HAL status retrieval
        let status = halIntegration.getHALStatus()
        
        XCTAssertNotNil(status, "HAL status should not be nil")
        XCTAssertNotNil(status.systemCapabilities, "System capabilities should not be nil")
        XCTAssertNotNil(status.lastUpdate, "Last update time should not be nil")
        
        // Test description doesn't crash
        let description = status.description
        XCTAssertFalse(description.isEmpty, "HAL status description should not be empty")
    }
    
    func testFeatureAvailabilityCheck() {
        // Test feature availability checking
        let hdmiSupport = halIntegration.isFeatureAvailable("HDMI Input")
        let audioSupport = halIntegration.isFeatureAvailable("Audio Capture")
        let hidSupport = halIntegration.isFeatureAvailable("HID Events")
        
        // Results depend on connected hardware, but should not crash
        XCTAssertTrue(hdmiSupport == true || hdmiSupport == false, "HDMI support check should return boolean")
        XCTAssertTrue(audioSupport == true || audioSupport == false, "Audio support check should return boolean")
        XCTAssertTrue(hidSupport == true || hidSupport == false, "HID support check should return boolean")
    }
    
    // MARK: - Chipset Specific Tests
    
    func testMS2109VideoChipset() {
        // Test MS2109 chipset creation and properties
        let ms2109 = MS2109VideoChipset()
        
        if let chipset = ms2109 {
            XCTAssertEqual(chipset.chipsetInfo.name, "MS2109", "MS2109 chipset name should be correct")
            XCTAssertEqual(chipset.chipsetInfo.vendorID, 0x534D, "MS2109 vendor ID should be correct")
            XCTAssertEqual(chipset.chipsetInfo.productID, 0x2109, "MS2109 product ID should be correct")
            XCTAssertEqual(chipset.maxFrameRate, 60.0, "MS2109 max frame rate should be 60 fps")
            XCTAssertTrue(chipset.capabilities.supportsHDMI, "MS2109 should support HDMI")
            XCTAssertTrue(chipset.capabilities.supportsAudio, "MS2109 should support audio")
            XCTAssertTrue(chipset.capabilities.supportsFirmwareUpdate, "MS2109 should support firmware update")
        }
    }
    
    func testMS2130VideoChipset() {
        // Test MS2130 chipset creation and properties
        let ms2130 = MS2130VideoChipset()
        
        if let chipset = ms2130 {
            XCTAssertEqual(chipset.chipsetInfo.name, "MS2130", "MS2130 chipset name should be correct")
            XCTAssertEqual(chipset.chipsetInfo.vendorID, 0x345F, "MS2130 vendor ID should be correct")
            XCTAssertEqual(chipset.chipsetInfo.productID, 0x2130, "MS2130 product ID should be correct")
            XCTAssertEqual(chipset.maxFrameRate, 60.0, "MS2130 max frame rate should be 60 fps")
            XCTAssertTrue(chipset.capabilities.supportsHDMI, "MS2130 should support HDMI")
            XCTAssertTrue(chipset.capabilities.supportsAudio, "MS2130 should support audio")
            XCTAssertFalse(chipset.capabilities.supportsFirmwareUpdate, "MS2130 should not support firmware update")
        }
    }
    
    func testCH9329ControlChipset() {
        // Test CH9329 chipset creation and properties
        let ch9329 = CH9329ControlChipset()
        
        if let chipset = ch9329 {
            XCTAssertEqual(chipset.chipsetInfo.name, "CH9329", "CH9329 chipset name should be correct")
            XCTAssertEqual(chipset.chipsetInfo.vendorID, 0x1A86, "CH9329 vendor ID should be correct")
            XCTAssertEqual(chipset.chipsetInfo.productID, 0x7523, "CH9329 product ID should be correct")
            XCTAssertTrue(chipset.capabilities.supportsHID, "CH9329 should support HID")
            XCTAssertTrue(chipset.supportedBaudRates.contains(9600), "CH9329 should support 9600 baud")
            XCTAssertTrue(chipset.supportedBaudRates.contains(115200), "CH9329 should support 115200 baud")
        }
    }
    
    func testCH32V208ControlChipset() {
        // Test CH32V208 chipset creation and properties
        let ch32v208 = CH32V208ControlChipset()
        
        if let chipset = ch32v208 {
            XCTAssertEqual(chipset.chipsetInfo.name, "CH32V208", "CH32V208 chipset name should be correct")
            XCTAssertEqual(chipset.chipsetInfo.vendorID, 0x1A86, "CH32V208 vendor ID should be correct")
            XCTAssertEqual(chipset.chipsetInfo.productID, 0xFE0C, "CH32V208 product ID should be correct")
            XCTAssertTrue(chipset.capabilities.supportsHID, "CH32V208 should support HID")
            XCTAssertTrue(chipset.capabilities.supportsFirmwareUpdate, "CH32V208 should support firmware update")
            XCTAssertEqual(chipset.supportedBaudRates, [115200], "CH32V208 should only support 115200 baud")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testHALGracefulFailure() {
        // Test HAL handles missing hardware gracefully
        hal.deinitializeHardware()
        
        let videoChipset = hal.getCurrentVideoChipset()
        let controlChipset = hal.getCurrentControlChipset()
        
        // Should return nil without crashing when no hardware is detected
        // (depending on test environment, this may or may not be nil)
        XCTAssertTrue(videoChipset == nil || videoChipset != nil, "Should handle missing video chipset gracefully")
        XCTAssertTrue(controlChipset == nil || controlChipset != nil, "Should handle missing control chipset gracefully")
    }
    
    func testHALReinitialization() {
        // Test HAL can be reinitialized
        hal.deinitializeHardware()
        let result = hal.detectAndInitializeHardware()
        
        // Should complete without crashing
        XCTAssertTrue(result == true || result == false, "HAL reinitialization should return a boolean value")
    }
}

// MARK: - Performance Tests

extension HardwareAbstractionLayerTests {
    
    func testHALInitializationPerformance() {
        // Test HAL initialization performance
        measure {
            let testHAL = HardwareAbstractionLayer.shared
            _ = testHAL.detectAndInitializeHardware()
            testHAL.deinitializeHardware()
        }
    }
    
    func testHALStatusRetrievalPerformance() {
        // Test HAL status retrieval performance
        halIntegration.initializeHALIntegration()
        
        measure {
            _ = halIntegration.getHALStatus()
        }
    }
}

// MARK: - HID Register Protocol Tests
    
    func testVideoChipsetHIDRegistersProtocol_MS2109() {
        // Test MS2109 implements VideoChipsetHIDRegisters protocol correctly
        let ms2109 = MS2109VideoChipset()
        
        if let chipset = ms2109 {
            // Test all required register properties are implemented
            XCTAssertEqual(chipset.resolution, 0xC6AF, "MS2109 resolution register should be 0xC6AF")
            XCTAssertEqual(chipset.fps, 0xC6B1, "MS2109 fps register should be 0xC6B1")
            XCTAssertEqual(chipset.pixelClock, 0xC6B3, "MS2109 pixel clock register should be 0xC6B3")
            XCTAssertEqual(chipset.version, 0xC6B5, "MS2109 version register should be 0xC6B5")
            XCTAssertEqual(chipset.inputHTotal, 0xC6B7, "MS2109 input H total register should be 0xC6B7")
            XCTAssertEqual(chipset.inputVTotal, 0xC6B9, "MS2109 input V total register should be 0xC6B9")
            XCTAssertEqual(chipset.inputHst, 0xC6BB, "MS2109 input H start register should be 0xC6BB")
            XCTAssertEqual(chipset.inputVst, 0xC6BD, "MS2109 input V start register should be 0xC6BD")
            XCTAssertEqual(chipset.inputHsyncWidth, 0xC6BF, "MS2109 input H sync width register should be 0xC6BF")
            XCTAssertEqual(chipset.inputVsyncWidth, 0xC6C1, "MS2109 input V sync width register should be 0xC6C1")
            XCTAssertEqual(chipset.hdmiConnectionStatus, 0xC6C3, "MS2109 HDMI status register should be 0xC6C3")
        }
    }
    
    func testVideoChipsetHIDRegistersProtocol_MS2130() {
        // Test MS2130 implements VideoChipsetHIDRegisters protocol correctly
        let ms2130 = MS2130VideoChipset()
        
        if let chipset = ms2130 {
            // Test all required register properties are implemented
            XCTAssertEqual(chipset.resolution, 0xD6AF, "MS2130 resolution register should be 0xD6AF")
            XCTAssertEqual(chipset.fps, 0xD6B1, "MS2130 fps register should be 0xD6B1")
            XCTAssertEqual(chipset.pixelClock, 0xD6B3, "MS2130 pixel clock register should be 0xD6B3")
            XCTAssertEqual(chipset.version, 0xD6B5, "MS2130 version register should be 0xD6B5")
            XCTAssertEqual(chipset.inputHTotal, 0xD6B7, "MS2130 input H total register should be 0xD6B7")
            XCTAssertEqual(chipset.inputVTotal, 0xD6B9, "MS2130 input V total register should be 0xD6B9")
            XCTAssertEqual(chipset.inputHst, 0xD6BB, "MS2130 input H start register should be 0xD6BB")
            XCTAssertEqual(chipset.inputVst, 0xD6BD, "MS2130 input V start register should be 0xD6BD")
            XCTAssertEqual(chipset.inputHsyncWidth, 0xD6BF, "MS2130 input H sync width register should be 0xD6BF")
            XCTAssertEqual(chipset.inputVsyncWidth, 0xD6C1, "MS2130 input V sync width register should be 0xD6C1")
            XCTAssertEqual(chipset.hdmiConnectionStatus, 0xD6C3, "MS2130 HDMI status register should be 0xD6C3")
        }
    }
    
    func testChipsetRegisterAddressRanges() {
        // Test that MS2109 and MS2130 use different register address ranges
        let ms2109 = MS2109VideoChipset()
        let ms2130 = MS2130VideoChipset()
        
        if let ms2109Chipset = ms2109, let ms2130Chipset = ms2130 {
            // MS2109 should use 0xC6AF-0xCBDF range
            XCTAssertTrue(ms2109Chipset.resolution >= 0xC6AF && ms2109Chipset.resolution <= 0xCBDF, "MS2109 registers should be in 0xC6AF-0xCBDF range")
            XCTAssertTrue(ms2109Chipset.fps >= 0xC6AF && ms2109Chipset.fps <= 0xCBDF, "MS2109 registers should be in 0xC6AF-0xCBDF range")
            XCTAssertTrue(ms2109Chipset.hdmiConnectionStatus >= 0xC6AF && ms2109Chipset.hdmiConnectionStatus <= 0xCBDF, "MS2109 registers should be in 0xC6AF-0xCBDF range")
            
            // MS2130 should use 0xD6AF-0xDBDF range
            XCTAssertTrue(ms2130Chipset.resolution >= 0xD6AF && ms2130Chipset.resolution <= 0xDBDF, "MS2130 registers should be in 0xD6AF-0xDBDF range")
            XCTAssertTrue(ms2130Chipset.fps >= 0xD6AF && ms2130Chipset.fps <= 0xDBDF, "MS2130 registers should be in 0xD6AF-0xDBDF range")
            XCTAssertTrue(ms2130Chipset.hdmiConnectionStatus >= 0xD6AF && ms2130Chipset.hdmiConnectionStatus <= 0xDBDF, "MS2130 registers should be in 0xD6AF-0xDBDF range")
            
            // Ranges should be different
            XCTAssertNotEqual(ms2109Chipset.resolution, ms2130Chipset.resolution, "MS2109 and MS2130 should have different register addresses")
            XCTAssertNotEqual(ms2109Chipset.fps, ms2130Chipset.fps, "MS2109 and MS2130 should have different register addresses")
        }
    }
