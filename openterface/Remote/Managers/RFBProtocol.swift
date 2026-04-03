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
    case awaitingServerCutTextHeader
    case awaitingSkip(Int)
}

final class RFBProtocolHandler {
    weak var delegate: RFBProtocolHandlerDelegate?

    private(set) var handshakeState: RFBHandshakeState = .idle
    private var receiveBuffer = Data()
    private var pointerButtonMask: UInt8 = 0
    private var selectedSecurityType: UInt8?

    init(delegate: RFBProtocolHandlerDelegate?) {
        self.delegate = delegate
    }

    func reset() {
        handshakeState = .idle
        receiveBuffer.removeAll(keepingCapacity: false)
        pointerButtonMask = 0
        selectedSecurityType = nil
    }

    func startHandshake() {
        handshakeState = .awaitingServerVersion
        receiveBuffer.removeAll(keepingCapacity: true)
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

    func handleKeyEvent(_ event: NSEvent, isDown: Bool) {
        guard let keySym = keySym(forKeyCode: event.keyCode,
                                  charactersIgnoringModifiers: event.charactersIgnoringModifiers) else { return }
        sendKeyEvent(keySym: keySym, isDown: isDown)
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard let keySym = modifierKeySym(for: event.keyCode),
              let isDown = modifierIsDown(forKeyCode: event.keyCode,
                                          modifierFlags: event.modifierFlags) else { return }
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
                delegate?.rfbSetFramebufferPixels(Data(count: size.width * size.height * 4))
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
                switch enc {
                case 0:
                    let bytes = rw * rh * 4
                    handshakeState = bytes > 0
                        ? .awaitingRectPixels(x: rx, y: ry, w: rw, h: rh, totalBytes: bytes, remaining: next)
                        : (next > 0 ? .awaitingRectHeader(remaining: next) : .awaitingMessageType)
                case 1:
                    handshakeState = .awaitingCopyRectSrc(dstX: rx, dstY: ry, w: rw, h: rh, remaining: next)
                default:
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
        var msg = Data(count: 12)
        msg[0] = 2
        msg[2] = 0; msg[3] = 2
        msg[4] = 0; msg[5] = 0; msg[6] = 0; msg[7] = 0
        msg[8] = 0; msg[9] = 0; msg[10] = 0; msg[11] = 1
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
        let frame = makeImage()
        delegate?.rfbPublishFrame(frame)
        sendFramebufferUpdateRequest(incremental: true)
    }

    private func applyRawRect(x: Int, y: Int, w: Int, h: Int, pixels: Data) {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard x >= 0, y >= 0, w > 0, h > 0,
              x + w <= size.width, y + h <= size.height else { return }
        var framebufferPixels = delegate?.rfbGetFramebufferPixels() ?? Data()
        let srcBPR = w * 4
        let dstBPR = size.width * 4
        for row in 0..<h {
            let srcOff = row * srcBPR
            let dstOff = (y + row) * dstBPR + x * 4
            framebufferPixels.replaceSubrange(dstOff ..< dstOff + srcBPR,
                                              with: pixels[srcOff ..< srcOff + srcBPR])
        }
        delegate?.rfbSetFramebufferPixels(framebufferPixels)
    }

    private func applyCopyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, w: Int, h: Int) {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0, w > 0, h > 0,
              srcX + w <= size.width, srcY + h <= size.height,
              dstX + w <= size.width, dstY + h <= size.height else { return }
        var framebufferPixels = delegate?.rfbGetFramebufferPixels() ?? Data()
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
        delegate?.rfbSetFramebufferPixels(framebufferPixels)
    }

    private func makeImage() -> CGImage? {
        let size = delegate?.rfbGetFramebufferSize() ?? (width: 0, height: 0)
        guard size.width > 0, size.height > 0 else { return nil }
        let framebufferPixels = delegate?.rfbGetFramebufferPixels() ?? Data()
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
