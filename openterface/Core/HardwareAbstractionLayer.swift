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
import IOKit
import IOKit.hid
import AVFoundation
import AVFoundation

// MARK: - Hardware Abstraction Layer Protocols

/// Base protocol for all hardware chipsets
protocol HardwareChipsetProtocol: AnyObject {
    var chipsetInfo: ChipsetInfo { get }
    var isConnected: Bool { get }
    var capabilities: ChipsetCapabilities { get }
    
    func initialize() -> Bool
    func deinitialize()
    func detectDevice() -> Bool
    func validateConnection() -> Bool
}

/// Protocol for video capture chipsets
protocol VideoChipsetProtocol: HardwareChipsetProtocol {
    var supportedResolutions: [VideoResolution] { get }
    var currentResolution: VideoResolution? { get }
    var maxFrameRate: Float { get }
    var currentFrameRate: Float { get }
    
    func getVideoDevices() -> [AVCaptureDevice]
    func setupVideoCapture(device: AVCaptureDevice) -> Bool
    func getResolution() -> (width: Int, height: Int)?
    func getFrameRate() -> Float?
    func getPixelClock() -> UInt32?
    func getSignalStatus() -> VideoSignalStatus
    func getTimingInfo() -> VideoTimingInfo?
    func updateConnectionStatus(_ isConnected: Bool)
}

/// Protocol for control chipsets (HID/Serial communication)
protocol ControlChipsetProtocol: HardwareChipsetProtocol {
    var communicationInterface: CommunicationInterface { get }
    var supportedBaudRates: [Int] { get }
    var currentBaudRate: Int { get }
    var isDeviceReady: Bool { get }
    
    func establishCommunication() -> Bool
    func sendAsyncCommand(_ command: [UInt8], force: Bool) -> Bool
    func getDeviceStatus() -> ControlDeviceStatus
    func getVersion() -> String?
    func resetDevice() -> Bool
    func configureDevice(baudRate: Int, mode: UInt8) -> Bool
    func monitorHIDEvents() -> Bool
    func updateConnectionStatus(_ isConnected: Bool)
}

/// Protocol for chipset-specific HID register addresses
/// This allows different video chipsets (MS2109, MS2130, etc.) to have
/// different register mappings for HID operations
protocol VideoChipsetHIDRegisters {
    // MARK: - Resolution Registers
    var inputResolutionWidthHigh: UInt16 { get }
    var inputResolutionWidthLow: UInt16 { get }
    var inputResolutionHeightHigh: UInt16 { get }
    var inputResolutionHeightLow: UInt16 { get }
    
    // MARK: - Frame Rate Registers
    var fpsHigh: UInt16 { get }
    var fpsLow: UInt16 { get }
    
    // MARK: - Pixel Clock Registers
    var pixelClockHigh: UInt16 { get }
    var pixelClockLow: UInt16 { get }
    
    // MARK: - Timing Registers
    var inputHTotalHigh: UInt16 { get }
    var inputHTotalLow: UInt16 { get }
    var inputVTotalHigh: UInt16 { get }
    var inputVTotalLow: UInt16 { get }
    var inputHstHigh: UInt16 { get }
    var inputHstLow: UInt16 { get }
    var inputVstHigh: UInt16 { get }
    var inputVstLow: UInt16 { get }
    var inputHwHigh: UInt16 { get }
    var inputHwLow: UInt16 { get }
    var inputVwHigh: UInt16 { get }
    var inputVwLow: UInt16 { get }
    
    // MARK: - Version Registers
    var version1: UInt16 { get }
    var version2: UInt16 { get }
    var version3: UInt16 { get }
    var version4: UInt16 { get }
    
    // MARK: - Status Registers
    var hdmiConnectionStatus: UInt16 { get }
    var softwareSwitchStatus: UInt16 { get }
    var hardwareSwitchStatus: UInt16 { get }
    
    // MARK: - Chipset Capabilities
    var supportsHIDCommands: Bool { get }
    var supportsEEPROM: Bool { get }
}

// MARK: - Data Structures

/// Chipset information structure
struct ChipsetInfo {
    let name: String
    let vendorID: Int
    let productID: Int
    let firmwareVersion: String?
    let manufacturer: String
    let chipsetType: ChipsetType
}

/// Chipset capabilities
struct ChipsetCapabilities {
    let supportsHDMI: Bool
    let supportsAudio: Bool
    let supportsHID: Bool
    let supportsFirmwareUpdate: Bool
    let supportsEEPROM: Bool
    let maxDataTransferRate: UInt64
    let features: [String]
}

