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

import Foundation
import IOKit
import IOKit.hid

class MS2130SFlashManager {
    static let shared = MS2130SFlashManager()

    private let vendorID = MS2130SVideoChipset.VENDOR_ID
    private let productID = MS2130SVideoChipset.PRODUCT_ID
    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

    private init() {}

    private func findDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matchingDict: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            logger.log(content: "MS2130SFlashManager: no matching HID device found")
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return nil
        }

        // The MS2130S exposes multiple HID interfaces with the same VID/PID.
        // The vendor-defined interface (usagePage 0xFF00) supports 4096-byte
        // Feature reports needed for flash data transfers.  The standard interface
        // only supports small reports — sending 4096 bytes to it times out.
        // HIDTester's connect() selects the 0xFF00 interface for this reason.
        var targetDevice: IOHIDDevice?
        for device in devices {
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let maxFeature = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0
            logger.log(content: "MS2130SFlashManager: found interface usagePage=0x\(String(format: "%04X", usagePage)) usage=0x\(String(format: "%04X", usage)) maxFeature=\(maxFeature)")
            if usagePage == 0xFF00 {
                targetDevice = device
            }
        }

        // Fall back to first device if no 0xFF00 interface found
        let selected = targetDevice ?? devices.first!
        let selUsage = IOHIDDeviceGetProperty(selected, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        logger.log(content: "MS2130SFlashManager: selected interface usagePage=0x\(String(format: "%04X", selUsage))")

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return selected
    }

    private func openDevice(_ device: IOHIDDevice, seize: Bool = false) -> Bool {
        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let result = IOHIDDeviceOpen(device, options)
        if result != kIOReturnSuccess {
            logger.log(content: "MS2130SFlashManager: IOHIDDeviceOpen Failed (seize=\(seize)): \(interpretIOReturn(result))")
            return false
        }
        // Do NOT call IOHIDDeviceScheduleWithRunLoop here.
        // Scheduling forces IOHIDDeviceSetReport into an async RunLoop-based path;
        // without an actively-pumped RunLoop, large transfers (4095-byte data chunks)
        // never receive their completion callback and time out after 5 seconds.
        // HIDTester does not schedule the device and relies on the synchronous path.
        // Add settle delay to avoid race conditions on initial `setReport`.
        Thread.sleep(forTimeInterval: 0.2)
        return true
    }

    private func closeDevice(_ device: IOHIDDevice) {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func interpretIOReturn(_ result: IOReturn) -> String {
        switch result {
        case kIOReturnSuccess: return "Success"
        case kIOReturnNotOpen: return "Device not open"
        case kIOReturnNoDevice: return "No such device"
        default: return "IOReturn(\(result))"
        }
    }

    // ── Direct HID report helpers ──────────────────────────────────────────
    // Match HIDTester byte-for-byte: 9-byte buffers WITH reportID at buffer[0],
    // reportID also passed as CFIndex parameter.
    // This eliminates sendFeatureReport's 6-format retry which may confuse the device.

    private func directSetReport(device: IOHIDDevice, buffer: inout [UInt8]) -> IOReturn {
        return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(buffer[0]), &buffer, buffer.count)
    }

    private func directGetReport(device: IOHIDDevice, buffer: inout [UInt8]) -> IOReturn {
        var length = buffer.count
        return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(buffer[0]), &buffer, &length)
    }

    // Read/write 8-bit and 16-bit device registers for GPIO initialization.
    // Uses HIDTester's exact buffer format: 9 bytes, buffer[0] = reportID = 0x01.

    private func read8BitRegister(device: IOHIDDevice, address: UInt8) -> UInt8? {
        var buf: [UInt8] = [0x01, 0xC5, address, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let setResult = directSetReport(device: device, buffer: &buf)
        guard setResult == kIOReturnSuccess else {
            logger.log(content: "MS2130SFlashManager: read8BitRegister(0x\(String(format: "%02X", address))) set failed: \(interpretIOReturn(setResult))")
            return nil
        }
        var getBuf: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let getResult = directGetReport(device: device, buffer: &getBuf)
        guard getResult == kIOReturnSuccess else {
            logger.log(content: "MS2130SFlashManager: read8BitRegister(0x\(String(format: "%02X", address))) get failed: \(interpretIOReturn(getResult))")
            return nil
        }
        return getBuf[3]
    }

    private func write8BitRegister(device: IOHIDDevice, address: UInt8, value: UInt8) -> Bool {
        var buf: [UInt8] = [0x01, 0xC6, address, value, 0x00, 0x00, 0x00, 0x00, 0x00]
        let result = directSetReport(device: device, buffer: &buf)
        if result != kIOReturnSuccess {
            logger.log(content: "MS2130SFlashManager: write8BitRegister(0x\(String(format: "%02X", address))) failed: \(interpretIOReturn(result))")
            return false
        }
        return true
    }

    private func read16BitRegister(device: IOHIDDevice, address: UInt16) -> UInt8? {
        var buf: [UInt8] = [0x01, 0xB5,
                            UInt8((address >> 8) & 0xFF),
                            UInt8(address & 0xFF),
                            0x00, 0x00, 0x00, 0x00, 0x00]
        let setResult = directSetReport(device: device, buffer: &buf)
        guard setResult == kIOReturnSuccess else {
            logger.log(content: "MS2130SFlashManager: read16BitRegister(0x\(String(format: "%04X", address))) set failed: \(interpretIOReturn(setResult))")
            return nil
        }
        var getBuf: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let getResult = directGetReport(device: device, buffer: &getBuf)
        guard getResult == kIOReturnSuccess else {
            logger.log(content: "MS2130SFlashManager: read16BitRegister(0x\(String(format: "%04X", address))) get failed: \(interpretIOReturn(getResult))")
            return nil
        }
        return getBuf[4]
    }

    private func write16BitRegister(device: IOHIDDevice, address: UInt16, value: UInt8) -> Bool {
        var buf: [UInt8] = [0x01, 0xB6,
                            UInt8((address >> 8) & 0xFF),
                            UInt8(address & 0xFF),
                            value, 0x00, 0x00, 0x00, 0x00]
        let result = directSetReport(device: device, buffer: &buf)
        if result != kIOReturnSuccess {
            logger.log(content: "MS2130SFlashManager: write16BitRegister(0x\(String(format: "%04X", address))) failed: \(interpretIOReturn(result))")
            return false
        }
        return true
    }

    // Configure MS2130S GPIO and SPI pins for flash write operations.
    // This matches the C++ mshidlink_open_device() sequence.
    // Without this initialization the burst write data phase times out even though
    // sector erase succeeds (erase uses an internal SPI path; burst write uses the GPIO-driven path).
    private func initializeGPIO(device: IOHIDDevice) -> Bool {
        logger.log(content: "MS2130SFlashManager: initializing GPIO for flash write...")

        // 1. Read 0xB0, clear bit 2, write back
        guard let b0 = read8BitRegister(device: device, address: 0xB0) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed reading 0xB0")
            return false
        }
        guard write8BitRegister(device: device, address: 0xB0, value: b0 & ~0x04) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xB0")
            return false
        }

        // 2. Read 0xA0, set bit 2, write back
        guard let a0 = read8BitRegister(device: device, address: 0xA0) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed reading 0xA0")
            return false
        }
        guard write8BitRegister(device: device, address: 0xA0, value: a0 | 0x04) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xA0")
            return false
        }

        // 3. Write 0xD1 to 0xC7
        guard write8BitRegister(device: device, address: 0xC7, value: 0xD1) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xC7")
            return false
        }

        // 4. Write 0xC0 to 0xC8
        guard write8BitRegister(device: device, address: 0xC8, value: 0xC0) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xC8")
            return false
        }

        // 5. Write 0x00 to 0xCA
        guard write8BitRegister(device: device, address: 0xCA, value: 0x00) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xCA")
            return false
        }

        // 6. Read 0xF01F, set bit 4, clear bit 7, write back
        guard let f01f = read16BitRegister(device: device, address: 0xF01F) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed reading 0xF01F")
            return false
        }
        let f01fNew = (f01f | 0x10) & ~0x80
        guard write16BitRegister(device: device, address: 0xF01F, value: f01fNew) else {
            logger.log(content: "MS2130SFlashManager: GPIO init failed writing 0xF01F")
            return false
        }

        logger.log(content: "MS2130SFlashManager: GPIO initialized successfully")
        return true
    }

    // Query erase completion status
    private func checkEraseDone(device: IOHIDDevice, verbose: Bool = false) -> Bool? {
        var command: [UInt8] = [0x01, 0xFD, 0xFD, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let setResult = directSetReport(device: device, buffer: &command)
        guard setResult == kIOReturnSuccess else { return nil }
        Thread.sleep(forTimeInterval: 0.01)
        var response: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let getResult = directGetReport(device: device, buffer: &response)
        guard getResult == kIOReturnSuccess else { return nil }

        guard response.count > 3 else { return nil }
        let status2 = response[2]
        let status3 = response[3]

        if verbose {
            logger.log(content: "MS2130SFlashManager: erase status response=\(response.map { String(format: "%02X", $0) }.joined(separator: " "))")
            logger.log(content: "MS2130SFlashManager: erase status byte2=0x\(String(format: "%02X", status2)), byte3=0x\(String(format: "%02X", status3))")
        }

        if status2 == 0xFD {
            return status3 == 0x00
        } else {
            return status2 == 0x00
        }
    }

    private func waitForEraseCompletion(device: IOHIDDevice, timeout: TimeInterval = 30.0, interval: TimeInterval = 0.1, verbose: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastResult: Bool = false

        while Date() < deadline {
            if let done = checkEraseDone(device: device, verbose: verbose) {
                lastResult = done
                if done {
                    logger.log(content: "MS2130SFlashManager: erase done confirmed")
                    return true
                }
                if verbose {
                    logger.log(content: "MS2130SFlashManager: erase in progress")
                }
            } else {
                logger.log(content: "MS2130SFlashManager: checkEraseDone returned nil, retry")
            }
            Thread.sleep(forTimeInterval: interval)
        }

        logger.log(content: "MS2130SFlashManager: waitForEraseCompletion timeout after \(timeout) seconds (last status=\(lastResult))")
        return lastResult
    }

    private func burstWriteFlash(device: IOHIDDevice, address: UInt32, data: Data) -> Bool {
        // Match the reference (HIDTester) byte-for-byte.
        // On macOS, IOHIDDeviceSetReport puts the reportID parameter into the USB
        // setup packet wValue; the buffer goes into the data stage AS-IS.
        // For the 0xE7 burst header, the buffer must NOT include the report ID
        // prefix — otherwise byte[0]=0x01 instead of 0xE7 and the device does
        // not recognise the burst write command (never enters burst receive mode).

        func sendBurstHeader() -> Bool {
            // 8-byte buffer matching HIDTester macOS format:
            // [0xE7, addr(4), length(2), 0x00]
            // The reportID 0x01 is passed as the CFIndex parameter only.
            var header: [UInt8] = [0xE7,
                                   UInt8((address >> 24) & 0xFF),
                                   UInt8((address >> 16) & 0xFF),
                                   UInt8((address >> 8) & 0xFF),
                                   UInt8(address & 0xFF),
                                   UInt8((data.count >> 8) & 0xFF),
                                   UInt8(data.count & 0xFF),
                                   0x00]

            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0x01), &header, header.count)
            if result == kIOReturnSuccess {
                logger.log(content: "MS2130SFlashManager: burstWriteFlash header sent (reportID=0x01, length=\(header.count), dataLen=\(data.count))")
                return true
            }
            logger.log(content: "MS2130SFlashManager: burstWriteFlash header failed -> \(interpretIOReturn(result)) (0x\(String(format: "%08X", UInt32(bitPattern: result))))")
            return false
        }

        let dataPerChunk = 4095
        let totalChunks = (data.count + dataPerChunk - 1) / dataPerChunk

        func sendDataChunk(_ chunkData: Data, index: Int) -> Bool {
            // 4096-byte buffer: [0x03, firmwareData(up to 4095)]
            // This matches HIDTester's WORKING method exactly:
            //   "Feature report with reportID=0x03 param and full 4096-byte buffer"
            //   buffer[0] = 0x03, buffer[1..4095] = data
            var packet = [UInt8](repeating: 0, count: 4096)
            packet[0] = 0x03
            chunkData.copyBytes(to: &packet[1], count: min(chunkData.count, 4095))

            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0x03), &packet, packet.count)
            if result == kIOReturnSuccess {
                if index == 1 {
                    logger.log(content: "MS2130SFlashManager: burstWriteFlash chunk \(index) success (4096 bytes)")
                }
                return true
            }
            logger.log(content: "MS2130SFlashManager: burstWriteFlash chunk \(index) failed -> \(interpretIOReturn(result)) (0x\(String(format: "%08X", UInt32(bitPattern: result))))")
            return false
        }

        guard sendBurstHeader() else {
            logger.log(content: "MS2130SFlashManager: burstWriteFlash header command failed")
            return false
        }

        // The device enters burst write mode immediately after the 0xE7 header and has a short
        // internal timer waiting for the first data packet. Do NOT add a delay here — sending
        // data must happen immediately (matching the C++ "sends data IMMEDIATELY" behavior).
        // Any delay > ~10ms risks the device timing out its burst session and returning to normal
        // mode, which causes the subsequent 0x03 feature report to be ignored (5-second timeout).

        for i in 0..<totalChunks {
            let start = i * dataPerChunk
            let end = min(start + dataPerChunk, data.count)
            let chunkData = data.subdata(in: start..<end)

            if !sendDataChunk(chunkData, index: i + 1) {
                logger.log(content: "MS2130SFlashManager: burstWriteFlash failed at chunk \(i+1)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.001)  // 1ms between chunks, matching reference
        }

        return true
    }

    private func burstReadFlash(device: IOHIDDevice, address: UInt32, length: UInt16) -> Data? {
        // Read command uses 8-byte format matching write command style
        let cmd: [UInt8] = [0x01, 0xE7,
                            UInt8((address >> 24) & 0xFF),
                            UInt8((address >> 16) & 0xFF),
                            UInt8((address >> 8) & 0xFF),
                            UInt8(address & 0xFF),
                            UInt8((length >> 8) & 0xFF),
                            UInt8(length & 0xFF)]

        var cmdBuf = cmd
        let setResult = directSetReport(device: device, buffer: &cmdBuf)
        guard setResult == kIOReturnSuccess else {
            logger.log(content: "MS2130SFlashManager: burstReadFlash command failed: \(interpretIOReturn(setResult))")
            return nil
        }

        var result = Data()
        let chunkSize = 4095
        var remaining = Int(length)

        while remaining > 0 {
            let request = min(chunkSize, remaining)
            var buffer = [UInt8](repeating: 0, count: request)
            var responseLength = request
            let hr = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(0x01), &buffer, &responseLength)

            if hr != kIOReturnSuccess {
                logger.log(content: "MS2130SFlashManager: burstReadFlash got report fail: \(interpretIOReturn(hr))")
                return nil
            }

            result.append(contentsOf: buffer[..<responseLength])
            remaining -= responseLength

            if responseLength == 0 { break }
        }

        return result
    }

    private func eraseFlash(device: IOHIDDevice, firmwareSize: UInt32) -> Bool {
        // Match HIDTester's eraseSectorInternal exactly:
        // - Single direct IOHIDDeviceSetReport call (no multi-format retry)
        // - No erase completion polling (no 0xFD/0xFD status checks)
        // - Fire-and-forget with short delay between sectors
        //
        // The status polling we used before sent 0xFD/0xFD commands which may leave
        // the device's internal command register in a state that blocks burst write mode.

        func eraseSector(address: UInt32) -> Bool {
            // 8-byte buffer matching HIDTester's eraseSectorInternal:
            // [0xFB, addr_hi, addr_mid, addr_lo, 0, 0, 0, 0]
            var reportData: [UInt8] = [
                0xFB,
                UInt8((address >> 16) & 0xFF),
                UInt8((address >> 8) & 0xFF),
                UInt8(address & 0xFF),
                0x00, 0x00, 0x00, 0x00
            ]
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0x01), &reportData, reportData.count)
            if result != kIOReturnSuccess {
                logger.log(content: "MS2130SFlashManager: sector erase failed at 0x\(String(format: "%06X", address)): \(interpretIOReturn(result))")
                return false
            }
            return true
        }

        if firmwareSize > 0 && firmwareSize < (512 * 1024) {
            let sectorSize: UInt32 = 4096
            let sectorCount = (firmwareSize + sectorSize - 1) / sectorSize
            for i in 0..<sectorCount {
                let addr = i * sectorSize
                logger.log(content: "MS2130SFlashManager: sector erase \(i+1)/\(sectorCount) @ 0x\(String(format: "%06X", addr))")
                if !eraseSector(address: addr) {
                    return false
                }
                // HIDTester uses 10ms delay between sectors (fire-and-forget, no polling)
                Thread.sleep(forTimeInterval: 0.01)
            }

            // Extra sector for compatibility (matching HIDTester)
            if sectorCount <= 15 {
                let extraAddr: UInt32 = 15 * sectorSize
                logger.log(content: "MS2130SFlashManager: extra sector erase at 0x\(String(format: "%06X", extraAddr))")
                let _ = eraseSector(address: extraAddr)
            }
            return true
        }

        // Full chip erase
        logger.log(content: "MS2130SFlashManager: full chip erase start")
        var eraseCmd: [UInt8] = [0xFC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0x01), &eraseCmd, eraseCmd.count)
        if result != kIOReturnSuccess {
            logger.log(content: "MS2130SFlashManager: full chip erase command failed: \(interpretIOReturn(result))")
            return false
        }
        // Full erase takes longer — wait with polling
        if !waitForEraseCompletion(device: device, timeout: 60.0, interval: 0.1, verbose: true) {
            logger.log(content: "MS2130SFlashManager: full chip erase completion timeout")
            return false
        }
        logger.log(content: "MS2130SFlashManager: full chip erase complete")
        return true
    }

    func flashFirmware(_ firmwareData: Data, progressCallback: ((String, Double) -> Void)? = nil) async -> Bool {
        logger.log(content: "MS2130SFlashManager: flashFirmware start, size=\(firmwareData.count) bytes")

        // Ensure no shared HID operations are racing while we do flash update
        HALIntegrationManager.shared.pausePeriodicHALUpdates()

        // CRITICAL: Close the main app's HID device handle completely.
        // stopAllHIDOperations() only stops timers but keeps the IOHIDDevice OPEN.
        // A competing open handle to the same USB interface causes 4096-byte
        // Feature report transfers to time out (kIOReturnNotResponding / 0xE00002D6).
        // HIDTester never has this problem because its connect() closes the device
        // before flashFirmwareComplete reopens it with exclusive access.
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        hidManager.closeHID()

        defer {
            // Reopen the HID connection after flash completes
            hidManager.startHID()
            HALIntegrationManager.shared.resumePeriodicHALUpdates()
        }

        // Run on a background GCD thread — matching HIDTester's FirmwareFlashView which
        // calls flashFirmwareComplete inside DispatchQueue.global(qos: .userInitiated).async.
        //
        // Running on the MAIN thread causes 4096-byte Feature reports to time out because
        // IOHIDDeviceSetReport internally calls CFRunLoopRunInMode, and the main RunLoop
        // has many competing sources (AppKit timers, display-link, input events) that
        // interfere with USB completion delivery.  On a clean GCD background thread the
        // RunLoop is empty so the USB completion is the only event processed.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.flashFirmwareImpl(firmwareData, progressCallback: progressCallback)
                continuation.resume(returning: result)
            }
        }
    }

    private func flashFirmwareImpl(_ firmwareData: Data, progressCallback: ((String, Double) -> Void)? = nil) -> Bool {
        guard let device = findDevice() else {
            logger.log(content: "MS2130SFlashManager: device not found")
            progressCallback?("Device not found", 0.0)
            return false
        }

        guard openDevice(device, seize: true) else {
            logger.log(content: "MS2130SFlashManager: failed to open device")
            progressCallback?("Device open failed", 0.0)
            return false
        }

        defer {
            closeDevice(device)
            logger.log(content: "MS2130SFlashManager: device closed")
        }

        // Configure MS2130S GPIO/SPI pins before any flash operation.
        // Without this the burst write data phase times out (the SPI output lines are not driven).
        guard initializeGPIO(device: device) else {
            logger.log(content: "MS2130SFlashManager: GPIO initialization failed")
            progressCallback?("GPIO init failed", 0.0)
            return false
        }

        let fwSize = UInt32(firmwareData.count)
        progressCallback?("Erasing flash...", 0.05)

        guard eraseFlash(device: device, firmwareSize: fwSize) else {
            logger.log(content: "MS2130SFlashManager: eraseFlash failed")
            progressCallback?("Erase failed", 0.0)
            return false
        }

        // Allow the device to fully stabilize after erase before entering burst write mode.
        // Match HIDTester: 1s wait, no GPIO re-init after erase.
        logger.log(content: "MS2130SFlashManager: waiting 1s for device to stabilize after erase")
        Thread.sleep(forTimeInterval: 1.0)

        progressCallback?("Writing firmware...", 0.2)
        let chunkSize = 60 * 1024
        let totalChunks = (firmwareData.count + chunkSize - 1) / chunkSize

        for index in 0..<totalChunks {
            let start = index * chunkSize
            let end = min((index + 1) * chunkSize, firmwareData.count)
            let chunk = firmwareData.subdata(in: start..<end)

            if !burstWriteFlash(device: device, address: UInt32(start), data: chunk) {
                logger.log(content: "MS2130SFlashManager: burstWriteFlash failed at chunk \(index + 1)/\(totalChunks), addr=\(start)")
                progressCallback?("Write failed at chunk \(index + 1)", Double(index) / Double(totalChunks))
                return false
            }

            let percent = 0.2 + 0.7 * Double(index + 1) / Double(totalChunks)
            progressCallback?("Writing firmware...", percent)
        }

        progressCallback?("Finalizing...", 0.95)
        Thread.sleep(forTimeInterval: 0.5)
        progressCallback?("Done", 1.0)
        logger.log(content: "MS2130SFlashManager: flashFirmware completed successfully")
        return true
    }

    func backupFirmware(totalSize: Int, to url: URL, progressCallback: ((String, Double) -> Void)? = nil) async -> Bool {
        guard let device = findDevice() else { return false }
        guard openDevice(device, seize: true) else { return false }
        defer { closeDevice(device) }

        let chunkSize = 64 * 1024
        var readData = Data()
        var offset: UInt32 = 0

        while offset < totalSize {
            let remaining = totalSize - Int(offset)
            let readLen = UInt16(min(4095, remaining))
            guard let chunk = burstReadFlash(device: device, address: offset, length: readLen) else {
                return false
            }
            readData.append(chunk)
            offset += UInt32(readLen)
            let percent = Double(Int(offset)) / Double(totalSize)
            progressCallback?("Reading firmware...", percent)
        }

        do {
            try readData.write(to: url)
            progressCallback?("Backup saved", 1.0)
            return true
        } catch {
            logger.log(content: "MS2130SFlashManager: backup save fail: \(error)")
            return false
        }
    }

    func restoreFirmware(from url: URL, progressCallback: ((String, Double) -> Void)? = nil) async -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            logger.log(content: "MS2130SFlashManager: restore file unreadable")
            return false
        }
        return await flashFirmware(data, progressCallback: progressCallback)
    }

    func getVersion() -> String? {
        // MS2130S firmware version reading is performed via HID manager (same as MS2109 family)
        let hidManager: HIDManagerProtocol = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        if let version = hidManager.getVersion(), version != "" {
            return version
        }

        // fallback: try reading chipset object version if available
        if let chipset = HardwareAbstractionLayer.shared.getCurrentVideoChipset(),
           let fwVersion = chipset.chipsetInfo.firmwareVersion,
           !fwVersion.isEmpty {
            return fwVersion
        }

        return nil
    }
}
