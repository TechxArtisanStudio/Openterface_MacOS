/*
 * WCH ISP USB Transport - IOKit bulk transfer implementation
 * Ported from wchisp-mac/Transport/USBTransport.swift
 *
 * NOTE: Requires IOKit USB interface. On modern macOS (12+) with the
 * AppleUSBHost stack, this transport may fail to find the IOUSBInterface.
 * In that case, install the included codeless kext or use a WCH-link tool
 * to force the device onto the legacy IOUSBFamily stack.
 */

import Foundation
import IOKit
import IOKit.usb

class WCHUSBTransport: WCHTransport {
    static let vendorIDs: [UInt16] = [0x4348, 0x1a86]
    static let productID: UInt16 = 0x55e0

    private static let endpointOut: UInt8 = 0x02
    private static let endpointIn: UInt8 = 0x82
    private static let timeoutMs: UInt32 = 5000
    private static let maxPacketSize = 64

    private var deviceService: io_service_t = 0
    private var plugInInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    private var deviceInterface: UnsafeMutablePointer<IOUSBDeviceInterface182>?
    private var interfaceInterface: UnsafeMutablePointer<IOUSBInterfaceInterface300>?

    // MARK: - Scan

    static func scanDevices() -> Int {
        guard let matchDict = IOServiceMatching(kIOUSBDeviceClassName) else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var count = 0
        var device = IOIteratorNext(iterator)
        while device != 0 {
            defer { IOObjectRelease(device); device = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(device, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let vid = (dict[kUSBVendorID as String] as? NSNumber)?.uint16Value,
                  let pid = (dict[kUSBProductID as String] as? NSNumber)?.uint16Value else { continue }
            if vendorIDs.contains(vid) && pid == productID { count += 1 }
        }
        return count
    }

    // MARK: - Init

    init(deviceIndex: Int = 0) throws {
        guard let matchDict = IOServiceMatching(kIOUSBDeviceClassName) else {
            throw WCHTransportError.deviceOpenFailed
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            throw WCHTransportError.deviceOpenFailed
        }
        defer { IOObjectRelease(iterator) }

        var foundIndex = 0
        var device = IOIteratorNext(iterator)
        while device != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(device, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let vid = (dict[kUSBVendorID as String] as? NSNumber)?.uint16Value,
               let pid = (dict[kUSBProductID as String] as? NSNumber)?.uint16Value,
               Self.vendorIDs.contains(vid) && pid == Self.productID {
                if foundIndex == deviceIndex {
                    deviceService = device
                    break
                }
                foundIndex += 1
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }

        guard deviceService != 0 else { throw WCHTransportError.deviceNotFound }
        try openUSBDevice()
    }

    // MARK: - Open device + interface

    private func openUSBDevice() throws {
        // UUIDs for IOKit plug-in interfaces
        let deviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
            nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
            0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
        let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(
            nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let deviceInterfaceID182 = CFUUIDGetConstantUUIDWithBytes(
            nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xd4,
            0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

        var plugInPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(deviceService, deviceUserClientTypeID, plugInInterfaceID,
                                               &plugInPtr, &score) == KERN_SUCCESS,
              let plugIn = plugInPtr else {
            throw WCHTransportError.interfaceCreationFailed
        }
        plugInInterface = plugIn

        var devInterfacePtr: UnsafeMutablePointer<IOUSBDeviceInterface182>?
        let qr = withUnsafeMutablePointer(to: &devInterfacePtr) { ptr in
            plugIn.pointee!.pointee.QueryInterface(
                plugIn, CFUUIDGetUUIDBytes(deviceInterfaceID182),
                UnsafeMutablePointer<LPVOID?>(OpaquePointer(ptr)))
        }
        guard qr == S_OK, let devInterface = devInterfacePtr else {
            _ = plugIn.pointee?.pointee.Release(plugIn)
            throw WCHTransportError.interfaceCreationFailed
        }
        deviceInterface = devInterface

        // Find the IOUSBInterface child service
        guard let ifMatchDict = IOServiceMatching(kIOUSBInterfaceClassName) else {
            throw WCHTransportError.interfaceCreationFailed
        }
        var ifIterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, ifMatchDict, &ifIterator) == KERN_SUCCESS else {
            throw WCHTransportError.interfaceCreationFailed
        }
        defer { IOObjectRelease(ifIterator) }

        var interfaceService: io_service_t = 0
        var service = IOIteratorNext(ifIterator)
        var totalScanned = 0
        while service != 0 {
            totalScanned += 1
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                if IOObjectIsEqualTo(parent, deviceService) != 0 {
                    interfaceService = service
                    IOObjectRelease(parent)
                    break
                }
                IOObjectRelease(parent)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(ifIterator)
        }

        if interfaceService == 0 && totalScanned == 0 {
            print("[WCH] Device uses AppleUSBHost (modern USB stack). IOUSBInterface not found.")
            print("[WCH] For bulk transfer access, a codeless kext matching VID/PID to IOUSBFamily is required.")
            throw WCHTransportError.interfaceCreationFailed
        }
        guard interfaceService != 0 else { throw WCHTransportError.interfaceCreationFailed }
        defer { IOObjectRelease(interfaceService) }

        // UUID constants for interface plugin
        let ifUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(
            nil, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4,
            0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
        let ifInterfaceID300 = CFUUIDGetConstantUUIDWithBytes(
            nil, 0x28, 0x87, 0x79, 0xC8, 0xA8, 0xA0, 0x11, 0xD5,
            0x9D, 0x52, 0x00, 0x30, 0x65, 0xD9, 0x6C, 0x97)

        var ifPlugInPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        guard IOCreatePlugInInterfaceForService(interfaceService, ifUserClientTypeID, plugInInterfaceID,
                                               &ifPlugInPtr, &score) == KERN_SUCCESS,
              let ifPlugIn = ifPlugInPtr else {
            throw WCHTransportError.interfaceCreationFailed
        }
        defer { _ = ifPlugIn.pointee?.pointee.Release(ifPlugIn) }

        var ifInterfacePtr: UnsafeMutablePointer<IOUSBInterfaceInterface300>?
        let iqr = withUnsafeMutablePointer(to: &ifInterfacePtr) { ptr in
            ifPlugIn.pointee!.pointee.QueryInterface(
                ifPlugIn, CFUUIDGetUUIDBytes(ifInterfaceID300),
                UnsafeMutablePointer<LPVOID?>(OpaquePointer(ptr)))
        }
        guard iqr == S_OK, let ifInterface = ifInterfacePtr else {
            throw WCHTransportError.interfaceCreationFailed
        }
        interfaceInterface = ifInterface

        guard ifInterface.pointee.USBInterfaceOpen(ifInterface) == kIOReturnSuccess else {
            throw WCHTransportError.interfaceOpenFailed
        }
        print("[WCH] USB interface opened successfully")
    }

    // MARK: - Deinit

    deinit {
        if let intf = interfaceInterface {
            _ = intf.pointee.USBInterfaceClose(intf)
            _ = intf.pointee.Release(intf)
        }
        if let plug = plugInInterface {
            _ = plug.pointee?.pointee.Release(plug)
        }
        if deviceService != 0 { IOObjectRelease(deviceService) }
    }

    // MARK: - WCHTransport

    func sendRaw(_ data: [UInt8]) throws {
        guard let intf = interfaceInterface else { throw WCHTransportError.writeFailed }
        var buf = data
        let result = buf.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
            return intf.pointee.WritePipe(intf, Self.endpointOut, base, UInt32(data.count))
        }
        guard result == kIOReturnSuccess else { throw WCHTransportError.writeFailed }
    }

    func receiveRaw(timeout: TimeInterval) throws -> [UInt8] {
        guard let intf = interfaceInterface else { throw WCHTransportError.readFailed }
        var buffer = [UInt8](repeating: 0, count: Self.maxPacketSize)
        var size = UInt32(buffer.count)
        let result = buffer.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
            return intf.pointee.ReadPipe(intf, Self.endpointIn, base, &size)
        }
        let kIOUSBPipeStalled = IOReturn(bitPattern: 0xe000404f)
        if result == kIOUSBPipeStalled {
            _ = intf.pointee.ClearPipeStallBothEnds(intf, Self.endpointIn)
            throw WCHTransportError.readFailed
        }
        guard result == kIOReturnSuccess else {
            throw result == kIOReturnTimeout ? WCHTransportError.timeout : WCHTransportError.readFailed
        }
        return Array(buffer.prefix(Int(size)))
    }

    func transfer(command: WCHCommand) throws -> WCHResponse {
        try sendRaw(command.toRawBytes())
        let raw = try receiveRaw(timeout: TimeInterval(Self.timeoutMs) / 1000.0)
        return try WCHResponse.fromRawBytes(raw)
    }

    func transfer(command: WCHCommand, timeout: TimeInterval) throws -> WCHResponse {
        try sendRaw(command.toRawBytes())
        let raw = try receiveRaw(timeout: timeout)
        return try WCHResponse.fromRawBytes(raw)
    }

    func dumpFirmware(flashSize: UInt32, progressCallback: ((Double) -> Void)? = nil) throws -> [UInt8] {
        var firmware = [UInt8]()
        var address: UInt32 = 0
        while address < flashSize {
            let toRead = UInt16(min(56, Int(flashSize - address)))
            let response = try transfer(command: .dataRead(address: address, length: toRead))
            guard case .ok(let payload) = response else { throw WCHTransportError.readFailed }
            firmware.append(contentsOf: payload)
            address += UInt32(toRead)
            progressCallback?(Double(address) / Double(flashSize))
        }
        return firmware
    }
}
