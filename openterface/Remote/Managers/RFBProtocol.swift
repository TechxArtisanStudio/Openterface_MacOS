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
import CoreGraphics
import AppKit
import Carbon
import ImageIO
import zlib

enum TightFilterType {
    case copy
    case palette
    case gradient
}

struct TightBasicRectContext {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let remaining: Int
    let streamID: Int
    let readUncompressed: Bool
    let filter: TightFilterType
    let rowSize: Int
    let bitsPerPixel: Int
    let palette: [[UInt8]]
}

// MARK: - RFBProtocolHandler

protocol RFBProtocolHandlerDelegate: AnyObject {
    var logger: LoggerProtocol { get }

    func rfbSend(_ data: Data)
    func rfbSetError(_ message: String)
    func rfbStopConnection(reason: String)
    func rfbMarkConnected()
    func rfbPublishFrame(_ frame: CGImage?)
    func rfbSetFramebufferSize(width: Int, height: Int)
    func rfbGetFramebufferSize() -> (width: Int, height: Int)
    func rfbSetFramebufferPixels(_ pixels: Data)
    func rfbGetFramebufferPixels() -> Data
    func rfbGetVNCPassword() -> String
    func rfbGetARDCredentials() -> (username: String, password: String)
    func rfbComputeARDResponse(generator: UInt16,
                               prime: [UInt8],
                               serverPublicKey: [UInt8],
                               username: String,
                               password: String,
                               completion: @escaping (Data?) -> Void)
}

enum RFBHandshakeState {
    case idle
    case awaitingServerVersion
    case awaitingSecurityTypes
    case awaitingVNCAuthChallenge
    case awaitingARDChallenge
    case computingARDResponse
    case awaitingSecurityResult
    case awaitingServerInitHeader
    case awaitingServerInitName(Int)
    case awaitingMessageType
    case awaitingFBUpdateHeader
    case awaitingRectHeader(remaining: Int)
    case awaitingRectPixels(x: Int, y: Int, w: Int, h: Int, totalBytes: Int, remaining: Int)
    case awaitingCopyRectSrc(dstX: Int, dstY: Int, w: Int, h: Int, remaining: Int)
    case awaitingZLIBLength(x: Int, y: Int, w: Int, h: Int, remaining: Int)
    case awaitingZLIBData(x: Int, y: Int, w: Int, h: Int, compressedBytes: Int, remaining: Int)
    case awaitingTightControl(x: Int, y: Int, w: Int, h: Int, remaining: Int)
    case awaitingTightFill(x: Int, y: Int, w: Int, h: Int, remaining: Int)
    case awaitingTightFilter(x: Int, y: Int, w: Int, h: Int, remaining: Int, streamID: Int, readUncompressed: Bool)
    case awaitingTightPaletteCount(x: Int, y: Int, w: Int, h: Int, remaining: Int, streamID: Int, readUncompressed: Bool)
    case awaitingTightPaletteData(x: Int, y: Int, w: Int, h: Int, remaining: Int, streamID: Int, readUncompressed: Bool, paletteEntries: Int)
    case awaitingTightDataLength(TightBasicRectContext)
    case awaitingTightData(TightBasicRectContext, compressedBytes: Int)
    case awaitingTightJPEGLength(x: Int, y: Int, w: Int, h: Int, remaining: Int)
    case awaitingTightJPEGData(x: Int, y: Int, w: Int, h: Int, remaining: Int, compressedBytes: Int)
    case awaitingServerCutTextHeader
    case awaitingSkip(Int)
}

final class RFBProtocolHandler {
    weak var delegate: RFBProtocolHandlerDelegate?

    private(set) var handshakeState: RFBHandshakeState = .idle
    private var receiveBuffer = Data()
    private var pointerButtonMask: UInt8 = 0
    private var selectedSecurityType: UInt8?
    private var useZLIBCompression: Bool = false
    private var useTightCompression: Bool = false
    private var frameDeliveryStartTime: Date = Date()
    private var frameCount: Int = 0
    private var rawBytesProcessed: UInt64 = 0
    private var lastFrameStatsLogTime: Date = .distantPast
    private var framebufferPixels = Data()
    private var zlibStream = z_stream()
    private var zlibStreamInitialized = false
    private var tightZlibStreams = Array(repeating: z_stream(), count: 4)
    private var tightZlibStreamInitialized = Array(repeating: false, count: 4)
    private let verboseFramebufferLogs = false

    init(delegate: RFBProtocolHandlerDelegate?, useZLIBCompression: Bool = false, useTightCompression: Bool = false) {
        self.delegate = delegate
        self.useZLIBCompression = useZLIBCompression
        self.useTightCompression = useTightCompression
    }

    func reset() {
        handshakeState = .idle
        receiveBuffer.removeAll(keepingCapacity: false)
        pointerButtonMask = 0
        selectedSecurityType = nil
        frameDeliveryStartTime = Date()
        frameCount = 0
        rawBytesProcessed = 0
        lastFrameStatsLogTime = .distantPast
        framebufferPixels.removeAll(keepingCapacity: false)
        resetZlibStream()
        resetTightZlibStreams()
    }

    func startHandshake() {
        handshakeState = .awaitingServerVersion
        receiveBuffer.removeAll(keepingCapacity: true)
        frameDeliveryStartTime = Date()
        frameCount = 0
        rawBytesProcessed = 0
        lastFrameStatsLogTime = .distantPast
        framebufferPixels.removeAll(keepingCapacity: true)
        resetZlibStream()
        resetTightZlibStreams()
    }

    func ingest(_ data: Data) {
        receiveBuffer.append(data)
        processHandshakeBuffer()
    }

