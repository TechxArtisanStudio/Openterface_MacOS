/*
 * WCH ISP Protocol - Commands, Responses, Constants
 * Ported from wchisp-mac / WCHISPKit
 */

import Foundation

enum WCHCommands {
    static let identify: UInt8 = 0xa1
    static let ispEnd: UInt8 = 0xa2
    static let ispKey: UInt8 = 0xa3
    static let erase: UInt8 = 0xa4
    static let program: UInt8 = 0xa5
    static let verify: UInt8 = 0xa6
    static let readConfig: UInt8 = 0xa7
    static let writeConfig: UInt8 = 0xa8
    static let dataErase: UInt8 = 0xa9
    static let dataProgram: UInt8 = 0xaa
    static let dataRead: UInt8 = 0xab
    static let writeOTP: UInt8 = 0xc3
    static let readOTP: UInt8 = 0xc4
    static let setBaud: UInt8 = 0xc5
}

enum WCHCommand {
    case identify(deviceID: UInt8, deviceType: UInt8)
    case ispEnd(reason: UInt8)
    case ispKey(key: [UInt8])
    case erase(sectors: UInt32)
    case program(address: UInt32, padding: UInt8, data: [UInt8])
    case verify(address: UInt32, padding: UInt8, data: [UInt8])
    case readConfig(bitMask: UInt8)
    case writeConfig(bitMask: UInt8, data: [UInt8])
    case dataRead(address: UInt32, length: UInt16)
    case dataProgram(address: UInt32, padding: UInt8, data: [UInt8])
    case dataErase(sectors: UInt32)
    case setBaud(baudrate: UInt32)
    case writeOTP(UInt8)
    case readOTP(UInt8)

