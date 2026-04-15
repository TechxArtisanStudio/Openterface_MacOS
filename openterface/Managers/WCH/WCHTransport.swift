/*
 * WCH ISP Transport Protocol
 * Ported from wchisp-mac / WCHISPKit
 */

import Foundation

protocol WCHTransport {
    func sendRaw(_ data: [UInt8]) throws
    func receiveRaw(timeout: TimeInterval) throws -> [UInt8]
    func transfer(command: WCHCommand) throws -> WCHResponse
    func transfer(command: WCHCommand, timeout: TimeInterval) throws -> WCHResponse
    func dumpFirmware(flashSize: UInt32, progressCallback: ((Double) -> Void)?) throws -> [UInt8]
}

enum WCHTransportError: Error {
    case deviceNotFound
    case deviceOpenFailed
    case configurationFailed
    case interfaceCreationFailed
    case interfaceOpenFailed
    case interfaceNotOpen
    case writeFailed
    case readFailed
    case responseMismatch
    case notImplemented
    case timeout
    case notConnected
    case initFailed
    case openFailed
    case claimFailed
    case sendFailed
    case receiveFailed
}
