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
                print(self?.getSwitch() ?? "read HID Device data is worry!")
            }
        }
        timer?.resume()
    }


    // 打开指定的HID设备
    func openHID(vid: Int, pid: Int, lid: String ) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        print(lid)
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

        var report = [UInt8](repeating: 0, count: 9)  // 创建一个9字节的缓冲区
        var reportLength = report.count
        
        // 从设备读取输入报告
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(0), &report, &reportLength)
        
        if result == kIOReturnSuccess {
            print("HID Report read successfully")
            return Array(report[0..<reportLength])  // 只返回实际读取的字节
        } else {
            print("Failed to read HID Report. Error: \(result)")
            return nil
        }
    }

    // Send data to HID device
    func sendHIDReport(report: [UInt8]) {
        guard let device = self.device else { return }
        var report = report

        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), &report, report.count)
//        if result == kIOReturnSuccess {
//            print("HID Report sent: \(report)")
//        } else {
//            print("Failed to send HID Report")
//        }
    }
    
    
    func getSwitch() -> Bool {
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
}
