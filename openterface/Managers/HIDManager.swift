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
import IOKit
import IOKit.usb
import IOKit.hid
import Foundation

// MARK: - HAL Integration

/// HIDManager now integrates with the Hardware Abstraction Layer
/// This provides chipset-aware HID operations and better hardware abstraction

class HIDManager: ObservableObject, HIDManagerProtocol {
    private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    static let shared = HIDManager()
    
    var manager: IOHIDManager!
    @Published var device: IOHIDDevice?
    @Published var isOpen: Bool = false
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.openterface.hidCommunicator", qos: .background)
    
    private init() {
        startHID()
        startCommunication()
    }
    
    func startHID() {
        if (AppStatus.DefaultVideoDevice != nil){
            if let _v = AppStatus.DefaultVideoDevice?.vendorID, let _p = AppStatus.DefaultVideoDevice?.productID, let _l = AppStatus.DefaultVideoDevice?.locationID {
                openHID(vid: _v, pid: _p, lid: _l)
            }
        }else{
            logger.log(content: "No HID device detected when start HID Manager.")
        }
    }
    
    func startCommunication() {
        if !self.isOpen {
            self.startHID()
        }
    }


    // Open specify HID
    func openHID(vid: Int, pid: Int, lid: String ) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        if let _lid = hexStringToDecimalInt(hexString: lid) {
            let deviceMatching: [String: Any] = [
                kIOHIDVendorIDKey: vid,
                kIOHIDProductIDKey: pid,
                kIOHIDLocationIDKey: _lid,
            ]
            
            IOHIDManagerSetDeviceMatching(manager, deviceMatching as CFDictionary)
            
            // Open HID Manager
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess {
                logger.log(content: "Failed to open HID Manager with error code: \(result). Please check device permissions and connectivity.")
                return
            }
            
            // get matching devices
            if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let matchedDevice = deviceSet.first {
                // try open device
                let openResult = IOHIDDeviceOpen(matchedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
                if openResult == kIOReturnSuccess {
                    self.device = matchedDevice
                    self.isOpen = true
                    AppStatus.isHIDOpen = true
                } else {
                    self.isOpen = false
                    AppStatus.isHIDOpen = false
                }
            } else {
                self.isOpen = false
                AppStatus.isHIDOpen = nil
            }
        }
        
    }

    func closeHID() {
        if let device = self.device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
        if manager != nil {
            IOHIDManagerClose(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        logger.log(content: "HID Manager and device connections closed successfully")
    }
    
    /// Stops all repeating HID operations while keeping the HID connection open
    /// This is used during firmware updates to prevent interference with EEPROM operations
    /// Note: Periodic operations are now handled by HAL's PeriodicHALUpdates
    func stopAllHIDOperations() {
        logger.log(content: "Stopping all repeating HID operations for firmware update...")
        
        // Periodic operations are now managed by HAL
        logger.log(content: "Periodic HID operations are handled by HAL's PeriodicHALUpdates.")
    }
    
    /// Restarts repeating HID operations after firmware update is complete
    /// Note: Periodic operations are now handled by HAL's PeriodicHALUpdates
    func restartHIDOperations() {
        logger.log(content: "Restarting HID operations after firmware update...")
        
        // Periodic operations are now managed by HAL
        logger.log(content: "HID operations restarted via HAL's PeriodicHALUpdates.")
    }
    
    // read date from HID device
    func readHIDReport() -> [UInt8]? {
        guard let device = self.device else {
            logger.log(content: "Cannot read HID report - no HID device is currently connected or available")
            return nil
        }

        // Use larger buffer to accommodate different chipset report formats
        // MS2109: 9 bytes, MS2130S: 11 bytes
        var report = [UInt8](repeating: 0, count: 11)
        var reportLength = report.count
        
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, self.getReportID(), &report, &reportLength)
        
        if result == kIOReturnSuccess {
            return Array(report[0..<reportLength])
        } else {
            logger.log(content: "Failed to read HID report - error code: \(result). \(self.interpretIOReturn(result))")
            return nil
        }
    }

    // Send data to HID device
    func sendHIDReport(report: [UInt8]) {
        guard let device = self.device else { return }
        var report = report
        let hexString = report.map { String(format: "%02X", $0) }.joined(separator: " ")

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, self.getReportID(), &report, report.count)
        if result != kIOReturnSuccess {
            logger.log(content: "Failed to send HID report - error code: \(result). \(self.interpretIOReturn(result))")
        }
    }
    
