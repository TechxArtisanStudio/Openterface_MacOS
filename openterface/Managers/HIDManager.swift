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
    // 单例模式
    static let shared = HIDManager()
    
    var manager: IOHIDManager!
    @Published var device: IOHIDDevice?
    @Published var isOpen: Bool?
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.example.hidCommunicator", qos: .background)
    
    private init() {
        print(AppStatus.groupOpenterfaceDevices)
        if (AppStatus.DefaultVideoDevice != nil){
            if let _v = AppStatus.DefaultVideoDevice?.vendorID, let _p = AppStatus.DefaultVideoDevice?.productID, let _l = AppStatus.DefaultVideoDevice?.locationID {
                openHID(vid: _v, pid: _p, lid: _l)
            }
        }else{
            print("No HID device")
        }
        
        startCommunication()
    }
    
    func startCommunication() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .seconds(1))
        timer?.setEventHandler { [weak self] in
            if AppStatus.isHIDOpen == nil {
                print("no HID device")
            } else if AppStatus.isHIDOpen == false {
                print("HID device has not been opened!")
            } else {
                //  HID has been opened!
                print(self?.getSwitchStatus() ?? "read HID Device data is worry!")
                
                print(self?.getResolution() ?? "nil")
                
                print(self?.getFps() ?? "nil")
                
                print(self?.getVersion() ?? "nil")
            }
        }
        timer?.resume()
    }


    // Open specify HID
    func openHID(vid: Int, pid: Int, lid: String ) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
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
                print("Failed to open HID Manager")
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

    // close hid device
    func closeHID() {
        if let device = self.device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        print("HID Manager closed")
    }

    // read date from HID device
    func readHIDReport() -> [UInt8]? {
        guard let device = self.device else {
            print("No HID device available")
            return nil
        }

        var report = [UInt8](repeating: 0, count: 9)
        var reportLength = report.count
        
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(0), &report, &reportLength)
        
        if result == kIOReturnSuccess {
            // print("HID Report read successfully")
            return Array(report[0..<reportLength])
        } else {
            // print("Failed to read HID Report. Error: \(result)")
            return nil
        }
    }

    // Send data to HID device
    func sendHIDReport(report: [UInt8]) {
        guard let device = self.device else { return }
        var report = report

        _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), &report, report.count)
        // if result == kIOReturnSuccess {
        //     print("HID Report sent: \(report)")
        // } else {
        //     print("Failed to send HID Report")
        // }
    }
    
    func sendAndReadHIDReport(_ report: [UInt8]) -> [UInt8]? {
        // print(report)
        self.sendHIDReport(report: report)
        // print(readHIDReport())
        return readHIDReport()
    }
    
    
    func getSwitchStatus() -> Bool {
        self.sendHIDReport(report: [181, 223, 0, 1, 0, 0, 0, 0, 0])
        
        if let report = self.readHIDReport() {
            if report[3] == 0 { // to host
                AppStatus.isSwitchToggleOn = false
                return true
            } else {
                AppStatus.isSwitchToggleOn = true
                return false
            }
        }
        AppStatus.isSwitchToggleOn = true
        return false
    }
    
    func getResolution() -> (width: Int, height: Int)? {
        // 发送宽度和高度的命令并读取响应
        let widthHighReport = generateHIDReport(for: .resolutionWidthHigh)
        let widthLowReport = generateHIDReport(for: .resolutionWidthLow)
        let heightHighReport = generateHIDReport(for: .resolutionHeightHigh)
        let heightLowReport = generateHIDReport(for: .resolutionHeightLow)
        
        guard let widthHighResponse = self.sendAndReadHIDReport(widthHighReport),
              let widthLowResponse = self.sendAndReadHIDReport(widthLowReport),
              let heightHighResponse = self.sendAndReadHIDReport(heightHighReport),
              let heightLowResponse = self.sendAndReadHIDReport(heightLowReport) else {
            print("Failed to read resolution data")
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
        
        return (width, height)
    }
    
    func getFps() -> Int? {
        let fpsHighReport = generateHIDReport(for: .fpsHigh)
        let fpsLowReport = generateHIDReport(for: .fpsLow)
        
        guard let fpsHighResponse = self.sendAndReadHIDReport(fpsHighReport),
              let fpsLowResponse = self.sendAndReadHIDReport(fpsLowReport) else {
            print("Failed to read FPS data")
            return nil
        }
        
        let fpsHigh = Int(fpsHighResponse[3])
        let fpsLow = Int(fpsLowResponse[3])
        
        let fps = ((fpsHigh << 8) | fpsLow) / 100
        
        return fps
    }
    
    func getVersion() -> String? {
        // 发送宽度和高度的命令并读取响应
        let v1 = generateHIDReport(for: .version1)
        let v2 = generateHIDReport(for: .version2)
        let v3 = generateHIDReport(for: .version3)
        let v4 = generateHIDReport(for: .version4)
        
        guard let _v1 = self.sendAndReadHIDReport(v1),
              let _v2 = self.sendAndReadHIDReport(v2),
              let _v3 = self.sendAndReadHIDReport(v3),
              let _v4 = self.sendAndReadHIDReport(v4) else {
            print("Failed to read resolution data")
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
    // get Resolusion data  C738 C739 C73A C73B
    case resolutionWidthHigh = 0xC738
    case resolutionWidthLow = 0xC739
    case resolutionHeightHigh = 0xC73A
    case resolutionHeightLow = 0xC73B
    
    // get FPS data C73E C73F
    case fpsHigh = 0xC73E
    case fpsLow = 0xC73F
    
    // get MS2019 version CBDC CBDD CBDE CBDF
    case version1 = 0xCBDC
    case version2 = 0xCBDD
    case version3 = 0xCBDE
    case version4 = 0xCBDF
}
