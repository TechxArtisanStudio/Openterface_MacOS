//
//  WCHLibusbTransport.swift
//  openterface
//
//  USB Transport implementation using libusb-1.0.
//  Works with modern macOS USB stack (AppleUSBHost/IOUSBHost).
//  Requires the WCH bootloader device (VID 0x4348 or 0x1a86, PID 0x55e0).
//
//  NOTE: libusb must be available at /opt/homebrew/lib/libusb-1.0.dylib.
//  For distribution, embed the dylib in the app bundle's Frameworks directory
//  and run `install_name_tool` to fix up the rpath.
//

import Foundation

/// Information about a scanned WCH bootloader device
struct ScannedDevice: Identifiable {
    let id: Int           // index in libusb device list (used for connect)
    let busNumber: UInt8
    let deviceAddress: UInt8
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let manufacturer: String?
    let product: String?
    let portPath: [UInt8]  // USB port topology path

    var displayName: String {
        // Prefer product name + port path for user-friendly identification
        let prod = product ?? "WCH Device"
        let port = portPath.map { String($0) }.joined(separator: "-")
        if let serial = serialNumber, !serial.isEmpty {
            return "\(prod) [Port \(port), S/N: \(serial)]"
        }
        return "\(prod) [Port \(port)]"
    }

    var detailedInfo: String {
        var info = "VID: 0x\(String(format: "%04X", vendorID)) PID: 0x\(String(format: "%04X", productID))"
        info += "\nBus: \(busNumber) Address: \(deviceAddress)"
        info += "\nPort Path: \(portPath.map { String($0) }.joined(separator: "-"))"
        if let mfr = manufacturer { info += "\nManufacturer: \(mfr)" }
        if let prod = product { info += "\nProduct: \(prod)" }
        if let serial = serialNumber, !serial.isEmpty { info += "\nSerial: \(serial)" }
        return info
    }
}

/// USB transport using libusb-1.0. Replaces the IOKit-based WCHUSBTransport
/// which fails on macOS 12+ when the device is driven by AppleUSBHost.
class WCHLibusbTransport: WCHTransport {

    // MARK: – Constants

    private static let vendorIDs: [UInt16]  = [0x4348, 0x1a86]
    private static let productID: UInt16    = 0x55e0
    private static let endpointOut: UInt8   = 0x02
    private static let endpointIn: UInt8    = 0x82
    private static let usbTimeoutMs: UInt32 = 5_000
    private static let maxPacketSize: Int   = 64

    // MARK: – State

    private var context:      OpaquePointer?
    private var deviceHandle: OpaquePointer?

    // MARK: – Static helpers