    func sendAndReadHIDReport(_ report: [UInt8]) -> [UInt8]? {
        self.sendHIDReport(report: report)
        return readHIDReport()
    }
    
    func sendAndReadHIDReportAsUInt8(_ report: [UInt8]) -> UInt8? {
        guard let response = sendAndReadHIDReport(report) else { return nil }
        //for ms2109 or ms2109s, the value at index 3 is the data we want
        //for ms2130s, the value at index 4 as 01 report id at index 0, command at index 1, address high at index 2, address low at index 3, data at index 4
        let valueIndex = (getActiveVideoChipset()?.chipsetInfo.chipsetType == .video(.ms2130s)) ? 4 : 3
        return response.count > valueIndex ? response[valueIndex] : nil
    }

    func sendAndReadHIDReportAsUInt16(_ report: [UInt8]) -> UInt16? {
        guard let response = sendAndReadHIDReport(report) else { return nil }
        guard response.count > 4 else { return nil }
        let valueIndex = (getActiveVideoChipset()?.chipsetInfo.chipsetType == .video(.ms2130s)) ? 4 : 3
        // For ms2109, only one byte is returned, so we need to read next address to get the full UInt16
        if getActiveVideoChipset()?.chipsetInfo.chipsetType == .video(.ms2109) {
            // highByte first as it's big-endian
            let highByte = response[valueIndex]
            let lowReport = generateHIDReport(address: (UInt16(response[1]) << 8) | UInt16(response[2]) + 1)
            guard let lowResponse = sendAndReadHIDReport(lowReport), lowResponse.count > valueIndex else { return nil }
            let lowByte = lowResponse[valueIndex]
            return (UInt16(highByte) << 8) | UInt16(lowByte)
        }
        return (UInt16(response[valueIndex]) << 8) | UInt16(response[valueIndex + 1])
    }
    
    //TODO handle MS2109 case
    func setUSBtoHost() {
        logger.log(content: "🔄 HIDManager.setUSBtoHost() called - sending host report")
        self.sendHIDReport(report: [182, 223, 1, 0, 1, 0, 0, 0]) // host
    }
    
    func setUSBtoTarget() {
        logger.log(content: "🔄 HIDManager.setUSBtoTarget() called - sending target report")
        self.sendHIDReport(report: [182, 223, 1, 1, 1, 0, 0, 0]) // target
    }
    
    func getHardwareConnetionStatus() -> Bool {
        self.sendHIDReport(report: [181, 223, 1, 0, 0, 0, 0, 0])
        if let report = self.readHIDReport() {
            if report[3] == 0 { // to host
                return false
            } else {
                return true
            }
        }
        return true
    }
    
    func getSwitchStatus() -> Bool {
        self.sendHIDReport(report: [181, 223, 0, 1, 0, 0, 0, 0, 0])
        
        if let report = self.readHIDReport() {
            if report[3] == 0 { // to host
                AppStatus.isHardwareSwitchOn = false
                return false
            } else {
                AppStatus.isHardwareSwitchOn = true
                return true
            }
        }
        AppStatus.isHardwareSwitchOn = true
        return true
    }
    
    func getHDMIStatus() -> Bool {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for HDMI status reading")
            AppStatus.hasHdmiSignal = nil
            return false
        }
        
        let hdmiStatusReport = generateHIDReport(address: hidRegisters.hdmiConnectionStatus)
        self.sendHIDReport(report: hdmiStatusReport)
        
