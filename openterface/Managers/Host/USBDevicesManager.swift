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

@available(macOS 12.0, *)
class USBDevicesManager: USBDevicesManagerProtocol {
    private var  logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    // Singleton instance
    static let shared = USBDevicesManager()
    let MS2019_VID = MS2109VideoChipset.VENDOR_ID
    let MS2019_PID = MS2109VideoChipset.PRODUCT_ID

    let MS2019S_VID = MS2109SVideoChipset.VENDOR_ID
    let MS2019S_PID = MS2109SVideoChipset.PRODUCT_ID
    
    let MS2130S_VID = MS2130SVideoChipset.VENDOR_ID
    let MS2130S_PID = MS2130SVideoChipset.PRODUCT_ID

    let WCH_VID = 0x1A86
    let CH9329_PID = 0x7523
    let CH32V208_PID = 0xFE0C
    
    // Hold references to specific chipset devices
    var videoChipDevice: USBDeviceInfo?
    var controlChipDevice: USBDeviceInfo?
    
    init(){
        self.update()
    }
    
    func update() {
        // get usb devices info
        let _d: [USBDeviceInfo] = getUSBDevices()
        
        // 
        if !_d.isEmpty {
            AppStatus.USBDevices = _d
        } else {
            logger.log(content: "USB device scan completed: No USB devices detected on the system")
            logger.log(content: "No USB devices found")
        }
        groundByOpenterface()
        
        // Update chipset type flag after grouping devices
        updateChipsetTypeFlag()
    }
    
    func getUSBDevices() -> [USBDeviceInfo] {
        var devices = [USBDeviceInfo]()
        
        let masterPort: mach_port_t = kIOMainPortDefault
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(masterPort, matchingDict, &iterator)
        if kr != KERN_SUCCESS {
            logger.log(content: "Failed to get matching USB services. This may indicate issues with USB device enumeration or system permissions.")
            return devices
        }

        while case let usbDevice = IOIteratorNext(iterator), usbDevice != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(usbDevice)
            }
           