/// Video resolution structure
struct VideoResolution {
    let width: Int
    let height: Int
    let refreshRate: Float
    
    var description: String {
        return "\(width)x\(height)@\(refreshRate)Hz"
    }
}

// Note: VideoSignalStatus and VideoTimingInfo are defined in ProtocolExtensions.swift

/// Control device status
struct ControlDeviceStatus {
    let isTargetConnected: Bool
    let isKeyboardConnected: Bool
    let isMouseConnected: Bool
    let lockStates: KeyboardLockStates
    let chipVersion: Int8
    let communicationQuality: Float
    let lastResponseTime: TimeInterval
}

/// Keyboard lock states
struct KeyboardLockStates {
    let numLock: Bool
    let capsLock: Bool
    let scrollLock: Bool
}

/// Communication interface types
enum CommunicationInterface {
    case serial(baudRate: Int)
    case hid(reportSize: Int)
    case hybrid(serial: Int, hid: Int)
}

/// Chipset types
enum ChipsetType: Equatable {
    case video(VideoChipsetType)
    case control(ControlChipsetType)
}

// MARK: - Hardware Abstraction Layer Manager

/// Main HAL manager that coordinates hardware abstraction
class HardwareAbstractionLayer {
    static let shared = HardwareAbstractionLayer()
    
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var videoChipset: VideoChipsetProtocol?
    private var controlChipset: ControlChipsetProtocol?
    
    private init() {}
    
    // MARK: - Hardware Detection and Initialization
    
    func detectAndInitializeHardware() -> Bool {
        logger.log(content: "🔍 HAL: Starting hardware detection...")
        
        let videoDetected = detectVideoChipset()
        let controlDetected = detectControlChipset()
        
        if videoDetected || controlDetected {
            logger.log(content: "✅ HAL: Hardware detection completed")
            return true
        } else {
            logger.log(content: "❌ HAL: No supported hardware detected")
            return false
        }
    }
    
    private func detectVideoChipset() -> Bool {
        // Check for MS2109 chipset
        if let ms2109 = MS2109VideoChipset() {
            if ms2109.detectDevice() {
                videoChipset = ms2109
                AppStatus.videoChipsetType = .ms2109
                if ms2109.initialize() {
                    logger.log(content: "✅ HAL: MS2109 video chipset detected and initialized")
                    return true
                } else {
                    logger.log(content: "❌ HAL: MS2109 video chipset initialization failed")
                }
            }
        }
        
        if let ms2109s = MS2109SVideoChipset() {
            if ms2109s.detectDevice() {
                videoChipset = ms2109s
                AppStatus.videoChipsetType = .ms2109s
                if ms2109s.initialize() {
                    logger.log(content: "✅ HAL: MS2109S video chipset detected and initialized")
                    return true
                } else {
                    logger.log(content: "❌ HAL: MS2109S video chipset initialization failed")
                }
            }
        }
        
        // Check for MS2130S chipset
        if let ms2130s = MS2130SVideoChipset() {
            if ms2130s.detectDevice() {
                videoChipset = ms2130s
                AppStatus.videoChipsetType = .ms2130s
                if ms2130s.initialize() {
                    logger.log(content: "✅ HAL: MS2130S video chipset detected and initialized")
                    return true
                } else {
                    logger.log(content: "❌ HAL: MS2130S video chipset initialization failed")  
                }
            }
        }
        
        AppStatus.videoChipsetType = .unknown
        logger.log(content: "HAL: No supported video chipset detected")
        return false
    }
    
    private func detectControlChipset() -> Bool {        
        // Check for CH32V208 chipset
        if let ch32v208 = CH32V208ControlChipset() {
            if ch32v208.detectDevice() && ch32v208.initialize() {
                controlChipset = ch32v208
                AppStatus.controlChipsetType = .ch32v208
                logger.log(content: "✅ HAL: CH32V208 control chipset detected and initialized")
                return true
            }
        }
        
        // Check for CH9329 chipset
        if let ch9329 = CH9329ControlChipset() {
            if ch9329.detectDevice() && ch9329.initialize() {
                controlChipset = ch9329
                AppStatus.controlChipsetType = .ch9329
                logger.log(content: "✅ HAL: CH9329 control chipset detected and initialized")
                return true
            }
        }

        AppStatus.controlChipsetType = .unknown
        logger.log(content: "⚠️ HAL: No supported control chipset detected")
        return false
    }
    