        if let report = self.readHIDReport() {
            let statusByte = report[3]
//            _ = String(statusByte, radix: 2).padLeft(toLength: 8, withPad: "0")
            
            if statusByte & 0x01 == 1 {
                AppStatus.hasHdmiSignal = true
                return true
            } else {
                AppStatus.hasHdmiSignal = false
                return false
            }
        } else {
            AppStatus.hasHdmiSignal = nil
            return false
        }
    }
    
    func getResolution() -> (width: Int, height: Int)? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for resolution reading")
            return nil
        }
        
        let widthHighReport = generateHIDReport(address: hidRegisters.inputResolutionWidthHigh)
        let heightHighReport = generateHIDReport(address: hidRegisters.inputResolutionHeightHigh)
        
        guard let widthU16 = self.sendAndReadHIDReportAsUInt16(widthHighReport),
              let heightU16 = self.sendAndReadHIDReportAsUInt16(heightHighReport) else {
            logger.log(content: "Failed to read resolution data from HID device. Check if device is properly connected.")
            return nil
        }
        var width = Int(widthU16)
        var height = Int(heightU16)
        
        // Cap resolution at 4K, default to 1920x1080 if exceeded
        if width > 4096 || height > 4096 {
            logger.log(content: "Input resolution (\(width)x\(height)) exceeds 4K limit, defaulting to 1920x1080")
            width = 1920
            height = 1080
        }
        
        let pixelClock = AppStatus.hidReadPixelClock / 100
        if AppStatus.videoChipsetType == .ms2109 {
            if pixelClock > 189 { // The magic value for MS2109 4K resolution correction
                width = width == 4096 ? width : width*2
                height = height == 2160 ? height : height*2
            }
        }else{
            if width == 3840 && height == 1080 {
                height = 2160
            }
        }
        
        // Check if a resolution change notification needs to be sent
        let newResolution = (width, height)
        let oldResolution = AppStatus.hidReadResolusion
        
        if (oldResolution.0 != 0 && oldResolution.1 != 0) && (newResolution.0 != oldResolution.0 || newResolution.1 != oldResolution.1) {
            logger.log(content: "HID input resolution changed: \(newResolution.0)x\(newResolution.1)")
            logger.log(content: "Old input resolution: \(oldResolution.0)x\(oldResolution.1)")
            // When the resolution changes, send a notification
            if newResolution.0 > 0 && newResolution.1 > 0 {
                NotificationCenter.default.post(name: .hidResolutionChanged, object: nil, userInfo: ["width": width, "height": height])
                
                // Reset user custom aspect ratio settings
                UserSettings.shared.useCustomAspectRatio = false
            }
        }
        
        return (width, height)
    }
    
    func getAspectRatio() -> Float? {
        guard let resolution = getResolution(),
              resolution.height > 0 else {
            return nil
        }
        return Float(resolution.width) / Float(resolution.height)
    }
    
    func getFps() -> Float? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for FPS reading")
            return nil
        }
        
        let fpsHighReport = generateHIDReport(address: hidRegisters.fpsHigh)
        
        guard let rawFps = self.sendAndReadHIDReportAsUInt16(fpsHighReport) else {
            logger.log(content: "Failed to read FPS data from HID device. Check if device is properly connected.")
            return nil
        }
        
        let fps = Float(rawFps) / 100.0
        
        // Round to 2 decimal places
        let roundedFps = Float(String(format: "%.2f", Double(fps))) ?? fps
        if roundedFps == 59.99 {
            // Special case for 59.99 FPS, round to 60
            return 60.0
        }
        return roundedFps
    }
    
    func getPixelClock() -> UInt32? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for pixel clock reading")
            return nil
        }
        
        let pixelClockHighReport = generateHIDReport(address: hidRegisters.pixelClockHigh)
        
        guard let pixelClock = self.sendAndReadHIDReportAsUInt16(pixelClockHighReport) else {
            logger.log(content: "Failed to read pixel clock data from HID device. Check if device is properly connected.")
            return nil
        }
        AppStatus.hidReadPixelClock = UInt32(pixelClock)
        return AppStatus.hidReadPixelClock
    }

    func getInputHTotal() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for HTotal reading")
            return nil
        }
        
        let hTotalHighReport = generateHIDReport(address: hidRegisters.inputHTotalHigh)
        let hTotalLowReport = generateHIDReport(address: hidRegisters.inputHTotalLow)

        guard let hTotalHighResponse = self.sendAndReadHIDReport(hTotalHighReport),
              let hTotalLowResponse = self.sendAndReadHIDReport(hTotalLowReport) else {
            logger.log(content: "Failed to read HTotal data from HID device. Check if device is properly connected.")
            return nil
        }

        let hTotalHigh = Int(hTotalHighResponse[3])
        let hTotalLow = Int(hTotalLowResponse[3])

        return (hTotalHigh << 8) | hTotalLow
    }

    func getInputVTotal() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for VTotal reading")
            return nil
        }
        
        let vTotalHighReport = generateHIDReport(address: hidRegisters.inputVTotalHigh)
        let vTotalLowReport = generateHIDReport(address: hidRegisters.inputVTotalLow)

        guard let vTotalHighResponse = self.sendAndReadHIDReport(vTotalHighReport),
              let vTotalLowResponse = self.sendAndReadHIDReport(vTotalLowReport) else {
            logger.log(content: "Failed to read VTotal data from HID device. Check if device is properly connected.")
            return nil
        }

        let vTotalHigh = Int(vTotalHighResponse[3])
        let vTotalLow = Int(vTotalLowResponse[3])

        return (vTotalHigh << 8) | vTotalLow
    }

    func getInputHst() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for HST reading")
            return nil
        }
        
        let hstHighReport = generateHIDReport(address: hidRegisters.inputHstHigh)
        let hstLowReport = generateHIDReport(address: hidRegisters.inputHstLow)

        guard let hstHighResponse = self.sendAndReadHIDReport(hstHighReport),
              let hstLowResponse = self.sendAndReadHIDReport(hstLowReport) else {
            logger.log(content: "Failed to read HST data from HID device. Check if device is properly connected.")
            return nil
        }

        let hstHigh = Int(hstHighResponse[3])
        let hstLow = Int(hstLowResponse[3])

        return (hstHigh << 8) | hstLow
    }

    func getInputVst() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for VST reading")
            return nil
        }
        
        let vstHighReport = generateHIDReport(address: hidRegisters.inputVstHigh)
        let vstLowReport = generateHIDReport(address: hidRegisters.inputVstLow)

        guard let vstHighResponse = self.sendAndReadHIDReport(vstHighReport),
              let vstLowResponse = self.sendAndReadHIDReport(vstLowReport) else {
            logger.log(content: "Failed to read VST data from HID device. Check if device is properly connected.")
            return nil
        }

        let vstHigh = Int(vstHighResponse[3])
        let vstLow = Int(vstLowResponse[3])

        return (vstHigh << 8) | vstLow
    }

    func getInputHsyncWidth() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for HW reading")
            return nil
        }
        
        let hwHighReport = generateHIDReport(address: hidRegisters.inputHwHigh)
        let hwLowReport = generateHIDReport(address: hidRegisters.inputHwLow)

        guard let hwHighResponse = self.sendAndReadHIDReport(hwHighReport),
              let hwLowResponse = self.sendAndReadHIDReport(hwLowReport) else {
            logger.log(content: "Failed to read HW data from HID device. Check if device is properly connected.")
            return nil
        }

        let hwHigh = Int(hwHighResponse[3])
        let hwLow = Int(hwLowResponse[3])

        return (hwHigh << 8) | hwLow
    }

    func getInputVsyncWidth() -> Int? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for VW reading")
            return nil
        }
        
        let vwHighReport = generateHIDReport(address: hidRegisters.inputVwHigh)
        let vwLowReport = generateHIDReport(address: hidRegisters.inputVwLow)

        guard let vwHighResponse = self.sendAndReadHIDReport(vwHighReport),
              let vwLowResponse = self.sendAndReadHIDReport(vwLowReport) else {
            logger.log(content: "Failed to read VW data from HID device. Check if device is properly connected.")
            return nil
        }

        let vwHigh = Int(vwHighResponse[3])
        let vwLow = Int(vwLowResponse[3])

        return (vwHigh << 8) | vwLow
    }

    func getVersion() -> String? {
        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            logger.log(content: "No active video chipset found for version reading")
            return nil
        }
        
        let v1 = generateHIDReport(address: hidRegisters.version1)
        let v2 = generateHIDReport(address: hidRegisters.version2)
        let v3 = generateHIDReport(address: hidRegisters.version3)
        let v4 = generateHIDReport(address: hidRegisters.version4)
        
        guard let _v1 = self.sendAndReadHIDReportAsUInt8(v1),
              let _v2 = self.sendAndReadHIDReportAsUInt8(v2),
              let _v3 = self.sendAndReadHIDReportAsUInt8(v3),
              let _v4 = self.sendAndReadHIDReportAsUInt8(v4) else {
            logger.log(content: "Failed to read version data from HID device. Check if device is properly connected.")
            return nil
        }

        return parseVersionData([_v1,_v2,_v3,_v4])
    }
    
    func parseVersionData(_ data: [UInt8]) -> String {
        let versionParts = data.compactMap { verString -> String? in
            return String(format: "%02d", verString)
        }
        
        return versionParts.joined()
    }
    
    func hexStringToDecimalInt(hexString: String) -> Int? {
        var cleanedHexString = hexString
        if hexString.hasPrefix("0x") {
            cleanedHexString = String(hexString.dropFirst(2))
        }
        
        guard let hexValue = UInt(cleanedHexString, radix: 16) else {
            return nil
        }
        
        return Int(hexValue)
    }
    
    private func interpretIOReturn(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnSuccess:
            return "Success"
        case kIOReturnNotOpen:
            return "Device not open"
        case kIOReturnUnsupported: // kIOReturnUnsupported
            return "Operation not supported: The HID device does not support the requested operation."
        case kIOReturnNotPermitted:
            return "Operation not permitted: The HID device is not permitted to perform the requested operation."
        case kIOReturnNoDevice:
            return "No such device: The HID device is not available or has been disconnected."
        case kIOReturnNotReady:
            return "Device not ready: The HID device is not ready to accept commands."
        case kIOReturnNotResponding:
            return "Device not responding: The HID device is not responding to commands."
        case kIOReturnBadArgument:
            return "Invalid argument: One or more arguments to the HID operation are invalid."
        case kIOReturnAborted:
            return "Operation aborted: The HID operation was aborted."
        case kIOReturnTimeout:
            return "Operation timeout: The HID operation timed out."
        case kIOReturnNotOpen:
            return "Device not open: The HID device is not open."
        default:
            let hexCode = String(format: "0x%08X", UInt32(bitPattern: Int32(truncatingIfNeeded: result)))
            if let machString = String(cString: mach_error_string(result), encoding: .utf8), !machString.isEmpty && machString != "(ipc/send) invalid destination port" {
                return "Unknown error: \(machString) (code: \(hexCode))"
            } else {
                return "Unknown error (code: \(hexCode))"
            }
        }
    }
    
    // MARK: - EEPROM Operations for Firmware Update
    
    /// Writes data to EEPROM using HID commands (based on Qt implementation)
    /// - Parameters:
    ///   - address: The starting address in EEPROM
    ///   - data: The data to write
    ///   - progressCallback: Optional callback to report progress (0.0 to 1.0)
    /// - Returns: True if write was successful
    func writeEeprom(address: UInt16, data: Data, progressCallback: ((Double) -> Void)? = nil) -> Bool {
        logger.log(content: "Writing \(data.count) bytes to EEPROM at address 0x\(String(format: "%04X", address))")
        
        // Write in chunks (based on C++ implementation)
        let maxChunkSize = 16
        var currentAddress = address
        var offset = 0
        var writtenSize = 0
        let totalSize = data.count
        
        // Report initial progress
        progressCallback?(0.0)
        
        while offset < data.count {
            let remainingBytes = data.count - offset
            let currentChunkSize = min(maxChunkSize, remainingBytes)
            
            let chunk = data.subdata(in: offset..<(offset + currentChunkSize))
            
            if !writeChunk(address: currentAddress, data: chunk) {
                logger.log(content: "Failed to write EEPROM chunk at address 0x\(String(format: "%04X", currentAddress))")
                return false
            }
            
            offset += currentChunkSize
            currentAddress += UInt16(currentChunkSize)
            writtenSize += currentChunkSize
            
            // Update progress
            let progress = Double(writtenSize) / Double(totalSize)
            progressCallback?(progress)
            
            // Log progress periodically
            if writtenSize % 64 == 0 {
                logger.log(content: "Written size: \(writtenSize)/\(totalSize) (\(Int(progress * 100))%)")
            }
            
            // Add delay between chunks (from C++ implementation)
            Thread.sleep(forTimeInterval: 0.1) // 100ms delay
        }
        
        // Report completion
        progressCallback?(1.0)
        logger.log(content: "EEPROM write completed successfully")
        return true
    }
    
    /// Writes data to EEPROM using HID commands (backward compatibility method without progress)
    /// - Parameters:
    ///   - address: The starting address in EEPROM
    ///   - data: The data to write
    /// - Returns: True if write was successful
    func writeEeprom(address: UInt16, data: Data) -> Bool {
        return writeEeprom(address: address, data: data, progressCallback: nil)
    }
    
    /// Writes a single chunk to EEPROM using HID feature report
    /// - Parameters:
    ///   - address: The address to write to
    ///   - data: The data chunk to write (2 bytes per command based on Python implementation)
    /// - Returns: True if successful
    private func writeChunk(address: UInt16, data: Data) -> Bool {
        let chunkSize = 1
        let reportSize = 9
        
        var currentAddress = address
        
        for i in stride(from: 0, to: data.count, by: chunkSize) {
            let endIndex = min(i + chunkSize, data.count)
            let chunk = data.subdata(in: i..<endIndex)
            let chunkBytes = [UInt8](chunk)
            
            // Create HID report for EEPROM write based on Python MS2109Device.py
            // report = [0, CMD_WRITE, (_address >> 8) & 0xFF, _address & 0xFF] + chunk + [0] * (REPORT_SIZE - 4 - chunk_length)
            var report = [UInt8](repeating: 0, count: reportSize)
            report[0] = 0xE6 // CMD_WRITE (from Python implementation)
            report[1] = UInt8((currentAddress >> 8) & 0xFF) // Address high byte
            report[2] = UInt8(currentAddress & 0xFF)        // Address low byte
            
            // Copy chunk data to report (starting at index 3)
            for (index, byte) in chunkBytes.enumerated() {
                if index + 3 < reportSize {
                    report[index + 3] = byte
                }
            }
            // Remaining bytes are already 0 from initialization
            
            logger.log(content: "EEPROM Write Report: \(report.map { String(format: "%02X", $0) }.joined(separator: " "))")
            
            // Send HID feature report (based on videohid.cpp implementation)
            // EEPROM operations use feature reports, not output reports
            if !sendHIDFeatureReport(report: report) {
                logger.log(content: "Failed to send EEPROM write feature report")
                return false
            }
            
            currentAddress += UInt16(chunkBytes.count)
        }
        
        return true
    }
    
    /// Reads data from EEPROM (for verification)
    /// - Parameters:
    ///   - address: The starting address to read from
    ///   - length: Number of bytes to read
    /// - Returns: The read data, or nil if failed
    func readEeprom(address: UInt16, length: UInt8) -> Data? {
        logger.log(content: "Reading \(length) bytes from EEPROM at address 0x\(String(format: "%04X", address))")
        
        guard length > 0 else {
            logger.log(content: "Invalid read length: \(length)")
            return nil
        }
        
        var readData = Data()
        var currentAddress = address
        let maxChunkSize: UInt8 = 16 // Read up to 16 bytes at a time (8 commands * 2 bytes each)
        var remainingBytes = length
        
        while remainingBytes > 0 {
            let currentChunkSize = min(maxChunkSize, remainingBytes)
            
            if let chunk = readEepromChunk(address: currentAddress, length: currentChunkSize) {
                readData.append(chunk)
                currentAddress += UInt16(chunk.count)
                remainingBytes -= UInt8(chunk.count)
            } else {
                logger.log(content: "Failed to read EEPROM chunk at address 0x\(String(format: "%04X", currentAddress))")
                return nil
            }
            
            // Add small delay between chunk reads for stability
            Thread.sleep(forTimeInterval: 0.05) // 50ms delay
        }
        
        logger.log(content: "EEPROM read completed successfully, read \(readData.count) bytes")
        return readData
    }
    
    /// Reads a single chunk from EEPROM using HID feature report
    /// - Parameters:
    ///   - address: The address to read from
    ///   - length: Number of bytes to read (can read up to 5 bytes per command)
    /// - Returns: The read data chunk, or nil if failed
    private func readEepromChunk(address: UInt16, length: UInt8) -> Data? {
        let reportSize = 9
        let cmdRead: UInt8 = 0xE5
        let maxBytesPerRead: UInt8 = 5 // Maximum bytes we can read in one command
        
        var result = Data()
        var remainingLength = length
        var currentAddress = address
        
        while remainingLength > 0 {
            // Determine how many bytes to read in this iteration (up to 5)
            let bytesToRead = min(remainingLength, maxBytesPerRead)
            
            // Construct the read command: [report_id=0, cmd, addr_high, addr_low, length, padding]
            var report = [UInt8](repeating: 0, count: reportSize)
            report[0] = cmdRead                             // CMD_READ = 0xE5
            report[1] = UInt8((currentAddress >> 8) & 0xFF) // Address high byte
            report[2] = UInt8(currentAddress & 0xFF)        // Address low byte
            report[3] = bytesToRead                         // Length (1-5 bytes)
            // Remaining bytes are already 0 from initialization (padding)
            
            logger.log(content: "EEPROM Read Request [0x\(String(format: "%04X", currentAddress)), \(bytesToRead) bytes]: \(report.map { String(format: "%02X", $0) }.joined(separator: " "))")
            
            // Send read command using feature report
            if !sendHIDFeatureReport(report: report) {
                logger.log(content: "Failed to send EEPROM read feature report at address 0x\(String(format: "%04X", currentAddress))")
                return nil
            }
            
            // Add delay for device processing (similar to write operations)
            Thread.sleep(forTimeInterval: 0.005) // 5ms delay
            
            // Read response using feature report
            guard let response = getHIDFeatureReport(bufferSize: reportSize) else {
                logger.log(content: "Failed to get EEPROM read response at address 0x\(String(format: "%04X", currentAddress))")
                return nil
            }
            
            logger.log(content: "EEPROM Read Response [0x\(String(format: "%04X", currentAddress))]: \(response.map { String(format: "%02X", $0) }.joined(separator: " "))")

            // Check if response has enough bytes (need at least 3 + bytesToRead)
            let expectedMinLength = 3 + Int(bytesToRead)
            if response.count >= expectedMinLength {
                // Read data from response bytes 3 to (3 + bytesToRead - 1)
                for i in 0..<Int(bytesToRead) {
                    result.append(response[3 + i])
                }
            } else {
                logger.log(content: "Invalid EEPROM read response length at address 0x\(String(format: "%04X", currentAddress)): expected >= \(expectedMinLength), got \(response.count)")
                return nil
            }
            
            // Update for next iteration
            currentAddress += UInt16(bytesToRead)
            remainingLength -= bytesToRead
        }
        
        return result
    }
    
    // MARK: - Feature Report Methods
    
    /// Send HID feature report (based on videohid.cpp sendFeatureReport)
    /// Used for EEPROM operations and other feature-based commands
    /// - Parameter report: The report data to send
    /// - Returns: True if successful, false otherwise
    func sendHIDFeatureReport(report: [UInt8]) -> Bool {
        guard let device = self.device else {
            print("Cannot send feature report - no HID device is currently connected")
            return false
        }
        
        var mutableReport = report
        
        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeFeature,  // Feature report type for EEPROM and configuration
            CFIndex(0),               // Report ID 0
            &mutableReport,
            mutableReport.count
        )
        
        let success = (result == kIOReturnSuccess)
        
        return success
    }
    
    /// Get HID feature report (based on videohid.cpp getFeatureReport)
    /// Used for reading EEPROM data and device status
    /// - Parameter buffer: Buffer to receive the report data
    /// - Returns: The received report data, or nil if failed
    func getHIDFeatureReport(bufferSize: Int = 9) -> [UInt8]? {
        guard let device = self.device else {
            print("Cannot get feature report - no HID device is currently connected")
            return nil
        }
        
        var report = [UInt8](repeating: 0, count: bufferSize)
        var reportLength = report.count
        
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,  // Feature report type
            CFIndex(0),               // Report ID 0
            &report,
            &reportLength
        )
        
        if result == kIOReturnSuccess {
            let receivedData = Array(report[0..<reportLength])
            return receivedData
        } else {
            print("Failed to get feature report: \(result)")
            return nil
        }
    }
}