            // USB Product Name
            var productName = IORegistryEntryCreateCFProperty(usbDevice, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "Unknown"

            // USB Vendor Name (Manufacturer)
            let manufacturer = IORegistryEntryCreateCFProperty(usbDevice, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "Unknown"

            // VendorID
            let vendorID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBVendorID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0

            // ProductID
            let productID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBProductID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0

            // LocationID (read early so we can use it for device lookup)
            let locationID = (IORegistryEntryCreateCFProperty(usbDevice, kUSBDevicePropertyLocationID as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            let locationIDString = String(format: "0x%08x", locationID)

            if isOpenterfaceVideoChipset(vendorId: vendorID, productId: productID) && !productName.contains("Openterface") {
                // Check if this device already has an updated product name in AppStatus
                // (e.g., from EEPROM read during chipset initialization)
                if let existingDevice = AppStatus.USBDevices.first(where: { device in
                    device.vendorID == vendorID &&
                    device.productID == productID &&
                    device.locationID == locationIDString
                }) {
                    // Use the existing product name from AppStatus if it's not "Unknown Capture Card"
                    if !existingDevice.productName.contains("Unknown Capture") {
                        productName = existingDevice.productName
                    } else {
                        productName = "Unknown Capture Card"
                    }
                } else {
                    productName = "Unknown Capture Card"
                }
            }
                
            // USB Speed
            let speedValue = (IORegistryEntryCreateCFProperty(usbDevice, kUSBDevicePropertySpeed as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            let speedString = formatUSBSpeed(speedValue)

            let deviceInfo = USBDeviceInfo(productName: productName, manufacturer: manufacturer, vendorID: vendorID, productID: productID, locationID: locationIDString, speed: speedString)
            devices.append(deviceInfo)
        }
        
        IOObjectRelease(iterator)
        return devices
    }
    
    /// Format USB speed value into human-readable string
    /// - Parameter speed: The speed value from IORegistry
    /// - Returns: Human-readable speed string
    private func formatUSBSpeed(_ speed: Int) -> String {
        switch speed {
        case 0:
            return "Low Speed (1.5 Mbps)"
        case 1:
            return "Full Speed (12 Mbps)"
        case 2:
            return "High Speed (480 Mbps)"
        case 3:
            return "Super Speed (5 Gbps)"
        case 4:
            return "Super Speed+ (10 Gbps)"
        case 5:
            return "Super Speed+ (20 Gbps)"
        default:
            return "Unknown (\(speed))"
        }
    }
    
    func isOpenterfaceVideoChipset(vendorId:Int, productId:Int) -> Bool{
        return (vendorId == MS2019_VID && productId == MS2019_PID) ||
            (vendorId == MS2019S_VID && productId == MS2019S_PID) ||
            (vendorId == MS2130S_VID && productId == MS2130S_PID)
    }

    func isOpenterfaceControlChipset(vendorId:Int, productId:Int) -> Bool{
        return (vendorId == WCH_VID && productId == CH9329_PID) || (vendorId == WCH_VID && productId == CH32V208_PID)
    }   
    
    /// Check if the device is a WCH chipset (CH9329 or CH32V208)
    /// - Parameters:
    ///   - vendorId: The vendor ID of the device
    ///   - productId: The product ID of the device
    /// - Returns: True if it's a WCH chipset, false otherwise
    func isWCHChipset(vendorId: Int, productId: Int) -> Bool {
        return (vendorId == WCH_VID && productId == CH9329_PID) || (vendorId == WCH_VID && productId == CH32V208_PID)
    }
    
    /// Check if any chipset (Openterface video or WCH control) is connected
    /// - Parameters:
    ///   - vendorId: The vendor ID of the device
    ///   - productId: The product ID of the device
    /// - Returns: True if it's any supported chipset, false otherwise
    func isAnyChipset(vendorId: Int, productId: Int) -> Bool {
        return isOpenterfaceVideoChipset(vendorId: vendorId, productId: productId) || isWCHChipset(vendorId: vendorId, productId: productId)
    }
    
    /// Determine the video chipset type based on vendor and product IDs
    /// - Parameters:
    ///   - vendorId: The vendor ID of the device
    ///   - productId: The product ID of the device
    /// - Returns: The corresponding VideoChipsetType
    func getVideoChipsetType(vendorId: Int, productId: Int) -> VideoChipsetType {
        if vendorId == MS2019_VID && productId == MS2019_PID {
            return .ms2109
        } else if vendorId == MS2130S_VID && productId == MS2130S_PID {
            return .ms2130s
        } else {
            return .unknown
        }
    }
    
    /// Determine the control chipset type based on vendor and product IDs
    /// - Parameters:
    ///   - vendorId: The vendor ID of the device
    ///   - productId: The product ID of the device
    /// - Returns: The corresponding ControlChipsetType
    func getControlChipsetType(vendorId: Int, productId: Int) -> ControlChipsetType {
        if vendorId == WCH_VID && productId == CH9329_PID {
            return .ch9329
        } else if vendorId == WCH_VID && productId == CH32V208_PID {
            return .ch32v208
        } else {
            return .unknown
        }
    }
    
    /// Update the global chipset type flags based on connected devices
    private func updateChipsetTypeFlag() {
        // Reset to unknown first
        AppStatus.videoChipsetType = .unknown
        AppStatus.controlChipsetType = .unknown
        
        // Reset device references
        videoChipDevice = nil
        controlChipDevice = nil
        
        // Check grouped Openterface devices first
        for deviceGroup in AppStatus.groupOpenterfaceDevices {
            for device in deviceGroup {
                let videoType = getVideoChipsetType(vendorId: device.vendorID, productId: device.productID)
                let controlType = getControlChipsetType(vendorId: device.vendorID, productId: device.productID)
                
                if videoType != .unknown && videoChipDevice == nil {
                    AppStatus.videoChipsetType = videoType
                    videoChipDevice = device
                    logger.log(content: "Detected video chipset type: \(videoType)")
                }
                
                if controlType != .unknown && controlChipDevice == nil {
                    AppStatus.controlChipsetType = controlType
                    controlChipDevice = device
                    logger.log(content: "Detected control chipset type: \(controlType)")
                }
            }
        }
        
        // If no grouped devices, check all USB devices for any supported chipset
        for device in AppStatus.USBDevices {
            let videoType = getVideoChipsetType(vendorId: device.vendorID, productId: device.productID)
            let controlType = getControlChipsetType(vendorId: device.vendorID, productId: device.productID)
            
            if videoType != .unknown && videoChipDevice == nil {
                AppStatus.videoChipsetType = videoType
                videoChipDevice = device
                logger.log(content: "Detected video chipset type: \(videoType)")
            }
            
            if controlType != .unknown && controlChipDevice == nil {
                AppStatus.controlChipsetType = controlType
                controlChipDevice = device
                logger.log(content: "Detected control chipset type: \(controlType)")
            }
        }
        
        if AppStatus.videoChipsetType == .unknown && AppStatus.controlChipsetType == .unknown {
            logger.log(content: "No supported chipsets detected")
        }
    }
    
    /// Check if any Openterface devices are currently connected
    /// - Returns: True if at least one supported device (Openterface or WCH) is connected, false otherwise
    func isOpenterfaceConnected() -> Bool {
        // Check if there are any grouped Openterface devices
        if !AppStatus.groupOpenterfaceDevices.isEmpty {
            return true
        }
        
        // Alternative check: scan USB devices for any supported chipsets (Openterface or WCH)
        for device in AppStatus.USBDevices {
            if isOpenterfaceVideoChipset(vendorId: device.vendorID, productId: device.productID) {
                return true
            }
        }
        
        return false
    }
    
    /// Get the count of connected Openterface devices
    /// - Returns: Number of Openterface device groups connected
    func getOpenterfaceDeviceCount() -> Int {
        return AppStatus.groupOpenterfaceDevices.count
    }
    
    /// Check if the currently connected device is MS2109 video chipset
    /// - Returns: True if MS2109 is connected, false otherwise
    func isMS2109Connected() -> Bool {
        return AppStatus.videoChipsetType == .ms2109
    }
    
    /// Check if the currently connected device is MS2130S video chipset
    /// - Returns: True if MS2130S is connected, false otherwise
    func isMS2130SConnected() -> Bool {
        return AppStatus.videoChipsetType == .ms2130s
    }
    
    /// Check if the currently connected device is CH9329 control chipset
    /// - Returns: True if CH9329 is connected, false otherwise
    func isCH9329Connected() -> Bool {
        return AppStatus.controlChipsetType == .ch9329
    }
    
    /// Check if the currently connected device is CH32V208 control chipset
    /// - Returns: True if CH32V208 is connected, false otherwise
    func isCH32V208Connected() -> Bool {
        return AppStatus.controlChipsetType == .ch32v208
    }
    
    /// Check if any video chipset (MS2109 or MS2130S) is connected
    /// - Returns: True if any video chipset is connected, false otherwise
    func isVideoChipsetConnected() -> Bool {
        return AppStatus.videoChipsetType != .unknown
    }
    
    /// Check if any control chipset (CH9329 or CH32V208) is connected
    /// - Returns: True if any control chipset is connected, false otherwise
    func isControlChipsetConnected() -> Bool {
        return AppStatus.controlChipsetType != .unknown
    }
    
    /// Check if any WCH chipset (CH9329 or CH32V208) is connected
    /// - Returns: True if any WCH chipset is connected, false otherwise
    func isWCHConnected() -> Bool {
        return isCH9329Connected() || isCH32V208Connected()
    }
    
    /// Get the current video chipset type as a string for logging or display
    /// - Returns: String representation of the current video chipset type
    func getCurrentVideoChipsetTypeString() -> String {
        switch AppStatus.videoChipsetType {
        case .ms2109:
            return "MS2109"
        case .ms2109s:
            return "MS2109S"
        case .ms2130s:
            return "MS2130S"
        case .unknown:
            return "Unknown"
        }
    }
    
    /// Get the current control chipset type as a string for logging or display
    /// - Returns: String representation of the current control chipset type
    func getCurrentControlChipsetTypeString() -> String {
        switch AppStatus.controlChipsetType {
        case .ch9329:
            return "CH9329"
        case .ch32v208:
            return "CH32V208"
        case .unknown:
            return "Unknown"
        }
    }
    
    /// Get both chipset types as a combined string for logging or display
    /// - Returns: String representation of both chipset types
    func getCurrentChipsetTypesString() -> String {
        let video = getCurrentVideoChipsetTypeString()
        let control = getCurrentControlChipsetTypeString()
        return "Video: \(video), Control: \(control)"
    }
    
    /// Get the current video chip USB device
    /// - Returns: The USB device info for the video chip, or nil if not found
    func getVideoChipDevice() -> USBDeviceInfo? {
        return videoChipDevice
    }
    
    /// Get the current control chip USB device
    /// - Returns: The USB device info for the control chip, or nil if not found
    func getControlChipDevice() -> USBDeviceInfo? {
        return controlChipDevice
    }
    
    /// Get the video chip device's location ID
    /// - Returns: The location ID string of the video chip, or nil if not found
    func getVideoChipLocationID() -> String? {
        return videoChipDevice?.locationID
    }
    
    /// Get the control chip device's location ID
    /// - Returns: The location ID string of the control chip, or nil if not found
    func getControlChipLocationID() -> String? {
        return controlChipDevice?.locationID
    }
    
    /// Get the video chip device's product name
    /// - Returns: The product name of the video chip, or nil if not found
    func getVideoChipProductName() -> String? {
        return videoChipDevice?.productName
    }
    
    /// Get the control chip device's product name
    /// - Returns: The product name of the control chip, or nil if not found
    func getControlChipProductName() -> String? {
        return controlChipDevice?.productName
    }
    
    /// Get the serial device path that should be used for the current control chipset
    /// - Returns: A string hint for the serial device, or nil if not available
    func getExpectedSerialDevicePath() -> String? {
        // For control chips, try to get the associated serial device
        if let controlDevice = controlChipDevice {
            logger.log(content: "Control chip device detected: \(controlDevice.productName) at \(controlDevice.locationID)")
            
            // Look for devices in the same group that contain "Serial" in the name
            for deviceGroup in AppStatus.groupOpenterfaceDevices {
                if deviceGroup.contains(where: { $0.locationID == controlDevice.locationID }) {
                    if let serialDevice = deviceGroup.first(where: { $0.productName.contains("Serial") }) {
                        logger.log(content: "Found associated serial device: \(serialDevice.productName)")
                        return serialDevice.locationID // Return as hint, actual correlation is handled in SerialPortManager
                    }
                }
            }
        }
        
        // If no control chip specific serial device found, search all groups for any serial device
        for deviceGroup in AppStatus.groupOpenterfaceDevices {
            if let serialDevice = deviceGroup.first(where: { $0.productName.contains("Serial") }) {
                logger.log(content: "Found serial device in group: \(serialDevice.productName)")
                return serialDevice.locationID
            }
        }
        
        // Fallback to default USB serial device
        if let defaultSerial = AppStatus.DefaultUSBSerial {
            logger.log(content: "Using default USB serial device: \(defaultSerial.productName)")
            return defaultSerial.locationID
        }
        
        return nil
    }

    func groundByOpenterface() {
        var groupedDevices: [[USBDeviceInfo]] = []
        var tempGroup: [USBDeviceInfo]?
        
        if tempGroup == nil {
            tempGroup = []
        }
        for device in AppStatus.USBDevices {
            if isOpenterfaceVideoChipset(vendorId: device.vendorID, productId: device.productID) {
                tempGroup?.append(device)
            }
            if isOpenterfaceControlChipset(vendorId: device.vendorID, productId: device.productID) {
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
                logger.log(content: "Created \(groupedDevices.count) device groups:")
                for (index, group) in groupedDevices.enumerated() {
                    logger.log(content: "Group \(index + 1): \(group.map { $0.productName }.joined(separator: ", "))")
                }
            }
            
            //setting default video and serial device from all groups
            if !groupedDevices.isEmpty {
                var defaultVideoDevice: USBDeviceInfo?
                var defaultSerialDevice: USBDeviceInfo?
                
                // Search through all groups to find video and serial devices
                for group in groupedDevices {
                    // Look for video device if not found yet
                    if defaultVideoDevice == nil {
                        defaultVideoDevice = group.first { $0.productName.contains("Openterface") || $0.productName.contains("Unknown Capture")}
                    }
                    
                    // Look for serial device if not found yet
                    if defaultSerialDevice == nil {
                        defaultSerialDevice = group.first { $0.productName.contains("Serial") }
                    }
                    
                    // If both found, no need to continue searching
                    if defaultVideoDevice != nil && defaultSerialDevice != nil {
                        break
                    }
                }
                
                AppStatus.DefaultVideoDevice = defaultVideoDevice
                AppStatus.DefaultUSBSerial = defaultSerialDevice
                
                logger.log(content: "Found \(groupedDevices.count) device groups, default video: \(defaultVideoDevice?.productName ?? "none"), default serial: \(defaultSerialDevice?.productName ?? "none")")
            }
        } else {
            logger.log(content: "No supported devices found in USB device list")
        }
    }
    
    func removeTrailingZeros(from hexString: String) -> String {
        guard hexString.hasPrefix("0x") else {
            return hexString
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
            return hexString
        }
        
        let hexPrefix = "0x"
        let hexWithoutPrefix = String(hexString.dropFirst(hexPrefix.count))
        
        // delete last 
        let trimmedHex = String(hexWithoutPrefix.dropLast())
        
        return hexPrefix + trimmedHex
    }
    
    /// Get information about all device groups
    /// - Returns: Array of tuples containing group index and device count
    func getDeviceGroupsInfo() -> [(groupIndex: Int, deviceCount: Int, devices: [USBDeviceInfo])] {
        return AppStatus.groupOpenterfaceDevices.enumerated().map { index, group in
            (groupIndex: index + 1, deviceCount: group.count, devices: group)
        }
    }
    
    /// Get the total number of devices across all groups
    /// - Returns: Total device count
    func getTotalDeviceCount() -> Int {
        return AppStatus.groupOpenterfaceDevices.reduce(0) { total, group in
            total + group.count
        }
    }
    
    /// Find which group contains a specific device
    /// - Parameter device: The USB device to search for
    /// - Returns: The group index (1-based) containing the device, or nil if not found
    func findGroupContaining(device: USBDeviceInfo) -> Int? {
        for (index, group) in AppStatus.groupOpenterfaceDevices.enumerated() {
            if group.contains(where: { $0.locationID == device.locationID }) {
                return index + 1 // Return 1-based index
            }
        }
        return nil
    }
}
