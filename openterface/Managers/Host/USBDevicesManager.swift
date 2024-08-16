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
}