    // MARK: - Public Interface
    
    func getCurrentVideoChipset() -> VideoChipsetProtocol? {
        if videoChipset == nil {
            detectVideoChipset()
        }
        return videoChipset
    }
    
    func getCurrentControlChipset() -> ControlChipsetProtocol? {
        return controlChipset
    }
    
    func getAvailableControlChipsets() -> [(chipset: ControlChipsetProtocol, type: ControlChipsetType)] {
        var available: [(chipset: ControlChipsetProtocol, type: ControlChipsetType)] = []
        
        // Check for CH32V208 chipset
        if let ch32v208 = CH32V208ControlChipset() {
            if ch32v208.detectDevice() {
                available.append((chipset: ch32v208, type: .ch32v208))
            }
        }
        
        // Check for CH9329 chipset
        if let ch9329 = CH9329ControlChipset() {
            if ch9329.detectDevice() {
                available.append((chipset: ch9329, type: .ch9329))
            }
        }
        
        logger.log(content: "📋 HAL: Found \(available.count) available control chipset(s)")
        return available
    }
    
    func selectControlChipset(_ chipset: ControlChipsetProtocol, type: ControlChipsetType) -> Bool {
        if chipset.initialize() {
            controlChipset = chipset
            AppStatus.controlChipsetType = type
            logger.log(content: "✅ HAL: Control chipset \(chipset.chipsetInfo.name) selected and initialized")
            return true
        } else {
            logger.log(content: "❌ HAL: Failed to initialize selected control chipset \(chipset.chipsetInfo.name)")
            return false
        }
    }
    
    func getVideoCapabilities() -> ChipsetCapabilities? {
        return videoChipset?.capabilities
    }
    
    func getControlCapabilities() -> ChipsetCapabilities? {
        return controlChipset?.capabilities
    }
    
    func getSystemInfo() -> HardwareSystemInfo {
        logger.log(content: "🔍 HAL: Gathering system hardware information...")
        logger.log(content: "\(controlChipset?.isConnected ?? false) - \(AppStatus.isTargetConnected)")
        return HardwareSystemInfo(
            videoChipset: videoChipset?.chipsetInfo,
            controlChipset: controlChipset?.chipsetInfo,
            isVideoActive: videoChipset?.isConnected ?? false,
            isControlActive: controlChipset?.isConnected ?? false || AppStatus.isTargetConnected,
            systemCapabilities: getSystemCapabilities()
        )
    }
    
    private func getSystemCapabilities() -> ChipsetCapabilities {
        let videoCapabilities = videoChipset?.capabilities
        let controlCapabilities = controlChipset?.capabilities
        
        return ChipsetCapabilities(
            supportsHDMI: videoCapabilities?.supportsHDMI ?? false,
            supportsAudio: videoCapabilities?.supportsAudio ?? false,
            supportsHID: controlCapabilities?.supportsHID ?? false,
            supportsFirmwareUpdate: videoCapabilities?.supportsFirmwareUpdate ?? false,
            supportsEEPROM: videoCapabilities?.supportsEEPROM ?? false,
            maxDataTransferRate: max(videoCapabilities?.maxDataTransferRate ?? 0, 
                                   controlCapabilities?.maxDataTransferRate ?? 0),
            features: (videoCapabilities?.features ?? []) + (controlCapabilities?.features ?? [])
        )
    }
    
    func deinitializeHardware() {
        logger.log(content: "🔄 HAL: Deinitializing hardware...")
        videoChipset?.deinitialize()
        controlChipset?.deinitialize()
        videoChipset = nil
        controlChipset = nil
        logger.log(content: "✅ HAL: Hardware deinitialized")
    }
}

/// System hardware information
struct HardwareSystemInfo {
    let videoChipset: ChipsetInfo?
    let controlChipset: ChipsetInfo?
    let isVideoActive: Bool
    let isControlActive: Bool
    let systemCapabilities: ChipsetCapabilities
    
    var description: String {
        var desc = "Hardware System Info:\n"
        if let video = videoChipset {
            desc += "Video: \(video.name) (Active: \(isVideoActive))\n"
        }
        if let control = controlChipset {
            desc += "Control: \(control.name) (Active: \(isControlActive))\n"
        }
        desc += "Capabilities: \(systemCapabilities.features.joined(separator: ", "))"
        return desc
    }
}
