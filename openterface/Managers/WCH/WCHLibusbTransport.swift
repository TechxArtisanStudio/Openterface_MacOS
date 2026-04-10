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

    /// Returns the number of WCH bootloader devices currently attached.
    static func scanDevices() -> Int {
        var ctx: OpaquePointer?
        guard libusb_init(&ctx) == LIBUSB_SUCCESS.rawValue else {
            print("[WCHLibusbTransport] Failed to initialise libusb")
            return 0
        }
        defer { libusb_exit(ctx) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let deviceList = list else { return 0 }
        defer { libusb_free_device_list(deviceList, 1) }

        var found = 0
        for i in 0..<count {
            guard let dev = deviceList[Int(i)] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == LIBUSB_SUCCESS.rawValue else { continue }
            if vendorIDs.contains(desc.idVendor) && desc.idProduct == productID {
                print("[WCHLibusbTransport] Found WCH device #\(found): vid=0x\(String(desc.idVendor, radix: 16)) pid=0x\(String(desc.idProduct, radix: 16))")
                found += 1
            }
        }
        return found
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