    func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        guard isSessionActive else { return }
        pointerButtonMask = buttonMask
        var msg = Data(count: 6)
        msg[0] = 5
        msg[1] = buttonMask
        msg[2] = UInt8((x >> 8) & 0xFF)
        msg[3] = UInt8(x & 0xFF)
        msg[4] = UInt8((y >> 8) & 0xFF)
        msg[5] = UInt8(y & 0xFF)
        delegate?.rfbSend(msg)
    }

    func sendKeyEvent(keySym: UInt32, isDown: Bool) {
        guard isSessionActive else { return }
        var msg = Data(count: 8)
        msg[0] = 4
        msg[1] = isDown ? 1 : 0
        msg[2] = 0
        msg[3] = 0
        msg[4] = UInt8((keySym >> 24) & 0xFF)
        msg[5] = UInt8((keySym >> 16) & 0xFF)
        msg[6] = UInt8((keySym >> 8) & 0xFF)
        msg[7] = UInt8(keySym & 0xFF)
        delegate?.rfbSend(msg)
    }

    func sendClipboardText(_ text: String) {
        guard isSessionActive, let textData = text.data(using: .isoLatin1) else { return }
        let length = UInt32(textData.count)
        var msg = Data(count: 8 + textData.count)
        msg[0] = 6
        msg[1] = 0
        msg[2] = 0
        msg[3] = 0
        msg[4] = UInt8((length >> 24) & 0xFF)
        msg[5] = UInt8((length >> 16) & 0xFF)
        msg[6] = UInt8((length >> 8) & 0xFF)
        msg[7] = UInt8(length & 0xFF)
        msg.replaceSubrange(8..., with: textData)
        delegate?.rfbSend(msg)
    }

    func sendScroll(x: Int, y: Int, deltaY: CGFloat, buttonMask: UInt8) {
        let scrollButton: UInt8 = deltaY > 0 ? 0x08 : 0x10
        guard scrollButton != 0 else { return }
        sendPointerEvent(x: x, y: y, buttonMask: buttonMask | scrollButton)
        sendPointerEvent(x: x, y: y, buttonMask: buttonMask)
    }

    func handleKeyEvent(keyCode: UInt16, charactersIgnoringModifiers: String?, isDown: Bool) {
        guard let keySym = keySym(forKeyCode: keyCode,
                                  charactersIgnoringModifiers: charactersIgnoringModifiers) else { return }
        sendKeyEvent(keySym: keySym, isDown: isDown)
    }

    func handleFlagsChanged(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard let keySym = modifierKeySym(for: keyCode),
              let isDown = modifierIsDown(forKeyCode: keyCode,
                                          modifierFlags: modifierFlags) else { return }
        sendKeyEvent(keySym: keySym, isDown: isDown)
    }

    private var isSessionActive: Bool {
        if case .idle = handshakeState {
            return false
        }
        return true
    }

    private func processHandshakeBuffer() {
        while true {
            switch handshakeState {
            case .idle:
                return

            case .awaitingServerVersion:
                guard receiveBuffer.count >= 12 else { return }
                let versionData = Data(receiveBuffer.prefix(12))
                receiveBuffer = Data(receiveBuffer.dropFirst(12))
                guard let serverVersion = String(data: versionData, encoding: .ascii),
                      serverVersion.hasPrefix("RFB ") else {
                    delegate?.logger.log(content: "Invalid VNC server version response: \(String(data: versionData, encoding: .ascii) ?? "nil")")
                    delegate?.rfbSetError("Invalid VNC server version response.")
                    delegate?.rfbStopConnection(reason: "invalid server version")
                    return
                }
                delegate?.logger.log(content: "VNC server version: \(serverVersion.trimmingCharacters(in: .whitespacesAndNewlines))")
                delegate?.rfbSend(Data("RFB 003.008\n".utf8))
                handshakeState = .awaitingSecurityTypes

            case .awaitingSecurityTypes:
                guard receiveBuffer.count >= 1 else { return }
                let count = Int(receiveBuffer[0])
                guard count > 0 else {
                    delegate?.logger.log(content: "VNC server does not offer supported security types.")
                    delegate?.rfbSetError("VNC server does not offer supported security types.")
                    delegate?.rfbStopConnection(reason: "no security types")
                    return
                }
                guard receiveBuffer.count >= 1 + count else { return }
                let securityTypes = Array(receiveBuffer[1..<(1 + count)])
                receiveBuffer = Data(receiveBuffer.dropFirst(1 + count))
                delegate?.logger.log(content: "VNC offered security types: \(securityTypes)")
                if securityTypes.contains(1) {
                    delegate?.logger.log(content: "VNC choosing None (1) security")
                    selectedSecurityType = 1
                    delegate?.rfbSend(Data([1]))
                    handshakeState = .awaitingSecurityResult
                } else if securityTypes.contains(2) {
                    delegate?.logger.log(content: "VNC choosing VNC Password (2) security")
                    selectedSecurityType = 2
                    delegate?.rfbSend(Data([2]))
                    handshakeState = .awaitingVNCAuthChallenge
                } else if securityTypes.contains(30) {
                    delegate?.logger.log(content: "VNC choosing Apple ARD (30) security")
                    selectedSecurityType = 30
                    delegate?.rfbSend(Data([30]))
                    handshakeState = .awaitingARDChallenge
                } else if securityTypes.contains(16) {
                    delegate?.logger.log(content: "VNC choosing Apple ARD (16) security")
                    selectedSecurityType = 16
                    delegate?.rfbSend(Data([16]))
                    handshakeState = .awaitingARDChallenge
                } else {
                    delegate?.logger.log(content: "Unsupported VNC security types: \(securityTypes)")
                    delegate?.rfbSetError("Unsupported VNC security types: \(securityTypes.map(String.init).joined(separator: ", "))")
                    delegate?.rfbStopConnection(reason: "unsupported security type")
                    return
                }

            case .awaitingARDChallenge:
                guard receiveBuffer.count >= 4 else { return }
                let generatorValue = UInt16(receiveBuffer[0]) << 8 | UInt16(receiveBuffer[1])
                let keyLen = Int(UInt16(receiveBuffer[2]) << 8 | UInt16(receiveBuffer[3]))
                delegate?.logger.log(content: "VNC ARD challenge header: generator=\(generatorValue) keyLen=\(keyLen) buffer=\(receiveBuffer.count)")
                guard generatorValue > 0, keyLen > 0, keyLen <= 2048 else {
                    delegate?.rfbSetError("ARD auth: invalid DH params generator=\(generatorValue) keyLen=\(keyLen)")
                    delegate?.rfbStopConnection(reason: "ard invalid params")
                    return
                }
                let totalDHLen = 4 + keyLen + keyLen
                guard receiveBuffer.count >= totalDHLen else { return }

                let ardPrime = [UInt8](receiveBuffer[4 ..< 4 + keyLen])
                let ardServerPub = [UInt8](receiveBuffer[4 + keyLen ..< totalDHLen])
                receiveBuffer = Data(receiveBuffer.dropFirst(totalDHLen))

                let creds = delegate?.rfbGetARDCredentials() ?? (username: "", password: "")
                delegate?.logger.log(content: "VNC ARD auth start: username=\(creds.username) keyLen=\(keyLen) \(usernameDiagnostics(creds.username))")
                handshakeState = .computingARDResponse
                let startedAt = Date()
                delegate?.rfbComputeARDResponse(generator: generatorValue,
                                                prime: ardPrime,
                                                serverPublicKey: ardServerPub,
                                                username: creds.username,
                                                password: creds.password,
                                                completion: { [weak self] response in
                    guard let self = self else { return }
                    guard case .computingARDResponse = self.handshakeState else { return }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    guard let response = response else {
                        self.delegate?.logger.log(content: "VNC ARD auth compute failed after \(String(format: "%.2f", elapsed))s")
                        self.delegate?.rfbSetError("ARD auth: failed to compute DH response")
                        self.delegate?.rfbStopConnection(reason: "ard dh failed")
                        return
                    }
                    self.delegate?.logger.log(content: "VNC ARD auth response ready: bytes=\(response.count) elapsed=\(String(format: "%.2f", elapsed))s")
                    self.delegate?.rfbSend(response)
                    self.handshakeState = .awaitingSecurityResult
                })
                return

            case .computingARDResponse:
                return

            case .awaitingVNCAuthChallenge:
                guard receiveBuffer.count >= 16 else { return }
                let challenge = Data(receiveBuffer.prefix(16))
                receiveBuffer = Data(receiveBuffer.dropFirst(16))
                let password = delegate?.rfbGetVNCPassword() ?? ""
                guard let response = rfbDesResponse(challenge: challenge, password: password) else {
                    delegate?.rfbSetError("VNC auth: failed to encrypt challenge.")
                    delegate?.rfbStopConnection(reason: "vnc auth encrypt failed")
                    return
                }
                delegate?.rfbSend(response)
                handshakeState = .awaitingSecurityResult

            case .awaitingSecurityResult:
                guard receiveBuffer.count >= 4 else { return }
                let statusData = Data(receiveBuffer.prefix(4))
                receiveBuffer = Data(receiveBuffer.dropFirst(4))
                let status = statusData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                delegate?.logger.log(content: "VNC security result status: \(status)")
                guard status == 0 else {
                    if status == 1 {
                        guard receiveBuffer.count >= 4 else { return }
                        let errorLengthData = Data(receiveBuffer.prefix(4))
                        let errorLength = errorLengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        if receiveBuffer.count >= 4 + Int(errorLength) {
                            let errorData = receiveBuffer[4..<4+Int(errorLength)]
                            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown reason"
                            delegate?.logger.log(content: "VNC security failure reason: \(errorMessage)")
                            delegate?.logger.log(content: securitySummary(status: status, reason: errorMessage))
                            delegate?.rfbSetError("VNC security handshake failed: \(errorMessage)")
                        } else {
                            delegate?.logger.log(content: "VNC security failure status=\(status), missing reason bytes. pending=\(receiveBuffer.count)")
                            delegate?.logger.log(content: securitySummary(status: status, reason: "missing reason bytes"))
                            delegate?.rfbSetError("VNC security handshake failed (status \(status)).")
                        }
                    } else {
                        delegate?.logger.log(content: "VNC security failure status=\(status)")
                        delegate?.logger.log(content: securitySummary(status: status, reason: "status \(status)"))
                        delegate?.rfbSetError("VNC security handshake failed (status \(status)).")
                    }
                    delegate?.rfbStopConnection(reason: "security failed")
                    return
                }
                delegate?.logger.log(content: "VNC security handshake success")
                delegate?.logger.log(content: securitySummary(status: status, reason: "ok"))
                delegate?.logger.log(content: "VNC compression config: zlibEnabled=\(useZLIBCompression) tightEnabled=\(useTightCompression)")
                delegate?.rfbSend(Data([1]))
                handshakeState = .awaitingServerInitHeader

            case .awaitingServerInitHeader:
                guard receiveBuffer.count >= 24 else { return }
                let header = Array(receiveBuffer.prefix(24))
                receiveBuffer = Data(receiveBuffer.dropFirst(24))

                let framebufferWidth = Int(UInt16(header[0]) << 8 | UInt16(header[1]))
                let framebufferHeight = Int(UInt16(header[2]) << 8 | UInt16(header[3]))
                let nameLength = Int(
                    UInt32(header[20]) << 24 | UInt32(header[21]) << 16 |
                    UInt32(header[22]) << 8  | UInt32(header[23])
                )
                delegate?.rfbSetFramebufferSize(width: framebufferWidth, height: framebufferHeight)
                handshakeState = .awaitingServerInitName(nameLength)

            case .awaitingServerInitName(let nameLength):
                guard receiveBuffer.count >= nameLength else { return }
                receiveBuffer = Data(receiveBuffer.dropFirst(nameLength))
                let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
                framebufferPixels = Data(count: size.width * size.height * 4)
                sendSetPixelFormat()
                sendSetEncodings()
                sendFramebufferUpdateRequest(incremental: false)
                handshakeState = .awaitingMessageType
                delegate?.rfbMarkConnected()

            case .awaitingMessageType:
                guard receiveBuffer.count >= 1 else { return }
                let msgType = receiveBuffer[0]
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                switch msgType {
                case 0: handshakeState = .awaitingFBUpdateHeader
                case 2: continue
                case 3: handshakeState = .awaitingServerCutTextHeader
                default:
                    delegate?.rfbSetError("VNC unexpected server message type: \(msgType)")
                    delegate?.rfbStopConnection(reason: "unexpected message type")
                    return
                }

            case .awaitingFBUpdateHeader:
                guard receiveBuffer.count >= 3 else { return }
                let numRects = Int(UInt16(receiveBuffer[1]) << 8 | UInt16(receiveBuffer[2]))
                receiveBuffer = Data(receiveBuffer.dropFirst(3))
                logVerboseFramebuffer("VNC FBUpdate: numRects=\(numRects)")
                handshakeState = numRects > 0 ? .awaitingRectHeader(remaining: numRects) : .awaitingMessageType

            case .awaitingRectHeader(let remaining):
                guard receiveBuffer.count >= 12 else { return }
                let rx = Int(UInt16(receiveBuffer[0])  << 8 | UInt16(receiveBuffer[1]))
                let ry = Int(UInt16(receiveBuffer[2])  << 8 | UInt16(receiveBuffer[3]))
                let rw = Int(UInt16(receiveBuffer[4])  << 8 | UInt16(receiveBuffer[5]))
                let rh = Int(UInt16(receiveBuffer[6])  << 8 | UInt16(receiveBuffer[7]))
                let enc = Int32(bitPattern:
                    UInt32(receiveBuffer[8])  << 24 | UInt32(receiveBuffer[9])  << 16 |
                    UInt32(receiveBuffer[10]) << 8  | UInt32(receiveBuffer[11]))
                receiveBuffer = Data(receiveBuffer.dropFirst(12))
                let next = remaining - 1
                logVerboseFramebuffer("VNC rect: x=\(rx) y=\(ry) w=\(rw) h=\(rh) enc=\(enc) remaining=\(next)")
                switch enc {
                case 0:
                    AppStatus.setRemoteCompressionLabel("RAW")
                    let bytes = rw * rh * 4
                    handshakeState = bytes > 0
                        ? .awaitingRectPixels(x: rx, y: ry, w: rw, h: rh, totalBytes: bytes, remaining: next)
                        : (next > 0 ? .awaitingRectHeader(remaining: next) : .awaitingMessageType)
                case 1:
                    AppStatus.setRemoteCompressionLabel("COPYRECT")
                    handshakeState = .awaitingCopyRectSrc(dstX: rx, dstY: ry, w: rw, h: rh, remaining: next)
                case 6:
                    AppStatus.setRemoteCompressionLabel("ZLIB")
                    // ZLIB encoding: 4-byte compressed length followed by data in a persistent inflate stream.
                    if rw > 0, rh > 0 {
                        handshakeState = .awaitingZLIBLength(x: rx, y: ry, w: rw, h: rh, remaining: next)
                    } else {
                        delegate?.logger.log(content: "VNC ZLIB: skipped empty rect \(rw)x\(rh)")
                        handshakeState = next > 0 ? .awaitingRectHeader(remaining: next) : .awaitingMessageType
                    }
                case 7:
                    AppStatus.setRemoteCompressionLabel("TIGHT")
                    handshakeState = .awaitingTightControl(x: rx, y: ry, w: rw, h: rh, remaining: next)
                default:
                    if useTightCompression {
                        delegate?.rfbSetError("VNC Tight negotiation failed: unsupported rect encoding \(enc)")
                        delegate?.rfbStopConnection(reason: "tight unsupported rect encoding")
                        return
                    }
                    delegate?.rfbSetError("VNC unsupported rect encoding: \(enc)")
                    delegate?.rfbStopConnection(reason: "unsupported rect encoding")
                    return
                }

            case .awaitingRectPixels(let rx, let ry, let rw, let rh, let totalBytes, let remaining):
                guard receiveBuffer.count >= totalBytes else { return }
                let pixels = Data(receiveBuffer.prefix(totalBytes))
                receiveBuffer = Data(receiveBuffer.dropFirst(totalBytes))
                applyRawRect(x: rx, y: ry, w: rw, h: rh, pixels: pixels)
                if remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingCopyRectSrc(let dstX, let dstY, let rw, let rh, let remaining):
                guard receiveBuffer.count >= 4 else { return }
                let srcX = Int(UInt16(receiveBuffer[0]) << 8 | UInt16(receiveBuffer[1]))
                let srcY = Int(UInt16(receiveBuffer[2]) << 8 | UInt16(receiveBuffer[3]))
                receiveBuffer = Data(receiveBuffer.dropFirst(4))
                applyCopyRect(srcX: srcX, srcY: srcY, dstX: dstX, dstY: dstY, w: rw, h: rh)
                if remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingZLIBLength(let x, let y, let w, let h, let remaining):
                guard receiveBuffer.count >= 4 else { return }
                let compressedLength = Int(
                    UInt32(receiveBuffer[0]) << 24 | UInt32(receiveBuffer[1]) << 16 |
                    UInt32(receiveBuffer[2]) << 8  | UInt32(receiveBuffer[3])
                )
                receiveBuffer = Data(receiveBuffer.dropFirst(4))
                handshakeState = .awaitingZLIBData(x: x, y: y, w: w, h: h, compressedBytes: compressedLength, remaining: remaining)

            case .awaitingZLIBData(let x, let y, let w, let h, let compressedLength, let remaining):
                guard receiveBuffer.count >= compressedLength else { return }
                let compressedData = Data(receiveBuffer.prefix(compressedLength))
                receiveBuffer = Data(receiveBuffer.dropFirst(compressedLength))

                let expectedUncompressed = w * h * 4
                guard let decompressed = inflateZlibRectangle(compressedData, expectedSize: expectedUncompressed) else {
                    delegate?.rfbSetError("VNC ZLIB decode failed")
                    delegate?.rfbStopConnection(reason: "zlib decode failed")
                    return
                }

                applyRawRect(x: x, y: y, w: w, h: h, pixels: decompressed)

                if remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingTightControl(let x, let y, let w, let h, let remaining):
                guard receiveBuffer.count >= 1 else { return }
                let control = receiveBuffer[0]
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                resetTightStreams(using: control)

                let mode = Int((control >> 4) & 0x0F)  // bits 7-4 = compression type
                let hexPreview = receiveBuffer.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                logVerboseFramebuffer("VNC Tight: control=0x\(String(format:"%02X", control)) mode=\(mode) x=\(x) y=\(y) w=\(w) h=\(h) next8=[\(hexPreview)]")
                var readUncompressed = false
                var streamID = 0
                let hasExplicitFilter = (mode & 0x04) != 0

                if mode == 0x08 {
                    AppStatus.setRemoteCompressionLabel("TIGHT/FILL")
                    handshakeState = .awaitingTightFill(x: x, y: y, w: w, h: h, remaining: remaining)
                } else if mode == 0x09 {
                    AppStatus.setRemoteCompressionLabel("TIGHT/JPEG")
                    handshakeState = .awaitingTightJPEGLength(x: x, y: y, w: w, h: h, remaining: remaining)
                } else if mode == 0x0A || mode == 0x0E {
                    readUncompressed = true
                    streamID = mode & 0x03
                    if hasExplicitFilter {
                        handshakeState = .awaitingTightFilter(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed)
                    } else {
                        let context = makeTightBasicContext(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, filter: .copy, palette: [])
                        handshakeState = advanceTightDataState(for: context)
                    }
                } else if mode >= 0x00 && mode <= 0x07 {
                    streamID = mode & 0x03
                    readUncompressed = false  // basic sub-encoding always uses zlib (small payload handled in advanceTightDataState)
                    if hasExplicitFilter {
                        handshakeState = .awaitingTightFilter(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed)
                    } else {
                        let context = makeTightBasicContext(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, filter: .copy, palette: [])
                        handshakeState = advanceTightDataState(for: context)
                    }
                } else {
                    delegate?.rfbSetError("VNC Tight unsupported subencoding: \(mode)")
                    delegate?.rfbStopConnection(reason: "tight unsupported subencoding")
                    return
                }

            case .awaitingTightFill(let x, let y, let w, let h, let remaining):
                guard receiveBuffer.count >= 3 else { return }
                let red = receiveBuffer[0]
                let green = receiveBuffer[1]
                let blue = receiveBuffer[2]
                receiveBuffer = Data(receiveBuffer.dropFirst(3))
                applyFillRect(x: x, y: y, w: w, h: h, red: red, green: green, blue: blue)
                if remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingTightFilter(let x, let y, let w, let h, let remaining, let streamID, let readUncompressed):
                guard receiveBuffer.count >= 1 else { return }
                let filterID = receiveBuffer[0]
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                switch filterID {
                case 0:
                    let context = makeTightBasicContext(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, filter: .copy, palette: [])
                    handshakeState = advanceTightDataState(for: context)
                case 1:
                    handshakeState = .awaitingTightPaletteCount(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed)
                case 2:
                    let context = makeTightBasicContext(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, filter: .gradient, palette: [])
                    handshakeState = advanceTightDataState(for: context)
                default:
                    delegate?.rfbSetError("VNC Tight unknown filter: \(filterID)")
                    delegate?.rfbStopConnection(reason: "tight unknown filter")
                    return
                }

            case .awaitingTightPaletteCount(let x, let y, let w, let h, let remaining, let streamID, let readUncompressed):
                guard receiveBuffer.count >= 1 else { return }
                let paletteEntries = Int(receiveBuffer[0]) + 1
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                handshakeState = .awaitingTightPaletteData(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, paletteEntries: paletteEntries)

            case .awaitingTightPaletteData(let x, let y, let w, let h, let remaining, let streamID, let readUncompressed, let paletteEntries):
                let paletteBytes = paletteEntries * 3
                guard receiveBuffer.count >= paletteBytes else { return }
                let paletteData = Data(receiveBuffer.prefix(paletteBytes))
                receiveBuffer = Data(receiveBuffer.dropFirst(paletteBytes))
                var palette = [[UInt8]]()
                palette.reserveCapacity(paletteEntries)
                for index in 0..<paletteEntries {
                    let offset = index * 3
                    let red = paletteData[offset]
                    let green = paletteData[offset + 1]
                    let blue = paletteData[offset + 2]
                    palette.append([blue, green, red, 0])
                }
                let context = makeTightBasicContext(x: x, y: y, w: w, h: h, remaining: remaining, streamID: streamID, readUncompressed: readUncompressed, filter: .palette, palette: palette)
                handshakeState = advanceTightDataState(for: context)

            case .awaitingTightDataLength(let context):
                guard let (compressedBytes, consumedBytes) = parseCompactLength(from: receiveBuffer) else { return }
                receiveBuffer = Data(receiveBuffer.dropFirst(consumedBytes))
                logVerboseFramebuffer("VNC Tight: compactLength=\(compressedBytes) consumed=\(consumedBytes) payloadSize=\(context.rowSize * context.h)")
                handshakeState = .awaitingTightData(context, compressedBytes: compressedBytes)

            case .awaitingTightData(let context, let compressedBytes):
                let payloadSize = context.rowSize * context.h
                guard receiveBuffer.count >= compressedBytes else { return }
                let compressedData = Data(receiveBuffer.prefix(compressedBytes))
                receiveBuffer = Data(receiveBuffer.dropFirst(compressedBytes))
                let decodedPayload: Data
                if context.readUncompressed {
                    decodedPayload = compressedData
                } else {
                    guard let inflated = inflateTightData(compressedData, expectedSize: payloadSize, streamID: context.streamID) else {
                        delegate?.rfbSetError("VNC Tight decode failed")
                        delegate?.rfbStopConnection(reason: "tight decode failed")
                        return
                    }
                    decodedPayload = inflated
                }

                guard let pixels = decodeTightPixels(from: decodedPayload, context: context) else {
                    delegate?.rfbSetError("VNC Tight filter decode failed")
                    delegate?.rfbStopConnection(reason: "tight filter decode failed")
                    return
                }
                applyRawRect(x: context.x, y: context.y, w: context.w, h: context.h, pixels: pixels)
                if context.remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: context.remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingTightJPEGLength(let x, let y, let w, let h, let remaining):
                guard let (compressedBytes, consumedBytes) = parseCompactLength(from: receiveBuffer) else { return }
                receiveBuffer = Data(receiveBuffer.dropFirst(consumedBytes))
                handshakeState = .awaitingTightJPEGData(x: x, y: y, w: w, h: h, remaining: remaining, compressedBytes: compressedBytes)

            case .awaitingTightJPEGData(let x, let y, let w, let h, let remaining, let compressedBytes):
                guard receiveBuffer.count >= compressedBytes else { return }
                let jpegData = Data(receiveBuffer.prefix(compressedBytes))
                receiveBuffer = Data(receiveBuffer.dropFirst(compressedBytes))
                guard let pixels = decodeTightJPEG(jpegData, width: w, height: h) else {
                    delegate?.rfbSetError("VNC Tight JPEG decode failed")
                    delegate?.rfbStopConnection(reason: "tight jpeg decode failed")
                    return
                }
                applyRawRect(x: x, y: y, w: w, h: h, pixels: pixels)
                if remaining > 0 {
                    handshakeState = .awaitingRectHeader(remaining: remaining)
                } else {
                    publishFrame()
                    handshakeState = .awaitingMessageType
                }

            case .awaitingServerCutTextHeader:
                guard receiveBuffer.count >= 7 else { return }
                let textLen = Int(
                    UInt32(receiveBuffer[3]) << 24 | UInt32(receiveBuffer[4]) << 16 |
                    UInt32(receiveBuffer[5]) << 8  | UInt32(receiveBuffer[6])
                )
                receiveBuffer = Data(receiveBuffer.dropFirst(7))
                handshakeState = textLen > 0 ? .awaitingSkip(textLen) : .awaitingMessageType

            case .awaitingSkip(let n):
                guard receiveBuffer.count >= n else { return }
                receiveBuffer = Data(receiveBuffer.dropFirst(n))
                handshakeState = .awaitingMessageType
            }
        }
    }

    private func usernameDiagnostics(_ username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLen = username.utf8.count
        let trimmedLen = trimmed.utf8.count
        let hasOuterWhitespace = rawLen != trimmedLen
        let fingerprint = fnv1a64Hex(username)
        return "rawLen=\(rawLen) trimmedLen=\(trimmedLen) outerWhitespace=\(hasOuterWhitespace) fp=\(fingerprint)"
    }

    private func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        let prime: UInt64 = 1099511628211
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private func securitySummary(status: UInt32, reason: String) -> String {
        let sec = selectedSecurityType.map(String.init) ?? "unknown"
        return "VNC auth summary: secType=\(sec) status=\(status) reason=\(reason)"
    }

    private func logVerboseFramebuffer(_ message: String) {
        guard verboseFramebufferLogs else { return }
        delegate?.logger.log(content: message)
    }

    private func sendSetPixelFormat() {
        var msg = Data(count: 20)
        msg[0]  = 0
        msg[4]  = 32
        msg[5]  = 24
        msg[6]  = 0
        msg[7]  = 1
        msg[8]  = 0; msg[9]  = 255
        msg[10] = 0; msg[11] = 255
        msg[12] = 0; msg[13] = 255
        msg[14] = 16
        msg[15] = 8
        msg[16] = 0
        delegate?.rfbSend(msg)
    }

    private func sendSetEncodings() {
        var encodings = [Int32]()
        if useTightCompression {
            encodings.append(7)
        }
        if useZLIBCompression {
            encodings.append(6)
        }
        encodings.append(contentsOf: [0, 1])
        let encodingCount = UInt16(encodings.count)
        var msg = Data(count: 4 + (encodings.count * 4))
        msg[0] = 2
        msg[1] = 0
        msg[2] = UInt8((encodingCount >> 8) & 0xFF)
        msg[3] = UInt8(encodingCount & 0xFF)
        for (index, encoding) in encodings.enumerated() {
            let offset = 4 + (index * 4)
            msg[offset] = UInt8((encoding >> 24) & 0xFF)
            msg[offset + 1] = UInt8((encoding >> 16) & 0xFF)
            msg[offset + 2] = UInt8((encoding >> 8) & 0xFF)
            msg[offset + 3] = UInt8(encoding & 0xFF)
        }
        let encodingNames = encodings.map { enc -> String in
            switch enc {
            case 0: return "Raw"
            case 1: return "CopyRect"
            case 6: return "ZLIB"
            case 7: return "Tight"
            default: return "Unknown(\(enc))"
            }
        }.joined(separator: ", ")
        delegate?.logger.log(content: "VNC SetEncodings: requested=[\(encodingNames)], zlibEnabled=\(useZLIBCompression) tightEnabled=\(useTightCompression)")
        delegate?.rfbSend(msg)
    }

    private func sendFramebufferUpdateRequest(incremental: Bool) {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard size.width > 0, size.height > 0 else { return }
        var msg = Data(count: 10)
        msg[0] = 3
        msg[1] = incremental ? 1 : 0
        msg[6] = UInt8(size.width >> 8 & 0xFF)
        msg[7] = UInt8(size.width & 0xFF)
        msg[8] = UInt8(size.height >> 8 & 0xFF)
        msg[9] = UInt8(size.height & 0xFF)
        delegate?.rfbSend(msg)
    }

    private func publishFrame() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(frameDeliveryStartTime)
        let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
        let bwMB = elapsed > 0 ? Double(rawBytesProcessed) / elapsed / 1_000_000 : 0
        AppStatus.setRemotePerformanceStats(fps: fps, bandwidthMBps: bwMB)
        if lastFrameStatsLogTime == .distantPast || now.timeIntervalSince(lastFrameStatsLogTime) >= 5 {
            delegate?.logger.log(content: "VNC frames: count=\(frameCount), pixels=\(framebufferPixels.count), fps=\(String(format: "%.1f", fps)), bw=\(String(format: "%.2f", bwMB))MB/s, zlibEnabled=\(useZLIBCompression)")
            lastFrameStatsLogTime = now
        }
        let frame = makeImage()
        delegate?.rfbPublishFrame(frame)
        sendFramebufferUpdateRequest(incremental: true)
    }

    private func applyRawRect(x: Int, y: Int, w: Int, h: Int, pixels: Data) {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard x >= 0, y >= 0, w > 0, h > 0,
              x + w <= size.width, y + h <= size.height else { return }
        rawBytesProcessed &+= UInt64(pixels.count)
        let srcBPR = w * 4
        let dstBPR = size.width * 4
        for row in 0..<h {
            let srcOff = row * srcBPR
            let dstOff = (y + row) * dstBPR + x * 4
            framebufferPixels.replaceSubrange(dstOff ..< dstOff + srcBPR,
                                              with: pixels[srcOff ..< srcOff + srcBPR])
        }
    }

    private func applyCopyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, w: Int, h: Int) {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0, w > 0, h > 0,
              srcX + w <= size.width, srcY + h <= size.height,
              dstX + w <= size.width, dstY + h <= size.height else { return }
        let bpr = size.width * 4
        var src = Data(count: w * h * 4)
        for row in 0..<h {
            let s = (srcY + row) * bpr + srcX * 4
            let d = row * w * 4
            src.replaceSubrange(d ..< d + w * 4, with: framebufferPixels[s ..< s + w * 4])
        }
        for row in 0..<h {
            let s = row * w * 4
            let d = (dstY + row) * bpr + dstX * 4
            framebufferPixels.replaceSubrange(d ..< d + w * 4, with: src[s ..< s + w * 4])
        }
    }

    private func resetZlibStream() {
        if zlibStreamInitialized {
            inflateEnd(&zlibStream)
            zlibStreamInitialized = false
        }
        zlibStream = z_stream()
    }

    private func resetTightZlibStreams() {
        for streamID in 0..<tightZlibStreams.count {
            resetTightZlibStream(streamID: streamID)
        }
    }

    private func resetTightStreams(using controlByte: UInt8) {
        // Bits 3-0 are stream-reset flags for streams 0...3.
        for streamID in 0..<4 where (controlByte & (1 << streamID)) != 0 {
            resetTightZlibStream(streamID: streamID)
        }
    }

    private func resetTightZlibStream(streamID: Int) {
        guard tightZlibStreams.indices.contains(streamID) else { return }
        if tightZlibStreamInitialized[streamID] {
            inflateEnd(&tightZlibStreams[streamID])
            tightZlibStreamInitialized[streamID] = false
        }
        tightZlibStreams[streamID] = z_stream()
    }

    private func ensureZlibStream() -> Bool {
        if zlibStreamInitialized {
            return true
        }
        zlibStream.zalloc = nil
        zlibStream.zfree = nil
        zlibStream.opaque = nil
        zlibStream.avail_in = 0
        zlibStream.next_in = nil
        zlibStream.avail_out = 0
        zlibStream.next_out = nil
        let result = inflateInit_(&zlibStream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            delegate?.logger.log(content: "VNC ZLIB: inflateInit failed result=\(result)")
            return false
        }
        zlibStreamInitialized = true
        return true
    }

    private func inflateZlibRectangle(_ compressedData: Data, expectedSize: Int) -> Data? {
        guard ensureZlibStream() else { return nil }
        var output = Data(count: expectedSize)
        let result: Int32 = compressedData.withUnsafeBytes { srcBuffer in
            output.withUnsafeMutableBytes { dstBuffer in
                guard let srcBase = srcBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let dstBase = dstBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_BUF_ERROR
                }
                zlibStream.next_in = UnsafeMutablePointer(mutating: srcBase)
                zlibStream.avail_in = uInt(compressedData.count)
                zlibStream.next_out = dstBase
                zlibStream.avail_out = uInt(expectedSize)
                zlibStream.data_type = Z_BINARY
                return inflate(&zlibStream, Z_SYNC_FLUSH)
            }
        }

        if result == Z_NEED_DICT {
            delegate?.logger.log(content: "VNC ZLIB: inflate requested dictionary")
            return nil
        }
        if result < 0 {
            let message = zlibStream.msg.map { String(cString: $0) } ?? "none"
            delegate?.logger.log(content: "VNC ZLIB: inflate failed result=\(result) msg=\(message)")
            return nil
        }
        if zlibStream.avail_in > 0 && zlibStream.avail_out == 0 {
            delegate?.logger.log(content: "VNC ZLIB: output buffer exhausted while input remained")
            return nil
        }

        let produced = expectedSize - Int(zlibStream.avail_out)
        guard produced == expectedSize else {
            delegate?.logger.log(content: "VNC ZLIB: produced \(produced) bytes, expected \(expectedSize)")
            return nil
        }
        return output
    }

    private func ensureTightZlibStream(streamID: Int) -> Bool {
        guard tightZlibStreams.indices.contains(streamID) else { return false }
        if tightZlibStreamInitialized[streamID] {
            return true
        }

        tightZlibStreams[streamID].zalloc = nil
        tightZlibStreams[streamID].zfree = nil
        tightZlibStreams[streamID].opaque = nil
        tightZlibStreams[streamID].avail_in = 0
        tightZlibStreams[streamID].next_in = nil
        tightZlibStreams[streamID].avail_out = 0
        tightZlibStreams[streamID].next_out = nil

        let result = inflateInit_(&tightZlibStreams[streamID], zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            delegate?.logger.log(content: "VNC Tight: inflateInit failed result=\(result) stream=\(streamID)")
            return false
        }
        tightZlibStreamInitialized[streamID] = true
        return true
    }

    private func inflateTightData(_ compressedData: Data, expectedSize: Int, streamID: Int) -> Data? {
        guard ensureTightZlibStream(streamID: streamID) else { return nil }
        guard expectedSize > 0 else { return Data() }
        
        var output = Data(count: expectedSize)
        let result: Int32 = compressedData.withUnsafeBytes { srcBuffer in
            output.withUnsafeMutableBytes { dstBuffer in
                guard let srcBase = srcBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let dstBase = dstBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_BUF_ERROR
                }
                tightZlibStreams[streamID].next_in = UnsafeMutablePointer(mutating: srcBase)
                tightZlibStreams[streamID].avail_in = uInt(compressedData.count)
                tightZlibStreams[streamID].next_out = dstBase
                tightZlibStreams[streamID].avail_out = uInt(expectedSize)
                tightZlibStreams[streamID].data_type = Z_BINARY
                return inflate(&tightZlibStreams[streamID], Z_SYNC_FLUSH)
            }
        }

        if result == Z_NEED_DICT {
            delegate?.logger.log(content: "VNC Tight: inflate requested dictionary stream=\(streamID)")
            return nil
        }
        if result < 0 {
            let message = tightZlibStreams[streamID].msg.map { String(cString: $0) } ?? "none"
            delegate?.logger.log(content: "VNC Tight: inflate failed result=\(result) stream=\(streamID) compressedLen=\(compressedData.count) expectedSize=\(expectedSize) msg=\(message)")
            return nil
        }

        let produced = expectedSize - Int(tightZlibStreams[streamID].avail_out)
        guard produced == expectedSize else {
            delegate?.logger.log(content: "VNC Tight: produced \(produced) bytes, expected \(expectedSize), stream=\(streamID)")
            return nil
        }

        return output
    }

    private func parseCompactLength(from data: Data) -> (value: Int, consumedBytes: Int)? {
        guard !data.isEmpty else { return nil }
        var length = Int(data[0] & 0x7F)
        if (data[0] & 0x80) == 0 {
            return (length, 1)
        }
        guard data.count >= 2 else { return nil }
        length |= Int(data[1] & 0x7F) << 7
        if (data[1] & 0x80) == 0 {
            return (length, 2)
        }
        guard data.count >= 3 else { return nil }
        length |= Int(data[2]) << 14
        return (length, 3)
    }

    private func makeTightBasicContext(x: Int,
                                       y: Int,
                                       w: Int,
                                       h: Int,
                                       remaining: Int,
                                       streamID: Int,
                                       readUncompressed: Bool,
                                       filter: TightFilterType,
                                       palette: [[UInt8]]) -> TightBasicRectContext {
        let bitsPerPixel: Int
        switch filter {
        case .copy, .gradient:
            bitsPerPixel = 24
        case .palette:
            bitsPerPixel = palette.count == 2 ? 1 : 8
        }
        let rowSize = (w * bitsPerPixel + 7) / 8
        return TightBasicRectContext(x: x,
                                     y: y,
                                     w: w,
                                     h: h,
                                     remaining: remaining,
                                     streamID: streamID,
                                     readUncompressed: readUncompressed,
                                     filter: filter,
                                     rowSize: rowSize,
                                     bitsPerPixel: bitsPerPixel,
                                     palette: palette)
    }

    private func advanceTightDataState(for context: TightBasicRectContext) -> RFBHandshakeState {
        let payloadSize = context.rowSize * context.h
        if context.readUncompressed {
            // Explicitly uncompressed (e.g. NoZlib modes 0x0A/0x0E)
            return .awaitingTightData(context, compressedBytes: payloadSize)
        }
        if payloadSize < 12 {
            // Small rects sent raw without compression or a length prefix
            let rawContext = TightBasicRectContext(
                x: context.x, y: context.y, w: context.w, h: context.h,
                remaining: context.remaining, streamID: context.streamID,
                readUncompressed: true, filter: context.filter,
                rowSize: context.rowSize, bitsPerPixel: context.bitsPerPixel,
                palette: context.palette)
            return .awaitingTightData(rawContext, compressedBytes: payloadSize)
        }
        return .awaitingTightDataLength(context)
    }

    private func decodeTightPixels(from payload: Data, context: TightBasicRectContext) -> Data? {
        let expectedPayloadSize = context.rowSize * context.h
        guard payload.count == expectedPayloadSize else {
            delegate?.logger.log(content: "VNC Tight: payload size mismatch got=\(payload.count) expected=\(expectedPayloadSize)")
            return nil
        }

        switch context.filter {
        case .copy:
            return decodeTightCopy(payload, width: context.w, height: context.h)
        case .palette:
            return decodeTightPalette(payload, width: context.w, height: context.h, palette: context.palette)
        case .gradient:
            return decodeTightGradient(payload, width: context.w, height: context.h)
        }
    }

    private func decodeTightCopy(_ payload: Data, width: Int, height: Int) -> Data? {
        guard payload.count == width * height * 3 else { return nil }
        var pixels = Data(count: width * height * 4)
        payload.withUnsafeBytes { srcBuffer in
            pixels.withUnsafeMutableBytes { dstBuffer in
                guard let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                for pixelIndex in 0..<(width * height) {
                    let srcOffset = pixelIndex * 3
                    let dstOffset = pixelIndex * 4
                    dst[dstOffset] = src[srcOffset + 2]
                    dst[dstOffset + 1] = src[srcOffset + 1]
                    dst[dstOffset + 2] = src[srcOffset]
                    dst[dstOffset + 3] = 0
                }
            }
        }
        return pixels
    }

    private func decodeTightPalette(_ payload: Data, width: Int, height: Int, palette: [[UInt8]]) -> Data? {
        guard !palette.isEmpty else { return nil }
        let rowSize = palette.count == 2 ? (width + 7) / 8 : width
        guard payload.count == rowSize * height else { return nil }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { dstBuffer in
            guard let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            if palette.count == 2 {
                payload.withUnsafeBytes { srcBuffer in
                    guard let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for y in 0..<height {
                        let rowBase = y * rowSize
                        for x in 0..<width {
                            let byte = src[rowBase + (x / 8)]
                            let bit = (byte >> (7 - (x % 8))) & 0x01
                            let color = palette[Int(bit)]
                            let dstOffset = (y * width + x) * 4
                            dst[dstOffset] = color[0]
                            dst[dstOffset + 1] = color[1]
                            dst[dstOffset + 2] = color[2]
                            dst[dstOffset + 3] = color[3]
                        }
                    }
                }
            } else {
                payload.withUnsafeBytes { srcBuffer in
                    guard let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for pixelIndex in 0..<(width * height) {
                        let paletteIndex = Int(src[pixelIndex])
                        guard palette.indices.contains(paletteIndex) else { continue }
                        let color = palette[paletteIndex]
                        let dstOffset = pixelIndex * 4
                        dst[dstOffset] = color[0]
                        dst[dstOffset + 1] = color[1]
                        dst[dstOffset + 2] = color[2]
                        dst[dstOffset + 3] = color[3]
                    }
                }
            }
        }
        return pixels
    }

    private func decodeTightGradient(_ payload: Data, width: Int, height: Int) -> Data? {
        guard payload.count == width * height * 3 else { return nil }
        let src = [UInt8](payload)
        var pixels = Data(count: width * height * 4)
        var prevRow = Array(repeating: UInt16(0), count: width * 3)
        var currentRow = Array(repeating: UInt16(0), count: width * 3)

        pixels.withUnsafeMutableBytes { dstBuffer in
            guard let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for y in 0..<height {
                let rowOffset = y * width * 3
                for c in 0..<3 {
                    let pix = UInt16((Int(prevRow[c]) + Int(src[rowOffset + c])) & 0xFF)
                    currentRow[c] = pix
                }
                writeTightRGBPixel(to: dst, pixelIndex: y * width, red: UInt8(currentRow[0]), green: UInt8(currentRow[1]), blue: UInt8(currentRow[2]))

                if width > 1 {
                    for x in 1..<width {
                        for c in 0..<3 {
                            let left = Int(currentRow[(x - 1) * 3 + c])
                            let up = Int(prevRow[x * 3 + c])
                            let upLeft = Int(prevRow[(x - 1) * 3 + c])
                            var estimate = left + up - upLeft
                            if estimate > 255 {
                                estimate = 255
                            } else if estimate < 0 {
                                estimate = 0
                            }
                            let sourceByte = Int(src[rowOffset + x * 3 + c])
                            currentRow[x * 3 + c] = UInt16((sourceByte + estimate) & 0xFF)
                        }
                        writeTightRGBPixel(to: dst,
                                           pixelIndex: y * width + x,
                                           red: UInt8(currentRow[x * 3]),
                                           green: UInt8(currentRow[x * 3 + 1]),
                                           blue: UInt8(currentRow[x * 3 + 2]))
                    }
                }
                prevRow = currentRow
            }
        }

        return pixels
    }

    private func writeTightRGBPixel(to dst: UnsafeMutablePointer<UInt8>, pixelIndex: Int, red: UInt8, green: UInt8, blue: UInt8) {
        let offset = pixelIndex * 4
        dst[offset] = blue
        dst[offset + 1] = green
        dst[offset + 2] = red
        dst[offset + 3] = 0
    }

    private func decodeTightJPEG(_ jpegData: Data, width: Int, height: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            delegate?.logger.log(content: "VNC Tight JPEG: CGImageSource decode failed")
            return nil
        }

        var pixels = Data(count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return rendered ? pixels : nil
    }

    private func applyFillRect(x: Int, y: Int, w: Int, h: Int, red: UInt8, green: UInt8, blue: UInt8) {
        let pixel = Data([blue, green, red, 0])
        let row = Data(repeating: 0, count: 0) + Array(repeating: pixel, count: w).reduce(into: Data()) { partial, element in
            partial.append(element)
        }
        var pixels = Data(capacity: w * h * 4)
        for _ in 0..<h {
            pixels.append(row)
        }
        applyRawRect(x: x, y: y, w: w, h: h, pixels: pixels)
    }

    private func makeImage() -> CGImage? {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard size.width > 0, size.height > 0 else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: framebufferPixels as CFData) else { return nil }
        return CGImage(
            width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    private func keySym(forKeyCode keyCode: UInt16, charactersIgnoringModifiers: String?) -> UInt32? {
        if let modifier = modifierKeySym(for: keyCode) {
            return modifier
        }

        switch Int(keyCode) {
        case Int(kVK_Return): return 0xFF0D
        case Int(kVK_Tab): return 0xFF09
        case Int(kVK_Space): return 0x0020
        case Int(kVK_Delete): return 0xFF08
        case Int(kVK_ForwardDelete): return 0xFFFF
        case Int(kVK_Escape): return 0xFF1B
        case Int(kVK_Home): return 0xFF50
        case Int(kVK_LeftArrow): return 0xFF51
        case Int(kVK_UpArrow): return 0xFF52
        case Int(kVK_RightArrow): return 0xFF53
        case Int(kVK_DownArrow): return 0xFF54
        case Int(kVK_PageUp): return 0xFF55
        case Int(kVK_PageDown): return 0xFF56
        case Int(kVK_End): return 0xFF57
        case Int(kVK_Help): return 0xFF63
        case Int(kVK_F1): return 0xFFBE
        case Int(kVK_F2): return 0xFFBF
        case Int(kVK_F3): return 0xFFC0
        case Int(kVK_F4): return 0xFFC1
        case Int(kVK_F5): return 0xFFC2
        case Int(kVK_F6): return 0xFFC3
        case Int(kVK_F7): return 0xFFC4
        case Int(kVK_F8): return 0xFFC5
        case Int(kVK_F9): return 0xFFC6
        case Int(kVK_F10): return 0xFFC7
        case Int(kVK_F11): return 0xFFC8
        case Int(kVK_F12): return 0xFFC9
        default:
            break
        }

        if let scalar = charactersIgnoringModifiers?.unicodeScalars.first {
            return scalar.value
        }

        return nil
    }

    private func modifierKeySym(for keyCode: UInt16) -> UInt32? {
        switch Int(keyCode) {
        case Int(kVK_Shift): return 0xFFE1
        case Int(kVK_RightShift): return 0xFFE2
        case Int(kVK_Control): return 0xFFE3
        case Int(kVK_RightControl): return 0xFFE4
        case Int(kVK_CapsLock): return 0xFFE5
        case Int(kVK_Option): return 0xFFE9
        case Int(kVK_RightOption): return 0xFFEA
        case Int(kVK_Command): return 0xFFEB
        case Int(kVK_RightCommand): return 0xFFEC
        default:
            return nil
        }
    }

    private func modifierIsDown(forKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(keyCode) {
        case Int(kVK_Shift): return flags.contains(.shift)
        case Int(kVK_RightShift): return flags.contains(.shift)
        case Int(kVK_Control): return flags.contains(.control)
        case Int(kVK_RightControl): return flags.contains(.control)
        case Int(kVK_Option): return flags.contains(.option)
        case Int(kVK_RightOption): return flags.contains(.option)
        case Int(kVK_Command): return flags.contains(.command)
        case Int(kVK_RightCommand): return flags.contains(.command)
        case Int(kVK_CapsLock): return flags.contains(.capsLock)
        default: return nil
        }
    }
}
