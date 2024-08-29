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
    @Published var device: IOHIDDevice?     // 当前打开的HID设备
    @Published var isOpen: Bool?            // 设备是否打开
    
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.example.hidCommunicator", qos: .background)
    
    private init() {
        //        DispatchQueue.global(qos: .background).async {
        //            // 执行耗时的后台任务
        //            for i in 0..<5 {
        //                print("后台任务正在运行 \(i)")
        //                Thread.sleep(forTimeInterval: 1) // 模拟耗时任务
        //            }
        //            print("后台任务完成")
        //        }
        // open hid
        print(AppStatus.groupOpenterfaceDevices)
        if (AppStatus.DefaultVideoDevice != nil){
            print(AppStatus.DefaultVideoDevice)
            if let _v = AppStatus.DefaultVideoDevice?.vendorID, let _p = AppStatus.DefaultVideoDevice?.productID, let _l = AppStatus.DefaultVideoDevice?.locationID {
                openHID(vid: _v, pid: _p, lid: _l)
            }
        }else{
            print("没有HID")
        }
        
//        startCommunication()
    }
    
    func startCommunication() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: .seconds(2))
        timer?.setEventHandler { [weak self] in
            if AppStatus.isHIDOpen == nil {
                print("hid没有🦥🦥🦥🦥🦥🦥🦥")
            } else if AppStatus.isHIDOpen == false {
                print("hid没有打开🌹🌹🌹🌹")
            } else {
                print("打开了🐯🐯🐯🐯🐯")
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
            
            // 打开 HID Manager
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess {
                print("Failed to open HID Manager")
                return
            }
            
            // 获取匹配的设备
            if let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let matchedDevice = deviceSet.first {
                // 尝试打开设备
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

    // 关闭HID设备
    func closeHID() {
        // 关闭 HID Device
        if let device = self.device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        // 关闭 HID Manager
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        print("HID Manager closed")
    }

    // 读取 HID 报告
    func readHIDReport() {
        guard let device = self.device else { return }

        var report = [UInt8](repeating: 0, count: 9)  // 创建一个9字节的缓冲区
        var reportLength = report.count
        // 从设备读取输入报告
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(0), &report, &reportLength)
        if result == kIOReturnSuccess {
            print("HID Report read: \(report)")
        } else {
            print("Failed to read HID Report")
        }
    }

    // 向设备发送 HID 报告
    func sendHIDReport(report: [UInt8]) {
        guard let device = self.device else { return }
        var report = report

        // 向设备发送输出报告
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(0), &report, report.count)
        if result == kIOReturnSuccess {
            print("HID Report sent: \(report)")
        } else {
            print("Failed to send HID Report")
        }
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