    func toRawBytes() -> [UInt8] {
        switch self {
        case .identify(let deviceID, let deviceType):
            var buf = [UInt8](repeating: 0, count: 0x12 + 3)
            buf[0] = WCHCommands.identify
            buf[1] = 0x12
            buf[2] = 0x00
            buf[3] = deviceID
            buf[4] = deviceType
            let stringBytes = [UInt8]("MCU ISP & WCH.CN".data(using: .ascii)!)
            for (i, byte) in stringBytes.enumerated() {
                buf[5 + i] = byte
            }
            return buf

        case .ispEnd(let reason):
            return [WCHCommands.ispEnd, 0x01, 0x00, reason]

        case .ispKey(let key):
            var buf = [UInt8](repeating: 0, count: 3 + key.count)
            buf[0] = WCHCommands.ispKey
            buf[1] = UInt8(key.count)
            buf[2] = 0x00
            buf[3..<(3 + key.count)] = key[0..<key.count]
            return buf

        case .erase(let sectors):
            var buf = [WCHCommands.erase, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]
            let sectorsBytes = withUnsafeBytes(of: sectors.littleEndian) { Array($0) }
            buf[3..<(3 + sectorsBytes.count)] = sectorsBytes[0..<sectorsBytes.count]
            return buf

        case .program(let address, let padding, let data):
            let payloadSize = 4 + 1 + data.count
            var buf = [UInt8](repeating: 0, count: 3 + payloadSize)
            buf[0] = WCHCommands.program
            let sizeBytes = withUnsafeBytes(of: UInt16(payloadSize).littleEndian) { Array($0) }
            buf[1..<3] = sizeBytes[0..<2]
            let addressBytes = withUnsafeBytes(of: address.littleEndian) { Array($0) }
            buf[3..<7] = addressBytes[0..<4]
            buf[7] = padding
            buf[8..<(8 + data.count)] = data[0..<data.count]
            return buf

        case .verify(let address, let padding, let data):
            let payloadSize = 4 + 1 + data.count
            var buf = [UInt8](repeating: 0, count: 3 + payloadSize)
            buf[0] = WCHCommands.verify
            let sizeBytes = withUnsafeBytes(of: UInt16(payloadSize).littleEndian) { Array($0) }
            buf[1..<3] = sizeBytes[0..<2]
            let addressBytes = withUnsafeBytes(of: address.littleEndian) { Array($0) }
            buf[3..<7] = addressBytes[0..<4]
            buf[7] = padding
            buf[8..<(8 + data.count)] = data[0..<data.count]
            return buf

        case .readConfig(let bitMask):
            return [WCHCommands.readConfig, 0x02, 0x00, bitMask, 0x00]

        case .writeConfig(let bitMask, let data):
            let payloadSize = 2 + data.count
            var buf = [UInt8](repeating: 0, count: 3 + payloadSize)
            buf[0] = WCHCommands.writeConfig
            let sizeBytes = withUnsafeBytes(of: UInt16(payloadSize).littleEndian) { Array($0) }
            buf[1..<3] = sizeBytes[0..<2]
            buf[3] = bitMask
            buf[5..<(5 + data.count)] = data[0..<data.count]
            return buf

        case .dataRead(let address, let length):
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = WCHCommands.dataRead
            buf[1] = 6
            let addressBytes = withUnsafeBytes(of: address.littleEndian) { Array($0) }
            buf[3..<7] = addressBytes[0..<4]
            let lengthBytes = withUnsafeBytes(of: length.littleEndian) { Array($0) }
            buf[7..<9] = lengthBytes[0..<2]
            return buf

        case .dataProgram(let address, let padding, let data):
            let payloadSize = 4 + 1 + data.count
            var buf = [UInt8](repeating: 0, count: 3 + payloadSize)
            buf[0] = WCHCommands.dataProgram
            let sizeBytes = withUnsafeBytes(of: UInt16(payloadSize).littleEndian) { Array($0) }
            buf[1..<3] = sizeBytes[0..<2]
            let addressBytes = withUnsafeBytes(of: address.littleEndian) { Array($0) }
            buf[3..<7] = addressBytes[0..<4]
            buf[7] = padding
            buf[8..<(8 + data.count)] = data[0..<data.count]
            return buf

        case .dataErase(let sectors):
            var buf = [WCHCommands.dataErase, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            buf[7] = UInt8(sectors)
            return buf

        case .setBaud(let baudrate):
            let baudrateBytes = withUnsafeBytes(of: baudrate.littleEndian) { Array($0) }
            var buf = [WCHCommands.setBaud, 0x04, 0x00]
            buf.append(contentsOf: baudrateBytes)
            return buf

        case .writeOTP(let value):
            return [WCHCommands.writeOTP, 0x01, 0x00, value]

        case .readOTP(let value):
            return [WCHCommands.readOTP, 0x01, 0x00, value]
        }
    }
}

enum WCHResponse {
    case ok([UInt8])
    case error(code: UInt8, data: [UInt8])

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    var payload: [UInt8] {
        switch self {
        case .ok(let data): return data
        case .error(_, let data): return data
        }
    }

    static func fromRawBytes(_ raw: [UInt8]) throws -> WCHResponse {
        guard raw.count >= 4 else {
            throw WCHProtocolError.invalidResponse
        }
        let length = UInt16(raw[2]) | (UInt16(raw[3]) << 8)
        let payload = Array(raw[4...])
        if payload.count == Int(length) {
            return .ok(payload)
        } else {
            if raw.count > 4 {
                return .error(code: raw[1], data: payload)
            } else {
                throw WCHProtocolError.invalidResponse
            }
        }
    }
}

enum WCHProtocolError: Error {
    case invalidResponse
    case timeout
    case deviceNotFound
    case communicationError(String)
}

enum WCHConstants {
    static let maxPacketSize: Int = 64
    static let sectorSize: Int = 1024

    static let cfgMaskRDPRUserDataWPR: UInt8 = 0x07
    static let cfgMaskBTVER: UInt8 = 0x08
    static let cfgMaskUID: UInt8 = 0x10
    static let cfgMaskAll: UInt8 = 0x1f
}
