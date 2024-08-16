//
//  USBDevicesManager.swift
//  openterface
//
//  Created by Shawn Ling on 2024/8/16.
//

import SwiftUI
import IOKit
import IOKit.usb
import IOKit.hid

class USBDeivcesManager {
    // Singleton instance
    static let shared = USBDeivcesManager()
    
    func update() {
        AppStatus.USBDevices = getUSBDevices()
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
            AppStatus.groupOpenterfaceDevices = groupedDevices
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
        
        // 去掉最后一位
        let trimmedHex = String(hexWithoutPrefix.dropLast())
        
        return hexPrefix + trimmedHex
    }
}
