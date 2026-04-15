/*
 * WCH ISP Flashing Logic + Intel HEX Parser
 * Ported from wchisp-mac / WCHISPKit
 */

import Foundation

// MARK: - WCHFlashing

class WCHFlashing {
    private(set) var transport: WCHTransport
    private(set) var chip: WCHChip
    private(set) var chipUID: [UInt8]
    private(set) var bootloaderVersion: [UInt8]
    private(set) var codeFlashProtected: Bool

    private let xorKey: [UInt8]

    init(transport: WCHTransport) throws {
        self.transport = transport

        let identifyResponse = try transport.transfer(command: .identify(deviceID: 0, deviceType: 0))
        guard case .ok(let payload) = identifyResponse, payload.count >= 2 else {
            throw WCHFlashingError.identificationFailed
        }

        let chipID = payload[0]
        let deviceType = payload[1]
        print("[WCH] Chip identified: ID=0x\(String(chipID, radix: 16)), DeviceType=0x\(String(deviceType, radix: 16))")

        let chipDB = WCHChipDB.load()
        self.chip = try chipDB.findChip(chipID: chipID, deviceType: deviceType)
        print("[WCH] Found chip: \(self.chip.name)")

        let configResponse = try transport.transfer(command: .readConfig(bitMask: WCHConstants.cfgMaskAll))
        guard case .ok(let configPayload) = configResponse, configPayload.count >= 18 else {
            throw WCHFlashingError.configReadFailed
        }

        self.codeFlashProtected = chip.supportsCodeFlashProtect && configPayload[2] != 0xa5
        self.bootloaderVersion = Array(configPayload[14..<18])
        self.chipUID = Array(configPayload[18...])

        let uidChecksum = self.chipUID.prefix(chip.uidSize).reduce(0 as UInt8) { $0 &+ $1 }
        var keyBytes = [UInt8](repeating: uidChecksum, count: 8)
        keyBytes[7] = keyBytes[7] &+ chipID
        self.xorKey = keyBytes

        guard chipUID.count >= chip.uidSize else {
            throw WCHFlashingError.invalidChipUID
        }
        print("[WCH] Init complete. Flash protected: \(codeFlashProtected)")
    }

    func getChipInfo() -> String {
        var info = "Chip: \(chip.name) (Flash: \(chip.flashSize / 1024)KiB"
        if chip.eepromSize > 0 {
            info += ", EEPROM: \(chip.eepromSize < 1024 ? "\(chip.eepromSize) Bytes" : "\(chip.eepromSize / 1024)KiB")"
        }
        info += ")"
        let uid = chipUID.map { String(format: "%02X", $0) }.joined(separator: "-")
        info += "\nUID: \(uid)"
        let btver = String(format: "%x%x.%x%x",
                           bootloaderVersion[0], bootloaderVersion[1],
                           bootloaderVersion[2], bootloaderVersion[3])
        info += "\nBTVER: \(btver)"
        if chip.supportsCodeFlashProtect {
            info += "\nFlash protected: \(codeFlashProtected)"
        }
        return info
    }

    func isCodeFlashProtected() -> Bool {
        return codeFlashProtected && chip.supportsCodeFlashProtect
    }

    // MARK: - Unprotect / Protect

    func unprotect(force: Bool = false, skipReset: Bool = false) throws {
        if !force && !codeFlashProtected { return }
        let configResponse = try transport.transfer(command: .readConfig(bitMask: WCHConstants.cfgMaskRDPRUserDataWPR))
        guard case .ok(let payload) = configResponse, payload.count >= 14 else {
            throw WCHFlashingError.configReadFailed
        }
        var config = Array(payload[2..<14])
        config[0] = 0xa5; config[1] = 0x5a
        config[8..<12] = [0xff, 0xff, 0xff, 0xff]
        let writeResponse = try transport.transfer(command: .writeConfig(bitMask: WCHConstants.cfgMaskRDPRUserDataWPR, data: config))
        guard writeResponse.isOK else { throw WCHFlashingError.configWriteFailed }
        codeFlashProtected = false
        if !skipReset { try reset() }
    }

    func protect() throws {
        guard chip.supportsCodeFlashProtect else { return }
        let configResponse = try transport.transfer(command: .readConfig(bitMask: WCHConstants.cfgMaskRDPRUserDataWPR))
        guard case .ok(let payload) = configResponse, payload.count >= 14 else {
            throw WCHFlashingError.configReadFailed
        }
        var config = Array(payload[2..<14])
        config[0] = 0x00; config[1] = 0x00
        config[8..<12] = [0x00, 0x00, 0x00, 0x00]
        let writeResponse = try transport.transfer(command: .writeConfig(bitMask: WCHConstants.cfgMaskRDPRUserDataWPR, data: config))
        guard writeResponse.isOK else { throw WCHFlashingError.configWriteFailed }
        codeFlashProtected = true
    }

