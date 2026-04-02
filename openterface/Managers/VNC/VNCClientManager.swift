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
import Network
import CommonCrypto
import CoreGraphics
import AppKit
import Carbon

// MARK: - RFB Handshake State Machine

private enum VNCHandshakeState {
    case idle
    case awaitingServerVersion
    case awaitingSecurityTypes
    case awaitingVNCAuthChallenge
    case awaitingSecurityResult
    case awaitingServerInitHeader
    case awaitingServerInitName(Int)
    // Post-handshake server message states
    case awaitingMessageType
    case awaitingFBUpdateHeader
    case awaitingRectHeader(remaining: Int)
    case awaitingRectPixels(x: Int, y: Int, w: Int, h: Int, totalBytes: Int, remaining: Int)
    case awaitingCopyRectSrc(dstX: Int, dstY: Int, w: Int, h: Int, remaining: Int)
    case awaitingServerCutTextHeader
    case awaitingSkip(Int)
}

// MARK: - VNCClientManager

final class VNCClientManager: VNCClientManagerProtocol {

    static let shared = VNCClientManager()

    // MARK: - VNCClientManagerProtocol conformance

    private(set) var isConnected: Bool = false
    private(set) var host: String = ""
    private(set) var port: Int = 5900
    var framebufferSize: CGSize {
        CGSize(width: framebufferWidth, height: framebufferHeight)
    }

    // MARK: - Private state

    private let queue = DispatchQueue(label: "com.openterface.vnc")
    private var connection: NWConnection?
    private var handshakeState: VNCHandshakeState = .idle
    private var receiveBuffer = Data()
    private let logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var framebufferWidth:  Int  = 0
    private var framebufferHeight: Int  = 0
    private var framebufferPixels: Data = Data()
    private(set) var currentFrame: CGImage?
    private var pointerButtonMask: UInt8 = 0

    private init() {}

    // MARK: - VNCClientManagerProtocol: connection lifecycle

    func connect(host: String, port: Int, password: String?) {
        queue.async { [weak self] in
            self?.performConnect(host: host, port: port, password: password)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopConnection(reason: "manual disconnect")
        }
    }

