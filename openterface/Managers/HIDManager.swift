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

class HIDManager {
    static let shared = HIDManager()
    
    var manager: IOHIDManager!
    @Published var device: IOHIDDevice?
    @Published var isOpen: Bool?
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.openterface.hidCommunicator", qos: .background)
    
    private init() {
        
        startHID()
        startCommunication()
        let spm = SerialPortManager.shared
        spm.tryOpenSerialPort()
    }
    
    func startHID() {
        if (AppStatus.DefaultVideoDevice != nil){
            if let _v = AppStatus.DefaultVideoDevice?.vendorID, let _p = AppStatus.DefaultVideoDevice?.productID, let _l = AppStatus.DefaultVideoDevice?.locationID {
                openHID(vid: _v, pid: _p, lid: _l)
            }
        }else{
            Logger.shared.log(content: "No HID device detected when start HID Manager.")
        }
    }
    
    func startCommunication() {
        AppStatus.isSwitchToggleOn = self.getSwitchStatus()
  
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .seconds(1))
        timer?.setEventHandler { [weak self] in
            if AppStatus.isHIDOpen == nil {
                Logger.shared.log(content: "No HID device detected during communication check")
            } else if AppStatus.isHIDOpen == false {
                Logger.shared.log(content: "HID device exists but failed to open - check device permissions and connectivity")
            } else {
                // Get switch and HDMI status since HID device is now open and ready
                //  HID has been opened!
                self?.getSwitchStatus()
                self?.getHDMIStatus()
                if let _status = self?.getHardwareConnetionStatus() {
                    AppStatus.isHardwareConnetionToTarget = _status
                }

                AppStatus.hidReadResolusion = self?.getResolution() ?? (width: 0, height: 0)
                AppStatus.hidReadFps = self?.getFps() ?? 0
                AppStatus.MS2109Version = self?.getVersion() ?? ""
                AppStatus.hidReadPixelClock = self?.getPixelClock() ?? 0
                AppStatus.hidInputHTotal = UInt32(self?.getInputHTotal() ?? 0)
                AppStatus.hidInputVTotal = UInt32(self?.getInputVTotal() ?? 0)
                AppStatus.hidInputHst = UInt32(self?.getInputHst() ?? 0)
                AppStatus.hidInputVst = UInt32(self?.getInputVst() ?? 0)
                AppStatus.hidInputHsyncWidth = UInt32(self?.getInputHsyncWidth() ?? 0)
                AppStatus.hidInputVsyncWidth = UInt32(self?.getInputVsyncWidth() ?? 0)
            }
        }
        timer?.resume()
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
                Logger.shared.log(content: "Failed to open HID Manager with error code: \(result). Please check device permissions and connectivity.")
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
                self.isOpen = nil
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
        Logger.shared.log(content: "HID Manager and device connections closed successfully")
    }
    
    // read date from HID device
    func readHIDReport() -> [UInt8]? {
        guard let device = self.device else {
            Logger.shared.log(content: "Cannot read HID report - no HID device is currently connected or available")
            return nil
        }

        var report = [UInt8](repeating: 0, count: 9)
        var reportLength = report.count
        
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(0), &report, &reportLength)
        
        if result == kIOReturnSuccess {
            return Array(report[0..<reportLength])
        } else {
            return nil
        }
    }

    // Send data to HID device
    func sendHIDReport(report: [UInt8]) {
        guard let device = self.device else { return }
        var report = report

        _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), &report, report.count)
    }
    
    func sendAndReadHIDReport(_ report: [UInt8]) -> [UInt8]? {
        self.sendHIDReport(report: report)
        return readHIDReport()
    }
    
    func setUSBtoHost() {
        self.sendHIDReport(report: [182, 223, 1, 0, 1, 0, 0, 0]) // host
    }
    
    func setUSBtoTrager() {
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
        self.sendHIDReport(report: [181, 250, 140, 0, 0, 0, 0, 0, 0])
        
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
        let widthHighReport = generateHIDReport(for: .inputResolutionWidthHigh)
        let widthLowReport = generateHIDReport(for: .inputResolutionWidthLow)
        let heightHighReport = generateHIDReport(for: .inputResolutionHeightHigh)
        let heightLowReport = generateHIDReport(for: .inputResolutionHeightLow)
        
        guard let widthHighResponse = self.sendAndReadHIDReport(widthHighReport),
              let widthLowResponse = self.sendAndReadHIDReport(widthLowReport),
              let heightHighResponse = self.sendAndReadHIDReport(heightHighReport),
              let heightLowResponse = self.sendAndReadHIDReport(heightLowReport) else {
            Logger.shared.log(content: "Failed to read resolution data from HID device. Check if device is properly connected.")
            return nil
        }
        
        // width
        let widthHigh = Int(widthHighResponse[3])
        let widthLow = Int(widthLowResponse[3])
        let width = (widthHigh << 8) | widthLow
        
        // height
        let heightHigh = Int(heightHighResponse[3])
        let heightLow = Int(heightLowResponse[3])
        let height = (heightHigh << 8) | heightLow
        
        // Check if a resolution change notification needs to be sent
        let newResolution = (width, height)
        let oldResolution = AppStatus.hidReadResolusion
        
        if (oldResolution.0 != 0 && oldResolution.1 != 0) && (newResolution.0 != oldResolution.0 || newResolution.1 != oldResolution.1) {
            Logger.shared.log(content: "HID input resolution changed: \(newResolution.0)x\(newResolution.1)")
            Logger.shared.log(content: "Old input resolution: \(oldResolution.0)x\(oldResolution.1)")
            // When the resolution changes, send a notification
            if newResolution.0 > 0 && newResolution.1 > 0 {
                NotificationCenter.default.post(name: .hidResolutionChanged, object: nil, userInfo: ["width": width, "height": height])
                
                // Reset user custom aspect ratio settings
                UserSettings.shared.useCustomAspectRatio = false
            }
        }
        
        return (width, height)
    }
    
    func getFps() -> Float? {
        let fpsHighReport = generateHIDReport(for: .fpsHigh)
        let fpsLowReport = generateHIDReport(for: .fpsLow)
        
        guard let fpsHighResponse = self.sendAndReadHIDReport(fpsHighReport),
              let fpsLowResponse = self.sendAndReadHIDReport(fpsLowReport) else {
            Logger.shared.log(content: "Failed to read FPS data from HID device. Check if device is properly connected.")
            return nil
        }
        
        let fpsHigh = Int(fpsHighResponse[3])
        let fpsLow = Int(fpsLowResponse[3])
        
        let rawFps = (fpsHigh << 8) | fpsLow
        let fps = Float(rawFps) / 100.0
        
        // Round to 2 decimal places
        let roundedFps = Float(String(format: "%.2f", fps)) ?? fps
        if roundedFps == 59.99 {
            // Special case for 59.99 FPS, round to 60
            return 60.0
        }
        return roundedFps
    }
    
    func getPixelClock() -> UInt32? {
        let pixelClockHighReport = generateHIDReport(for: .pixelClockHigh)
        let pixelClockLowReport = generateHIDReport(for: .pixelClockLow)
        
        guard let pixelClockHighResponse = self.sendAndReadHIDReport(pixelClockHighReport),
              let pixelClockLowResponse = self.sendAndReadHIDReport(pixelClockLowReport) else {
            Logger.shared.log(content: "Failed to read pixel clock data from HID device. Check if device is properly connected.")
            return nil
        }
        
        let pixelClockHigh = UInt32(pixelClockHighResponse[3])
        let pixelClockLow = UInt32(pixelClockLowResponse[3])
        
        let pixelClock = (pixelClockHigh << 8) | pixelClockLow
        
        return pixelClock
    }

    func getInputHTotal() -> Int? {
        let hTotalHighReport = generateHIDReport(for: .inputHTotalHigh)
        let hTotalLowReport = generateHIDReport(for: .inputHTotalLow)

        guard let hTotalHighResponse = self.sendAndReadHIDReport(hTotalHighReport),
              let hTotalLowResponse = self.sendAndReadHIDReport(hTotalLowReport) else {
            Logger.shared.log(content: "Failed to read HTotal data from HID device. Check if device is properly connected.")
            return nil
        }

        let hTotalHigh = Int(hTotalHighResponse[3])
        let hTotalLow = Int(hTotalLowResponse[3])

        return (hTotalHigh << 8) | hTotalLow
    }

    func getInputVTotal() -> Int? {
        let vTotalHighReport = generateHIDReport(for: .inputResolutionHeightHigh)
        let vTotalLowReport = generateHIDReport(for: .inputResolutionHeightLow)

        guard let vTotalHighResponse = self.sendAndReadHIDReport(vTotalHighReport),
              let vTotalLowResponse = self.sendAndReadHIDReport(vTotalLowReport) else {
            Logger.shared.log(content: "Failed to read VTotal data from HID device. Check if device is properly connected.")
            return nil
        }

        let vTotalHigh = Int(vTotalHighResponse[3])
        let vTotalLow = Int(vTotalLowResponse[3])

        return (vTotalHigh << 8) | vTotalLow
    }

    func getInputHst() -> Int? {
        let hstHighReport = generateHIDReport(for: .inputHstHigh)
        let hstLowReport = generateHIDReport(for: .inputHstLow)

        guard let hstHighResponse = self.sendAndReadHIDReport(hstHighReport),
              let hstLowResponse = self.sendAndReadHIDReport(hstLowReport) else {
            Logger.shared.log(content: "Failed to read HST data from HID device. Check if device is properly connected.")
            return nil
        }

        let hstHigh = Int(hstHighResponse[3])
        let hstLow = Int(hstLowResponse[3])

        return (hstHigh << 8) | hstLow
    }

    func getInputVst() -> Int? {
        let vstHighReport = generateHIDReport(for: .inputVstHigh)
        let vstLowReport = generateHIDReport(for: .inputVstLow)

        guard let vstHighResponse = self.sendAndReadHIDReport(vstHighReport),
              let vstLowResponse = self.sendAndReadHIDReport(vstLowReport) else {
            Logger.shared.log(content: "Failed to read VST data from HID device. Check if device is properly connected.")
            return nil
        }

        let vstHigh = Int(vstHighResponse[3])
        let vstLow = Int(vstLowResponse[3])

        return (vstHigh << 8) | vstLow
    }

    func getInputHsyncWidth() -> Int? {
        let hwHighReport = generateHIDReport(for: .inputHwHigh)
        let hwLowReport = generateHIDReport(for: .inputHwLow)

        guard let hwHighResponse = self.sendAndReadHIDReport(hwHighReport),
              let hwLowResponse = self.sendAndReadHIDReport(hwLowReport) else {
            Logger.shared.log(content: "Failed to read HW data from HID device. Check if device is properly connected.")
            return nil
        }

        let hwHigh = Int(hwHighResponse[3])
        let hwLow = Int(hwLowResponse[3])

        return (hwHigh << 8) | hwLow
    }

    func getInputVsyncWidth() -> Int? {
        let vwHighReport = generateHIDReport(for: .inputVwHigh)
        let vwLowReport = generateHIDReport(for: .inputVwLow)

        guard let vwHighResponse = self.sendAndReadHIDReport(vwHighReport),
              let vwLowResponse = self.sendAndReadHIDReport(vwLowReport) else {
            Logger.shared.log(content: "Failed to read VW data from HID device. Check if device is properly connected.")
            return nil
        }

        let vwHigh = Int(vwHighResponse[3])
        let vwLow = Int(vwLowResponse[3])

        return (vwHigh << 8) | vwLow
    }

    func getVersion() -> String? {
        let v1 = generateHIDReport(for: .version1)
        let v2 = generateHIDReport(for: .version2)
        let v3 = generateHIDReport(for: .version3)
        let v4 = generateHIDReport(for: .version4)
        
        guard let _v1 = self.sendAndReadHIDReport(v1),
              let _v2 = self.sendAndReadHIDReport(v2),
              let _v3 = self.sendAndReadHIDReport(v3),
              let _v4 = self.sendAndReadHIDReport(v4) else {
            Logger.shared.log(content: "Failed to read version data from HID device. Check if device is properly connected.")
            return nil
        }

        return parseVersionData([_v1,_v2,_v3,_v4])
    }
    
    func parseVersionData(_ data: [[UInt8]]) -> String {
        let versionParts = data.compactMap { report -> String? in
            guard report.count >= 4 else { return nil }
            return String(format: "%02d", report[3])
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
    
    func generateHIDReport(for subCommand: HIDSubCommand) -> [UInt8] {
        let commandPrefix: UInt8 = 181
        
        let highByte = UInt8((subCommand.rawValue >> 8) & 0xFF)
        let lowByte = UInt8(subCommand.rawValue & 0xFF)
        
        let report: [UInt8] = [commandPrefix, highByte, lowByte, 0, 0, 0, 0, 0, 0]
        
        return report
    }
}


// define HID sub commands
enum HIDSubCommand: UInt16 {
    case inputResolutionWidthHigh = 0xC6AF
    case inputResolutionWidthLow = 0xC6B0
    case inputResolutionHeightHigh = 0xC6B1
    case inputResolutionHeightLow = 0xC6B2

    // new
    // get input resolution data C6AF C6B0 C6B1 C6B2
    // case inputWidthHigh = 0xC6AF
    // case inputWidthLow = 0xC6B0
    // case inputHeightHigh = 0xC6B1
    // case inputHeightLow = 0xC6B2
    
    // old
    // get FPS data C73E C73F
    case fpsHigh = 0xC6B5
    case fpsLow = 0xC6B6

    // // new
    // // get input FPS data C6B5 C6B6
    // case inputFpsHigh = 0xC6B5
    // case inputFpsLow = 0xC6B6

    // get input pixel clock data C73C C73D
    case pixelClockHigh = 0xC73C
    case pixelClockLow = 0xC73D

    case inputHTotalHigh = 0xC734 // Total Horizontal pixels per line (inclcuding active and blanking pixels)
    case inputHTotalLow = 0xC735
    case inputVTotalHigh = 0xC736 // Total Vertical lines per frame (inclcuding active and blanking lines)
    case inputVTotalLow = 0xC737

    case inputHstHigh = 0xC740 // Horizontal Sync Start Offset — how many pixels from line start until sync begins.
    case inputHstLow = 0xC741
    case inputVstHigh = 0xC742 // Vertical Sync Start Offset — how many lines from frame start until vertical sync begins.
    case inputVstLow = 0xC743
    case inputHwHigh = 0xC744 // Horizontal Sync Width in pixels.
    case inputHwLow = 0xC745
    case inputVwHigh = 0xC746 // Vertical Sync Width in lines.
    case inputVwLow = 0xC747


    // get MS2019 version CBDC CBDD CBDE CBDF
    case version1 = 0xCBDC
    case version2 = 0xCBDD
    case version3 = 0xCBDE
    case version4 = 0xCBDF
    
    // ADDR_HDMI_CONNECTION_STATUS
    case HDMI_CONNECTION_STATUS = 0xFA8C

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