    // MARK: - Reset

    func reset() throws {
        let response = try transport.transfer(command: .ispEnd(reason: 1))
        guard response.isOK else { throw WCHFlashingError.resetFailed }
        sleep(3)
    }

    // MARK: - Erase

    func eraseCodeFlash(firmwareSize: UInt32? = nil) throws {
        let sectors = calculateSectors(dataSize: firmwareSize)
        let response = try transport.transfer(command: .erase(sectors: sectors))
        guard response.isOK else { throw WCHFlashingError.eraseFailed }
        print("[WCH] Erased \(sectors) sectors")
    }

    // MARK: - Flash / Verify

    func flashCode(data: [UInt8], progressCallback: ((Double) -> Void)? = nil) throws {
        let ispKeyBytes = [UInt8](repeating: 0x00, count: 0x1E)
        let ispKeyResponse = try transport.transfer(command: .ispKey(key: ispKeyBytes))
        guard case .ok(let keyPayload) = ispKeyResponse, !keyPayload.isEmpty else {
            throw WCHFlashingError.ispKeyFailed
        }
        let expected = xorKey.reduce(0 as UInt8) { $0 &+ $1 }
        guard keyPayload[0] == expected else { throw WCHFlashingError.ispKeyFailed }

        var address: UInt32 = 0
        for chunk in data.wchChunked(into: 56) {
            try flashChunk(address: address, data: chunk)
            address += UInt32(chunk.count)
            progressCallback?(Double(address) / Double(data.count))
        }
        try flashChunk(address: address, data: [])
        usleep(500_000)
    }

    func verifyCode(data: [UInt8], progressCallback: ((Double) -> Void)? = nil) throws {
        let ispKeyBytes = [UInt8](repeating: 0x00, count: 0x1E)
        let ispKeyResponse = try transport.transfer(command: .ispKey(key: ispKeyBytes))
        guard case .ok(let keyPayload) = ispKeyResponse, !keyPayload.isEmpty else {
            throw WCHFlashingError.ispKeyFailed
        }
        let expected = xorKey.reduce(0 as UInt8) { $0 &+ $1 }
        guard keyPayload[0] == expected else { throw WCHFlashingError.ispKeyFailed }

        var address: UInt32 = 0
        for chunk in data.wchChunked(into: 56) {
            try verifyChunk(address: address, data: chunk)
            address += UInt32(chunk.count)
            progressCallback?(Double(address) / Double(data.count))
        }
    }

    // MARK: - EEPROM

    func readEEPROM(length: UInt32? = nil, progressCallback: ((Double) -> Void)? = nil) throws -> [UInt8] {
        let size = length ?? chip.eepromSize
        guard size > 0 else { throw WCHFlashingError.eepromNotSupported }
        var data = [UInt8]()
        var address: UInt32 = 0
        while address < size {
            let toRead = UInt16(min(UInt32(56), size - address))
            let response = try transport.transfer(command: .dataRead(address: address, length: toRead))
            guard case .ok(let payload) = response else { throw WCHFlashingError.readEEPROMFailed }
            data.append(contentsOf: payload)
            address += UInt32(toRead)
            progressCallback?(Double(address) / Double(size))
        }
        return data
    }

    func writeEEPROM(data: [UInt8], progressCallback: ((Double) -> Void)? = nil) throws {
        var keyBytes = xorKey
        while keyBytes.count < 0x1E { keyBytes.append(0x00) }
        let ispKeyResponse = try transport.transfer(command: .ispKey(key: keyBytes))
        guard ispKeyResponse.isOK else { throw WCHFlashingError.ispKeyFailed }
        var address: UInt32 = 0
        for chunk in data.wchChunked(into: 56) {
            try writeDataChunk(address: address, data: chunk)
            address += UInt32(chunk.count)
            progressCallback?(Double(address) / Double(data.count))
        }
    }

    // MARK: - Private helpers

    private func calculateSectors(dataSize: UInt32?) -> UInt32 {
        let sectorSize: UInt32 = 1024
        let sectors: UInt32
        if let size = dataSize, size > 0 {
            sectors = ((size + sectorSize - 1) / sectorSize) + 1
        } else {
            sectors = chip.flashSize / sectorSize
        }
        return max(sectors, chip.minEraseSectorNumber)
    }

    private func xorEncrypt(data: [UInt8]) -> [UInt8] {
        data.enumerated().map { offset, byte in byte ^ xorKey[offset % xorKey.count] }
    }