    // Must be called on `queue`.
    private func performConnect(host: String, port: Int, password: String?) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            setError("VNC host is empty.")
            logger.log(content: "VNC connect skipped: empty host")
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(1, min(port, 65535)))) else {
            setError("VNC port is invalid.")
            logger.log(content: "VNC connect skipped: invalid port \(port)")
            return
        }

        stopConnection(reason: "reconnect")

        self.host = trimmedHost
        self.port = port
        isConnected = false

        AppStatus.protocolSessionState = .connecting
        AppStatus.protocolLastErrorMessage = ""
        handshakeState = .awaitingServerVersion
        receiveBuffer.removeAll(keepingCapacity: true)

        let nwConnection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .tcp)
        connection = nwConnection

        logger.log(content: "VNC connecting to \(trimmedHost):\(port)")

        nwConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.log(content: "VNC TCP connection ready")
                self.receiveData()
            case .failed(let error):
                self.logger.log(content: "VNC connection failed: \(error.localizedDescription)")
                self.setError("VNC connection failed: \(error.localizedDescription)")
                self.stopConnection(reason: "connection failed")
            case .cancelled:
                self.logger.log(content: "VNC connection cancelled")
            default:
                break
            }
        }

        nwConnection.start(queue: queue)
    }

    // MARK: - VNCClientManagerProtocol: input forwarding (post-handshake)

    func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        queue.async { [weak self] in
            self?.performSendPointerEvent(x: x, y: y, buttonMask: buttonMask)
        }
    }

    func sendKeyEvent(keySym: UInt32, isDown: Bool) {
        queue.async { [weak self] in
            self?.performSendKeyEvent(keySym: keySym, isDown: isDown)
        }
    }

    func sendClipboardText(_ text: String) {
        queue.async { [weak self] in
            self?.performSendClipboardText(text)
        }
    }

    func sendScroll(x: Int, y: Int, deltaY: CGFloat, buttonMask: UInt8) {
        queue.async { [weak self] in
            self?.performSendScroll(x: x, y: y, deltaY: deltaY, buttonMask: buttonMask)
        }
    }

    func handleKeyEvent(_ event: NSEvent, isDown: Bool) {
        let keyCode = event.keyCode
        let charactersIgnoringModifiers = event.charactersIgnoringModifiers
        queue.async { [weak self] in
            self?.performHandleKeyEvent(
                keyCode: keyCode,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                isDown: isDown
            )
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlagsRawValue = event.modifierFlags.rawValue
        queue.async { [weak self] in
            self?.performHandleFlagsChanged(
                keyCode: keyCode,
                modifierFlagsRawValue: modifierFlagsRawValue
            )
        }
    }

    // MARK: - Private: teardown

    private func stopConnection(reason: String) {
        if connection != nil {
            logger.log(content: "VNC disconnect: \(reason)")
        }
        connection?.cancel()
        connection = nil
        handshakeState = .idle
        receiveBuffer.removeAll(keepingCapacity: false)
        isConnected = false
        framebufferWidth  = 0
        framebufferHeight = 0
        framebufferPixels = Data()
        currentFrame = nil
        pointerButtonMask = 0
        if AppStatus.activeConnectionProtocol == .vnc {
            AppStatus.protocolSessionState = .idle
        }
    }

    private func setError(_ message: String) {
        AppStatus.protocolSessionState = .error
        AppStatus.protocolLastErrorMessage = message
    }

    // MARK: - Private: receive loop

    private func receiveData() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.log(content: "VNC receive error: \(error.localizedDescription)")
                self.setError("VNC receive error: \(error.localizedDescription)")
                self.stopConnection(reason: "receive error")
                return
            }

            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processHandshakeBuffer()
            }

            if isComplete {
                self.logger.log(content: "VNC remote endpoint closed connection")
                self.stopConnection(reason: "remote closed")
                return
            }

            self.receiveData()
        }
    }

    // MARK: - Private: RFB 3.8 state machine (handshake + post-handshake messages)

    private func processHandshakeBuffer() {
        while true {
            switch handshakeState {

            case .idle:
                return

            // ── Handshake ────────────────────────────────────────────────────

            case .awaitingServerVersion:
                guard receiveBuffer.count >= 12 else { return }
                let versionData = Data(receiveBuffer.prefix(12))
                receiveBuffer = Data(receiveBuffer.dropFirst(12))
                guard let serverVersion = String(data: versionData, encoding: .ascii),
                      serverVersion.hasPrefix("RFB ") else {
                    setError("Invalid VNC server version response.")
                    stopConnection(reason: "invalid server version")
                    return
                }
                logger.log(content: "VNC server version: \(serverVersion.trimmingCharacters(in: .whitespacesAndNewlines))")
                send(Data("RFB 003.008\n".utf8))
                handshakeState = .awaitingSecurityTypes

            case .awaitingSecurityTypes:
                guard receiveBuffer.count >= 1 else { return }
                let count = Int(receiveBuffer[0])
                guard count > 0 else {
                    setError("VNC server does not offer supported security types.")
                    stopConnection(reason: "no security types")
                    return
                }
                guard receiveBuffer.count >= 1 + count else { return }
                let securityTypes = Array(receiveBuffer[1 ..< (1 + count)])
                receiveBuffer = Data(receiveBuffer.dropFirst(1 + count))
                if securityTypes.contains(1) {
                    send(Data([1]))
                    handshakeState = .awaitingSecurityResult
                } else if securityTypes.contains(2) {
                    send(Data([2]))
                    handshakeState = .awaitingVNCAuthChallenge
                } else {
                    setError("Unsupported VNC security types: \(securityTypes.map(String.init).joined(separator: ", "))")
                    stopConnection(reason: "unsupported security type")
                    return
                }

            case .awaitingVNCAuthChallenge:
                guard receiveBuffer.count >= 16 else { return }
                let challenge = Data(receiveBuffer.prefix(16))
                receiveBuffer = Data(receiveBuffer.dropFirst(16))
                let password = UserSettings.shared.vncPassword
                guard let response = desResponse(challenge: challenge, password: password) else {
                    setError("VNC auth: failed to encrypt challenge.")
                    stopConnection(reason: "vnc auth encrypt failed")
                    return
                }
                send(response)
                handshakeState = .awaitingSecurityResult

            case .awaitingSecurityResult:
                guard receiveBuffer.count >= 4 else { return }
                let statusData = Data(receiveBuffer.prefix(4))
                receiveBuffer = Data(receiveBuffer.dropFirst(4))
                let status = statusData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard status == 0 else {
                    setError("VNC security handshake failed (status \(status)).")
                    stopConnection(reason: "security failed")
                    return
                }
                send(Data([1]))  // ClientInit: shared flag
                handshakeState = .awaitingServerInitHeader

            case .awaitingServerInitHeader:
                guard receiveBuffer.count >= 24 else { return }
                let header = Array(receiveBuffer.prefix(24))
                receiveBuffer = Data(receiveBuffer.dropFirst(24))
                framebufferWidth  = Int(UInt16(header[0]) << 8 | UInt16(header[1]))
                framebufferHeight = Int(UInt16(header[2]) << 8 | UInt16(header[3]))
                let nameLength = Int(
                    UInt32(header[20]) << 24 | UInt32(header[21]) << 16 |
                    UInt32(header[22]) << 8  | UInt32(header[23])
                )
                logger.log(content: "VNC framebuffer: \(framebufferWidth)x\(framebufferHeight), nameLength=\(nameLength)")
                handshakeState = .awaitingServerInitName(nameLength)

            case .awaitingServerInitName(let nameLength):
                guard receiveBuffer.count >= nameLength else { return }
                let nameData = Data(receiveBuffer.prefix(nameLength))
                receiveBuffer = Data(receiveBuffer.dropFirst(nameLength))
                let serverName = String(data: nameData, encoding: .utf8) ?? "Unknown"
                logger.log(content: "VNC connected to desktop: \(serverName)")
                // Allocate pixel buffer (32bpp BGRA little-endian: bytes = [B,G,R,X])
                framebufferPixels = Data(count: framebufferWidth * framebufferHeight * 4)
                sendSetPixelFormat()
                sendSetEncodings()
                sendFramebufferUpdateRequest(incremental: false)
                handshakeState = .awaitingMessageType
                isConnected = true
                AppStatus.protocolSessionState = .connected
                AppStatus.protocolLastErrorMessage = ""

            // ── Post-handshake server messages ───────────────────────────────

            case .awaitingMessageType:
                guard receiveBuffer.count >= 1 else { return }
                let msgType = receiveBuffer[0]
                receiveBuffer = Data(receiveBuffer.dropFirst(1))
                switch msgType {
                case 0:  handshakeState = .awaitingFBUpdateHeader
                case 2:  logger.log(content: "VNC Bell") // no payload; loop continues
                case 3:  handshakeState = .awaitingServerCutTextHeader
                default:
                    setError("VNC unexpected server message type: \(msgType)")
                    stopConnection(reason: "unexpected message type")
                    return
                }

            case .awaitingFBUpdateHeader:
                guard receiveBuffer.count >= 3 else { return }
                // byte 0: padding; bytes 1-2: number-of-rectangles (big-endian)
                let numRects = Int(UInt16(receiveBuffer[1]) << 8 | UInt16(receiveBuffer[2]))
                receiveBuffer = Data(receiveBuffer.dropFirst(3))
                handshakeState = numRects > 0 ? .awaitingRectHeader(remaining: numRects) : .awaitingMessageType

            case .awaitingRectHeader(let remaining):
                guard receiveBuffer.count >= 12 else { return }
                let rx  = Int(UInt16(receiveBuffer[0])  << 8 | UInt16(receiveBuffer[1]))
                let ry  = Int(UInt16(receiveBuffer[2])  << 8 | UInt16(receiveBuffer[3]))
                let rw  = Int(UInt16(receiveBuffer[4])  << 8 | UInt16(receiveBuffer[5]))
                let rh  = Int(UInt16(receiveBuffer[6])  << 8 | UInt16(receiveBuffer[7]))
                let enc = Int32(bitPattern:
                    UInt32(receiveBuffer[8])  << 24 | UInt32(receiveBuffer[9])  << 16 |
                    UInt32(receiveBuffer[10]) << 8  | UInt32(receiveBuffer[11]))
                receiveBuffer = Data(receiveBuffer.dropFirst(12))
                let next = remaining - 1
                switch enc {
                case 0:  // Raw
                    let bytes = rw * rh * 4
                    handshakeState = bytes > 0
                        ? .awaitingRectPixels(x: rx, y: ry, w: rw, h: rh, totalBytes: bytes, remaining: next)
                        : (next > 0 ? .awaitingRectHeader(remaining: next) : .awaitingMessageType)
                case 1:  // CopyRect (4-byte src position follows)
                    handshakeState = .awaitingCopyRectSrc(dstX: rx, dstY: ry, w: rw, h: rh, remaining: next)
                default:
                    setError("VNC unsupported rect encoding: \(enc)")
                    stopConnection(reason: "unsupported rect encoding")
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
                // 3 bytes padding + 4 bytes length
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

    // MARK: - Private: framebuffer helpers

    private func publishFrame() {
        currentFrame = makeImage()
        sendFramebufferUpdateRequest(incremental: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vncFrameUpdated, object: nil)
        }
    }

    private func performSendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        guard isConnected else { return }
        pointerButtonMask = buttonMask
        // RFB PointerEvent: type=5, buttonMask, xPos (2B), yPos (2B)
        var msg = Data(count: 6)
        msg[0] = 5
        msg[1] = buttonMask
        msg[2] = UInt8((x >> 8) & 0xFF)
        msg[3] = UInt8(x & 0xFF)
        msg[4] = UInt8((y >> 8) & 0xFF)
        msg[5] = UInt8(y & 0xFF)
        send(msg)
    }

    private func performSendKeyEvent(keySym: UInt32, isDown: Bool) {
        guard isConnected else { return }
        // RFB KeyEvent: type=4, downFlag (1B), padding (2B), keySym (4B)
        var msg = Data(count: 8)
        msg[0] = 4
        msg[1] = isDown ? 1 : 0
        msg[2] = 0
        msg[3] = 0
        msg[4] = UInt8((keySym >> 24) & 0xFF)
        msg[5] = UInt8((keySym >> 16) & 0xFF)
        msg[6] = UInt8((keySym >> 8) & 0xFF)
        msg[7] = UInt8(keySym & 0xFF)
        send(msg)
    }

    private func performSendClipboardText(_ text: String) {
        guard isConnected, let textData = text.data(using: .isoLatin1) else { return }
        // RFB ClientCutText: type=6, padding (3B), length (4B), text
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
        send(msg)
    }

    private func performSendScroll(x: Int, y: Int, deltaY: CGFloat, buttonMask: UInt8) {
        guard isConnected else { return }
        let scrollButton: UInt8 = deltaY > 0 ? 0x08 : 0x10
        guard scrollButton != 0 else { return }
        performSendPointerEvent(x: x, y: y, buttonMask: buttonMask | scrollButton)
        performSendPointerEvent(x: x, y: y, buttonMask: buttonMask)
    }

    private func performHandleKeyEvent(keyCode: UInt16, charactersIgnoringModifiers: String?, isDown: Bool) {
        guard isConnected,
              let keySym = keySym(forKeyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) else { return }
        performSendKeyEvent(keySym: keySym, isDown: isDown)
    }

    private func performHandleFlagsChanged(keyCode: UInt16, modifierFlagsRawValue: NSEvent.ModifierFlags.RawValue) {
        guard isConnected,
              let keySym = modifierKeySym(for: keyCode),
              let isDown = modifierIsDown(forKeyCode: keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)) else { return }
        performSendKeyEvent(keySym: keySym, isDown: isDown)
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

    private func sendSetPixelFormat() {
        // 32bpp little-endian: red at shift 16, green at shift 8, blue at shift 0.
        // Bytes in memory per pixel: [B, G, R, padding].
        // CGImage: byteOrder32Little + noneSkipFirst = BGRA in byte order. ✓
        var msg = Data(count: 20)
        msg[0]  = 0   // SetPixelFormat
        // msg[1..3]: padding
        msg[4]  = 32  // bits-per-pixel
        msg[5]  = 24  // depth
        msg[6]  = 0   // big-endian-flag
        msg[7]  = 1   // true-colour-flag
        msg[8]  = 0; msg[9]  = 255  // red-max   (UInt16 big-endian)
        msg[10] = 0; msg[11] = 255  // green-max
        msg[12] = 0; msg[13] = 255  // blue-max
        msg[14] = 16  // red-shift
        msg[15] = 8   // green-shift
        msg[16] = 0   // blue-shift
        // msg[17..19]: padding
        send(msg)
    }

    private func sendSetEncodings() {
        // Advertise Raw (0) and CopyRect (1).
        var msg = Data(count: 12)
        msg[0]  = 2          // SetEncodings
        // msg[1]: padding
        msg[2]  = 0; msg[3]  = 2   // number-of-encodings = 2
        // Raw  = 0
        msg[4]  = 0; msg[5]  = 0; msg[6]  = 0; msg[7]  = 0
        // CopyRect = 1
        msg[8]  = 0; msg[9]  = 0; msg[10] = 0; msg[11] = 1
        send(msg)
    }

    private func sendFramebufferUpdateRequest(incremental: Bool) {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return }
        var msg = Data(count: 10)
        msg[0] = 3   // FramebufferUpdateRequest
        msg[1] = incremental ? 1 : 0
        // x=0, y=0 (bytes 2-5 remain 0)
        msg[6] = UInt8(framebufferWidth  >> 8 & 0xFF)
        msg[7] = UInt8(framebufferWidth       & 0xFF)
        msg[8] = UInt8(framebufferHeight >> 8 & 0xFF)
        msg[9] = UInt8(framebufferHeight      & 0xFF)
        send(msg)
    }

    private func applyRawRect(x: Int, y: Int, w: Int, h: Int, pixels: Data) {
        guard x >= 0, y >= 0, w > 0, h > 0,
              x + w <= framebufferWidth, y + h <= framebufferHeight else { return }
        let srcBPR = w * 4
        let dstBPR = framebufferWidth * 4
        for row in 0..<h {
            let srcOff = row * srcBPR
            let dstOff = (y + row) * dstBPR + x * 4
            framebufferPixels.replaceSubrange(dstOff ..< dstOff + srcBPR,
                                              with: pixels[srcOff ..< srcOff + srcBPR])
        }
    }

    private func applyCopyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, w: Int, h: Int) {
        guard srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0, w > 0, h > 0,
              srcX + w <= framebufferWidth, srcY + h <= framebufferHeight,
              dstX + w <= framebufferWidth, dstY + h <= framebufferHeight else { return }
        let bpr = framebufferWidth * 4
        // Extract source first to cover overlapping regions
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

    private func makeImage() -> CGImage? {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: framebufferPixels as CFData) else { return nil }
        return CGImage(
            width: framebufferWidth, height: framebufferHeight,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: framebufferWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }



    // MARK: - Private: send helper

    private func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.log(content: "VNC send error: \(error.localizedDescription)")
                self?.setError("VNC send error: \(error.localizedDescription)")
                self?.stopConnection(reason: "send error")
            }
        })
    }

    // MARK: - Private: VNC DES authentication (RFC 6143 §7.2.2)

    /// Encrypts the 16-byte server challenge with DES using the VNC password key.
    /// VNC reverses the bit order of each password byte before using it as the DES key.
    private func desResponse(challenge: Data, password: String) -> Data? {
        var keyBytes = [UInt8](repeating: 0, count: 8)
        let pwBytes = Array(password.utf8.prefix(8))
        for i in 0..<pwBytes.count { keyBytes[i] = pwBytes[i] }

        // Bit-reverse each key byte (VNC-specific DES encoding)
        for i in 0..<8 {
            var b = keyBytes[i]
            b = (b & 0xF0) >> 4 | (b & 0x0F) << 4
            b = (b & 0xCC) >> 2 | (b & 0x33) << 2
            b = (b & 0xAA) >> 1 | (b & 0x55) << 1
            keyBytes[i] = b
        }

        let challengeBytes = Array(challenge)

        func encryptBlock(_ block: [UInt8]) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: 8)
            var outLen = 0
            let status = out.withUnsafeMutableBytes { outPtr in
                block.withUnsafeBytes { inPtr in
                    keyBytes.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, kCCKeySizeDES,
                            nil,
                            inPtr.baseAddress, 8,
                            outPtr.baseAddress, 8,
                            &outLen
                        )
                    }
                }
            }
            return status == kCCSuccess ? out : nil
        }

        guard let b1 = encryptBlock(Array(challengeBytes[0..<8])),
              let b2 = encryptBlock(Array(challengeBytes[8..<16])) else { return nil }

        var result = Data(count: 16)
        result.replaceSubrange(0..<8,  with: b1)
        result.replaceSubrange(8..<16, with: b2)
        return result
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let vncFrameUpdated = Notification.Name("VNCFrameUpdated")
}