extension String {
    func padLeft(toLength: Int, withPad character: Character) -> String {
        let paddingLength = toLength - self.count
        if paddingLength <= 0 {
            return self
        }
        return String(repeating: character, count: paddingLength) + self
    }
}

// Add notification name extension
extension Notification.Name {
    static let hidResolutionChanged = Notification.Name("hidResolutionChanged")
}

// MARK: - HAL Integration Methods

extension HIDManager {
    /// Get the active video chipset that supports HID register mapping
    private func getActiveVideoChipset() -> VideoChipsetProtocol? {
        let hal = HardwareAbstractionLayer.shared
        return hal.getCurrentVideoChipset()
    }
    
    /// Generate HID report using HAL register address instead of enum
    func generateHIDReport(address: UInt16) -> [UInt8] {
        let commandPrefix: UInt8 = 0xB5
        let highByte = UInt8((address >> 8) & 0xFF)
        let lowByte = UInt8(address & 0xFF)

        guard let chipset = getActiveVideoChipset(),
              let hidRegisters = chipset as? VideoChipsetHIDRegisters else {
            // Fallback to MS2109 format if no chipset detected
            return [commandPrefix, highByte, lowByte, 0, 0, 0, 0]
        }
        

        // MS2130S requires a prefix before commandPrefix
        if chipset.chipsetInfo.chipsetType == ChipsetType.video(VideoChipsetType.ms2130s) {
            return [0x01, commandPrefix, highByte, lowByte]
        } else {
            // MS2109 and other chipsets use the standard format
            return [commandPrefix, highByte, lowByte, 0, 0, 0, 0]
        }
    }
    
