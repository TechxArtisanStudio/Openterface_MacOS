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

class USBDeivcesManager {
    // Singleton instance
    static let shared = USBDeivcesManager()
    
    func update() {
        // get usb devices info
        let _d: [USBDeviceInfo] = getUSBDevices()
        
        // 
        if !_d.isEmpty {
            AppStatus.USBDevices = _d
        } else {
            print("No USB devices found")
            // 处理无设备情况，例如记录日志或显示错误提示
            Logger.shared.log(content: "No USB devices found")
        }
        groundByOpenterface()
    }
    
    func getUSBDevices() -> [USBDeviceInfo] {
        var devices = [USBDeviceInfo]()
        
        let masterPort: mach_port_t = kIOMainPortDefault
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(masterPort, matchingDict, &iterator)
        if kr != KERN_SUCCESS {
            print("Error: Unable to get matching services")
            return devices
        }

        while case let usbDevice = IOIteratorNext(iterator), usbDevice != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(usbDevice)
            }
           
            // USB Product Name
            let productName = IORegistryEntryCreateCFProperty(usbDevice, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "Unknow"

            // VendorID
            let vendorID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0

            // ProductID
            let productID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBProductID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0

            // LocationID
            let locationID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBDevicePropertyLocationID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            let locationIDString = String(format: "0x%08x", locationID)

            let deviceInfo = USBDeviceInfo(productName: productName, vendorID: vendorID, productID: productID, locationID: locationIDString)
            devices.append(deviceInfo)
        }
        
        IOObjectRelease(iterator)
        return devices
    }
    
    func groundByOpenterface() {
        var groupedDevices: [[USBDeviceInfo]] = []
        var tempGroup: [USBDeviceInfo]?
        
        for device in AppStatus.USBDevices {
            if device.productName.contains("Openterface") {
                if tempGroup == nil {
                    tempGroup = []
                }
                tempGroup?.append(device)
            }
        }

        if let validTempGroup = tempGroup {
            for device in validTempGroup {
                let ex_ = trimHexString(removeTrailingZeros(from: device.locationID))
                
                for _d in AppStatus.USBDevices {
                    if _d.locationID.hasPrefix(ex_) {

                        // First check if there is already a group with that prefix
                        if let index = groupedDevices.firstIndex(where: { $0.first?.locationID.hasPrefix(ex_) == true }) {
                            groupedDevices[index].append(_d)
                        } else {
                            // Create a new array to add to groups
                            groupedDevices.append([_d])
                        }
                    }
                }
            }
            if !groupedDevices.isEmpty {
                AppStatus.groupOpenterfaceDevices = groupedDevices
            }
            
            
            //setting default video and serial device
            if !groupedDevices.isEmpty {
                if let defaultGroup = groupedDevices.first {
                    let defaultVideoDevice = defaultGroup.first { $0.productName.contains("Openterface") }
                    let defaultSerialDevice = defaultGroup.first { $0.productName.contains("Serial") }
                    
                    AppStatus.DefaultVideoDevice = defaultVideoDevice
                    AppStatus.DefaultUSBSerial = defaultSerialDevice
                }
            }
        } else {
            print("tempGroup is nil")
        }
    }
    
    func removeTrailingZeros(from hexString: String) -> String {
        guard hexString.hasPrefix("0x") else {
            return hexString // 保持原样，如果字符串不以 "0x" 开头
        }

        let hexPrefix = "0x"
        var hexWithoutPrefix = String(hexString.dropFirst(hexPrefix.count))
        
        while hexWithoutPrefix.last == "0" {
            hexWithoutPrefix = String(hexWithoutPrefix.dropLast())
        }
        
        return hexPrefix + hexWithoutPrefix
    }
    
    func trimHexString(_ hexString: String) -> String {
        guard hexString.hasPrefix("0x") else {
            return hexString  // 保持原样，如果字符串不以 "0x" 开头
        }
        
        let hexPrefix = "0x"
        let hexWithoutPrefix = String(hexString.dropFirst(hexPrefix.count))
        
        // delete last 
        let trimmedHex = String(hexWithoutPrefix.dropLast())
        
        return hexPrefix + trimmedHex
    }
}