    /// Returns information about all WCH bootloader devices currently attached.
    static func scanDevices() -> [ScannedDevice] {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] Failed to initialise libusb")
            return []
        }
        defer { libusb_exit(ctx) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let deviceList = list else { return [] }
        defer { libusb_free_device_list(deviceList, 1) }

        var devices: [ScannedDevice] = []
        var matchIndex = 0
        for i in 0..<count {
            guard let dev = deviceList[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LIBUSB_SUCCESS.rawValue else { continue }
            if vendorIDs.contains(desc.idVendor) && desc.idProduct == productID {
                let bus = libusb_get_bus_number(dev)
                let addr = libusb_get_device_address(dev)

                // Get port path (physical USB topology)
                var portNumbers = [UInt8](repeating: 0, count: 7)
                let portCount = libusb_get_port_numbers(dev, &portNumbers, Int32(portNumbers.count))
                let portPath = portCount > 0 ? Array(portNumbers.prefix(Int(portCount))) : []

                // Open device to read string descriptors
                var handle: OpaquePointer?
                let opened = libusb_open(dev, &handle) == LIBUSB_SUCCESS.rawValue
                let h = opened ? handle : nil

                // Read manufacturer string
                var manufacturer: String? = nil
                if let h = h, desc.iManufacturer > 0 {
                    var buf = [UInt8](repeating: 0, count: 256)
                    let rc = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
                        libusb_get_string_descriptor_ascii(h, desc.iManufacturer, ptr.baseAddress!, Int32(ptr.count))
                    }
                    if rc > 0 {
                        manufacturer = String(bytes: buf.prefix(Int(rc)), encoding: .ascii)
                    }
                }

                // Read product string
                var product: String? = nil
                if let h = h, desc.iProduct > 0 {
                    var buf = [UInt8](repeating: 0, count: 256)
                    let rc = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
                        libusb_get_string_descriptor_ascii(h, desc.iProduct, ptr.baseAddress!, Int32(ptr.count))
                    }
                    if rc > 0 {
                        product = String(bytes: buf.prefix(Int(rc)), encoding: .ascii)
                    }
                }

                // Read serial number
                var serial: String? = nil
                if let h = h, desc.iSerialNumber > 0 {
                    var buf = [UInt8](repeating: 0, count: 256)
                    let rc = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
                        libusb_get_string_descriptor_ascii(h, desc.iSerialNumber, ptr.baseAddress!, Int32(ptr.count))
                    }
                    if rc > 0 {
                        serial = String(bytes: buf.prefix(Int(rc)), encoding: .ascii)
                    }
                }

                if let h = h { libusb_close(h) }

                devices.append(ScannedDevice(
                    id: matchIndex,
                    busNumber: bus,
                    deviceAddress: addr,
                    vendorID: desc.idVendor,
                    productID: desc.idProduct,
                    serialNumber: serial,
                    manufacturer: manufacturer,
                    product: product,
                    portPath: portPath
                ))
                print("[WCHLibusbTransport] Found WCH device #\(matchIndex): bus=\(bus) addr=\(addr) port=\(portPath.map { String($0) }.joined(separator: "-")) vid=0x\(String(desc.idVendor, radix: 16)) pid=0x\(String(desc.idProduct, radix: 16)) mfr=\(manufacturer ?? "N/A") prod=\(product ?? "N/A") serial=\(serial ?? "N/A")")
                matchIndex += 1
            }
        }
        return devices
    }

    // MARK: – Init / deinit

    init(deviceIndex: Int = 0) throws {
        print("[WCHLibusbTransport] Initialising libusb transport (deviceIndex=\(deviceIndex))…")

        guard libusb_init(&context) == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] libusb_init failed")
            throw WCHTransportError.deviceOpenFailed
        }

        // --- enumerate devices ---
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let total = libusb_get_device_list(context, &list)
        guard total > 0, let deviceList = list else {
            print("[WCHLibusbTransport] No USB devices found")
            libusb_exit(context)
            throw WCHTransportError.deviceNotFound
        }
        defer { libusb_free_device_list(deviceList, 1) }

        var matchIndex  = 0
        var targetDevice: OpaquePointer?

        for i in 0..<total {
            guard let dev = deviceList[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LIBUSB_SUCCESS.rawValue else { continue }

            if Self.vendorIDs.contains(desc.idVendor) && desc.idProduct == Self.productID {
                if matchIndex == deviceIndex {
                    targetDevice = dev
                    break
                }
                matchIndex += 1
            }
        }

        guard let device = targetDevice else {
            print("[WCHLibusbTransport] WCH device at index \(deviceIndex) not found")
            libusb_exit(context)
            throw WCHTransportError.deviceNotFound
        }

        // --- open device ---
        var handle: OpaquePointer?
        let openResult = libusb_open(device, &handle)
        guard openResult == LIBUSB_SUCCESS.rawValue, let devHandle = handle else {
            print("[WCHLibusbTransport] libusb_open failed (\(openResult))")
            libusb_exit(context)
            throw WCHTransportError.deviceOpenFailed
        }
        self.deviceHandle = devHandle

        // --- detach kernel driver if active (no-op on macOS usually) ---
        if libusb_kernel_driver_active(devHandle, 0) == 1 {
            let r = libusb_detach_kernel_driver(devHandle, 0)
            if r != LIBUSB_SUCCESS.rawValue {
                print("[WCHLibusbTransport] WARNING: detach kernel driver failed (\(r)) – continuing")
            }
        }

        // --- set configuration 1 ---
        let cfgResult = libusb_set_configuration(devHandle, 1)
        if cfgResult != LIBUSB_SUCCESS.rawValue {
            print("[WCHLibusbTransport] WARNING: set_configuration failed (\(cfgResult)) – continuing")
        }

        // --- claim interface 0 ---
        let claimResult = libusb_claim_interface(devHandle, 0)
        guard claimResult == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] libusb_claim_interface failed (\(claimResult))")
            libusb_close(devHandle)
            libusb_exit(context)
            throw WCHTransportError.interfaceOpenFailed
        }

        print("[WCHLibusbTransport] Device opened and interface 0 claimed")
    }

    deinit {
        if let handle = deviceHandle {
            libusb_release_interface(handle, 0)
            libusb_close(handle)
            print("[WCHLibusbTransport] Device closed")
        }
        if let ctx = context {
            libusb_exit(ctx)
            print("[WCHLibusbTransport] libusb context released")
        }
    }

    // MARK: – WCHTransport

    func sendRaw(_ data: [UInt8]) throws {
        guard let handle = deviceHandle else {
            throw WCHTransportError.writeFailed
        }

        var buf = data
        var transferred: Int32 = 0
        let result = buf.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return libusb_bulk_transfer(handle, Self.endpointOut, base, Int32(data.count), &transferred, Self.usbTimeoutMs)
        }
        guard result == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] Bulk write failed (\(result), transferred=\(transferred))")
            throw WCHTransportError.writeFailed
        }
    }

    func receiveRaw(timeout: TimeInterval) throws -> [UInt8] {
        guard let handle = deviceHandle else {
            throw WCHTransportError.readFailed
        }

        var buf = [UInt8](repeating: 0, count: Self.maxPacketSize)
        var transferred: Int32   = 0
        let timeoutMs            = UInt32(timeout * 1_000)
        let bufCount             = buf.count

        let result = buf.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return libusb_bulk_transfer(handle, Self.endpointIn, base, Int32(bufCount), &transferred, timeoutMs)
        }

        if result == LIBUSB_ERROR_TIMEOUT.rawValue {
            print("[WCHLibusbTransport] Read timeout")
            throw WCHTransportError.timeout
        }
        guard result == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] Bulk read failed (\(result), transferred=\(transferred))")
            throw WCHTransportError.readFailed
        }
        return Array(buf.prefix(Int(transferred)))
    }

    func transfer(command: WCHCommand) throws -> WCHResponse {
        try sendRaw(command.toRawBytes())
        let bytes = try receiveRaw(timeout: TimeInterval(Self.usbTimeoutMs) / 1_000.0)
        logReceive(bytes)
        return try WCHResponse.fromRawBytes(bytes)
    }

    func transfer(command: WCHCommand, timeout: TimeInterval) throws -> WCHResponse {
        try sendRaw(command.toRawBytes())
        let bytes = try receiveRaw(timeout: timeout)
        logReceive(bytes)
        return try WCHResponse.fromRawBytes(bytes)
    }

    func dumpFirmware(flashSize: UInt32, progressCallback: ((Double) -> Void)?) throws -> [UInt8] {
        print("[WCHLibusbTransport] Dumping \(flashSize) bytes from code flash…")
        var firmware  = [UInt8]()
        let chunkSize = 56
        var address: UInt32 = 0

        while address < flashSize {
            let toRead    = Int(min(UInt32(chunkSize), flashSize - address))
            let response  = try transfer(command: .dataRead(address: address, length: UInt16(toRead)))
            guard case .ok(let payload) = response, !payload.isEmpty else {
                print("[WCHLibusbTransport] Bad read response at 0x\(String(address, radix: 16))")
                throw WCHTransportError.readFailed
            }
            firmware.append(contentsOf: payload)
            address += UInt32(toRead)
            progressCallback?(Double(address) / Double(flashSize))
        }
        print("[WCHLibusbTransport] Dump complete: \(firmware.count) bytes")
        return firmware
    }

    // MARK: – Private helpers

    private func logReceive(_ bytes: [UInt8]) {
        let addr = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let data = bytes.dropFirst(4).map { String(format: "%02x", $0) }.joined()
        print("Receive <= \(addr) \(data)")
    }
}