    private func flashChunk(address: UInt32, data: [UInt8]) throws {
        let encrypted = xorEncrypt(data: data)
        let padding = UInt8.random(in: 0...255)
        let response = try transport.transfer(command: .program(address: address, padding: padding, data: encrypted))
        guard response.isOK else { throw WCHFlashingError.programFailed }
    }

    private func verifyChunk(address: UInt32, data: [UInt8]) throws {
        let encrypted = xorEncrypt(data: data)
        let padding = UInt8.random(in: 0...255)
        let response = try transport.transfer(command: .verify(address: address, padding: padding, data: encrypted))
        guard response.isOK else { throw WCHFlashingError.verifyFailed }
    }

    private func writeDataChunk(address: UInt32, data: [UInt8]) throws {
        let encrypted = xorEncrypt(data: data)
        let padding = UInt8.random(in: 0...255)
        let response = try transport.transfer(command: .dataProgram(address: address, padding: padding, data: encrypted))
        guard response.isOK else { throw WCHFlashingError.dataProgramFailed }
    }
}

// MARK: - Errors

enum WCHFlashingError: Error {
    case identificationFailed
    case configReadFailed
    case configWriteFailed
    case resetFailed
    case eraseFailed
    case ispKeyFailed
    case programFailed
    case verifyFailed
    case dataProgramFailed
    case invalidChipUID
    case chipNotSupported
    case eepromNotSupported
    case readEEPROMFailed
}

// MARK: - Intel HEX Parser

class WCHHexFileParser {
    static func parse(data: Data) throws -> [UInt8] {
        var dataToProcess = data
        // Strip UTF-8 BOM
        if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            dataToProcess = Data(data.dropFirst(3))
        }

        var hexString: String?
        for encoding: String.Encoding in [.utf8, .utf16, .ascii, .isoLatin1] {
            if let s = String(data: dataToProcess, encoding: encoding), s.contains(":") {
                hexString = s; break
            }
        }
        guard let hex = hexString else { throw WCHHexParseError.invalidEncoding }

        var memoryMap: [UInt32: UInt8] = [:]
        var extendedBase: UInt32 = 0

        for line in hex.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.hasPrefix(":") else { continue }

            let content = String(trimmed.dropFirst())
            guard content.count >= 10 else { continue }

            guard let byteCount = UInt8(content.prefix(2), radix: 16),
                  let address = UInt16(content.dropFirst(2).prefix(4), radix: 16),
                  let recordType = UInt8(content.dropFirst(6).prefix(2), radix: 16) else { continue }

            guard content.count >= 10 + Int(byteCount) * 2 else { continue }

            let dataStart = content.index(content.startIndex, offsetBy: 8)
            let dataEnd = content.index(dataStart, offsetBy: Int(byteCount) * 2)
            var lineData = [UInt8]()
            var idx = dataStart
            while idx < dataEnd {
                let next = content.index(idx, offsetBy: 2)
                guard let byte = UInt8(content[idx..<next], radix: 16) else { throw WCHHexParseError.invalidHexValue }
                lineData.append(byte)
                idx = next
            }

            switch recordType {
            case 0x00:
                let base = extendedBase | UInt32(address)
                for (i, byte) in lineData.enumerated() { memoryMap[base + UInt32(i)] = byte }
            case 0x01:
                break
            case 0x02: // Extended Segment Address: segment value × 16
                guard lineData.count == 2 else { throw WCHHexParseError.invalidRecordData }
                extendedBase = ((UInt32(lineData[0]) << 8) | UInt32(lineData[1])) << 4
            case 0x04: // Extended Linear Address: upper 16 bits
                guard lineData.count == 2 else { throw WCHHexParseError.invalidRecordData }
                extendedBase = (UInt32(lineData[0]) << 24) | (UInt32(lineData[1]) << 16)
            case 0x05:
                break
            default:
                throw WCHHexParseError.unsupportedRecordType
            }
        }

        guard !memoryMap.isEmpty else { return [] }
        let addrs = memoryMap.keys.sorted().filter { $0 <= 0x100000 }
        guard !addrs.isEmpty else { return [] }

        let minAddr = addrs.first!
        let maxAddr = addrs.last!
        var binary = [UInt8](repeating: 0xFF, count: Int(maxAddr - minAddr + 1))
        for (addr, byte) in memoryMap where addr >= minAddr && addr <= maxAddr {
            binary[Int(addr - minAddr)] = byte
        }
        return binary
    }
}

enum WCHHexParseError: Error {
    case invalidEncoding
    case invalidFormat
    case invalidHexValue
    case invalidRecordData
    case unsupportedRecordType
}

// MARK: - Array chunking helper

extension Array {
    func wchChunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