    /// Get the report ID based on the chipset type
    /// MS2109 uses report ID 0, MS2130S uses report ID 1
    func getReportID() -> CFIndex {
        return CFIndex(1)
    }
    
    /// Get HAL-aware chipset information
    func getHALChipsetInfo() -> ChipsetInfo? {
        // Try to get chipset info from the HAL
        let hal = HardwareAbstractionLayer.shared
        if let videoChipset = hal.getCurrentVideoChipset() {
            return videoChipset.chipsetInfo
        }
        
        // Fallback: create chipset info based on connected USB device
        if let device = AppStatus.DefaultVideoDevice {
            return ChipsetInfo(
                name: "MS2109", // Default assumption
                vendorID: device.vendorID,
                productID: device.productID,
                firmwareVersion: getVersion(),
                manufacturer: "MacroSilicon",
                chipsetType: ChipsetType.video(VideoChipsetType.ms2109)
            )
        }
        
        return nil
    }
    
    /// Get HAL-aware signal status
    func getHALSignalStatus() -> VideoSignalStatus {
        let hasSignal = getHDMIStatus()
        
        return VideoSignalStatus(
            hasSignal: hasSignal,
            signalStrength: hasSignal ? 1.0 : 0.0,
            isStable: hasSignal,
            errorRate: 0.0,
            lastUpdate: Date()
        )
    }
    
    /// Get HAL-aware timing info
    func getHALTimingInfo() -> VideoTimingInfo? {
        // Check if we have timing information available
        guard AppStatus.hidInputHTotal > 0 && AppStatus.hidInputVTotal > 0 else {
            return nil
        }
        
        return VideoTimingInfo(
            horizontalTotal: AppStatus.hidInputHTotal,
            verticalTotal: AppStatus.hidInputVTotal,
            horizontalSyncStart: AppStatus.hidInputHst,
            verticalSyncStart: AppStatus.hidInputVst,
            horizontalSyncWidth: AppStatus.hidInputHsyncWidth,
            verticalSyncWidth: AppStatus.hidInputVsyncWidth,
            pixelClock: AppStatus.hidReadPixelClock
        )
    }
}
