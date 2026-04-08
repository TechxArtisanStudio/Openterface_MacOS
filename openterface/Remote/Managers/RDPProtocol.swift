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
*    along with this program. If not, see <http://www.gnu.org/licenses/>.   *
*                                                                            *
* ========================================================================== *
*/

import Foundation
import Security
import AppKit
import CommonCrypto
import os.log

private let rdpTraceLog = OSLog(subsystem: "com.openterface.rdp", category: "trace")

// MARK: - RDP Protocol PDU parsing and construction

enum RDPHandshakeState {
    case idle
    case awaitingServerData
    case awaitingClientInfo
    case awaitingLicense
    case awaitingDemandActive
    case awaitingConfirmActiveResponse
    case awaitingControlGrant
    case awaitingFontMap
    case active
    case awaitingCredSSP
    case awaitingNTLMChallenge
    case awaitingCredSSPPubKeyEcho
    case awaitingMCSConnectResponse
    case awaitingMCSAttachUserConfirm
    case awaitingMCSChannelJoinConfirm
}

protocol RDPProtocolHandlerDelegate: AnyObject {
    var logger: LoggerProtocol { get }

    func rdpSend(_ data: Data)
    func rdpAttemptTLSUpgrade() -> Bool
    func rdpSetError(_ message: String)
    func rdpStopConnection(reason: String)
    func rdpMarkConnected()
    func rdpPublishFrame(_ frame: CGImage?)
    func rdpSetFramebufferSize(width: Int, height: Int)
    func rdpGetFramebufferSize() -> (width: Int, height: Int)
}

final class RDPProtocolHandler {
    weak var delegate: RDPProtocolHandlerDelegate?

    // Trace using os_log at error level so it always appears in log stream
    static func trace(_ msg: String) {
        os_log(.error, log: rdpTraceLog, "[RDPTrace] %{public}@", msg)
    }

    private(set) var handshakeState: RDPHandshakeState = .idle
    private var receiveBuffer = Data()
    private var encryptionContext: (clientEnc: RDPrc4?, serverEnc: RDPrc4?, macKey: [UInt8])? = nil
    private var clientRandom = [UInt8](repeating: 0, count: 32)
    private var serverRandom = [UInt8]()
    private var serverPublicKey = [UInt8]()

    // CredSSP / NTLMv2 state
    private var ntlmAuth: NTLMAuth?
    private var credSSPClientNonce = Data()   // 32-byte nonce for v5/v6 pubKeyAuth binding

    private var username: String = ""
    private var password: String = ""
    private var domain: String = ""
    private var credSSPTimeoutWorkItem: DispatchWorkItem?
    private var mcsUserId: UInt16?
    private var pendingMCSChannels: [UInt16] = []
    // Stability-first profile: optional static virtual channels stay disabled
    // until corresponding client handlers are fully implemented.
    private let advertisedStaticChannels: [(String, UInt32)] = []
    private var rdpClientChannelId: UInt16 {
        return mcsUserChannelId ?? 0x03EA
    }
    private var rdpShareId: UInt32 = 0x000103EA
    private var rdpDesktopWidth: Int = 0
    private var rdpDesktopHeight: Int = 0
    private var lastAckedFrameId: UInt32?
    private var frameCounter: UInt32 = 0  // Incremented on FRAME_START, used for ack on FRAME_END
    private var lastFrameMarkerSeenAt: Date?
    private var hasOpenOrdersFrameMarker = false
    private var openOrdersFrameMarkerAt: Date?
    private var hasPendingFramebufferPublish = false
    private let framebufferPublishDelay: TimeInterval = 0.012
    private var pendingFramebufferPublishWorkItem: DispatchWorkItem?
    private var suppressOutboundSends = false
    private var serverSupportsFrameAcknowledge = false
    private var serverSupportsSurfaceCommands = false
    private var usingEnhancedSecurityTransport = false
    private var hasControl = false
    private var hasSentWakeDisplayInput = false
    private var hasSentSaveSessionInfoNudge = false
    private var postActivationNudgeWorkItems: [DispatchWorkItem] = []
    private var preferNonNLAForBringup: Bool { !UserSettings.shared.rdpEnableNLA }
    private var strictCompatibilityMode: Bool { UserSettings.shared.rdpStrictCompatibilityMode }
    private var strictDebugAllowFastPathOutput: Bool { UserSettings.shared.rdpDebugAllowFastPathOutputInStrictMode }
    private var strictDebugAllowBitmapCodecs: Bool { UserSettings.shared.rdpDebugAllowBitmapCodecsInStrictMode }
    private var allowBitmapEOFSalvage: Bool {
        // Default is to avoid rendering visibly corrupted partial frames.
        // Set OPENTERFACE_RDP_EOF_SALVAGE_BITMAP=1 to force legacy salvage behavior.
        return ProcessInfo.processInfo.environment["OPENTERFACE_RDP_EOF_SALVAGE_BITMAP"] == "1"
    }
    private let pointerMoveFlag: UInt16 = 0x0800
    private let pointerCoalesceInterval: TimeInterval = 1.0 / 90.0
    private var pendingPointerEvent: (x: Int, y: Int, flags: UInt16)?
    private var pointerCoalesceWorkItem: DispatchWorkItem?
    private var pointerLastSentAt: Date = .distantPast
    private let framebufferCoverageTileSize = 64
    private let framebufferCoverageSufficientThreshold = 0.90
    private let framebufferCoverageRetryThreshold = 0.75
    private let framebufferRefreshRetryCooldown: TimeInterval = 0.75
    private let maxFramebufferRefreshRetries = 6
    private var framebufferUpdatedTiles: Set<Int> = []
    private var framebufferRefreshRetryCount = 0
    private var lastFramebufferRefreshAt: Date = .distantPast

    private var mcsUserChannelId: UInt16? {
        guard let userId = mcsUserId else { return nil }
        return UInt16(1001 + Int(userId))
    }

    var receiveBufferCount: Int { receiveBuffer.count }

        // Fast-Path fragment reassembly and framebuffer
        private var fpFragmentBuffer = Data()
        private var fpFragmentUpdateCode: UInt8?
        private var fpFragmentStartTime: Date?
        private let fpFragmentMaxBytes = 16 * 1024 * 1024
        private let fpAllowOrphanRecovery = true
        private var fpFramebufferStorage: NSMutableData?
        private var fpFramebuffer: CGContext?
        private var fpFramebufferWidth  = 1920
        private var fpFramebufferHeight = 1080

    /// Dispatch queue the protocol handler uses for internal scheduling (post-activation
    /// nudges, timers). Must be set by the owner (RDPClientManager) to the RDP serial queue
    /// so that scheduled work runs in the correct serialisation context.
    var schedulingQueue: DispatchQueue?

    init(delegate: RDPProtocolHandlerDelegate?) {
        self.delegate = delegate
    }

    /// Called when the transport layer reports EOF.  Attempts to salvage any
    /// in-progress Fast-Path fragment train so that the last bitmap update is
    /// not silently lost, and logs diagnostic state for post-mortem analysis.
    func flushOnEOF() {
        delegate?.logger.log(content: "RDP EOF state: hs=\(handshakeState) supportsFrameAck=\(serverSupportsFrameAcknowledge) supportsSurface=\(serverSupportsSurfaceCommands) frameCounter=\(frameCounter) lastAcked=\(lastAckedFrameId.map(String.init) ?? "nil") openOrdersMarker=\(hasOpenOrdersFrameMarker) recvBuf=\(receiveBuffer.count)")
        // Transport is closing; do not emit any further outbound PDUs from salvage paths.
        suppressOutboundSends = true
        if !fpFragmentBuffer.isEmpty {
            let code = fpFragmentUpdateCode ?? 0xFF
            let codeText = String(format: "0x%02x", code)
            let ageMs: Int
            if let start = fpFragmentStartTime {
                ageMs = Int(Date().timeIntervalSince(start) * 1000)
            } else {
                ageMs = -1
            }
            if code == 0x01 && !allowBitmapEOFSalvage {
                delegate?.logger.log(content: "RDP EOF: dropping incomplete BITMAP fragment train code=\(codeText) accumulated=\(fpFragmentBuffer.count) bytes ageMs=\(ageMs) (set OPENTERFACE_RDP_EOF_SALVAGE_BITMAP=1 to salvage)")
            } else {
                delegate?.logger.log(content: "RDP EOF: fragment train in progress code=\(codeText) accumulated=\(fpFragmentBuffer.count) bytes ageMs=\(ageMs) — attempting salvage")

                // Treat the accumulated data as a complete update. This mirrors
                // what FreeRDP does when a transport error interrupts a train.
                handleFastPathUpdate(code: code, data: [UInt8](fpFragmentBuffer))
            }
            resetFastPathFragmentTrain(reason: nil, keepingCapacity: false)
        }
        if !receiveBuffer.isEmpty {
            logReceiveBufferSummaryOnEOF(receiveBuffer)
        }
    }

    private func logReceiveBufferSummaryOnEOF(_ data: Data) {
        let bytes = [UInt8](data)
        let prefix = bytes.prefix(min(bytes.count, 24)).map { String(format: "%02x", $0) }.joined(separator: " ")
        delegate?.logger.log(content: "RDP EOF: \(bytes.count) bytes remain in receive buffer (prefix=\(prefix))")

        guard bytes.count >= 2 else {
            delegate?.logger.log(content: "RDP EOF parse: receive buffer too short for header")
            return
        }

        let b0 = bytes[0]
        if b0 == 0x03 {
            guard bytes.count >= 4 else {
                delegate?.logger.log(content: "RDP EOF parse: looks like TPKT but header incomplete (\(bytes.count) bytes)")
                return
            }
            let tpktLen = (Int(bytes[2]) << 8) | Int(bytes[3])
            delegate?.logger.log(content: "RDP EOF parse: TPKT header version=0x03 len=\(tpktLen) buffered=\(bytes.count)")
            return
        }

        // Candidate Fast-Path packet header
        var packetLen = Int(bytes[1])
        var hdrLen = 2
        if (bytes[1] & 0x80) != 0 {
            guard bytes.count >= 3 else {
                delegate?.logger.log(content: "RDP EOF parse: Fast-Path long-length header incomplete (\(bytes.count) bytes)")
                return
            }
            packetLen = (Int(bytes[1] & 0x7F) << 8) | Int(bytes[2])
            hdrLen = 3
        }

        let action = (b0 >> 6) & 0x03
        delegate?.logger.log(content: "RDP EOF parse: Fast-Path candidate action=0x\(String(action, radix: 16)) packetLen=\(packetLen) headerLen=\(hdrLen) buffered=\(bytes.count)")

        guard bytes.count >= hdrLen + 3 else {
            delegate?.logger.log(content: "RDP EOF parse: Fast-Path update header incomplete")
            return
        }
        let updateHdr = bytes[hdrLen]
        let updateCode = updateHdr & 0x0F
        let frag = (updateHdr >> 4) & 0x03
        let updLen = Int(bytes[hdrLen + 1]) | (Int(bytes[hdrLen + 2]) << 8)
        delegate?.logger.log(content: "RDP EOF parse: Fast-Path update hdr=0x\(String(format: "%02x", updateHdr)) code=0x\(String(updateCode, radix: 16)) frag=\(frag) updateLen=\(updLen)")
    }

    func reset() {
        cancelCredSSPTimeout()
        handshakeState = .idle
        receiveBuffer.removeAll(keepingCapacity: false)
        encryptionContext = nil
        clientRandom = [UInt8](repeating: 0, count: 32)
        serverRandom = []
        serverPublicKey = []
        username = ""
        password = ""
        domain = ""
        ntlmAuth = nil
        credSSPClientNonce = Data()
        mcsUserId = nil
        pendingMCSChannels = []
        rdpShareId = 0x000103EA
        rdpDesktopWidth = 0
        rdpDesktopHeight = 0
        lastAckedFrameId = nil
        frameCounter = 0
        lastFrameMarkerSeenAt = nil
        hasOpenOrdersFrameMarker = false
        openOrdersFrameMarkerAt = nil
        hasPendingFramebufferPublish = false
        pendingFramebufferPublishWorkItem?.cancel()
        pendingFramebufferPublishWorkItem = nil
        suppressOutboundSends = false
        serverSupportsFrameAcknowledge = false
        serverSupportsSurfaceCommands = false
        usingEnhancedSecurityTransport = false
        hasControl = false
        hasSentWakeDisplayInput = false
        hasSentSaveSessionInfoNudge = false
        cancelPostActivationNudges()
        pointerCoalesceWorkItem?.cancel()
        pointerCoalesceWorkItem = nil
        pendingPointerEvent = nil
        pointerLastSentAt = .distantPast
        framebufferUpdatedTiles.removeAll(keepingCapacity: false)
        framebufferRefreshRetryCount = 0
        lastFramebufferRefreshAt = .distantPast
        resetFastPathFragmentTrain(reason: nil, keepingCapacity: false)
        fpFramebuffer = nil
        fpFramebufferStorage = nil
    }

    func startHandshake(username: String = "", password: String = "", domain: String = "") {
        reset()
        self.username = username
        self.password = password
        self.domain = domain
        
        handshakeState = .awaitingServerData
        receiveBuffer.removeAll(keepingCapacity: true)

        // Generate client random
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &clientRandom) == errSecSuccess else {
            delegate?.rdpSetError("Failed to generate client random")
            return
        }

        sendX224ConnectionRequest()
    }

    func ingest(_ data: Data) {
        RDPProtocolHandler.trace("ingest: \(data.count) bytes, state=\(handshakeState), bufBefore=\(receiveBuffer.count)")
        if handshakeState == .awaitingCredSSP {
            cancelCredSSPTimeout()
        }
        delegate?.logger.log(content: "RDP ingest: \(data.count) bytes appended to buffer (total: \(receiveBuffer.count + data.count))")
        receiveBuffer.append(data)
        processBuffer()
    }

    func sendPointerEvent(x: Int, y: Int, flags: UInt16) {
        guard case .active = handshakeState else { return }
        let isMoveOnly = (flags & pointerMoveFlag) != 0 && (flags & ~pointerMoveFlag) == 0

        // Non-move pointer events (button down/up, wheel, etc.) should remain immediate.
        if !isMoveOnly {
            flushPendingPointerEventIfNeeded()
            sendInputEventsPDU(pointerEvents: buildPointerEventPDU(x: x, y: y, flags: flags))
            pointerLastSentAt = Date()
            return
        }

        // Coalesce dense pointer-move traffic and send at a bounded rate.
        pendingPointerEvent = (x, y, flags)
        let now = Date()
        let elapsed = now.timeIntervalSince(pointerLastSentAt)
        if elapsed >= pointerCoalesceInterval {
            flushPendingPointerEventIfNeeded()
            return
        }

        guard pointerCoalesceWorkItem == nil else { return }
        let delay = pointerCoalesceInterval - elapsed
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pointerCoalesceWorkItem = nil
            self.flushPendingPointerEventIfNeeded()
        }
        pointerCoalesceWorkItem = work
        (schedulingQueue ?? DispatchQueue.main).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func buildPointerEventPDU(x: Int, y: Int, flags: UInt16) -> Data {
        // TS_POINTER_EVENT in compact form for sendInputEventsPDU.
        var pdu = Data()
        pdu.append(contentsOf: withUnsafeBytes(of: UInt16(littleEndian: UInt16(x))) { Data($0) })
        pdu.append(contentsOf: withUnsafeBytes(of: UInt16(littleEndian: UInt16(y))) { Data($0) })
        pdu.append(contentsOf: withUnsafeBytes(of: UInt16(littleEndian: flags)) { Data($0) })
        return pdu
    }

    private func flushPendingPointerEventIfNeeded() {
        guard case .active = handshakeState else {
            pendingPointerEvent = nil
            return
        }
        guard let ev = pendingPointerEvent else { return }
        pendingPointerEvent = nil
        sendInputEventsPDU(pointerEvents: buildPointerEventPDU(x: ev.x, y: ev.y, flags: ev.flags))
        pointerLastSentAt = Date()
    }

    func sendKeyEvent(scanCode: UInt16, flags: UInt16) {
        guard case .active = handshakeState else { return }
        // flags: RDP_KEYRELEASE(0x4000), scanCode is single byte (8-bit)
        var pdu = Data()
        pdu.append(UInt8(scanCode & 0xFF))
        pdu.append(UInt8(flags >> 8))
        sendInputEventsPDU(keyboardEvents: pdu)
    }

    func sendClipboardText(_ text: String) {
        // RDP clipboard support: would implement CLIPRDR channel
        // For now, placeholder
    }

    // MARK: - Private methods

    private func processBuffer() {
        RDPProtocolHandler.trace("processBuffer: \(receiveBuffer.count) bytes, state=\(handshakeState)")
        delegate?.logger.log(content: "RDP processBuffer: starting with \(receiveBuffer.count) bytes in buffer")

        // In CredSSP states the data arriving is raw DER (not TPKT) – route directly.
        if handshakeState == .awaitingNTLMChallenge || handshakeState == .awaitingCredSSPPubKeyEcho {
            let data = receiveBuffer
            receiveBuffer.removeAll(keepingCapacity: true)
            processCredSSPResponse(data)
            return
        }

        // After server selects HYBRID/NLA, transport switches to TLS records (0x16/0x14/0x17)
        // instead of TPKT (0x03). The initial awaitingCredSSP state is reached right before we
        // call upgradeToTLS; by the time server data arrives we should already be in
        // awaitingNTLMChallenge or later.
        if handshakeState == .awaitingCredSSP,
           let first = receiveBuffer.first,
           first != 0x03 {
            delegate?.logger.log(content: "RDP CredSSP path: received non-TPKT byte 0x\(String(first, radix: 16)); routing as raw DER")
            let data = receiveBuffer
            receiveBuffer.removeAll(keepingCapacity: true)
            processCredSSPResponse(data)
            return
        }
        
        // Parse TPKT / Fast-Path packets.
        // Minimum useful size is 2 bytes (Fast-Path header + 1-byte length).
        while receiveBuffer.count >= 2 {
            let bufferBytes = [UInt8](receiveBuffer)
            delegate?.logger.log(content: "RDP processBuffer: buffer has \(bufferBytes.count) bytes, parsing TPKT...")

            // TPKT: [version=3 (1 byte), reserved (1 byte), length (2 bytes big-endian)]
            guard let version = bufferBytes.first else {
                delegate?.logger.log(content: "RDP processBuffer: buffer became empty before TPKT parse")
                return
            }
            delegate?.logger.log(content: "RDP TPKT version byte: 0x\(String(version, radix: 16))")
            
            guard version == 3 else {
                if handshakeState == .awaitingConfirmActiveResponse ||
                    handshakeState == .awaitingControlGrant ||
                    handshakeState == .awaitingFontMap ||
                    handshakeState == .active {
                    if !processFastPathBuffer() {
                        delegate?.logger.log(content: "RDP Fast-Path: incomplete packet, waiting for more data")
                        return
                    }
                    continue
                }

                let hexPrefix = bufferBytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                delegate?.rdpSetError("Invalid TPKT version: \(version)")
                delegate?.logger.log(content: "RDP ERROR: Invalid TPKT version: \(version), buffer hex: \(hexPrefix)")
                return
            }

            // TPKT needs at least 4 bytes for the header
            guard bufferBytes.count >= 4 else { return }
            let length = (Int(bufferBytes[2]) << 8) | Int(bufferBytes[3])
            delegate?.logger.log(content: "RDP TPKT length: \(length) bytes (0x\(String(length, radix: 16)))")

            guard length > 4 && length <= 32768 else {
                delegate?.rdpSetError("Invalid TPKT length: \(length)")
                delegate?.logger.log(content: "RDP ERROR: Invalid TPKT length: \(length)")
                return
            }

            guard bufferBytes.count >= length else {
                delegate?.logger.log(content: "RDP processBuffer: incomplete TPKT packet (have \(bufferBytes.count), need \(length)), waiting for more data...")
                return
            }

            delegate?.logger.log(content: "RDP processBuffer: complete TPKT packet ready, extracting...")
            
            // Extract the complete TPKT packet
            let tpktPacket = Data(bufferBytes[0..<length])
            receiveBuffer.removeFirst(length)
            
            delegate?.logger.log(content: "RDP processBuffer: removed \(length) bytes from buffer, \(receiveBuffer.count) bytes remain")

            // Process the X.224 payload (skip 4-byte TPKT header)
            if tpktPacket.count > 4 {
                let payload = tpktPacket.subdata(in: 4..<tpktPacket.count)
                let liByte = payload.first.map { String($0, radix: 16) } ?? "--"
                delegate?.logger.log(content: "RDP processBuffer: X.224 payload is \(payload.count) bytes, LI byte: 0x\(liByte)")
                processX224Packet(payload)
            } else {
                delegate?.logger.log(content: "RDP processBuffer: TPKT packet too small for X.224 payload")
            }
        }
        
        delegate?.logger.log(content: "RDP processBuffer: done, \(receiveBuffer.count) bytes remaining in buffer")
    }

    private func processFastPathBuffer() -> Bool {
        guard receiveBuffer.count >= 2 else { return false }

        let bytes = [UInt8](receiveBuffer)
        guard bytes.count >= 2 else { return false }

        let first  = bytes[0]
        let second = bytes[1]
        var packetLength = Int(second)
        var headerLength = 2

        if (second & 0x80) != 0 {
            guard bytes.count >= 3 else { return false }
            packetLength = (Int(second & 0x7F) << 8) | Int(bytes[2])
            headerLength = 3
        }

        guard packetLength >= headerLength else {
            delegate?.logger.log(content: "RDP Fast-Path: invalid packet length \(packetLength)")
            receiveBuffer.removeAll(keepingCapacity: true)
            return false
        }

        guard packetLength <= 32768 else {
            delegate?.logger.log(content: "RDP Fast-Path: oversized packet length \(packetLength), dropping receive buffer")
            receiveBuffer.removeAll(keepingCapacity: true)
            resetFastPathFragmentTrain(reason: "oversized packet", keepingCapacity: true)
            return false
        }

        guard bytes.count >= packetLength else { return false }

        receiveBuffer.removeFirst(packetLength)

        let action = first & 0x03
        delegate?.logger.log(content: "RDP Fast-Path: received packet len=\(packetLength), action=0x\(String(action, radix: 16))")

        if handshakeState != .active {
            delegate?.logger.log(content: "RDP Fast-Path: packet received before active state; dropping")
            return true
        }

        // Parse TS_FP_UPDATE entries within the PDU payload
        // encryptionFlags bits 6-7 of first byte; we don't use RDP encryption so no security header
        if packetLength > headerLength {
            let payload = Array(bytes[headerLength..<packetLength])
            parseFastPathUpdates(payload)
        }

        return true
    }

    private func resetFastPathFragmentTrain(reason: String?, keepingCapacity: Bool = true) {
        if let reason,
           !fpFragmentBuffer.isEmpty || fpFragmentUpdateCode != nil {
            let ms: Int
            if let start = fpFragmentStartTime {
                ms = Int(Date().timeIntervalSince(start) * 1000)
            } else {
                ms = -1
            }
            let codeText = fpFragmentUpdateCode.map { String(format: "0x%02x", $0) } ?? "n/a"
            delegate?.logger.log(content: "RDP Fast-Path frag: reset train reason=\(reason) code=\(codeText) bytes=\(fpFragmentBuffer.count) ageMs=\(ms)")
        }
        fpFragmentBuffer.removeAll(keepingCapacity: keepingCapacity)
        fpFragmentUpdateCode = nil
        fpFragmentStartTime = nil
    }

    private func appendFastPathFragment(_ updateData: [UInt8], updateCode: UInt8) -> Bool {
        if fpFragmentBuffer.count + updateData.count > fpFragmentMaxBytes {
            delegate?.logger.log(content: "RDP Fast-Path frag: train overflow code=0x\(String(updateCode, radix: 16)) cur=\(fpFragmentBuffer.count) add=\(updateData.count) max=\(fpFragmentMaxBytes)")
            resetFastPathFragmentTrain(reason: "overflow", keepingCapacity: true)
            return false
        }
        fpFragmentBuffer.append(contentsOf: updateData)
        return true
    }

    private func parseFastPathUpdates(_ payload: [UInt8]) {
        var offset = 0
        while offset < payload.count {
            let updateHeader  = payload[offset]
            let updateCode    = updateHeader & 0x0F
            let fragmentation = (updateHeader >> 4) & 0x03
            let compression   = (updateHeader >> 6) & 0x03

            var hdrSize = 1
            if compression != 0 { hdrSize += 1 }  // skip compressionFlags byte

            guard offset + hdrSize + 2 <= payload.count else {
                delegate?.logger.log(content: "RDP Fast-Path: malformed TS_FP_UPDATE header at offset=\(offset), payloadLen=\(payload.count)")
                resetFastPathFragmentTrain(reason: "malformed update header", keepingCapacity: true)
                return
            }
            let sz = Int(payload[offset + hdrSize]) | (Int(payload[offset + hdrSize + 1]) << 8)
            let totalSize = hdrSize + 2 + sz
            guard offset + totalSize <= payload.count else {
                delegate?.logger.log(content: "RDP Fast-Path: malformed TS_FP_UPDATE body at offset=\(offset), size=\(sz), payloadLen=\(payload.count)")
                resetFastPathFragmentTrain(reason: "malformed update body", keepingCapacity: true)
                return
            }

            let updateData = Array(payload[(offset + hdrSize + 2)..<(offset + totalSize)])
            delegate?.logger.log(content: "RDP Fast-Path update: hdr=0x\(String(format:"%02x",updateHeader)) code=0x\(String(updateCode, radix: 16)) frag=\(fragmentation) size=\(sz) trainBytes=\(fpFragmentBuffer.count)")

            // fragmentation: 0x0=SINGLE, 0x1=LAST, 0x2=FIRST, 0x3=NEXT
            switch fragmentation {
            case 0x00: // SINGLE – process immediately
                // Only reset an in-flight fragment train if the SINGLE update has the
                // SAME code as the train.  Windows RDP servers can interleave unrelated
                // non-fragmented updates (pointer, synchronize, …) between fragments of
                // a large bitmap stream.  Discarding the train here was the primary
                // reason the client never completed fragment reassembly.
                if !fpFragmentBuffer.isEmpty, fpFragmentUpdateCode == updateCode {
                    resetFastPathFragmentTrain(reason: "single update interrupted train", keepingCapacity: true)
                }
                handleFastPathUpdate(code: updateCode, data: updateData)
            case 0x02: // FIRST – start a new fragment train
                if !fpFragmentBuffer.isEmpty {
                    resetFastPathFragmentTrain(reason: "new FIRST while train active", keepingCapacity: true)
                }
                fpFragmentUpdateCode = updateCode
                fpFragmentStartTime = Date()
                guard appendFastPathFragment(updateData, updateCode: updateCode) else {
                    offset += totalSize
                    continue
                }
                delegate?.logger.log(content: "RDP Fast-Path frag: FIRST code=0x\(String(updateCode, radix: 16)) size=\(updateData.count)")
                if updateCode == 0x01,
                   hasOpenOrdersFrameMarker,
                   serverSupportsFrameAcknowledge,
                   lastAckedFrameId != frameCounter {
                    // Some servers appear to gate continuation (NEXT/LAST/END) on
                    // seeing frame-ack progress during large bitmap trains.
                    sendFrameAcknowledgeIfNeeded(frameCounter)
                    delegate?.logger.log(content: "RDP frame-ack progress: sent on BITMAP FIRST frameId=\(frameCounter)")
                }
            case 0x03: // NEXT – accumulate
                if fpFragmentBuffer.isEmpty {
                    if fpAllowOrphanRecovery {
                        delegate?.logger.log(content: "RDP Fast-Path frag: NEXT without active train; starting recovery train code=0x\(String(updateCode, radix: 16)) size=\(updateData.count)")
                        fpFragmentUpdateCode = updateCode
                        fpFragmentStartTime = Date()
                        _ = appendFastPathFragment(updateData, updateCode: updateCode)
                    } else {
                        delegate?.logger.log(content: "RDP Fast-Path frag: NEXT without active train; dropped")
                    }
                    offset += totalSize
                    continue
                }

                guard fpFragmentUpdateCode == updateCode else {
                    delegate?.logger.log(content: "RDP Fast-Path frag: NEXT code mismatch train=0x\(String(fpFragmentUpdateCode ?? 0xFF, radix: 16)) incoming=0x\(String(updateCode, radix: 16)); dropping train")
                    resetFastPathFragmentTrain(reason: "fragment code mismatch", keepingCapacity: true)
                    offset += totalSize
                    continue
                }

                guard appendFastPathFragment(updateData, updateCode: updateCode) else {
                    offset += totalSize
                    continue
                }
                delegate?.logger.log(content: "RDP Fast-Path frag: NEXT accumulated train=\(fpFragmentBuffer.count) bytes")
                if updateCode == 0x01,
                   hasOpenOrdersFrameMarker,
                   serverSupportsFrameAcknowledge,
                   lastAckedFrameId != frameCounter {
                    sendFrameAcknowledgeIfNeeded(frameCounter)
                    delegate?.logger.log(content: "RDP frame-ack progress: sent on BITMAP NEXT frameId=\(frameCounter) train=\(fpFragmentBuffer.count)")
                }
            case 0x01: // LAST – finish and process
                if !fpFragmentBuffer.isEmpty {
                    guard fpFragmentUpdateCode == updateCode else {
                        delegate?.logger.log(content: "RDP Fast-Path frag: LAST code mismatch train=0x\(String(fpFragmentUpdateCode ?? 0xFF, radix: 16)) incoming=0x\(String(updateCode, radix: 16)); dropping train")
                        resetFastPathFragmentTrain(reason: "fragment code mismatch", keepingCapacity: true)
                        offset += totalSize
                        continue
                    }

                    guard appendFastPathFragment(updateData, updateCode: updateCode) else {
                        offset += totalSize
                        continue
                    }
                    delegate?.logger.log(content: "RDP Fast-Path frag: LAST complete train=\(fpFragmentBuffer.count) bytes")
                    handleFastPathUpdate(code: fpFragmentUpdateCode ?? updateCode, data: [UInt8](fpFragmentBuffer))
                    resetFastPathFragmentTrain(reason: nil, keepingCapacity: true)
                } else {
                    if fpAllowOrphanRecovery {
                        delegate?.logger.log(content: "RDP Fast-Path frag: LAST without active train; orphan recovery processing size=\(updateData.count)")
                        handleFastPathUpdate(code: updateCode, data: updateData)
                    } else {
                        delegate?.logger.log(content: "RDP Fast-Path frag: LAST without active train; dropped")
                    }
                }
            default:
                break
            }

            offset += totalSize
        }
    }

    private func handleFastPathUpdate(code: UInt8, data: [UInt8]) {
        switch code {
        case 0x00: // FASTPATH_UPDATETYPE_ORDERS
            maybeAcknowledgeFrameFromOrders(data)
        case 0x01: // FASTPATH_UPDATETYPE_BITMAP
            delegate?.logger.log(content: "RDP Fast-Path: BITMAP update received (\(data.count) bytes)")
            decodeFastPathBitmapUpdate(data)
        case 0x02: // FASTPATH_UPDATETYPE_PALETTE
            delegate?.logger.log(content: "RDP Fast-Path: PALETTE update (\(data.count) bytes)")
        case 0x03: // FASTPATH_UPDATETYPE_SYNCHRONIZE
            delegate?.logger.log(content: "RDP Fast-Path: SYNCHRONIZE update")
        case 0x04: // FASTPATH_UPDATETYPE_SURFCMDS
            delegate?.logger.log(content: "RDP Fast-Path: SURFCMDS update (\(data.count) bytes)")
            maybeAcknowledgeFrameFromSurfaceCommands(data)
        case 0x05: // FASTPATH_UPDATETYPE_PTR_NULL
            delegate?.logger.log(content: "RDP Fast-Path: pointer null (hide cursor)")
        case 0x06: // FASTPATH_UPDATETYPE_PTR_DEFAULT
            delegate?.logger.log(content: "RDP Fast-Path: pointer default")
        case 0x08: // FASTPATH_UPDATETYPE_PTR_POSITION
            delegate?.logger.log(content: "RDP Fast-Path: pointer position (\(data.count) bytes)")
        case 0x09: // FASTPATH_UPDATETYPE_COLOR
            delegate?.logger.log(content: "RDP Fast-Path: color pointer (\(data.count) bytes)")
        case 0x0A: // FASTPATH_UPDATETYPE_CACHED
            delegate?.logger.log(content: "RDP Fast-Path: cached pointer (\(data.count) bytes)")
        case 0x0B: // FASTPATH_UPDATETYPE_POINTER
            delegate?.logger.log(content: "RDP Fast-Path: new pointer (\(data.count) bytes)")
        default:
            delegate?.logger.log(content: "RDP Fast-Path: unhandled update code=0x\(String(code, radix: 16)) size=\(data.count)")
            break
        }
    }

    private func maybeAcknowledgeFrameFromOrders(_ data: [UInt8]) {
        guard serverSupportsFrameAcknowledge else {
            delegate?.logger.log(content: "RDP orders frame-ack: skipped (server did not advertise FrameAcknowledge)")
            return
        }
        // NOTE: Do NOT early-return when serverSupportsSurfaceCommands is true.
        // The server may negotiate surface commands yet still deliver frame markers
        // through ORDERS (e.g. when using the bitmap path rather than SURFCMDS).
        // Always process frame markers from whichever channel they actually arrive on.

        // TS_ALTSEC_FRAME_MARKER_ORDER: controlFlags=0x36, frameAction(4 LE)
        // Orders frame markers do NOT carry a frameId; the client maintains a counter.
        // Ack on FRAME_END with current counter, then increment counter.
        guard data.count >= 2 else { return }
        // Fast-path ORDERS data: the first 2 bytes are a pad/numberOrders field
        // (present in Windows Server fast-path despite not being in the spec).
        // Log the first 12 bytes so we can verify the offset is correct.
        let hexPrefix = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        delegate?.logger.log(content: "RDP ORDERS data[\(data.count)]: \(hexPrefix)")
        var offset = 2 // skip pad/numberOrders (2 bytes present in Windows fast-path ORDERS)
        while offset + 5 <= data.count {
            let controlFlags = data[offset]
            if controlFlags == 0x36 { // TS_ALTSEC_FRAME_MARKER
                let frameAction = UInt32(data[offset + 1])
                    | (UInt32(data[offset + 2]) << 8)
                    | (UInt32(data[offset + 3]) << 16)
                    | (UInt32(data[offset + 4]) << 24)
                if frameAction == 0x0000 { // FRAME_START
                    lastFrameMarkerSeenAt = Date()
                    hasOpenOrdersFrameMarker = true
                    openOrdersFrameMarkerAt = Date()
                    delegate?.logger.log(content: "RDP Fast-Path orders frame-marker: BEGIN (counter=\(frameCounter))")
                    // Send ACK immediately on BEGIN if server supports it and previous frame was acked
                    if serverSupportsFrameAcknowledge && lastAckedFrameId != frameCounter {
                        sendFrameAcknowledgeIfNeeded(frameCounter)
                        delegate?.logger.log(content: "RDP frame-ack: sent on FRAME_BEGIN frameId=\(frameCounter)")
                    }
                } else { // FRAME_END
                    lastFrameMarkerSeenAt = Date()
                    delegate?.logger.log(content: "RDP Fast-Path orders frame-marker: END (ack counter=\(frameCounter))")
                    if lastAckedFrameId == frameCounter {
                        delegate?.logger.log(content: "RDP Fast-Path orders frame-marker: END already acked frameId=\(frameCounter)")
                    } else {
                        sendFrameAcknowledgeIfNeeded(frameCounter)
                    }
                    frameCounter &+= 1
                    hasOpenOrdersFrameMarker = false
                    openOrdersFrameMarkerAt = nil
                    if hasPendingFramebufferPublish {
                        pendingFramebufferPublishWorkItem?.cancel()
                        pendingFramebufferPublishWorkItem = nil
                        hasPendingFramebufferPublish = false
                        publishFramebufferIfAvailable(trigger: "orders-frame-end")
                    } else {
                        let coverage = framebufferCoverageFraction()
                        maybeRequestAdditionalFramebufferRefresh(reason: "orders-frame-end-no-bitmap", coverage: coverage)
                    }
                }
                offset += 5
            } else {
                // Orders payload can contain non-frame-marker orders interleaved with
                // frame markers. Advance by one byte and keep scanning so we don't
                // miss a later FRAME_END marker in the same update.
                offset += 1
            }
        }
    }

    private func maybeAcknowledgeFrameFromSurfaceCommands(_ data: [UInt8]) {
        // TS_SURFCMD structures: cmdType(2) + cmdData(variable, depends on type).
        // No length prefix — size is determined by cmdType.
        var offset = 0
        var rendered = false
        while offset + 2 <= data.count {
            let cmdType = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            offset += 2

            switch cmdType {
            case 0x0004: // CMDTYPE_FRAME_MARKER: frameAction(2) + frameId(4) = 6 bytes
                guard offset + 6 <= data.count else { return }
                let frameAction = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                let frameId = UInt32(data[offset + 2])
                    | (UInt32(data[offset + 3]) << 8)
                    | (UInt32(data[offset + 4]) << 16)
                    | (UInt32(data[offset + 5]) << 24)
                offset += 6
                delegate?.logger.log(content: "RDP SURFCMD frame-marker: action=\(frameAction == 0 ? "BEGIN" : "END") frameId=\(frameId)")
                if frameAction == 0x0001 { // SURFACECMD_FRAMEACTION_END
                    lastFrameMarkerSeenAt = Date()
                    sendFrameAcknowledgeIfNeeded(frameId)
                } else {
                    lastFrameMarkerSeenAt = Date()
                }
            case 0x0001, 0x0006: // SET_SURFACE_BITS, STREAM_SURFACE_BITS
                // destLeft(2)+destTop(2)+destRight(2)+destBottom(2)+bitmapDataLength(4)+bitmapData(variable)
                guard offset + 12 <= data.count else { return }
                let destLeft = Int(UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
                let destTop = Int(UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8))
                let destRight = Int(UInt16(data[offset + 4]) | (UInt16(data[offset + 5]) << 8))
                let destBottom = Int(UInt16(data[offset + 6]) | (UInt16(data[offset + 7]) << 8))
                let bitmapDataLength = Int(UInt32(data[offset + 8])
                    | (UInt32(data[offset + 9]) << 8)
                    | (UInt32(data[offset + 10]) << 16)
                    | (UInt32(data[offset + 11]) << 24))
                let cmdDataSize = 12 + bitmapDataLength // 8(rect) + 4(bitmapDataLength) + bitmapData
                guard offset + cmdDataSize <= data.count else { return }
                delegate?.logger.log(content: "RDP SURFCMD surface-bits: type=0x\(String(cmdType, radix: 16)) dataLen=\(bitmapDataLength)")

                if bitmapDataLength > 0 {
                    let dataStart = offset + 12
                    let dataEnd = dataStart + bitmapDataLength
                    let bitmapData = Array(data[dataStart..<dataEnd])
                    if decodeSurfaceBitsRaw(bitmapData,
                                            destLeft: destLeft,
                                            destTop: destTop,
                                            destRight: destRight,
                                            destBottom: destBottom) {
                        rendered = true
                    }
                }
                offset += cmdDataSize
            default:
                delegate?.logger.log(content: "RDP SURFCMD unknown cmdType=0x\(String(cmdType, radix: 16)), stopping parse")
                return
            }
        }

        if rendered, let image = fpFramebuffer?.makeImage() {
            delegate?.rdpPublishFrame(image)
        }
    }

    private func decodeSurfaceBitsRaw(_ bitmapData: [UInt8],
                                      destLeft: Int,
                                      destTop: Int,
                                      destRight: Int,
                                      destBottom: Int) -> Bool {
        let width = max(0, destRight - destLeft + 1)
        let height = max(0, destBottom - destTop + 1)
        guard width > 0, height > 0 else { return false }

        ensureFramebuffer()
        guard let storage = fpFramebufferStorage else { return false }

        // Heuristic fallback: many servers send raw BGR/BGRA bytes for surface bits in compatibility modes.
        let expected32 = width * height * 4
        if bitmapData.count >= expected32 {
            decodeBitmapRect(bytes: Array(bitmapData.prefix(expected32)),
                             destLeft: destLeft,
                             destTop: destTop,
                             width: width,
                             height: height,
                             bitsPerPixel: 32,
                             flags: 0,
                             storage: storage)
            delegate?.logger.log(content: "RDP SURFCMD rendered raw 32bpp rect=\(width)x\(height)")
            return true
        }

        let strideCandidates = [width * 3, ((width * 3 + 1) & ~1), ((width * 3 + 3) & ~3)]
        for stride in strideCandidates where stride > 0 {
            let needed = stride * height
            if bitmapData.count >= needed {
                decodeBitmapRect(bytes: Array(bitmapData.prefix(needed)),
                                 destLeft: destLeft,
                                 destTop: destTop,
                                 width: width,
                                 height: height,
                                 bitsPerPixel: 24,
                                 flags: 0,
                                 storage: storage)
                delegate?.logger.log(content: "RDP SURFCMD rendered raw 24bpp rect=\(width)x\(height) stride=\(stride)")
                return true
            }
        }

        delegate?.logger.log(content: "RDP SURFCMD raw decode skipped: rect=\(width)x\(height) dataLen=\(bitmapData.count)")
        return false
    }

    private func sendFrameAcknowledgeIfNeeded(_ frameId: UInt32) {
        guard !suppressOutboundSends else {
            delegate?.logger.log(content: "RDP frame-ack dropped: transport is closing (EOF), frameId=\(frameId)")
            return
        }
        guard handshakeState == .active else {
            delegate?.logger.log(content: "RDP frame-ack dropped: handshakeState=\(handshakeState), frameId=\(frameId)")
            return
        }
        guard serverSupportsFrameAcknowledge else {
            delegate?.logger.log(content: "RDP frame-ack skipped: server did not advertise FrameAcknowledge capability")
            return
        }
        if lastAckedFrameId == frameId {
            delegate?.logger.log(content: "RDP frame-ack skipped: already acked frameId=\(frameId)")
            return
        }
        lastAckedFrameId = frameId

        var payload = Data()
        payload.append(le32(frameId))
        sendActivationDataPDU(pduType2: 0x38, payload: payload)
        delegate?.logger.log(content: "RDP frame-ack sent: frameId=\(frameId)")
    }

    // MARK: - Fast-Path Bitmap Decoding

    private func ensureFramebuffer() {
        guard fpFramebuffer == nil else { return }
        if rdpDesktopWidth > 0 && rdpDesktopHeight > 0 {
            fpFramebufferWidth = rdpDesktopWidth
            fpFramebufferHeight = rdpDesktopHeight
        }
        let w = fpFramebufferWidth
        let h = fpFramebufferHeight
        let bytesPerRow = w * 4
        guard let storage = NSMutableData(length: bytesPerRow * h) else { return }
        // BGRX pixel format: kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little
        if let ctx = CGContext(
            data: storage.mutableBytes,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue).rawValue
        ) {
            fpFramebufferStorage = storage
            fpFramebuffer = ctx
            framebufferUpdatedTiles.removeAll(keepingCapacity: false)
            framebufferRefreshRetryCount = 0
            lastFramebufferRefreshAt = .distantPast
            delegate?.rdpSetFramebufferSize(width: w, height: h)
        }
    }

    private func applyServerDesktopSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != rdpDesktopWidth || height != rdpDesktopHeight else { return }

        rdpDesktopWidth = width
        rdpDesktopHeight = height
        fpFramebufferWidth = width
        fpFramebufferHeight = height
        fpFramebuffer = nil
        fpFramebufferStorage = nil
        framebufferUpdatedTiles.removeAll(keepingCapacity: false)
        framebufferRefreshRetryCount = 0
        lastFramebufferRefreshAt = .distantPast
        delegate?.rdpSetFramebufferSize(width: width, height: height)
    }

    private func noteFramebufferRegionUpdated(destLeft: Int, destTop: Int, width: Int, height: Int) {
        guard width > 0, height > 0, fpFramebufferWidth > 0, fpFramebufferHeight > 0 else { return }

        let clampedLeft = max(0, min(fpFramebufferWidth - 1, destLeft))
        let clampedTop = max(0, min(fpFramebufferHeight - 1, destTop))
        let clampedRight = max(clampedLeft, min(fpFramebufferWidth - 1, destLeft + width - 1))
        let clampedBottom = max(clampedTop, min(fpFramebufferHeight - 1, destTop + height - 1))
        let minTileX = clampedLeft / framebufferCoverageTileSize
        let maxTileX = clampedRight / framebufferCoverageTileSize
        let minTileY = clampedTop / framebufferCoverageTileSize
        let maxTileY = clampedBottom / framebufferCoverageTileSize
        let tileColumns = max(1, (fpFramebufferWidth + framebufferCoverageTileSize - 1) / framebufferCoverageTileSize)

        for tileY in minTileY...maxTileY {
            for tileX in minTileX...maxTileX {
                framebufferUpdatedTiles.insert(tileY * tileColumns + tileX)
            }
        }
    }

    private func framebufferCoverageFraction() -> Double {
        guard fpFramebufferWidth > 0, fpFramebufferHeight > 0 else { return 0 }
        let tileColumns = max(1, (fpFramebufferWidth + framebufferCoverageTileSize - 1) / framebufferCoverageTileSize)
        let tileRows = max(1, (fpFramebufferHeight + framebufferCoverageTileSize - 1) / framebufferCoverageTileSize)
        let totalTiles = max(1, tileColumns * tileRows)
        return Double(framebufferUpdatedTiles.count) / Double(totalTiles)
    }

    private func maybeRequestAdditionalFramebufferRefresh(reason: String, coverage: Double) {
        guard handshakeState == .active else { return }
        guard coverage < framebufferCoverageRetryThreshold else { return }
        guard framebufferRefreshRetryCount < maxFramebufferRefreshRetries else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFramebufferRefreshAt) >= framebufferRefreshRetryCooldown else { return }

        framebufferRefreshRetryCount += 1
        lastFramebufferRefreshAt = now
        sendSuppressOutputPDU(allow: true)
        sendRefreshRectPDU()
        delegate?.logger.log(content: "RDP framebuffer refresh retry: reason=\(reason) coverage=\(String(format: "%.2f", coverage * 100))% retry=\(framebufferRefreshRetryCount)/\(maxFramebufferRefreshRetries)")
    }

    private func publishFramebufferIfAvailable(trigger: String) {
        guard let ctx = fpFramebuffer, let image = ctx.makeImage() else { return }
        let coverage = framebufferCoverageFraction()
        delegate?.rdpPublishFrame(image)
        delegate?.logger.log(content: "RDP framebuffer publish: trigger=\(trigger) coverage=\(String(format: "%.2f", coverage * 100))%")
        if coverage >= framebufferCoverageSufficientThreshold {
            cancelPostActivationNudges()
        } else {
            maybeRequestAdditionalFramebufferRefresh(reason: trigger, coverage: coverage)
        }
    }

    private func scheduleDeferredFramebufferPublish() {
        pendingFramebufferPublishWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingFramebufferPublishWorkItem = nil
            guard self.hasPendingFramebufferPublish else { return }
            self.hasPendingFramebufferPublish = false
            self.publishFramebufferIfAvailable(trigger: "bitmap-update-deferred")
        }
        pendingFramebufferPublishWorkItem = work
        (schedulingQueue ?? DispatchQueue.main).asyncAfter(deadline: .now() + framebufferPublishDelay, execute: work)
    }

    private func decodeFastPathBitmapUpdate(_ payload: [UInt8]) {
        // TS_UPDATE_BITMAP_DATA (MS-RDPBCGR §2.2.9.1.1.3.1.2):
        //   updateType(2, MUST be 0x0001) + numberRectangles(2) + TS_BITMAP_DATA[]
        //
        // Windows RDP servers include the updateType prefix even in Fast-Path
        // bitmap updates.  Some third-party servers may omit it.  Disambiguate
        // by checking whether the first word is 0x0001 AND the first rectangle's
        // bitsPerPixel at the corresponding candidate offset is a valid value
        // (15, 16, 24, or 32).
        guard payload.count >= 4 else { return }

        var offset: Int
        var numRects: Int

        let firstWord = UInt16(payload[0]) | (UInt16(payload[1]) << 8)

        if firstWord == 0x0001, payload.count >= 22 {
            // Candidate: updateType prefix present.  Validate by checking the
            // bitsPerPixel field of the first TS_BITMAP_DATA at offset 4.
            // bpp is at rect_offset + 12 = 4 + 12 = 16.
            let bppCandidate = Int(UInt16(payload[16]) | (UInt16(payload[17]) << 8))
            if bppCandidate == 15 || bppCandidate == 16 || bppCandidate == 24 || bppCandidate == 32 {
                numRects = Int(UInt16(payload[2]) | (UInt16(payload[3]) << 8))
                offset = 4
            } else {
                // 0x0001 is coincidentally numRects=1 with no prefix
                numRects = Int(firstWord)
                offset = 2
            }
        } else {
            // No updateType prefix: numberRectangles starts at byte 0
            numRects = Int(firstWord)
            offset = 2
        }

        guard numRects > 0, numRects <= 4096 else {
            delegate?.logger.log(content: "RDP bitmap: invalid numRects=\(numRects), payload=\(payload.count) bytes")
            return
        }
        delegate?.logger.log(content: "RDP bitmap: decoding \(numRects) rectangles from \(payload.count) bytes (dataOffset=\(offset))")

        ensureFramebuffer()
        guard let ctx = fpFramebuffer, let storage = fpFramebufferStorage else { return }

        var rectsDecoded = 0
        for rectIndex in 0..<numRects {
            guard offset + 18 <= payload.count else { break }
            let destLeft   = Int(UInt16(payload[offset])    | (UInt16(payload[offset+1])  << 8))
            let destTop    = Int(UInt16(payload[offset+2])  | (UInt16(payload[offset+3])  << 8))
            let width      = Int(UInt16(payload[offset+8])  | (UInt16(payload[offset+9])  << 8))
            let height     = Int(UInt16(payload[offset+10]) | (UInt16(payload[offset+11]) << 8))
            let bpp        = Int(UInt16(payload[offset+12]) | (UInt16(payload[offset+13]) << 8))
            let flags      = UInt16(payload[offset+14]) | (UInt16(payload[offset+15]) << 8)
            let bmpLen     = Int(UInt16(payload[offset+16]) | (UInt16(payload[offset+17]) << 8))
            offset += 18

            guard offset + bmpLen <= payload.count, width > 0, height > 0 else {
                offset += bmpLen
                continue
            }

            let bitmapBytes = Array(payload[offset..<(offset + bmpLen)])
            offset += bmpLen

            if rectIndex == 0 {
                delegate?.logger.log(content: "RDP bitmap rect[0]: dest=(\(destLeft),\(destTop)) size=\(width)x\(height) bpp=\(bpp) flags=0x\(String(flags, radix: 16)) dataLen=\(bmpLen)")
            }
            guard bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32 else {
                if rectIndex == 0 {
                    delegate?.logger.log(content: "RDP bitmap rect[\(rectIndex)]: unsupported bpp=\(bpp), skipping")
                }
                continue
            }
            decodeBitmapRect(bytes: bitmapBytes,
                             destLeft: destLeft, destTop: destTop,
                             width: width, height: height,
                             bitsPerPixel: bpp, flags: flags,
                             storage: storage)
            rectsDecoded += 1
        }

        if rectsDecoded < numRects {
            delegate?.logger.log(content: "RDP bitmap: decoded \(rectsDecoded)/\(numRects) rects (\(numRects - rectsDecoded) skipped)")
        } else {
            delegate?.logger.log(content: "RDP bitmap: decoded \(rectsDecoded)/\(numRects) rects")
        }

        // Some servers advertise FrameAcknowledge but omit explicit frame markers
        // on the bitmap path. Send a conservative fallback ack so the server does
        // not throttle/close waiting for acknowledgments.
        if serverSupportsFrameAcknowledge {
            var sentFallbackAck = false
            if hasOpenOrdersFrameMarker {
                let beginAge = openOrdersFrameMarkerAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                if beginAge >= 0.20 {
                    if lastAckedFrameId == frameCounter {
                        delegate?.logger.log(content: "RDP frame-ack fallback: stale ORDER BEGIN cleared; frameId=\(frameCounter) ageMs=\(Int(beginAge * 1000)) alreadyAcked")
                    } else {
                        delegate?.logger.log(content: "RDP frame-ack fallback: ORDER BEGIN without END; ack counter=\(frameCounter) ageMs=\(Int(beginAge * 1000))")
                        let ackedBefore = lastAckedFrameId
                        sendFrameAcknowledgeIfNeeded(frameCounter)
                        if lastAckedFrameId != ackedBefore {
                            frameCounter &+= 1
                        }
                    }
                    hasOpenOrdersFrameMarker = false
                    openOrdersFrameMarkerAt = nil
                    sentFallbackAck = true
                }
            }

            let markerRecentlySeen: Bool
            if let t = lastFrameMarkerSeenAt {
                markerRecentlySeen = Date().timeIntervalSince(t) < 0.25
            } else {
                markerRecentlySeen = false
            }
            if !sentFallbackAck && !markerRecentlySeen && !hasOpenOrdersFrameMarker {
                delegate?.logger.log(content: "RDP frame-ack fallback: bitmap path ack counter=\(frameCounter) (no recent frame marker)")
                sendFrameAcknowledgeIfNeeded(frameCounter)
                frameCounter &+= 1
            }
        }

        hasPendingFramebufferPublish = true
        if hasOpenOrdersFrameMarker {
            delegate?.logger.log(content: "RDP framebuffer publish deferred: waiting for FRAME_END")
        } else {
            scheduleDeferredFramebufferPublish()
        }
    }

    private func decodeBitmapRect(bytes: [UInt8], destLeft: Int, destTop: Int,
                                  width: Int, height: Int, bitsPerPixel: Int,
                                  flags: UInt16, storage: NSMutableData) {
        // TS_BITMAP_DATA flags
        // 0x0001: BITMAP_COMPRESSION
        // 0x0400: NO_BITMAP_COMPRESSION_HDR
        let isCompressed = (flags & 0x0001) != 0
        let noCompressionHeader = (flags & 0x0400) != 0

        var src = bytes
        if isCompressed && !noCompressionHeader && src.count >= 8 {
            src = Array(src.dropFirst(8))  // skip TS_CD_HEADER (8 bytes)
        }

        if isCompressed {
            if bitsPerPixel == 32 {
                // MS-RDPBCGR §2.2.9.1.1.3.1.2.2: 32bpp compressed bitmaps use
                // RDP 6.0 planar compression (MS-RDPEGDI §2.2.2.5.1), NOT Interleaved RLE.
                let fhDesc = src.isEmpty ? "empty" : String(format: "fh=0x%02x(cll=%d,cs=%d,rle=%d,na=%d)",
                    src[0], Int(src[0] & 0x07), (src[0] & 0x08) != 0 ? 1 : 0,
                    (src[0] & 0x10) != 0 ? 1 : 0, (src[0] & 0x20) != 0 ? 1 : 0)
                guard let decompressed = decompress32bppPlanar(src: src, width: width, height: height) else {
                    delegate?.logger.log(content: "RDP bitmap: planar decompression failed w=\(width) h=\(height) srcLen=\(src.count) \(fhDesc)")
                    return
                }
                src = decompressed
            } else {
                // For <32bpp, use Interleaved RLE (MS-RDPBCGR §3.1.9).
                guard let decompressed = decompressInterleaved(src: src, width: width, height: height, bpp: bitsPerPixel) else {
                    delegate?.logger.log(content: "RDP bitmap: RLE decompression failed w=\(width) h=\(height) bpp=\(bitsPerPixel) srcLen=\(src.count)")
                    return
                }
                src = decompressed
            }
        }
        guard width > 0, height > 0 else { return }
        var didWriteAnyPixel = false

        // 32bpp planar decompressor produces BGRA (4 bytes/pixel).
        // Interleaved RLE for 24bpp produces 3 bytes/pixel.
        // Raw uncompressed uses bitsPerPixel directly.
        let renderBpp: Int
        if isCompressed {
            renderBpp = 32  // planar → BGRA; interleaved <32bpp → treat as 24 below
        } else {
            renderBpp = bitsPerPixel
        }
        // For interleaved-RLE decompressed data (non-32bpp), override to 24.
        let effectiveBpp = (isCompressed && bitsPerPixel != 32) ? 24 : renderBpp

        let fbW = fpFramebufferWidth
        let fbH = fpFramebufferHeight
        let bytesPerRow = fbW * 4
        let ptr = storage.mutableBytes.assumingMemoryBound(to: UInt8.self)

        switch effectiveBpp {
        case 24:
            // Decompressed (Interleaved RLE) data is tightly packed;
            // raw uncompressed is 2-byte aligned per row.
            let srcStride = isCompressed ? (width * 3) : ((width * 3 + 1) & ~1)
            guard src.count >= srcStride * height else { return }
            for y in 0..<height {
                let srcRow = (height - 1 - y) * srcStride  // bottom-up flip
                let dstY   = destTop + y
                guard dstY >= 0, dstY < fbH else { continue }
                for x in 0..<width {
                    let dstX = destLeft + x
                    guard dstX >= 0, dstX < fbW else { continue }
                    let s = srcRow + x * 3
                    let d = dstY * bytesPerRow + dstX * 4
                    ptr[d]   = src[s]        // B
                    ptr[d+1] = src[s+1]      // G
                    ptr[d+2] = src[s+2]      // R
                    ptr[d+3] = 0
                    didWriteAnyPixel = true
                }
            }
        case 32:
            // 32bpp bitmap rects are rendered bottom-up in this path.
            let srcStride = width * 4
            guard src.count >= srcStride * height else { return }
            for y in 0..<height {
                let srcRow = (height - 1 - y) * srcStride
                let dstY   = destTop + y
                guard dstY >= 0, dstY < fbH else { continue }
                for x in 0..<width {
                    let dstX = destLeft + x
                    guard dstX >= 0, dstX < fbW else { continue }
                    let s = srcRow + x * 4
                    let d = dstY * bytesPerRow + dstX * 4
                    ptr[d]   = src[s]        // B
                    ptr[d+1] = src[s+1]      // G
                    ptr[d+2] = src[s+2]      // R
                    ptr[d+3] = 0
                    didWriteAnyPixel = true
                }
            }
        case 15, 16:
            let srcStride = width * 2
            guard src.count >= srcStride * height else { return }
            for y in 0..<height {
                let srcRow = (height - 1 - y) * srcStride
                let dstY   = destTop + y
                guard dstY >= 0, dstY < fbH else { continue }
                for x in 0..<width {
                    let dstX = destLeft + x
                    guard dstX >= 0, dstX < fbW else { continue }
                    let s = srcRow + x * 2
                    let d = dstY * bytesPerRow + dstX * 4
                    let pixel = UInt16(src[s]) | (UInt16(src[s+1]) << 8)
                    if bitsPerPixel == 16 {
                        ptr[d]   = UInt8((pixel & 0x001F) << 3)
                        ptr[d+1] = UInt8(((pixel >> 5) & 0x003F) << 2)
                        ptr[d+2] = UInt8(((pixel >> 11) & 0x001F) << 3)
                    } else {
                        ptr[d]   = UInt8((pixel & 0x001F) << 3)
                        ptr[d+1] = UInt8(((pixel >> 5) & 0x001F) << 3)
                        ptr[d+2] = UInt8(((pixel >> 10) & 0x001F) << 3)
                    }
                    ptr[d+3] = 0
                    didWriteAnyPixel = true
                }
            }
        default:
            break
        }

        if didWriteAnyPixel {
            noteFramebufferRegionUpdated(destLeft: destLeft, destTop: destTop, width: width, height: height)
        }
    }

    // MARK: - RDP 6.0 Planar Bitmap Decompression (MS-RDPEGDI §2.2.2.5.1)

    /// Decompress a 32bpp RDP 6.0 bitmap stream into a flat BGRA byte array
    /// (width × height × 4 bytes, top-to-bottom, left-to-right).
    ///
    /// FormatHeader byte layout:  bits[0:2]=CLL, bit[3]=CS, bit[4]=RLE, bit[5]=NA
    ///   CLL=0 → ARGB color space.  CLL 1-7 → AYCoCg with color-loss level.
    ///   CS=1   → chroma planes are ceil(w/2) × ceil(h/2) (AYCoCg only).
    ///   RLE=1  → planes are RDP 6.0 RLE-encoded.  RLE=0 → raw plane bytes.
    ///   NA=1   → no alpha plane (alpha assumed 0xFF).
    ///
    /// Tolerates truncated input: incomplete planes are zero-padded rather than failing.
    private func decompress32bppPlanar(src: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard src.count >= 1, width > 0, height > 0 else { return nil }

        let fh      = src[0]
        let cll     = Int(fh & 0x07)
        let cs      = (fh & 0x08) != 0
        let useRLE  = (fh & 0x10) != 0
        let noAlpha = (fh & 0x20) != 0

        let chromaW    = (cll > 0 && cs) ? (width  + 1) / 2 : width
        let chromaH    = (cll > 0 && cs) ? (height + 1) / 2 : height
        let lumCount   = width   * height
        let chromCount = chromaW * chromaH

        var si = 1  // read cursor; advances through planes sequentially

        // --- RDP 6.0 RLE plane decoder ---
        // controlByte = nRunLength[3:0] | cRawBytes[7:4]
        //   nRunLength == 1 → actualRun = cRawBytes + 16, actualRaw = 0
        //   nRunLength == 2 → actualRun = cRawBytes + 32, actualRaw = 0
        // Raw bytes on row 0 are absolute pixel values.
        // Raw bytes on later rows are signed deltas encoded as:
        //   even:  delta = value >> 1
        //   odd:   delta = -((value >> 1) + 1)
        // Run segments repeat the most recent decoded pixel/delta for the current row.
        // On truncated input: stop filling and zero-pad the rest (do NOT return nil).
        func decodeRLEPlane(count: Int, planeW: Int) -> [UInt8] {
            var plane = [UInt8](repeating: 0, count: count)
            guard planeW > 0 else { return plane }

            let planeH = count / planeW
            for row in 0..<planeH {
                let rowStart = row * planeW
                var x = 0
                var pixel = 0

                while x < planeW {
                    guard si < src.count else { return plane }
                    let controlByte = src[si]
                    si += 1

                    var runLength = Int(controlByte & 0x0F)
                    var rawBytes = Int((controlByte >> 4) & 0x0F)

                    if runLength == 1 {
                        runLength = rawBytes + 16
                        rawBytes = 0
                    } else if runLength == 2 {
                        runLength = rawBytes + 32
                        rawBytes = 0
                    }

                    guard x + rawBytes + runLength <= planeW else {
                        return plane
                    }

                    if row == 0 {
                        while rawBytes > 0 {
                            guard si < src.count else { return plane }
                            pixel = Int(src[si])
                            si += 1
                            plane[rowStart + x] = UInt8(pixel)
                            x += 1
                            rawBytes -= 1
                        }

                        while runLength > 0 {
                            plane[rowStart + x] = UInt8(pixel)
                            x += 1
                            runLength -= 1
                        }
                    } else {
                        let previousRowStart = rowStart - planeW

                        while rawBytes > 0 {
                            guard si < src.count else { return plane }
                            let deltaByte = Int(src[si])
                            si += 1

                            if (deltaByte & 1) != 0 {
                                pixel = -((deltaByte >> 1) + 1)
                            } else {
                                pixel = deltaByte >> 1
                            }

                            plane[rowStart + x] = UInt8(truncatingIfNeeded: Int(plane[previousRowStart + x]) + pixel)
                            x += 1
                            rawBytes -= 1
                        }

                        while runLength > 0 {
                            plane[rowStart + x] = UInt8(truncatingIfNeeded: Int(plane[previousRowStart + x]) + pixel)
                            x += 1
                            runLength -= 1
                        }
                    }
                }
            }
            return plane
        }

        // Raw plane: copy exactly `count` bytes; zero-pad if input is shorter.
        func decodeRawPlane(count: Int) -> [UInt8] {
            let avail = min(count, max(0, src.count - si))
            var plane = [UInt8](repeating: 0, count: count)
            if avail > 0 {
                plane.replaceSubrange(0..<avail, with: src[si..<(si + avail)])
                si += avail
            }
            return plane
        }

        func decodePlane(count: Int, planeW: Int) -> [UInt8] {
            return useRLE ? decodeRLEPlane(count: count, planeW: planeW)
                          : decodeRawPlane(count: count)
        }

        // Decode planes in order: [Alpha], Luma/R, ChromaA/G, ChromaB/B
        let alphaPlane = noAlpha ? [UInt8](repeating: 0xFF, count: lumCount)
                                 : decodePlane(count: lumCount,   planeW: width)
        let plane1 = decodePlane(count: lumCount,   planeW: width)    // Y or R
        let plane2 = decodePlane(count: chromCount, planeW: chromaW)  // Co or G
        let plane3 = decodePlane(count: chromCount, planeW: chromaW)  // Cg or B

        // Assemble BGRA output (top-to-bottom; no row flip needed for planar data)
        var dst = [UInt8](repeating: 0, count: lumCount * 4)

        if cll == 0 {
            // ARGB: plane1=R, plane2=G, plane3=B
            for i in 0..<lumCount {
                dst[i*4]   = plane3[i]
                dst[i*4+1] = plane2[i]
                dst[i*4+2] = plane1[i]
                dst[i*4+3] = alphaPlane[i]
            }
        } else {
            // AYCoCg: plane1=Y, plane2=Co, plane3=Cg.
            // Match FreeRDP's YCoCgToRGB path: shift before sign conversion,
            // which folds the required divide-by-2 into the signed chroma term.
            let chromaShift = max(cll - 1, 0)
            for y in 0..<height {
                for x in 0..<width {
                    let i  = y * width + x
                    let ci = (y / (cs ? 2 : 1)) * chromaW + (x / (cs ? 2 : 1))
                    let yv = Int(plane1[i])
                    let coRaw = UInt8(truncatingIfNeeded: Int(plane2[ci]) << chromaShift)
                    let cgRaw = UInt8(truncatingIfNeeded: Int(plane3[ci]) << chromaShift)
                    let co = Int(Int8(bitPattern: coRaw))
                    let cg = Int(Int8(bitPattern: cgRaw))
                    let t = yv - cg
                    dst[i*4]   = UInt8(max(0, min(255, t + co)))
                    dst[i*4+1] = UInt8(max(0, min(255, yv + cg)))
                    dst[i*4+2] = UInt8(max(0, min(255, t - co)))
                    dst[i*4+3] = alphaPlane[i]
                }
            }
        }
        return dst
    }

    // MARK: - RDP Interleaved Bitmap Decompression (MS-RDPBCGR §3.1.9)

    private func decompressInterleaved(src: [UInt8], width: Int, height: Int, bpp: Int) -> [UInt8]? {
        let Bpp: Int
        switch bpp {
        case 24: Bpp = 3
        case 32: Bpp = 4
        case 16, 15: Bpp = 2
        default: return nil
        }

        let rowStride = width * Bpp
        let totalSize = rowStride * height
        guard totalSize > 0, !src.isEmpty else { return nil }

        var dst = [UInt8](repeating: 0, count: totalSize)
        var fg = [UInt8](repeating: 0xFF, count: Bpp)
        var si = 0  // source index
        var di = 0  // destination index
        var insertFgPel = false

        // Pixel-write helpers (capture local state by reference)
        let writeBgPixel = {
            guard di + Bpp <= totalSize else { return }
            if di < rowStride {
                for j in 0..<Bpp { dst[di + j] = 0 }
            } else {
                for j in 0..<Bpp { dst[di + j] = dst[di - rowStride + j] }
            }
            di += Bpp
        }

        let writeFgPixel = {
            guard di + Bpp <= totalSize else { return }
            if di < rowStride {
                for j in 0..<Bpp { dst[di + j] = fg[j] }
            } else {
                for j in 0..<Bpp { dst[di + j] = fg[j] ^ dst[di - rowStride + j] }
            }
            di += Bpp
        }

        // Process FGBG bitmask from source stream
        let doFGBG = { (count: Int) in
            let maskBytes = (count + 7) / 8
            guard si + maskBytes <= src.count else { return }
            var remaining = count
            for mi in 0..<maskBytes {
                let mask = src[si + mi]
                for bit in 0..<8 {
                    guard remaining > 0, di + Bpp <= totalSize else { break }
                    if (mask & (1 << bit)) != 0 { writeFgPixel() } else { writeBgPixel() }
                    remaining -= 1
                }
            }
            si += maskBytes
        }

        // FGBG with hardcoded bitmask (for SPECIAL codes)
        let doFGBGInline = { (count: Int, mask: UInt8) in
            var remaining = count
            for bit in 0..<8 {
                guard remaining > 0, di + Bpp <= totalSize else { break }
                if (mask & (1 << bit)) != 0 { writeFgPixel() } else { writeBgPixel() }
                remaining -= 1
            }
        }

        while si < src.count && di < totalSize {
            let byte = src[si]
            si += 1

            if (byte & 0xC0) != 0xC0 {
                // ===== REGULAR orders: code in top 3 bits, run in bottom 5 =====
                let code = byte >> 5
                var rl = Int(byte & 0x1F)

                if code == 2 { // FGBG: *8 or extended
                    if rl == 0 { guard si < src.count else { break }; rl = Int(src[si]) + 1; si += 1 }
                    else { rl *= 8 }
                } else {
                    if rl == 0 { guard si < src.count else { break }; rl = Int(src[si]) + 1; si += 1 }
                }

                switch code {
                case 0: // BG_RUN
                    if insertFgPel { writeFgPixel(); rl -= 1 }
                    if rl > 0 { for _ in 0..<rl { writeBgPixel() } }
                    insertFgPel = true
                case 1: // FG_RUN
                    for _ in 0..<rl { writeFgPixel() }
                    insertFgPel = false
                case 2: // FGBG_IMAGE
                    doFGBG(rl)
                    insertFgPel = false
                case 3: // COLOR_RUN
                    guard si + Bpp <= src.count else { break }
                    let c = Array(src[si..<(si + Bpp)]); si += Bpp
                    for _ in 0..<rl {
                        guard di + Bpp <= totalSize else { break }
                        for j in 0..<Bpp { dst[di + j] = c[j] }; di += Bpp
                    }
                    insertFgPel = false
                case 4: // COLOR_IMAGE
                    let n = rl * Bpp
                    guard si + n <= src.count, di + n <= totalSize else { break }
                    for i in 0..<n { dst[di + i] = src[si + i] }
                    si += n; di += n
                    insertFgPel = false
                default: break
                }

            } else if byte >= 0xF0 {
                // ===== MEGA / SPECIAL orders =====
                switch byte {
                case 0xF0: // MEGA_MEGA_BG_RUN
                    guard si + 2 <= src.count else { break }
                    var rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    if insertFgPel { writeFgPixel(); rl -= 1 }
                    if rl > 0 { for _ in 0..<rl { writeBgPixel() } }
                    insertFgPel = true
                case 0xF1: // MEGA_MEGA_FG_RUN
                    guard si + 2 <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    for _ in 0..<rl { writeFgPixel() }
                    insertFgPel = false
                case 0xF2: // MEGA_MEGA_FGBG_IMAGE
                    guard si + 2 <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    doFGBG(rl)
                    insertFgPel = false
                case 0xF3: // MEGA_MEGA_COLOR_RUN
                    guard si + 2 + Bpp <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    let c = Array(src[si..<(si + Bpp)]); si += Bpp
                    for _ in 0..<rl {
                        guard di + Bpp <= totalSize else { break }
                        for j in 0..<Bpp { dst[di + j] = c[j] }; di += Bpp
                    }
                    insertFgPel = false
                case 0xF4: // MEGA_MEGA_COLOR_IMAGE
                    guard si + 2 <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    let n = rl * Bpp
                    guard si + n <= src.count, di + n <= totalSize else { break }
                    for i in 0..<n { dst[di + i] = src[si + i] }
                    si += n; di += n
                    insertFgPel = false
                case 0xF6: // MEGA_MEGA_SET_FG_RUN
                    guard si + 2 + Bpp <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    for j in 0..<Bpp { fg[j] = src[si + j] }; si += Bpp
                    for _ in 0..<rl { writeFgPixel() }
                    insertFgPel = false
                case 0xF7: // MEGA_MEGA_SET_FGBG_IMAGE
                    guard si + 2 + Bpp <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    for j in 0..<Bpp { fg[j] = src[si + j] }; si += Bpp
                    doFGBG(rl)
                    insertFgPel = false
                case 0xF8: // MEGA_MEGA_DITHERED_RUN
                    guard si + 2 + 2 * Bpp <= src.count else { break }
                    let rl = Int(src[si]) | (Int(src[si+1]) << 8); si += 2
                    let c1 = Array(src[si..<(si + Bpp)]); si += Bpp
                    let c2 = Array(src[si..<(si + Bpp)]); si += Bpp
                    for i in 0..<(rl * 2) {
                        guard di + Bpp <= totalSize else { break }
                        let c = (i % 2 == 0) ? c1 : c2
                        for j in 0..<Bpp { dst[di + j] = c[j] }; di += Bpp
                    }
                    insertFgPel = false
                case 0xF9: // SPECIAL_FGBG_1 (8 pixels, mask 0x03)
                    doFGBGInline(8, 0x03)
                    insertFgPel = false
                case 0xFA: // SPECIAL_FGBG_2 (8 pixels, mask 0x05)
                    doFGBGInline(8, 0x05)
                    insertFgPel = false
                case 0xFD: // WHITE
                    guard di + Bpp <= totalSize else { break }
                    for j in 0..<Bpp { dst[di + j] = 0xFF }; di += Bpp
                    insertFgPel = false
                case 0xFE: // BLACK
                    guard di + Bpp <= totalSize else { break }
                    for j in 0..<Bpp { dst[di + j] = 0x00 }; di += Bpp
                    insertFgPel = false
                default: break
                }

            } else {
                // ===== LITE orders: code in top 4 bits, run in bottom 4 =====
                let code = byte >> 4
                var rl = Int(byte & 0x0F)

                if code == 0x0D { // SET_FG_FGBG: *8 or extended
                    if rl == 0 { guard si < src.count else { break }; rl = Int(src[si]) + 1; si += 1 }
                    else { rl *= 8 }
                } else {
                    if rl == 0 { guard si < src.count else { break }; rl = Int(src[si]) + 1; si += 1 }
                }

                switch code {
                case 0x0C: // SET_FG_FG_RUN
                    guard si + Bpp <= src.count else { break }
                    for j in 0..<Bpp { fg[j] = src[si + j] }; si += Bpp
                    for _ in 0..<rl { writeFgPixel() }
                    insertFgPel = false
                case 0x0D: // SET_FG_FGBG_IMAGE
                    guard si + Bpp <= src.count else { break }
                    for j in 0..<Bpp { fg[j] = src[si + j] }; si += Bpp
                    doFGBG(rl)
                    insertFgPel = false
                case 0x0E: // DITHERED_RUN
                    guard si + 2 * Bpp <= src.count else { break }
                    let c1 = Array(src[si..<(si + Bpp)]); si += Bpp
                    let c2 = Array(src[si..<(si + Bpp)]); si += Bpp
                    for i in 0..<(rl * 2) {
                        guard di + Bpp <= totalSize else { break }
                        let c = (i % 2 == 0) ? c1 : c2
                        for j in 0..<Bpp { dst[di + j] = c[j] }; di += Bpp
                    }
                    insertFgPel = false
                default: break
                }
            }
        }

        return dst
    }

    /// Send INPUT_EVENT_SYNC to synchronise keyboard toggle-key state (Caps/Num/Scroll Lock).
    /// Standard RDP clients (mstsc, FreeRDP) send this immediately after activation.
    private func sendInputSyncPDU() {
        // Slow-path TS_INPUT_PDU (pduType2 = 0x1C)
        var payload = Data()
        payload.append(le16(1))       // numberEvents
        payload.append(le16(0))       // pad2Octets
        payload.append(le32(0))       // eventTime
        payload.append(le16(0x0000))  // messageType = INPUT_EVENT_SYNC
        payload.append(le16(0))       // pad2Octets
        payload.append(le32(0))       // toggleFlags (no toggle keys pressed)
        sendActivationDataPDU(pduType2: 0x1C, payload: payload)
        delegate?.logger.log(content: "RDP session: Input Sync sent (toggleFlags=0)")
    }

    private func sendSuppressOutputPDU(allow: Bool) {
        var payload = Data()
        payload.append(allow ? 0x01 : 0x00)  // allowDisplayUpdates
        payload.append(0x00)
        payload.append(0x00)
        payload.append(0x00)

        if allow {
            let fallback = delegate?.rdpGetFramebufferSize() ?? (width: 1920, height: 1080)
            let width = max(1, rdpDesktopWidth > 0 ? rdpDesktopWidth : fallback.width)
            let height = max(1, rdpDesktopHeight > 0 ? rdpDesktopHeight : fallback.height)
            let right = max(0, width - 1)
            let bottom = max(0, height - 1)
            // desktopRect coordinates are inclusive.
            payload.append(le16(0))
            payload.append(le16(0))
            payload.append(le16(UInt16(right)))
            payload.append(le16(UInt16(bottom)))
        }

        sendActivationDataPDU(pduType2: 0x23, payload: payload)
        delegate?.logger.log(content: "RDP session: Suppress Output sent allow=\(allow) payload=\(payload.count) bytes")
    }

    private func sendRefreshRectPDU() {
        let fallback = delegate?.rdpGetFramebufferSize() ?? (width: 1920, height: 1080)
        let width = max(1, rdpDesktopWidth > 0 ? rdpDesktopWidth : fallback.width)
        let height = max(1, rdpDesktopHeight > 0 ? rdpDesktopHeight : fallback.height)
        let right = max(0, width - 1)
        let bottom = max(0, height - 1)

        // TS_REFRESH_RECT_PDU_DATA: numberOfAreasToRefresh(1), pad3Octets(3), then TS_RECTANGLE_16 list.
        var payload = Data()
        payload.append(0x01) // one rectangle
        payload.append(0x00)
        payload.append(0x00)
        payload.append(0x00)
        payload.append(le16(0))
        payload.append(le16(0))
        payload.append(le16(UInt16(right)))
        payload.append(le16(UInt16(bottom)))

        sendActivationDataPDU(pduType2: 0x21, payload: payload)
        delegate?.logger.log(content: "RDP session: Refresh Rect sent full=\(width)x\(height) rect=(0,0)-(\(right),\(bottom))")
    }

    private func sendWakeDisplayInputIfNeeded(reason: String) {
        guard !hasSentWakeDisplayInput else { return }

        let fallback = delegate?.rdpGetFramebufferSize() ?? (width: 1920, height: 1080)
        let width = max(1, rdpDesktopWidth > 0 ? rdpDesktopWidth : fallback.width)
        let height = max(1, rdpDesktopHeight > 0 ? rdpDesktopHeight : fallback.height)
        let x = min(max(0, width / 2), 0xFFFF)
        let y = min(max(0, height / 2), 0xFFFF)

        sendPointerEvent(x: x, y: y, flags: 0x0800)
        hasSentWakeDisplayInput = true
        delegate?.logger.log(content: "RDP session: wake-display pointer move sent x=\(x) y=\(y) reason=\(reason)")
    }

    private func cancelPostActivationNudges() {
        postActivationNudgeWorkItems.forEach { $0.cancel() }
        postActivationNudgeWorkItems.removeAll(keepingCapacity: false)
    }

    private func schedulePostActivationNudges() {
        cancelPostActivationNudges()
        let targetQueue = schedulingQueue ?? DispatchQueue.main
        let delays: [Double] = [0.4, 1.2, 2.5, 4.0]
        for delay in delays {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.handshakeState == .active else { return }
                self.sendSuppressOutputPDU(allow: true)
                self.sendRefreshRectPDU()
                self.sendWakeDisplayInputIfNeeded(reason: "post-activation-nudge")
                self.lastFramebufferRefreshAt = Date()
                self.delegate?.logger.log(content: "RDP session: delayed repaint nudge fired t=\(String(format: "%.2f", delay))s coverage=\(String(format: "%.2f", self.framebufferCoverageFraction() * 100))%")
            }
            postActivationNudgeWorkItems.append(work)
            targetQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }


    private func processX224Packet(_ data: Data) {
        guard data.count >= 2 else {
            delegate?.logger.log(content: "RDP processX224Packet: data too short (\(data.count) bytes)")
            return
        }

        let lengthIndicator = Int(data[0])
        let requiredLength = lengthIndicator + 1
        guard data.count >= requiredLength else {
            delegate?.logger.log(content: "RDP processX224Packet: incomplete X.224 TPDU (have \(data.count), need \(requiredLength))")
            return
        }

        let tpduCode = data[1]
        delegate?.logger.log(content: "RDP processX224Packet: LI=\(lengthIndicator), tpduCode=0x\(String(tpduCode, radix: 16)), length=\(data.count), full hex: \(data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " "))")

        switch tpduCode {
        case 0xD0: // Connection Confirm
            delegate?.logger.log(content: "RDP processX224Packet: X.224 Connection Confirm detected")
            handleX224ConnectionConfirm(data)
        case 0xF0: // Data TPDU
            processDataTPDU(data)
        default:
            delegate?.logger.log(content: "RDP processX224Packet: unhandled X.224 TPDU code 0x\(String(tpduCode, radix: 16))")
        }
    }

    private func processDataTPDU(_ data: Data) {
        guard data.count >= 3 else {
            delegate?.logger.log(content: "RDP processDataTPDU: payload too short (\(data.count) bytes)")
            return
        }

        // Data TPDU layout: LI, Code(0xF0), EOT(0x80), user data...
        let userData = data.subdata(in: 3..<data.count)
        delegate?.logger.log(content: "RDP processDataTPDU: userData=\(userData.count) bytes, state=\(handshakeState)")
        processMCSData(userData)
    }

    private func processMCSData(_ data: Data) {
        switch handshakeState {
        case .awaitingMCSConnectResponse:
            delegate?.logger.log(content: "RDP MCS: received Connect-Response-like payload (\(data.count) bytes)")
            sendMCSErectDomainRequest()
            sendMCSAttachUserRequest()
            handshakeState = .awaitingMCSAttachUserConfirm

        case .awaitingMCSAttachUserConfirm:
            // Attach User Confirm typically contains allocated user channel id.
            if let guessed = parseAttachUserId(from: data) {
                mcsUserId = guessed
                let userChannelText = mcsUserChannelId.map(String.init) ?? "unknown"
                delegate?.logger.log(content: "RDP MCS: parsed user id=\(guessed), user channel=\(userChannelText)")
            } else {
                mcsUserId = 3
                delegate?.logger.log(content: "RDP MCS: could not parse user id; using fallback userId=3 channel=1004")
            }

            // Join the assigned user channel and the global channel before Client Info.
            pendingMCSChannels = []
            if let userChannel = mcsUserChannelId {
                pendingMCSChannels.append(userChannel)
            }
            pendingMCSChannels.append(1003)
            if !advertisedStaticChannels.isEmpty {
                for index in 0..<advertisedStaticChannels.count {
                    pendingMCSChannels.append(UInt16(1004 + index))
                }
            }
            handshakeState = .awaitingMCSChannelJoinConfirm
            sendNextMCSChannelJoinRequest()

        case .awaitingMCSChannelJoinConfirm:
            delegate?.logger.log(content: "RDP MCS: channel join confirm received (\(data.count) bytes)")
            if !pendingMCSChannels.isEmpty {
                sendNextMCSChannelJoinRequest()
            } else {
                delegate?.logger.log(content: "RDP MCS: all baseline channels joined")
                handshakeState = .awaitingClientInfo
                sendClientInfo()
            }

        case .awaitingClientInfo:
            guard let parsed = parseMCSSendDataIndication(data) else {
                delegate?.logger.log(content: "RDP post-ClientInfo: unexpected payload format (\(data.count) bytes)")
                return
            }

            if isLicenseErrorValidClientPacket(parsed.userData) {
                delegate?.logger.log(content: "RDP licensing: server accepted client as valid (ERROR_ALERT/STATUS_VALID_CLIENT)")
                handshakeState = .awaitingDemandActive
            } else {
                delegate?.logger.log(content: "RDP licensing: received non-final licensing packet (\(parsed.userData.count) bytes)")
                handshakeState = .awaitingLicense
            }

        case .awaitingLicense:
            guard let parsed = parseMCSSendDataIndication(data) else {
                delegate?.logger.log(content: "RDP licensing: unexpected payload format (\(data.count) bytes)")
                return
            }

            if isLicenseErrorValidClientPacket(parsed.userData) {
                delegate?.logger.log(content: "RDP licensing: completed by server")
                handshakeState = .awaitingDemandActive
            } else {
                delegate?.logger.log(content: "RDP licensing: waiting for completion (\(parsed.userData.count) bytes)")
            }

        case .awaitingDemandActive, .awaitingConfirmActiveResponse, .awaitingControlGrant, .awaitingFontMap:
            guard let parsed = parseMCSSendDataIndication(data) else {
                delegate?.logger.log(content: "RDP activation: unexpected payload format (\(data.count) bytes)")
                return
            }

            if let pduType = parseShareControlPDUType(parsed.userData), pduType == 0x01 {
                guard let demand = parseDemandActive(parsed.userData) else {
                    delegate?.rdpSetError("RDP received Demand Active, but parsing failed.")
                    delegate?.rdpStopConnection(reason: "invalid Demand Active")
                    return
                }

                rdpShareId = demand.shareId
                if let desktopSize = parseBitmapCapabilityDesktopSize(demand.capabilitySets) {
                    applyServerDesktopSize(width: desktopSize.width, height: desktopSize.height)
                    delegate?.logger.log(content: "RDP activation: server desktop size=\(desktopSize.width)x\(desktopSize.height)")
                }
                parseServerCapabilities(demand.capabilitySets)
                // Dump server caps for diagnostics
                let serverCapsHex = demand.capabilitySets.prefix(min(demand.capabilitySets.count, 300)).map { String(format: "%02x", $0) }.joined(separator: " ")
                delegate?.logger.log(content: "RDP activation: Demand Active received shareId=0x\(String(rdpShareId, radix: 16)) caps=\(demand.numberCapabilities) capData=\(demand.capabilitySets.count)B hex=\(serverCapsHex)")
                sendClientActivationSequence(using: demand)
                hasControl = false
                handshakeState = .awaitingConfirmActiveResponse
            } else if let pduType = parseShareControlPDUType(parsed.userData), pduType == 0x07 {
                if let type2 = parseShareDataPDUType2(parsed.userData) {
                    delegate?.logger.log(content: "RDP activation: server data pduType2=0x\(String(type2, radix: 16))")
                    if type2 == 0x1F {
                        if handshakeState == .awaitingConfirmActiveResponse {
                            handshakeState = .awaitingControlGrant
                            delegate?.logger.log(content: "RDP activation: Synchronize received, awaiting Control Grant")
                        }
                    } else if type2 == 0x14 {
                        let controlAction = parseControlAction(parsed.userData)
                        if controlAction == 0x0002 {
                            hasControl = true
                            handshakeState = .awaitingFontMap
                            delegate?.logger.log(content: "RDP activation: Control Granted received")
                        }
                    } else if type2 == 0x28 {
                        guard hasControl else {
                            delegate?.logger.log(content: "RDP activation: FontMap received before Control Grant; waiting")
                            return
                        }
                        handshakeState = .active
                        hasSentSaveSessionInfoNudge = false
                        delegate?.rdpMarkConnected()
                        sendSuppressOutputPDU(allow: true)
                        if strictCompatibilityMode {
                            delegate?.logger.log(content: "RDP session: strict mode still sends Suppress Output allow=true to solicit updates")
                        }
                        sendInputSyncPDU()
                        sendRefreshRectPDU()
                        schedulePostActivationNudges()
                        delegate?.logger.log(content: "RDP activation complete: ACTIVE (FontMap received after Control Grant)")
                    } else if type2 == 0x2F {
                        // Set Error Info PDU (MS-RDPBCGR §2.2.5.1.1)
                        let errorCode = parseSetErrorInfoCode(parsed.userData)
                        let errorHex = String(format: "0x%08X", errorCode)
                        delegate?.logger.log(content: "RDP activation: Set Error Info PDU received, errorCode=\(errorHex) (\(rdpErrorDescription(errorCode)))")
                        delegate?.rdpSetError("RDP server error: \(errorHex) (\(rdpErrorDescription(errorCode)))")
                    }
                }
            } else {
                delegate?.logger.log(content: "RDP activation: received data pduType=\(parseShareControlPDUType(parsed.userData).map(String.init) ?? "unknown")")
            }

        case .active:
            guard let parsed = parseMCSSendDataIndication(data) else {
                let dump = data.prefix(min(data.count, 48)).map { String(format: "%02x", $0) }.joined(separator: " ")
                delegate?.logger.log(content: "RDP session: failed to parse MCS SendDataIndication (\(data.count)B, prefix=\(dump))")
                return
            }
            guard let pduType = parseShareControlPDUType(parsed.userData) else {
                let dump = parsed.userData.prefix(min(parsed.userData.count, 48)).map { String(format: "%02x", $0) }.joined(separator: " ")
                delegate?.logger.log(content: "RDP session: missing Share Control pduType (userData=\(parsed.userData.count)B, prefix=\(dump))")
                return
            }
            if pduType == 0x06 {  // PDUTYPE_DEACTIVATEALLPDU
                delegate?.logger.log(content: "RDP session: Deactivate All received, renegotiating")
                resetFastPathFragmentTrain(reason: "deactivate all", keepingCapacity: true)
                hasControl = false
                handshakeState = .awaitingDemandActive
            } else if pduType == 0x07 {
                if let type2 = parseShareDataPDUType2(parsed.userData) {
                    delegate?.logger.log(content: "RDP session: slow-path pduType2=0x\(String(type2, radix: 16))")
                    if type2 == 0x02 {
                        guard let payload = parseShareDataPDUPayload(parsed.userData) else {
                            delegate?.logger.log(content: "RDP session: slow-path UPDATE payload too short")
                            return
                        }
                        guard let updateType = parseSlowPathUpdateType(payload) else {
                            delegate?.logger.log(content: "RDP session: slow-path UPDATE missing updateType")
                            return
                        }

                        switch updateType {
                        case 0x0001: // UPDATETYPE_BITMAP
                            delegate?.logger.log(content: "RDP session: slow-path BITMAP update (\(payload.count) bytes)")
                            decodeFastPathBitmapUpdate([UInt8](payload))
                        case 0x0000: // UPDATETYPE_ORDERS
                            // payload layout: updateType(2) + numberOrders(2) + orderData...
                            if payload.count >= 4 {
                                maybeAcknowledgeFrameFromOrders(Array(payload.dropFirst(2)))
                            }
                            delegate?.logger.log(content: "RDP session: slow-path ORDERS update (\(payload.count) bytes)")
                        default:
                            delegate?.logger.log(content: "RDP session: slow-path UPDATE type=0x\(String(updateType, radix: 16)) size=\(payload.count)")
                        }
                    } else if type2 == 0x26 {
                        if let payload = parseShareDataPDUPayload(parsed.userData), payload.count >= 4 {
                            let infoType = UInt32(littleEndian: payload.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
                            delegate?.logger.log(content: "RDP session: Save Session Info infoType=0x\(String(format: "%08X", infoType)) size=\(payload.count)")
                            if !hasSentSaveSessionInfoNudge {
                                hasSentSaveSessionInfoNudge = true
                                sendSuppressOutputPDU(allow: true)
                                sendRefreshRectPDU()
                                sendWakeDisplayInputIfNeeded(reason: "save-session-info")
                            } else {
                                delegate?.logger.log(content: "RDP session: Save Session Info nudge already sent; skipping duplicate refresh")
                            }
                        } else {
                            delegate?.logger.log(content: "RDP session: Save Session Info payload too short")
                        }
                    } else if type2 == 0x2F {
                        let errorCode = parseSetErrorInfoCode(parsed.userData)
                        let errorHex = String(format: "0x%08X", errorCode)
                        delegate?.logger.log(content: "RDP session: Set Error Info errorCode=\(errorHex) (\(rdpErrorDescription(errorCode)))")
                        delegate?.rdpSetError("RDP server error: \(errorHex) (\(rdpErrorDescription(errorCode)))")
                    } else {
                        if let payload = parseShareDataPDUPayload(parsed.userData) {
                            let dump = payload.prefix(min(payload.count, 48)).map { String(format: "%02x", $0) }.joined(separator: " ")
                            delegate?.logger.log(content: "RDP session: unhandled slow-path pduType2=0x\(String(type2, radix: 16)) payload=\(payload.count)B prefix=\(dump)")
                        } else {
                            delegate?.logger.log(content: "RDP session: unhandled slow-path pduType2=0x\(String(type2, radix: 16)) with no payload")
                        }
                    }
                } else {
                    let dump = parsed.userData.prefix(min(parsed.userData.count, 48)).map { String(format: "%02x", $0) }.joined(separator: " ")
                    delegate?.logger.log(content: "RDP session: Share Data PDU missing pduType2 (size=\(parsed.userData.count)B, prefix=\(dump))")
                }
            } else {
                delegate?.logger.log(content: "RDP session: unhandled Share Control pduType=0x\(String(pduType, radix: 16))")
            }

        default:
            delegate?.logger.log(content: "RDP MCS: data received in state \(handshakeState), parser not implemented for this stage")
        }
    }

    private func parseAttachUserId(from data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }

        // Attach User Confirm ends with the raw MCS user id.
        let raw = UInt16(bigEndian: data.suffix(2).withUnsafeBytes { $0.load(as: UInt16.self) })
        return raw == 0 ? nil : raw
    }

    private func handleX224ConnectionConfirm(_ data: Data) {
        RDPProtocolHandler.trace("handleX224ConnectionConfirm: \(data.count) bytes")
        delegate?.logger.log(content: "RDP handleX224ConnectionConfirm: processing \(data.count) bytes")
        delegate?.logger.log(content: "RDP X.224 Connection Confirm received")

        // Optional RDP negotiation response starts right after standard X.224 fields.
        // X.224 CCF fields: LI(1) + Code(1) + DST-REF(2) + SRC-REF(2) + Class(1) = 7 bytes
        if data.count >= 15 {
            let negoType = data[7]
            let negoFlags = data[8]
            let negoLength = Int(UInt16(littleEndian: data.subdata(in: 9..<11).withUnsafeBytes { $0.load(as: UInt16.self) }))
            let negoValue = UInt32(littleEndian: data.subdata(in: 11..<15).withUnsafeBytes { $0.load(as: UInt32.self) })

            delegate?.logger.log(content: "RDP negotiation response: type=0x\(String(negoType, radix: 16)) flags=0x\(String(negoFlags, radix: 16)) len=\(negoLength) value=0x\(String(negoValue, radix: 16))")

            if negoType == 0x03 {
                // 0x5 often means server requires HYBRID/NLA and the request did not match policy.
                if negoValue == 0x0000_0005 {
                    if preferNonNLAForBringup {
                        delegate?.rdpSetError("Server enforces NLA (code 0x5). Non-NLA bring-up mode cannot proceed. Disable NLA on target to continue testing MCS/GCC path.")
                        delegate?.rdpStopConnection(reason: "NLA required while non-NLA mode enabled")
                        return
                    }
                    delegate?.logger.log(content: "RDP server requires HYBRID/NLA. Attempting minimal CredSSP bootstrap path.")
                    startMinimalCredSSPBootstrap()
                    return
                }

                delegate?.rdpSetError("RDP negotiation failed: \(describeNegotiationFailure(negoValue))")
                delegate?.rdpStopConnection(reason: "server negotiation failure")
                return
            }

            if negoType == 0x02 {
                if negoValue == 0x0000_0002 || negoValue == 0x0000_0008 {
                    if preferNonNLAForBringup {
                        delegate?.rdpSetError("Server selected HYBRID/NLA, but client is currently in non-NLA bring-up mode. Disable NLA on target host to test MCS/GCC path.")
                        delegate?.rdpStopConnection(reason: "NLA selected while non-NLA bring-up mode enabled")
                        return
                    }
                    delegate?.logger.log(content: "RDP negotiation selected HYBRID/NLA. Starting minimal CredSSP bootstrap.")
                    startMinimalCredSSPBootstrap()
                    return
                }

                if negoValue == 0x0000_0001 {
                    delegate?.logger.log(content: "RDP selected SSL transport")
                    delegate?.rdpSetError("Server selected SSL transport. TLS-based RDP data phase is not implemented yet.")
                    delegate?.rdpStopConnection(reason: "SSL data path not implemented")
                    return
                } else if negoValue == 0x0000_0000 {
                    delegate?.logger.log(content: "RDP selected standard RDP security")
                    startNonNLAPath()
                    return
                }
            }
        }

        // No negotiation block means legacy/non-NLA path.
        delegate?.logger.log(content: "RDP negotiation block not present; assuming standard RDP security")
        startNonNLAPath()
    }

    private func startNonNLAPath() {
        delegate?.logger.log(content: "RDP non-NLA path: sending MCS Connect-Initial")
        handshakeState = .awaitingMCSConnectResponse
        sendMCSConnectInitial()
    }

    private func sendMCSConnectInitial() {
        let (framebufferWidth, framebufferHeight) = delegate?.rdpGetFramebufferSize() ?? (1920, 1080)
        let gccUserData = buildGCCConferenceCreateRequest(
            width: UInt16(clamping: framebufferWidth),
            height: UInt16(clamping: framebufferHeight)
        )

        func domainParameters(maxChannelIds: Int, maxUserIds: Int, maxTokenIds: Int, maxMCSPDUSize: Int) -> Data {
            var body = Data()
            body.append(berInteger(maxChannelIds))
            body.append(berInteger(maxUserIds))
            body.append(berInteger(maxTokenIds))
            body.append(berInteger(1))
            body.append(berInteger(0))
            body.append(berInteger(1))
            body.append(berInteger(maxMCSPDUSize))
            body.append(berInteger(2))
            return berTLV(tag: 0x30, content: body)
        }

        let body = berOctetString(Data([0x01]))
            + berOctetString(Data([0x01]))
            + Data([0x01, 0x01, 0xFF])
            + domainParameters(maxChannelIds: 34, maxUserIds: 2, maxTokenIds: 0, maxMCSPDUSize: 65535)
            + domainParameters(maxChannelIds: 1, maxUserIds: 1, maxTokenIds: 1, maxMCSPDUSize: 1056)
            + domainParameters(maxChannelIds: 65535, maxUserIds: 64535, maxTokenIds: 65535, maxMCSPDUSize: 65535)
            + berOctetString(gccUserData)

        var pdu = Data([0x7F, 0x65])
        pdu.append(berLength(body.count))
        pdu.append(body)

        sendX224DataTPDU(pdu)
        delegate?.logger.log(content: "RDP MCS: Connect-Initial sent (\(pdu.count) bytes, gccUserData=\(gccUserData.count) bytes)")
    }

    private func buildGCCConferenceCreateRequest(width: UInt16, height: UInt16) -> Data {
        let clientData = buildCSCoreData(width: width, height: height)
            + buildCSClusterData()
            + buildCSSecurityData()
            + buildCSNetData()

        var gcc = Data([0x00, 0x05, 0x00, 0x14, 0x7C, 0x00, 0x01])
        gcc.append(perLength(14 + clientData.count))
        gcc.append(contentsOf: [0x00, 0x08, 0x00, 0x10, 0x00, 0x01, 0xC0, 0x00])
        gcc.append(Data("Duca".utf8))
        gcc.append(perLength(clientData.count))
        gcc.append(clientData)
        return gcc
    }

    private func buildCSCoreData(width: UInt16, height: UInt16) -> Data {
        var body = Data()
        body.append(le32(0x00080004))
        body.append(le16(width))
        body.append(le16(height))
        body.append(le16(0xCA01))
        body.append(le16(0xAA03))
        body.append(le32(0x00000409))
        body.append(le32(3790))

        let clientNameUTF16 = Array("OPENTERFACE".utf16.prefix(15))
        var clientName = Data()
        for codeUnit in clientNameUTF16 {
            clientName.append(le16(codeUnit))
        }
        clientName.append(Data(count: max(0, 32 - clientName.count)))
        body.append(clientName)

        body.append(le32(4))
        body.append(le32(0))
        body.append(le32(12))
        body.append(Data(count: 64))
        body.append(le16(0xCA01))
        body.append(le16(1))
        body.append(le32(0))
        body.append(le16(32))     // highColorDepth: 32bpp
        body.append(le16(0x000F)) // supportedColorDepths: 15|16|24|32 bpp
        // earlyCapabilityFlags:
        //   SUPPORT_ERRINFO_PDU(0x0001) | WANT_32BPP_SESSION(0x0002) |
        //   SUPPORT_STATUSINFO_PDU(0x0004) | STRONG_ASYMMETRIC_KEYS(0x0008) |
        //   VALID_CONNECTION_TYPE(0x0020)
        body.append(le16(0x002F))

        let productIdUTF16 = Array("69712-783-0357974-42714".utf16.prefix(31))
        var productId = Data()
        for codeUnit in productIdUTF16 {
            productId.append(le16(codeUnit))
        }
        productId.append(Data(count: max(0, 64 - productId.count)))
        body.append(productId)

        body.append(0x06)  // connectionType: CONNECTION_TYPE_LAN
        body.append(0x00)  // pad1octet
        body.append(le32(2))  // serverSelectedProtocol: PROTOCOL_HYBRID

        var block = Data()
        block.append(le16(0xC001))
        block.append(le16(UInt16(body.count + 4)))
        block.append(body)
        return block
    }

    private func buildCSClusterData() -> Data {
        var block = Data()
        block.append(le16(0xC004))
        block.append(le16(12))
        block.append(le32(0x0000000D))
        block.append(le32(0))
        return block
    }

    private func buildCSSecurityData() -> Data {
        var block = Data()
        block.append(le16(0xC002))
        block.append(le16(12))
        block.append(le32(0x0000001B))
        block.append(le32(0))
        return block
    }

    private func buildCSNetData() -> Data {
        let channels = advertisedStaticChannels

        var body = Data()
        body.append(le32(UInt32(channels.count)))
        for (name, options) in channels {
            var nameField = Data(name.utf8.prefix(8))
            nameField.append(Data(count: max(0, 8 - nameField.count)))
            body.append(nameField)
            body.append(le32(options))
        }

        var block = Data()
        block.append(le16(0xC003))
        block.append(le16(UInt16(body.count + 4)))
        block.append(body)
        return block
    }

    private func berTLV(tag: UInt8, content: Data) -> Data {
        Data([tag]) + berLength(content.count) + content
    }

    private func berOctetString(_ data: Data) -> Data {
        berTLV(tag: 0x04, content: data)
    }

    private func berInteger(_ value: Int) -> Data {
        var bytes = Data()
        var started = false
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((value >> shift) & 0xFF)
            if byte != 0 || started || shift == 0 {
                bytes.append(byte)
                started = true
            }
        }
        if let first = bytes.first, (first & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return berTLV(tag: 0x02, content: bytes)
    }

    private func berLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        if length < 0x100 {
            return Data([0x81, UInt8(length)])
        }
        return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }

    private func perLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        return Data([0x80 | UInt8((length >> 8) & 0x7F), UInt8(length & 0xFF)])
    }

    private func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func sendMCSErectDomainRequest() {
        let pdu = Data([0x04, 0x01, 0x00, 0x01, 0x00])
        sendX224DataTPDU(pdu)
        delegate?.logger.log(content: "RDP MCS: ErectDomainRequest sent")
    }

    private func sendMCSAttachUserRequest() {
        let pdu = Data([0x28])
        sendX224DataTPDU(pdu)
        delegate?.logger.log(content: "RDP MCS: AttachUserRequest sent")
    }

    private func sendNextMCSChannelJoinRequest() {
        guard !pendingMCSChannels.isEmpty else { return }
        guard let user = mcsUserId else {
            delegate?.logger.log(content: "RDP MCS: missing user id; cannot send ChannelJoinRequest")
            return
        }

        let channel = pendingMCSChannels.removeFirst()

        var pdu = Data([0x38])
        pdu.append(contentsOf: withUnsafeBytes(of: user.bigEndian) { Data($0) })
        pdu.append(contentsOf: withUnsafeBytes(of: channel.bigEndian) { Data($0) })

        sendX224DataTPDU(pdu)
        delegate?.logger.log(content: "RDP MCS: ChannelJoinRequest sent for channel=\(channel)")
    }

    private func sendX224DataTPDU(_ payload: Data) {
        var x224 = Data([0x02, 0xF0, 0x80])
        x224.append(payload)
        let tpkt = wrapInTPKT(x224)
        delegate?.rdpSend(tpkt)
    }

    private func describeNegotiationFailure(_ code: UInt32) -> String {
        switch code {
        case 0x0000_0001:
            return "SSL required by server (0x1)."
        case 0x0000_0002:
            return "SSL not allowed by server (0x2)."
        case 0x0000_0003:
            return "SSL certificate not present on server (0x3)."
        case 0x0000_0004:
            return "Inconsistent negotiation flags (0x4)."
        case 0x0000_0005:
            return "HYBRID/NLA required by server (0x5). This client does not implement CredSSP yet; disable NLA on target to continue."
        case 0x0000_0006:
            return "SSL with user auth required by server (0x6)."
        default:
            return "unknown code 0x\(String(code, radix: 16))."
        }
    }

    // MARK: - Full CredSSP / NLA bootstrap (MS-CSSP + NTLMv2)

    private func cancelCredSSPTimeout() {
        credSSPTimeoutWorkItem?.cancel()
        credSSPTimeoutWorkItem = nil
    }

    private func startMinimalCredSSPBootstrap() {
        RDPProtocolHandler.trace("startMinimalCredSSPBootstrap: upgrading to TLS")
        handshakeState = .awaitingCredSSP

        // Upgrade the underlying socket to TLS – required before any CredSSP bytes.
        guard delegate?.rdpAttemptTLSUpgrade() == true else {
            delegate?.rdpSetError("NLA requires TLS upgrade but transport refused.")
            delegate?.rdpStopConnection(reason: "TLS upgrade unavailable for NLA")
            return
        }
        usingEnhancedSecurityTransport = true

        // TLS handshake succeeded; start the NTLMv2 exchange.
        startFullCredSSPNLA()
    }

    private func startFullCredSSPNLA() {
        RDPProtocolHandler.trace("startFullCredSSPNLA: creating NTLMAuth for user=\(username)")
        let auth = NTLMAuth(username: username, password: password, domain: domain)
        ntlmAuth = auth

        // Generate 32-byte client nonce for CredSSP v5/v6 pubKeyAuth binding (MS-CSSP §3.1.5.1.2)
        var nonce = Data(count: 32)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        credSSPClientNonce = nonce

        let negotiate = auth.negotiate()
        // Wrap raw NTLM in SPNEGO NegTokenInit – Windows rejects unwrapped NTLM in CredSSP
        let spnegoNegotiate = spnegoNegTokenInit(mechToken: negotiate)
        // TSRequest version 6 – required by Windows after CVE-2018-0886 (KB4093492)
        let tsRequest = buildCredSSPTSRequest(negoToken: spnegoNegotiate, version: 6)

        delegate?.logger.log(content: "RDP CredSSP: sending TSRequest/NTLM NEGOTIATE (\(tsRequest.count) bytes)")
        delegate?.rdpSend(tsRequest)

        handshakeState = .awaitingNTLMChallenge

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.handshakeState == .awaitingNTLMChallenge else { return }
            self.delegate?.rdpSetError("CredSSP NTLM challenge timed out.")
            self.delegate?.rdpStopConnection(reason: "CredSSP NTLM challenge timeout")
        }
        credSSPTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutItem)
    }

    /// Handles raw DER data received during CredSSP negotiation (all three CredSSP states).
    private func processCredSSPResponse(_ data: Data) {
        RDPProtocolHandler.trace("processCredSSPResponse: \(data.count) bytes, state=\(handshakeState), hex=\(data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
        delegate?.logger.log(content: "RDP CredSSP response: \(data.count) bytes, state=\(handshakeState)")

        // Check for server-side SSPI error before doing anything else.
        // The server encodes errors in TSRequest as [4] errorCode INTEGER (MS-CSSP §2.2.1).
        if let errorCode = extractCredSSPErrorCode(from: data) {
            RDPProtocolHandler.trace("SSPI error detected: 0x\(String(errorCode, radix: 16, uppercase: true))")
            cancelCredSSPTimeout()
            let name = sspiErrorName(errorCode)
            let msg = "CredSSP: server SSPI error \(name) (0x\(String(errorCode, radix: 16, uppercase: true))). " +
                      "Common causes: NLA/CredSSP disabled on server; NTLM blocked by Group Policy; wrong domain."
            delegate?.logger.log(content: "RDP " + msg)
            delegate?.rdpSetError(msg)
            delegate?.rdpStopConnection(reason: "CredSSP server error \(name)")
            return
        }
        RDPProtocolHandler.trace("no SSPI error, dispatching by state=\(handshakeState)")

        switch handshakeState {
        case .awaitingNTLMChallenge:
            RDPProtocolHandler.trace("dispatching to handleCredSSPNTLMChallenge")
            cancelCredSSPTimeout()
            handleCredSSPNTLMChallenge(data)

        case .awaitingCredSSPPubKeyEcho:
            RDPProtocolHandler.trace("dispatching to handleCredSSPPubKeyEcho")
            cancelCredSSPTimeout()
            handleCredSSPPubKeyEcho(data)

        default:
            delegate?.logger.log(content: "RDP CredSSP: unexpected data in state \(handshakeState)")
        }
    }

    /// Extracts the NTSTATUS/SSPI errorCode from a CredSSP TSRequest (field [4]).
    private func extractCredSSPErrorCode(from data: Data) -> UInt32? {
        guard let seqContent = derPeelTLV(data, expectedTag: 0x30) else { return nil }
        var cursor = seqContent.startIndex
        while cursor < seqContent.endIndex {
            guard let (tag, content, next) = derNextTLV(seqContent, at: cursor) else { break }
            if tag == 0xA4 {
                // [4] EXPLICIT INTEGER
                if let intBytes = derPeelTLV(content, expectedTag: 0x02) {
                    var value: UInt32 = 0
                    for b in intBytes { value = (value << 8) | UInt32(b) }
                    return value
                }
            }
            cursor = next
        }
        return nil
    }

    /// Extracts the CredSSP version from a TSRequest (field [0]).
    private func extractCredSSPVersion(from data: Data) -> Int? {
        guard let seqContent = derPeelTLV(data, expectedTag: 0x30) else { return nil }
        var cursor = seqContent.startIndex
        while cursor < seqContent.endIndex {
            guard let (tag, content, next) = derNextTLV(seqContent, at: cursor) else { break }
            if tag == 0xA0 {
                if let intBytes = derPeelTLV(content, expectedTag: 0x02) {
                    var value: Int = 0
                    for b in intBytes { value = (value << 8) | Int(b) }
                    return value
                }
            }
            cursor = next
        }
        return nil
    }

    /// Human-readable name for common SSPI/NTSTATUS codes returned in CredSSP errorCode.
    private func sspiErrorName(_ code: UInt32) -> String {
        switch code {
        case 0x80090302: return "SEC_E_UNSUPPORTED_FUNCTION"
        case 0x80090308: return "SEC_E_INVALID_TOKEN"
        case 0x80090311: return "SEC_E_NO_CREDENTIALS"
        case 0x80090345: return "SEC_E_MUTUAL_AUTH_FAILED"
        case 0x8009030C: return "SEC_E_LOGON_DENIED"
        case 0x8009030F: return "SEC_E_MESSAGE_ALTERED"
        case 0xC000006D: return "STATUS_LOGON_FAILURE (wrong credentials)"
        case 0xC0000064: return "STATUS_NO_SUCH_USER"
        case 0xC0000234: return "STATUS_ACCOUNT_LOCKED_OUT"
        case 0xC000006E: return "STATUS_ACCOUNT_RESTRICTION"
        case 0xC0000072: return "STATUS_ACCOUNT_DISABLED"
        default:         return "0x\(String(code, radix: 16, uppercase: true))"
        }
    }

    private func handleCredSSPNTLMChallenge(_ data: Data) {
        RDPProtocolHandler.trace("handleCredSSPNTLMChallenge: \(data.count) bytes")
        guard let auth = ntlmAuth else {
            delegate?.rdpSetError("CredSSP: ntlmAuth missing when processing NTLM challenge")
            delegate?.rdpStopConnection(reason: "CredSSP internal error")
            return
        }

        // Extract negoToken from TSRequest DER, then peel SPNEGO envelope if present
        let rawNegoToken = extractNegoToken(from: data)
        let challengeData: Data
        if !rawNegoToken.isEmpty {
            let unwrapped = spnegoExtractToken(from: rawNegoToken)
            challengeData = unwrapped.isEmpty ? rawNegoToken : unwrapped
            delegate?.logger.log(content: "RDP CredSSP: extracted NTLM challenge \(challengeData.count) bytes (SPNEGO unwrap: \(!unwrapped.isEmpty))")
        } else {
            delegate?.logger.log(content: "RDP CredSSP: no negoToken in TSRequest, trying raw payload")
            challengeData = data
        }

        // Log server CredSSP version
        if let serverVersion = extractCredSSPVersion(from: data) {
            delegate?.logger.log(content: "RDP CredSSP: server version=\(serverVersion)")
        }
        // Log NTLM challenge prefix for diagnostic
        delegate?.logger.log(content: "RDP CredSSP: challenge prefix: \(challengeData.prefix(min(challengeData.count, 32)).map { String(format: "%02x", $0) }.joined(separator: " "))")

        guard auth.parseChallenge(challengeData) else {
            delegate?.rdpSetError("CredSSP: NTLM CHALLENGE message parse failed")
            delegate?.rdpStopConnection(reason: "CredSSP NTLM parse failure")
            return
        }

        delegate?.logger.log(content: "RDP CredSSP: NTLM CHALLENGE parsed OK; building AUTHENTICATE")

        // Round 2: AUTHENTICATE + pubKeyAuth (CredSSP v5/v6 binding hash formula)
        let authenticate = auth.authenticate()

        // Log NTLM diagnostic info through delegate logger (print() not visible to user)
        for line in auth.diagnosticInfo.split(separator: "\n") {
            delegate?.logger.log(content: "RDP \(line)")
        }

        // pubKeyAuth for v5/v6 (MS-CSSP §3.1.5):
        //   1. hash = SHA-256("CredSSP Client-To-Server Binding Hash\0" || clientNonce || serverPublicKey)
        //   2. pubKeyAuth = NTLM_Seal(hash) → 16-byte signature + 32-byte encrypted hash
        //
        // DIAGNOSTIC MODE: skip mechListMIC, no MsvAvFlags=0x02, seal at seqNum=0.
        // If server returns SEC_E_MESSAGE_ALTERED → basic NTLMv2 auth OK, pubKeyAuth wrong.
        // If server closes connection → NTLMv2 response itself is broken.
        let pubKeyAuth: Data
        if auth.sessionKey != nil {
            let spkDER = serverPublicKeyBytes()
            if !spkDER.isEmpty {
                let bindingMsg = credSSPBindingMsg(direction: "Client-To-Server")
                let hashInput = bindingMsg + credSSPClientNonce + spkDER
                let hash = sha256(hashInput)
                delegate?.logger.log(content: "RDP CredSSP v6 DIAG: pubKeyAuth SHA256 input: magic[\(bindingMsg.count)] + nonce[\(credSSPClientNonce.count)] + spk[\(spkDER.count)] = \(hashInput.count) bytes")
                delegate?.logger.log(content: "RDP CredSSP v6 DIAG: spk format: \(spkDER.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")) (\(spkDER.count) bytes)")
                delegate?.logger.log(content: "RDP CredSSP v6 DIAG: SHA256 hash: \(hash.map { String(format: "%02x", $0) }.joined(separator: " "))")
                delegate?.logger.log(content: "RDP CredSSP DIAG: no mechListMIC, no MsvAvFlags, no MIC → seal at seqNum=0")

                if let sealed = auth.seal(hash) {
                    pubKeyAuth = sealed
                    delegate?.logger.log(content: "RDP CredSSP v6 DIAG: pubKeyAuth sealed (\(pubKeyAuth.count) bytes, seqNum=0) sig: \(pubKeyAuth.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
                } else {
                    pubKeyAuth = Data()
                }
            } else {
                delegate?.logger.log(content: "RDP CredSSP: server public key unavailable, skipping pubKeyAuth binding")
                pubKeyAuth = Data()
            }
        } else {
            pubKeyAuth = Data()
        }

        // Wrap AUTHENTICATE in SPNEGO NegTokenResp (no mechListMIC — diagnostic mode)
        let spnegoAuthenticate = spnegoNegTokenResp(token: authenticate)

        let tsRequest = buildCredSSPTSRequestWithPubKey(negoToken: spnegoAuthenticate,
                                                        pubKeyAuth: pubKeyAuth,
                                                        clientNonce: credSSPClientNonce)
        delegate?.logger.log(content: "RDP CredSSP: sending TSRequest/NTLM AUTHENTICATE (\(tsRequest.count) bytes)")
        delegate?.rdpSend(tsRequest)

        handshakeState = .awaitingCredSSPPubKeyEcho
        RDPProtocolHandler.trace("AUTHENTICATE sent, state -> awaitingCredSSPPubKeyEcho, setting 10s timeout")

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            RDPProtocolHandler.trace("pubKeyEcho timeout FIRED, current state=\(self.handshakeState)")
            guard self.handshakeState == .awaitingCredSSPPubKeyEcho else {
                RDPProtocolHandler.trace("pubKeyEcho timeout: state no longer awaitingCredSSPPubKeyEcho, skipping")
                return
            }
            self.delegate?.rdpSetError("CredSSP pubKeyEcho timed out.")
            self.delegate?.rdpStopConnection(reason: "CredSSP pubKeyEcho timeout")
        }
        credSSPTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeoutItem)
        RDPProtocolHandler.trace("timeout scheduled on main queue")
    }

    private func handleCredSSPPubKeyEcho(_ data: Data) {
        RDPProtocolHandler.trace("handleCredSSPPubKeyEcho: \(data.count) bytes")
        delegate?.logger.log(content: "RDP CredSSP: server pubKeyAuth echo received (\(data.count) bytes)")

        guard let auth = ntlmAuth else {
            delegate?.rdpSetError("CredSSP: ntlmAuth missing at pubKeyEcho stage")
            delegate?.rdpStopConnection(reason: "CredSSP internal error")
            return
        }

        // TODO: verify server's pubKeyAuth echo (unseal + compare Server-To-Client hash)

        // Round 3: send TSCredentials (domain, user, password) sealed with NTLM session security
        let tsCredentials = buildTSCredentials(username: username, password: password, domain: domain)
        guard let sealedCredentials = auth.seal(tsCredentials) else {
            delegate?.rdpSetError("CredSSP: failed to NTLM-seal TSCredentials")
            delegate?.rdpStopConnection(reason: "CredSSP seal failure")
            return
        }
        let versionField    = derContextSpecific(tag: 0, value: derInteger(6))
        let authInfoField   = derContextSpecific(tag: 2, value: derOctetString(sealedCredentials))
        let clientNonceField = derContextSpecific(tag: 5, value: derOctetString(credSSPClientNonce))
        let tsRequest = derSequence(versionField + authInfoField + clientNonceField)

        delegate?.logger.log(content: "RDP CredSSP: sending TSCredentials (\(tsRequest.count) bytes, sealed \(sealedCredentials.count) bytes)")
        delegate?.rdpSend(tsRequest)

        // CredSSP complete – transition to standard MCS phase
        RDPProtocolHandler.trace("CredSSP complete, proceeding to MCS")
        delegate?.logger.log(content: "RDP CredSSP: authentication complete, proceeding to MCS")
        startNonNLAPath()
    }

    // MARK: - CredSSP DER helpers

    private func extractNegoToken(from tsRequestDER: Data) -> Data {
        // TSRequest: SEQUENCE { [0] version, [1] negoTokens SEQUENCE OF { SEQUENCE { [0] negoToken } } }
        // We walk the top-level SEQUENCE looking for [1] (negoTokens context tag 0xA1)
        guard let seqContent = derPeelTLV(tsRequestDER, expectedTag: 0x30) else { return Data() }
        var cursor = seqContent.startIndex
        while cursor < seqContent.endIndex {
            guard let (tag, content, next) = derNextTLV(seqContent, at: cursor) else { break }
            if tag == 0xA1 {
                // negoTokens field: strip outer SEQUENCE of SEQUENCE, then [0] octet string
                if let outer = derPeelTLV(content, expectedTag: 0x30),
                   let inner = derPeelTLV(outer, expectedTag: 0x30),
                   let tokenField = derPeelContextSpecific(inner, tag: 0),
                   let tokenBytes = derPeelTLV(tokenField, expectedTag: 0x04) {
                    return tokenBytes
                }
            }
            cursor = next
        }
        return Data()
    }

    // MARK: - SPNEGO helpers (GSS-API token wrapping for NLA)

    /// Wraps a raw NTLM token in a SPNEGO NegTokenInit (round 1, client → server).
    /// GSS-API APPLICATION[0] { OID(spnego) [0] NegTokenInit { [0] mechTypes [2] mechToken } }
    private func spnegoNegTokenInit(mechToken: Data) -> Data {
        // mechTypes lists only NTLM. NEGOEX (1.3.6.1.4.1.311.2.2.30) is for Kerberos/PKU2U and
        // must NOT be listed when the mechToken is raw NTLM — Windows SSPI would try to parse
        // the mechToken as NEGOEX format and return SEC_E_INVALID_TOKEN.
        // NTLM OID: 1.3.6.1.4.1.311.2.2.10
        let ntlmOID        = Data([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a])
        let mechTypesSeq   = derTLV(tag: 0x30, content: ntlmOID)
        let mechTypesField = derContextSpecific(tag: 0, value: mechTypesSeq)
        let mechTokenField = derContextSpecific(tag: 2, value: derOctetString(mechToken))
        let negTokenInit   = derTLV(tag: 0x30, content: mechTypesField + mechTokenField)
        let ctxZero        = derContextSpecific(tag: 0, value: negTokenInit)
        // OID for SPNEGO: 1.3.6.1.5.5.2
        let spnegoOID      = Data([0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02])
        return derTLV(tag: 0x60, content: spnegoOID + ctxZero)
    }

    /// Wraps a raw NTLM token in a SPNEGO NegTokenResp (round 2+, client → server).
    /// [1] NegTokenResp { [2] responseToken, [3] mechListMIC (optional) }
    private func spnegoNegTokenResp(token: Data, mechListMIC: Data? = nil) -> Data {
        // NOTE: negState is NOT included — only the acceptor (server) sends negState.
        // Including it from the initiator causes Windows SSPI to return SEC_E_INVALID_TOKEN.
        var fields = derContextSpecific(tag: 2, value: derOctetString(token))
        if let mic = mechListMIC, !mic.isEmpty {
            fields += derContextSpecific(tag: 3, value: derOctetString(mic))
        }
        let seq = derTLV(tag: 0x30, content: fields)
        return derContextSpecific(tag: 1, value: seq)
    }

    /// Returns the DER-encoded mechTypeList (SEQUENCE { NTLM_OID }) used in NegTokenInit.
    /// This exact blob is what the SPNEGO mechListMIC is computed over (MS-SPNG §3.1.5.1).
    private func spnegoMechTypeList() -> Data {
        let ntlmOID = Data([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a])
        return derTLV(tag: 0x30, content: ntlmOID)
    }

    /// Extracts the embedded NTLM token from a SPNEGO blob (NegTokenInit or NegTokenResp).
    /// Returns empty Data if the input is not a recognisable SPNEGO structure.
    private func spnegoExtractToken(from data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        // NegTokenResp: a1 LL 30 LL { [0]? negState, [1]? mechOID, [2] responseToken, ... }
        if data[data.startIndex] == 0xa1 {
            if let inner = derPeelTLV(data, expectedTag: 0xa1),
               let seqC  = derPeelTLV(inner, expectedTag: 0x30) {
                var cur = seqC.startIndex
                while cur < seqC.endIndex {
                    guard let (tag, cnt, nxt) = derNextTLV(seqC, at: cur) else { break }
                    if tag == 0xa2, let tok = derPeelTLV(cnt, expectedTag: 0x04) { return tok }
                    cur = nxt
                }
            }
        }

        // APPLICATION[0] GSS token: 60 LL OID(spnego) [0] NegTokenInit { 30 { [2] mechToken } }
        if data[data.startIndex] == 0x60 {
            if let appC = derPeelTLV(data, expectedTag: 0x60) {
                var cur = appC.startIndex
                while cur < appC.endIndex {
                    guard let (tag, cnt, nxt) = derNextTLV(appC, at: cur) else { break }
                    if tag == 0xa0, let seqC = derPeelTLV(cnt, expectedTag: 0x30) {
                        var c2 = seqC.startIndex
                        while c2 < seqC.endIndex {
                            guard let (t2, c2cnt, c2nxt) = derNextTLV(seqC, at: c2) else { break }
                            if t2 == 0xa2, let tok = derPeelTLV(c2cnt, expectedTag: 0x04) { return tok }
                            c2 = c2nxt
                        }
                    }
                    cur = nxt
                }
            }
        }
        return Data()
    }

    private func buildCredSSPTSRequest(negoToken: Data, version: UInt8 = 6) -> Data {
        let negoTokenOctet  = derContextSpecific(tag: 0, value: derOctetString(negoToken))
        let negoDataItem    = derSequence(negoTokenOctet)
        let negoTokensSeq   = derSequence(negoDataItem)
        let versionField    = derContextSpecific(tag: 0, value: derInteger(version))
        let negoTokensField = derContextSpecific(tag: 1, value: negoTokensSeq)
        // CredSSP v6+: clientNonce [5] MUST be present in every TSRequest (MS-CSSP §3.1.5.1.1)
        let clientNonceField = credSSPClientNonce.isEmpty ? Data()
            : derContextSpecific(tag: 5, value: derOctetString(credSSPClientNonce))
        return derSequence(versionField + negoTokensField + clientNonceField)
    }

    private func buildCredSSPTSRequestWithPubKey(negoToken: Data, pubKeyAuth: Data, clientNonce: Data) -> Data {
        let negoTokenOctet   = derContextSpecific(tag: 0, value: derOctetString(negoToken))
        let negoDataItem     = derSequence(negoTokenOctet)
        let negoTokensSeq    = derSequence(negoDataItem)

        let versionField     = derContextSpecific(tag: 0, value: derInteger(6))
        let negoTokensField  = derContextSpecific(tag: 1, value: negoTokensSeq)

        var fields = versionField + negoTokensField
        if !pubKeyAuth.isEmpty {
            fields += derContextSpecific(tag: 3, value: derOctetString(pubKeyAuth))
        }
        fields += derContextSpecific(tag: 5, value: derOctetString(clientNonce))
        return derSequence(fields)
    }

    private func credSSPBindingMsg(direction: String) -> Data {
        // MS-CSSP §3.1.5.1.2 — binding magic string includes a trailing NUL byte
        return Data(("CredSSP \(direction) Binding Hash\0").utf8)
    }

    private func buildTSCredentials(username: String, password: String, domain: String) -> Data {
        // TSCredentials ::= SEQUENCE { credType [0] INTEGER, credentials [1] OCTET STRING }
        // credentials = TSPasswordCreds ::= SEQUENCE { [0] domain, [1] userName, [2] password }
        func utf16le(_ s: String) -> Data { s.data(using: .utf16LittleEndian) ?? Data() }

        let domainOctet   = derContextSpecific(tag: 0, value: derOctetString(utf16le(domain)))
        let userOctet     = derContextSpecific(tag: 1, value: derOctetString(utf16le(username)))
        let passOctet     = derContextSpecific(tag: 2, value: derOctetString(utf16le(password)))
        let pwdCreds      = derSequence(domainOctet + userOctet + passOctet)

        let credType      = derContextSpecific(tag: 0, value: derInteger(1))   // 1 = password
        let credentials   = derContextSpecific(tag: 1, value: derOctetString(pwdCreds))
        return derSequence(credType + credentials)
    }

    private func serverPublicKeyBytes() -> Data {
        // The channel exposes the key via RDPTLSChannel. We access it through the delegate
        // by querying the shared singleton (both sides know this is RDPClientManager).
        guard let ch = RDPClientManager.shared.tlsChannel else { return Data() }
        return ch.serverPublicKeyDER ?? Data()
    }

    /// Returns the full SubjectPublicKeyInfo DER from the server certificate.
    /// Falls back to PKCS#1 RSAPublicKey if SubjectPublicKeyInfo extraction failed.
    private func serverSubjectPublicKeyInfoBytes() -> Data {
        guard let ch = RDPClientManager.shared.tlsChannel else { return Data() }
        if let spki = ch.serverSubjectPublicKeyInfo { return spki }
        return ch.serverPublicKeyDER ?? Data()
    }

    // SHA-256 HMAC
    private func hmacSHA256(key: Data, data: Data) -> Data {
        var mac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        mac.withUnsafeMutableBytes { macPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                           keyPtr.baseAddress, key.count,
                           dataPtr.baseAddress, data.count,
                           macPtr.baseAddress)
                }
            }
        }
        return mac
    }

    // Plain SHA-256 digest
    private func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hash.withUnsafeMutableBytes { hashPtr in
            data.withUnsafeBytes { dataPtr in
                CC_SHA256(dataPtr.baseAddress, CC_LONG(data.count),
                          hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    private func rc4Encrypt(key: Data, data: Data) -> Data {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
        var out = Data(count: data.count)
        var i = 0; j = 0
        for k in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out[k] = data[k] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }

    // MARK: - Simple DER walker helpers

    private func derPeelTLV(_ data: Data, expectedTag: UInt8) -> Data? {
        guard !data.isEmpty, data[data.startIndex] == expectedTag else { return nil }
        guard let (_, content, _) = derNextTLV(data, at: data.startIndex) else { return nil }
        return content
    }

    private func derPeelContextSpecific(_ data: Data, tag: UInt8) -> Data? {
        return derPeelTLV(data, expectedTag: 0xA0 | tag)
    }

    private func derNextTLV(_ data: Data, at start: Data.Index) -> (tag: UInt8, content: Data, next: Data.Index)? {
        guard start < data.endIndex else { return nil }
        let tag = data[start]
        var pos = data.index(after: start)
        guard pos < data.endIndex else { return nil }
        let firstLenByte = data[pos]
        pos = data.index(after: pos)
        let length: Int
        if firstLenByte < 0x80 {
            length = Int(firstLenByte)
        } else {
            let extraBytes = Int(firstLenByte & 0x7F)
            guard data.distance(from: pos, to: data.endIndex) >= extraBytes else { return nil }
            var len = 0
            for _ in 0..<extraBytes {
                len = (len << 8) | Int(data[pos])
                pos = data.index(after: pos)
            }
            length = len
        }
        let contentEnd = data.index(pos, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
        guard contentEnd <= data.endIndex else { return nil }
        return (tag, data.subdata(in: pos..<contentEnd), contentEnd)
    }

    private func derSequence(_ content: Data) -> Data {
        return derTLV(tag: 0x30, content: content)
    }

    private func derInteger(_ value: UInt8) -> Data {
        return derTLV(tag: 0x02, content: Data([value]))
    }

    private func derOctetString(_ bytes: Data) -> Data {
        return derTLV(tag: 0x04, content: bytes)
    }

    private func derContextSpecific(tag: UInt8, value: Data) -> Data {
        // Constructed context-specific tag: 0xA0 + tag
        return derTLV(tag: 0xA0 | tag, content: value)
    }

    private func derTLV(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        out.append(derLength(content.count))
        out.append(content)
        return out
    }

    private func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var bytes = withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) }
        while bytes.first == 0 && bytes.count > 1 {
            bytes.removeFirst()
        }

        var out = Data([0x80 | UInt8(bytes.count)])
        out.append(bytes)
        return out
    }

    private func sendX224ConnectionRequest() {
        // Build a standards-compliant X.224 Connection Request + RDP_NEG_REQ.
        // Layout (payload inside TPKT):
        // LI(0x0e), CR(0xe0), DST-REF(2), SRC-REF(2), CLASS(1),
        // RDP_NEG_REQ: type(0x01), flags(0x00), length(0x0008 LE), requestedProtocols(LE)
        var x224Pdu = Data()

        x224Pdu.append(0x0E) // Length indicator: 14 bytes follow
        x224Pdu.append(0xE0) // CR-TPDU
        x224Pdu.append(contentsOf: [0x00, 0x00]) // DST-REF
        x224Pdu.append(contentsOf: [0x00, 0x00]) // SRC-REF
        x224Pdu.append(0x00) // Class + options

        x224Pdu.append(0x01) // RDP_NEG_REQ
        x224Pdu.append(0x00) // flags
        x224Pdu.append(contentsOf: [0x08, 0x00]) // length (8) little-endian

        // Choose negotiation profile depending on bring-up mode.
        let requestedProtocols: UInt32 = preferNonNLAForBringup ? 0x0000_0000 : 0x0000_0003
        if preferNonNLAForBringup {
            delegate?.logger.log(content: "RDP negotiation profile: non-NLA bring-up (requesting standard RDP security)")
        } else {
            delegate?.logger.log(content: "RDP negotiation profile: SSL|HYBRID (NLA enabled)")
        }
        x224Pdu.append(contentsOf: withUnsafeBytes(of: requestedProtocols.littleEndian) { Data($0) })
        
        delegate?.logger.log(content: "RDP sendX224ConnectionRequest: building X.224 PDU (\(x224Pdu.count) bytes)")
        
        // Wrap in TPKT
        let tpktPacket = wrapInTPKT(x224Pdu)
        delegate?.logger.log(content: "RDP sendX224ConnectionRequest: wrapped in TPKT (\(tpktPacket.count) bytes), hex: \(tpktPacket.map { String(format: "%02x", $0) }.joined(separator: " "))")
        delegate?.rdpSend(tpktPacket)
        delegate?.logger.log(content: "RDP sent X.224 Connection Request")
    }

    private func sendClientInfo() {
        guard let initiator = mcsUserId else {
            delegate?.logger.log(content: "RDP sendClientInfo: missing MCS user id")
            return
        }

        let payload = buildClientInfoPayload(
            username: username,
            password: password,
            domain: domain
        )
        let mcsPDU = buildMCSSendDataRequest(initiator: initiator, channelId: 1003, userData: payload)
        sendX224DataTPDU(mcsPDU)
        delegate?.logger.log(content: "RDP sendClientInfo: sent Client Info payload (\(payload.count) bytes, mcs=\(mcsPDU.count) bytes, enhancedSecurity=\(usingEnhancedSecurityTransport))")
    }

    private func buildClientInfoPayload(username: String, password: String, domain: String) -> Data {
        // Client Info PDU per MS-RDPBCGR §2.2.1.11.1:
        // Basic Security Header (SEC_INFO_PKT) + TS_INFO_PACKET + TS_EXTENDED_INFO_PACKET
        // The Basic Security Header is ALWAYS required, even for enhanced security (§2.2.1.11.1).
        let domain16 = utf16leNul(domain)
        let user16 = utf16leNul(username)
        let pass16 = utf16leNul(password)
        let shell16 = utf16leNul("")
        let workingDir16 = utf16leNul("")

        var infoFlags: UInt32 = 0x0000_0001   // INFO_MOUSE
            | 0x0000_0002                     // INFO_DISABLECTRLALTDEL
            | 0x0000_0010                     // INFO_UNICODE
            | 0x0000_0020                     // INFO_MAXIMIZESHELL
            | 0x0000_0040                     // INFO_LOGONNOTIFY
            | 0x0000_0100                     // INFO_ENABLEWINDOWSKEY
            | 0x0000_0200                     // INFO_COMPRESSION
            | 0x0000_0600                     // CompressionTypeMask: RDP6.1 (level 3)

        if !password.isEmpty {
            infoFlags |= 0x0000_0008         // INFO_AUTOLOGON
        }

        delegate?.logger.log(content: "RDP ClientInfo: flags=0x\(String(infoFlags, radix: 16)) domainBytes=\(max(0, domain16.count - 2)) userBytes=\(max(0, user16.count - 2)) passBytes=\(max(0, pass16.count - 2))")

        // --- TS_INFO_PACKET (§2.2.1.11.1.1) ---
        var info = Data()
        info.append(le32(0)) // CodePage
        info.append(le32(infoFlags))

        // Length fields are string bytes excluding terminal UTF-16 NUL.
        info.append(le16(UInt16(max(0, domain16.count - 2))))
        info.append(le16(UInt16(max(0, user16.count - 2))))
        info.append(le16(UInt16(max(0, pass16.count - 2))))
        info.append(le16(0)) // cbAlternateShell
        info.append(le16(0)) // cbWorkingDir

        info.append(domain16)
        info.append(user16)
        info.append(pass16)
        info.append(shell16)
        info.append(workingDir16)

        // --- TS_EXTENDED_INFO_PACKET (§2.2.1.11.1.1.1) ---
        let clientAddr = utf16leNul("0.0.0.0")
        let clientDir  = utf16leNul("C:\\Windows\\System32\\mstscax.dll")

        info.append(le16(0x0002))           // clientAddressFamily = AF_INET
        info.append(le16(UInt16(clientAddr.count))) // cbClientAddress (incl NUL)
        info.append(clientAddr)
        info.append(le16(UInt16(clientDir.count)))  // cbClientDir (incl NUL)
        info.append(clientDir)

        // TS_TIME_ZONE_INFORMATION (172 bytes, all zeros = UTC)
        info.append(Data(count: 172))

        info.append(le32(0))                // clientSessionId
        info.append(le32(0x0000_0001        // PERF_DISABLE_WALLPAPER
                       | 0x0000_0004        // PERF_DISABLE_FULLWINDOWDRAG
                       | 0x0000_0008        // PERF_DISABLE_MENUANIMATIONS
                       | 0x0000_0020        // PERF_DISABLE_THEMING
                       | 0x0000_0080))      // PERF_DISABLE_CURSOR_SHADOW
        info.append(le16(0))                // cbAutoReconnectLen

        // --- Basic Security Header (§2.2.8.1.1.2.1) with SEC_INFO_PKT ---
        var payload = Data()
        payload.append(le16(0x0040))        // flags = SEC_INFO_PKT
        payload.append(le16(0x0000))        // flagsHi
        payload.append(info)

        delegate?.logger.log(content: "RDP ClientInfo: totalPayload=\(payload.count) bytes (secHdr=4, infoPacket=\(info.count))")
        return payload
    }

    private func utf16leNul(_ value: String) -> Data {
        var out = value.data(using: .utf16LittleEndian) ?? Data()
        out.append(0x00)
        out.append(0x00)
        return out
    }

    private func wrapInTPKT(_ payload: Data) -> Data {
        var tpktPacket = Data()
        tpktPacket.append(0x03)  // TPKT version
        tpktPacket.append(0x00)  // Reserved
        
        let totalLength = UInt16(payload.count + 4)
        tpktPacket.append(contentsOf: withUnsafeBytes(of: totalLength.bigEndian) { Data($0) })
        tpktPacket.append(contentsOf: payload)
        
        delegate?.logger.log(content: "RDP wrapInTPKT: wrapped \(payload.count) bytes -> TPKT packet (\(tpktPacket.count) bytes)")
        
        return tpktPacket
    }

    private func sendInputEventsPDU(pointerEvents: Data = Data(), keyboardEvents: Data = Data()) {
        guard !pointerEvents.isEmpty || !keyboardEvents.isEmpty else {
            delegate?.logger.log(content: "RDP sendInputEventsPDU: skipping empty input payload")
            return
        }

        guard let initiator = mcsUserId else {
            delegate?.logger.log(content: "RDP sendInputEventsPDU: missing MCS user id; dropping input")
            return
        }

        var eventRecords = Data()
        var eventCount: UInt16 = 0

        if pointerEvents.count >= 6 {
            let x = UInt16(littleEndian: pointerEvents.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
            let y = UInt16(littleEndian: pointerEvents.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
            let flags = UInt16(littleEndian: pointerEvents.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) })

            // TS_POINTER_EVENT in TS_INPUT_EVENT: eventTime + messageType + pointerFlags + xPos + yPos
            eventRecords.append(le32(0))
            eventRecords.append(le16(0x8001))
            eventRecords.append(le16(flags))
            eventRecords.append(le16(x))
            eventRecords.append(le16(y))
            eventCount &+= 1
        }

        if keyboardEvents.count >= 2 {
            let scanCode = UInt16(keyboardEvents[0])
            let flags = UInt16(keyboardEvents[1]) << 8

            // TS_KEYBOARD_EVENT in TS_INPUT_EVENT: eventTime + messageType + keyboardFlags + keyCode + pad
            eventRecords.append(le32(0))
            eventRecords.append(le16(0x0004))
            eventRecords.append(le16(flags))
            eventRecords.append(le16(scanCode))
            eventRecords.append(le16(0))
            eventCount &+= 1
        }

        guard eventCount > 0 else {
            delegate?.logger.log(content: "RDP sendInputEventsPDU: no valid input events to send")
            return
        }

        // Slow-path Input Event PDU payload
        var inputPayload = Data()
        inputPayload.append(le16(eventCount))
        inputPayload.append(le16(0))
        inputPayload.append(eventRecords)

        // Share Data Header + payload, channel 1003 (I/O channel)
        let shareData = buildShareDataPDU(pduType2: 0x1C, payload: inputPayload)
        let mcsPDU = buildMCSSendDataRequest(initiator: initiator, channelId: 1003, userData: shareData)
        sendX224DataTPDU(mcsPDU)
        delegate?.logger.log(content: "RDP sendInputEventsPDU: sent \(eventCount) event(s), payload=\(mcsPDU.count) bytes")
    }

    private func buildShareDataPDU(pduType2: UInt8, payload: Data) -> Data {
        // Share Control Header (6 bytes) + Share Data Header (12 bytes)
        let totalLength = UInt16(18 + payload.count)
        let pduSource = rdpClientChannelId

        var pdu = Data()
        pdu.append(le16(totalLength))
        pdu.append(le16(0x0017)) // PDUTYPE_DATAPDU
        pdu.append(le16(pduSource))

        pdu.append(le32(rdpShareId))
        pdu.append(0x00)         // pad1
        pdu.append(0x01)         // streamId = STREAM_LOW
        pdu.append(le16(UInt16(payload.count)))  // uncompressedLength (payload only, per FreeRDP convention)
        pdu.append(pduType2)
        pdu.append(0x00)         // compressedType
        pdu.append(le16(0))      // compressedLength
        pdu.append(payload)

        return pdu
    }

    private func buildMCSSendDataRequest(initiator: UInt16, channelId: UInt16, userData: Data) -> Data {
        // Send Data Request (X.224 user data):
        // 0x64, initiator, channelId, dataPriority(0x70), userDataLength(PER), userData
        var pdu = Data()
        pdu.append(0x64)
        pdu.append(contentsOf: withUnsafeBytes(of: initiator.bigEndian) { Data($0) })
        pdu.append(contentsOf: withUnsafeBytes(of: channelId.bigEndian) { Data($0) })
        pdu.append(0x70)
        pdu.append(perLength(userData.count))
        pdu.append(userData)
        return pdu
    }

    private func parseMCSSendDataIndication(_ data: Data) -> (initiator: UInt16, channelId: UInt16, userData: Data)? {
        // MCS Send Data Indication: 0x68, initiator(2), channel(2), flags(1), length(PER), userData
        guard data.count >= 7, data[0] == 0x68 else { return nil }

        let initiator = UInt16(bigEndian: data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self) })
        let channelId = UInt16(bigEndian: data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: UInt16.self) })

        var index = 6
        guard let (userLen, consumed) = parsePERLength(in: data, at: index) else { return nil }
        index += consumed

        guard index + userLen <= data.count else { return nil }
        let userData = data.subdata(in: index..<(index + userLen))
        return (initiator, channelId, userData)
    }

    private func parsePERLength(in data: Data, at offset: Int) -> (length: Int, consumed: Int)? {
        guard offset < data.count else { return nil }
        let b0 = data[offset]
        if (b0 & 0x80) == 0 {
            return (Int(b0), 1)
        }

        guard offset + 1 < data.count else { return nil }
        let length = (Int(b0 & 0x7F) << 8) | Int(data[offset + 1])
        return (length, 2)
    }

    private func isLicenseErrorValidClientPacket(_ userData: Data) -> Bool {
        // TS_SECURITY_HEADER + Server License Error Alert:
        // flags includes SEC_LICENSE_PKT (0x0080), message type 0xFF,
        // dwErrorCode=STATUS_VALID_CLIENT(0x00000007)
        guard userData.count >= 16 else { return false }

        let securityFlags = UInt16(littleEndian: userData.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
        guard (securityFlags & 0x0080) != 0 else { return false }

        let msgType = userData[4]
        guard msgType == 0xFF else { return false }

        let errorCode = UInt32(littleEndian: userData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) })
        return errorCode == 0x00000007
    }

    private func parseShareControlPDUType(_ userData: Data) -> UInt16? {
        // Share Control Header starts with totalLength(2), pduType(2), pduSource(2)
        guard userData.count >= 6 else { return nil }
        let rawType = UInt16(littleEndian: userData.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self) })
        return rawType & 0x000F
    }

    private func parseShareDataPDUType2(_ userData: Data) -> UInt8? {
        // Share Data Header begins at offset 6; pduType2 at offset 14.
        guard userData.count >= 15 else { return nil }
        return userData[14]
    }

    private func parseSetErrorInfoCode(_ userData: Data) -> UInt32 {
        // Share Control Header (6) + Share Data Header (12) = 18 bytes before payload.
        // Payload is a single UINT32 errorInfo.
        guard userData.count >= 22 else { return 0xFFFFFFFF }
        return UInt32(littleEndian: userData.subdata(in: 18..<22).withUnsafeBytes { $0.load(as: UInt32.self) })
    }

    private func parseShareDataPDUPayload(_ userData: Data) -> Data? {
        guard userData.count > 18 else { return nil }
        return userData.subdata(in: 18..<userData.count)
    }

    private func parseControlAction(_ userData: Data) -> UInt16? {
        guard let payload = parseShareDataPDUPayload(userData), payload.count >= 2 else { return nil }
        return UInt16(littleEndian: payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
    }

    private func parseSlowPathUpdateType(_ payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        return UInt16(littleEndian: payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self) })
    }

    private func rdpErrorDescription(_ code: UInt32) -> String {
        switch code {
        case 0x0000_0000: return "ERRINFO_NONE"
        case 0x0000_0001: return "ERRINFO_RPC_INITIATED_DISCONNECT"
        case 0x0000_0002: return "ERRINFO_RPC_INITIATED_LOGOFF"
        case 0x0000_0003: return "ERRINFO_IDLE_TIMEOUT"
        case 0x0000_0004: return "ERRINFO_LOGON_TIMEOUT"
        case 0x0000_0005: return "ERRINFO_DISCONNECTED_BY_OTHERCONNECTION"
        case 0x0000_0006: return "ERRINFO_OUT_OF_MEMORY"
        case 0x0000_0007: return "ERRINFO_SERVER_DENIED_CONNECTION"
        case 0x0000_0009: return "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES"
        case 0x0000_000A: return "ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED"
        case 0x0000_000B: return "ERRINFO_RPC_INITIATED_DISCONNECT_BYUSER"
        case 0x0000_000C: return "ERRINFO_LOGOFF_BY_USER"
        case 0x0000_0100: return "ERRINFO_LICENSE_INTERNAL"
        case 0x0000_0101: return "ERRINFO_LICENSE_NO_LICENSE_SERVER"
        case 0x0000_0102: return "ERRINFO_LICENSE_NO_LICENSE"
        case 0x0000_0103: return "ERRINFO_LICENSE_BAD_CLIENT_MSG"
        case 0x0000_0104: return "ERRINFO_LICENSE_HWID_DOESNT_MATCH_LICENSE"
        case 0x0000_0105: return "ERRINFO_LICENSE_BAD_CLIENT_LICENSE"
        case 0x0000_0106: return "ERRINFO_LICENSE_CANT_FINISH_PROTOCOL"
        case 0x0000_0107: return "ERRINFO_LICENSE_CLIENT_ENDED_PROTOCOL"
        case 0x0000_0108: return "ERRINFO_LICENSE_BAD_CLIENT_ENCRYPTION"
        case 0x0000_0109: return "ERRINFO_LICENSE_CANT_UPGRADE_LICENSE"
        case 0x0000_010A: return "ERRINFO_LICENSE_NO_REMOTE_CONNECTIONS"
        case 0x0000_1001: return "ERRINFO_CB_DESTINATION_NOT_FOUND"
        case 0x0000_1002: return "ERRINFO_CB_LOADING_DESTINATION"
        case 0x0000_1003: return "ERRINFO_CB_REDIRECTING_TO_DESTINATION"
        case 0x0000_1004: return "ERRINFO_CB_SESSION_ONLINE_VM_WAKE"
        case 0x0000_1005: return "ERRINFO_CB_SESSION_ONLINE_VM_BOOT"
        case 0x0000_1006: return "ERRINFO_CB_SESSION_ONLINE_VM_NO_DNS"
        case 0x0000_1007: return "ERRINFO_CB_DESTINATION_POOL_NOT_FREE"
        case 0x0000_1008: return "ERRINFO_CB_CONNECTION_CANCELLED"
        case 0x0000_1009: return "ERRINFO_CB_CONNECTION_ERROR_INVALID_SETTINGS"
        case 0x0000_100A: return "ERRINFO_CB_SESSION_ONLINE_VM_BOOT_TIMEOUT"
        case 0x0000_100B: return "ERRINFO_CB_SESSION_ONLINE_VM_SESSMON_FAILED"
        case 0x0000_10C9: return "ERRINFO_UNKNOWN_DATA_PDU_TYPE"
        case 0x0000_10CA: return "ERRINFO_UNKNOWN_PDU_TYPE"
        case 0x0000_10CB: return "ERRINFO_DATA_PDU_SEQUENCE"
        case 0x0000_10CD: return "ERRINFO_CONTROL_PDU_SEQUENCE"
        case 0x0000_10CE: return "ERRINFO_INVALID_CONTROL_PDU_ACTION"
        case 0x0000_10D3: return "ERRINFO_CONNECT_FAILED"
        case 0x0000_10D4: return "ERRINFO_CONFIRM_ACTIVE_HAS_WRONG_SHAREID"
        case 0x0000_10D5: return "ERRINFO_CONFIRM_ACTIVE_HAS_WRONG_ORIGINATOR"
        case 0x0000_10E0: return "ERRINFO_SECURITY_DATA_TOO_SHORT"
        case 0x0000_10E2: return "ERRINFO_SHARE_DATA_TOO_SHORT"
        case 0x0000_10E5: return "ERRINFO_CONFIRM_ACTIVE_PDU_TOO_SHORT"
        case 0x0000_10E7: return "ERRINFO_CAPABILITY_SET_TOO_SMALL"
        case 0x0000_10E8: return "ERRINFO_CAPABILITY_SET_TOO_LARGE"
        case 0x0000_10E9: return "ERRINFO_NO_CURSOR_CACHE"
        case 0x0000_10EA: return "ERRINFO_BAD_CAPABILITIES"
        case 0x0000_10EC: return "ERRINFO_VIRTUAL_CHANNEL_DECOMPRESSION"
        case 0x0000_10F4: return "ERRINFO_CACHE_CAP_NOT_SET"
        case 0x0000_1129: return "ERRINFO_BAD_MONITOR_DATA"
        case 0x0000_112A: return "ERRINFO_VC_DECOMPRESSED_REASSEMBLE_FAILED"
        case 0x0000_112B: return "ERRINFO_VC_DATA_TOO_LONG"
        case 0x0000_112C: return "ERRINFO_BAD_FRAME_ACK_DATA"
        case 0x0000_112D: return "ERRINFO_GRAPHICS_MODE_NOT_SUPPORTED"
        case 0x0000_112E: return "ERRINFO_GRAPHICS_SUBSYSTEM_RESET_FAILED"
        case 0x0000_112F: return "ERRINFO_GRAPHICS_SUBSYSTEM_FAILED"
        case 0x0000_1130: return "ERRINFO_TIMEZONE_KEY_NAME_LENGTH_TOO_SHORT"
        case 0x0000_1131: return "ERRINFO_TIMEZONE_KEY_NAME_LENGTH_TOO_LONG"
        case 0x0000_1132: return "ERRINFO_DYNAMIC_DST_DISABLED_FIELD_MISSING"
        case 0x0000_1133: return "ERRINFO_VC_DECODING_ERROR"
        case 0x0000_1134: return "ERRINFO_VIRTUALDESKTOPTOOLARGE"
        case 0x0000_1135: return "ERRINFO_MONITORGEOMETRYVALIDATIONFAILED"
        case 0x0000_1136: return "ERRINFO_INVALIDMONITORCOUNT"
        case 0x0000_1191: return "ERRINFO_UPDATE_SESSION_KEY_FAILED"
        case 0x0000_1192: return "ERRINFO_DECRYPT_FAILED"
        case 0x0000_1193: return "ERRINFO_ENCRYPT_FAILED"
        case 0x0000_1194: return "ERRINFO_ENCRYPTION_PACKAGE_MISMATCH"
        case 0x0000_1195: return "ERRINFO_DECRYPT_FAILED2"
        case 0x0000_1196: return "ERRINFO_PEER_DISCONNECTED"
        default: return "UNKNOWN_ERROR"
        }
    }

    private func parseDemandActive(_ userData: Data) -> (shareId: UInt32, numberCapabilities: UInt16, capabilitySets: Data)? {
        // Demand Active PDU body starts after Share Control Header (6 bytes).
        guard userData.count >= 20 else { return nil }

        let bodyStart = 6
        let shareId = UInt32(littleEndian: userData.subdata(in: bodyStart..<(bodyStart + 4)).withUnsafeBytes { $0.load(as: UInt32.self) })
        let lengthSourceDescriptor = Int(UInt16(littleEndian: userData.subdata(in: (bodyStart + 4)..<(bodyStart + 6)).withUnsafeBytes { $0.load(as: UInt16.self) }))
        let lengthCombinedCapabilities = Int(UInt16(littleEndian: userData.subdata(in: (bodyStart + 6)..<(bodyStart + 8)).withUnsafeBytes { $0.load(as: UInt16.self) }))

        let descriptorStart = bodyStart + 8
        let descriptorEnd = descriptorStart + lengthSourceDescriptor
        guard descriptorEnd + 4 <= userData.count else { return nil }

        let numberCapabilities = UInt16(littleEndian: userData.subdata(in: descriptorEnd..<(descriptorEnd + 2)).withUnsafeBytes { $0.load(as: UInt16.self) })

        let capStart = descriptorEnd + 4 // skip numberCapabilities + pad2Octets
        let capLength = max(0, lengthCombinedCapabilities - 4)
        guard capStart + capLength <= userData.count else { return nil }

        let capabilitySets = userData.subdata(in: capStart..<(capStart + capLength))
        return (shareId, numberCapabilities, capabilitySets)
    }

    private func parseBitmapCapabilityDesktopSize(_ capabilitySets: Data) -> (width: Int, height: Int)? {
        var offset = 0
        while offset + 4 <= capabilitySets.count {
            let capType = UInt16(littleEndian: capabilitySets.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) })
            let capLen = Int(UInt16(littleEndian: capabilitySets.subdata(in: (offset + 2)..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt16.self) }))

            guard capLen >= 4, offset + capLen <= capabilitySets.count else { break }

            // TS_BITMAP_CAPABILITYSET (type 0x0002): desktopWidth/desktopHeight at offsets 12/14 from cap start.
            if capType == 0x0002, capLen >= 16 {
                let width = Int(UInt16(littleEndian: capabilitySets.subdata(in: (offset + 12)..<(offset + 14)).withUnsafeBytes { $0.load(as: UInt16.self) }))
                let height = Int(UInt16(littleEndian: capabilitySets.subdata(in: (offset + 14)..<(offset + 16)).withUnsafeBytes { $0.load(as: UInt16.self) }))
                if width > 0 && height > 0 {
                    return (width, height)
                }
            }

            offset += capLen
        }
        return nil
    }

    private func parseServerCapabilities(_ capabilitySets: Data) {
        var offset = 0
        var hasSurfaceCommands = false
        var hasFrameAcknowledge = false

        while offset + 4 <= capabilitySets.count {
            let capType = UInt16(littleEndian: capabilitySets.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) })
            let capLen = Int(UInt16(littleEndian: capabilitySets.subdata(in: (offset + 2)..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt16.self) }))

            guard capLen >= 4, offset + capLen <= capabilitySets.count else { break }

            if capType == 0x001C {
                hasSurfaceCommands = true
            } else if capType == 0x001E {
                hasFrameAcknowledge = true
            }

            offset += capLen
        }

        serverSupportsSurfaceCommands = hasSurfaceCommands
        serverSupportsFrameAcknowledge = hasFrameAcknowledge
        delegate?.logger.log(content: "RDP activation: capabilities surfaceCommands=\(hasSurfaceCommands) frameAcknowledge=\(hasFrameAcknowledge)")
    }

    private func sendClientActivationSequence(using demand: (shareId: UInt32, numberCapabilities: UInt16, capabilitySets: Data)) {
        sendConfirmActivePDU(using: demand)
        sendSynchronizeDataPDU()
        sendControlDataPDU(action: 0x0004) // cooperate
        sendControlDataPDU(action: 0x0001) // request control
        sendFontListDataPDU()
        delegate?.logger.log(content: "RDP activation: client activation sequence sent")
    }

    private func sendConfirmActivePDU(using demand: (shareId: UInt32, numberCapabilities: UInt16, capabilitySets: Data)) {
        guard let initiator = mcsUserId else {
            delegate?.logger.log(content: "RDP activation: missing initiator for Confirm Active")
            return
        }

        let (capsData, capCount) = buildConfirmActiveCapabilitySets(from: demand.capabilitySets)

        let sourceDescriptor = Data("OPENTERFACE".utf8)
        let lengthCombinedCapabilities = UInt16(capsData.count + 4)

        var body = Data()
        body.append(le32(demand.shareId))
        body.append(le16(0x03EA))  // originatorId MUST be 0x03EA per MS-RDPBCGR §2.2.1.13.2.1
        body.append(le16(UInt16(sourceDescriptor.count)))
        body.append(le16(lengthCombinedCapabilities))
        body.append(sourceDescriptor)
        body.append(le16(capCount))
        body.append(le16(0))
        body.append(capsData)

        let totalLength = UInt16(body.count + 6)
        var shareControl = Data()
        shareControl.append(le16(totalLength))
        shareControl.append(le16(0x0013)) // PDUTYPE_CONFIRMACTIVEPDU | version 1
        shareControl.append(le16(rdpClientChannelId))
        shareControl.append(body)

        // Hex dump first 200 bytes for diagnostics
        let dumpLen = min(shareControl.count, 200)
        let hexDump = shareControl.prefix(dumpLen).map { String(format: "%02x", $0) }.joined(separator: " ")
        delegate?.logger.log(content: "RDP activation: Confirm Active hex (first \(dumpLen)B): \(hexDump)")

        let mcsPDU = buildMCSSendDataRequest(initiator: initiator, channelId: 1003, userData: shareControl)
        sendX224DataTPDU(mcsPDU)
        delegate?.logger.log(content: "RDP activation: Confirm Active sent (\(shareControl.count) bytes, caps=\(capCount))")
    }

    // MARK: - Build Confirm Active capabilities (hybrid: echo + add missing)

    /// Hybrid approach: echo server caps with targeted modifications, then append
    /// any mandatory client-only caps the server didn't include.
    private func buildConfirmActiveCapabilitySets(from serverCaps: Data) -> (data: Data, count: UInt16) {
        var out = Data()
        var count: UInt16 = 0
        var dropped: [UInt16] = []
        var includedTypes = Set<UInt16>()

        // --- Phase 1: echo/modify server caps ---
        var offset = 0
        while offset + 4 <= serverCaps.count {
            let capType = UInt16(littleEndian: serverCaps.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) })
            let capLen = Int(UInt16(littleEndian: serverCaps.subdata(in: (offset + 2)..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt16.self) }))
            guard capLen >= 4, offset + capLen <= serverCaps.count else { break }

            switch capType {
            case 0x0019, 0x0015, 0x0016, 0x0011:
                // Drop compdesk/drawninegrid/gdi+/offscreen (not supported by this client)
                dropped.append(capType)
            case 0x0012:
                // Drop BITMAP_CACHE_HOST_SUPPORT — server-only per MS-RDPBCGR
                dropped.append(capType)
            case 0x001D:
                // Build client BitmapCodecs with proper NSCodec properties
                dropped.append(capType)
            case 0x001C: // SurfaceCommands — keep only FRAME_MARKER support
                var cap = Data(repeating: 0, count: 12)
                cap[0] = 0x1C; cap[1] = 0x00 // type
                cap[2] = 0x0C; cap[3] = 0x00 // len=12
                // strict mode: conservative but valid graphics path (SET_SURFACE_BITS + FRAME_MARKER)
                // non-strict: include STREAM_SURFACE_BITS as well
                let cmdFlags: UInt32 = strictCompatibilityMode ? 0x12 : 0x52
                let flagBytes = withUnsafeBytes(of: cmdFlags.littleEndian) { Data($0) }
                cap.replaceSubrange(4..<8, with: flagBytes)
                out.append(cap); count &+= 1; includedTypes.insert(capType)
                if strictCompatibilityMode {
                    delegate?.logger.log(content: "RDP activation: strict mode keeps SurfaceCommands with conservative flags")
                }
            case 0x001E: // FrameAcknowledge — set client maxUnackedFrameCount
                // Always include FrameAcknowledge when the server offers it.
                // Without this, the server sends frame markers and expects ACKs;
                // if the client drops the capability the server may still require acks
                // and disconnect when none arrive.
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                if capLen >= 8 {
                    // maxUnacknowledgedFrameCount: large value so the server never
                    // throttles frame delivery while we are busy decoding tiles.
                    // FreeRDP uses 2; we use 2048 to prevent the server from pausing
                    // mid-fragment-train waiting for an ACK.
                    let maxUnacked: UInt32 = 2048
                    let bytes = withUnsafeBytes(of: maxUnacked.littleEndian) { Data($0) }
                    cap.replaceSubrange(4..<8, with: bytes)
                }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
                delegate?.logger.log(content: "RDP activation: FrameAcknowledge included (maxUnacked=2048)")
            case 0x0001: // General — fix client-side fields
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                if capLen >= 24 {
                    cap[4] = 0x04; cap[5] = 0x00  // osMajorType: MACINTOSH
                    cap[6] = 0x0B; cap[7] = 0x00  // osMinorType
                    var flags = UInt16(cap[14]) | (UInt16(cap[15]) << 8)
                    flags |= 0x0001  // FASTPATH_OUTPUT_SUPPORTED
                    flags |= 0x0004  // LONG_CREDENTIALS_SUPPORTED
                    flags |= 0x0008  // AUTORECONNECT_SUPPORTED
                    flags |= 0x0010  // ENC_SALTED_CHECKSUM
                    flags |= 0x0400  // NO_BITMAP_COMPRESSION_HDR — keep set (FreeRDP default)
                    cap[14] = UInt8(flags & 0xFF); cap[15] = UInt8(flags >> 8)
                    cap[22] = 0x01  // refreshRectSupport
                    cap[23] = 0x01  // suppressOutputSupport
                }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
            case 0x0003: // Order — echo server's order support but set client negotiation flags
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                // Set orderFlags at offset 16-17 to include NEGOTIATEORDERSUPPORT
                if capLen >= 18 {
                    cap[16] = 0x22; cap[17] = 0x00  // NEGOTIATEORDERSUPPORT | ZEROBOUNDSDELTASUPPORT
                }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
            case 0x000D: // Input — set client input flags
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                if capLen >= 8 {
                    cap[4] = 0x15; cap[5] = 0x00  // SCANCODES|MOUSEX|UNICODE
                }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
            case 0x0013: // BitmapCacheRev2 — clear persistent keys flag
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                if capLen >= 6 { cap[4] &= 0xFE }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
            case 0x001A: // MultifragmentUpdate — set client MaxRequestSize
                var cap = Data(serverCaps.subdata(in: offset..<(offset + capLen)))
                if capLen >= 8 {
                    let maxReqSize: UInt32 = strictCompatibilityMode ? (4 * 1024 * 1024) : (16 * 1024 * 1024)
                    let bytes = withUnsafeBytes(of: maxReqSize.littleEndian) { Data($0) }
                    cap.replaceSubrange(4..<8, with: bytes)
                }
                out.append(cap); count &+= 1; includedTypes.insert(capType)
                if strictCompatibilityMode {
                    delegate?.logger.log(content: "RDP activation: strict mode keeps MultifragmentUpdate with reduced max request size")
                }
            default:
                // Echo all other server caps unchanged
                out.append(serverCaps.subdata(in: offset..<(offset + capLen)))
                count &+= 1; includedTypes.insert(capType)
            }
            offset += capLen
        }

        // --- Phase 2: append missing mandatory client caps ---
        func appendCap(type: UInt16, payload: Data) {
            guard !includedTypes.contains(type) else { return }
            let totalLen = UInt16(payload.count + 4)
            out.append(le16(type))
            out.append(le16(totalLen))
            out.append(payload)
            count &+= 1
            includedTypes.insert(type)
        }

        // Control (0x0005)
        do {
            var p = Data()
            p.append(le16(0)); p.append(le16(0))
            p.append(le16(0x0002)); p.append(le16(0x0002))
            appendCap(type: 0x0005, payload: p)
        }
        // Window Activation (0x0007)
        do {
            var p = Data()
            p.append(le16(0)); p.append(le16(0)); p.append(le16(0)); p.append(le16(0))
            appendCap(type: 0x0007, payload: p)
        }
        // Brush (0x000F)
        do {
            var p = Data()
            p.append(le32(0x00000001))
            appendCap(type: 0x000F, payload: p)
        }
        // Sound (0x000C)
        do {
            var p = Data()
            p.append(le16(0x0001)); p.append(le16(0))
            appendCap(type: 0x000C, payload: p)
        }
        // Color Cache (0x000A)
        do {
            var p = Data()
            p.append(le16(0x0006)); p.append(le16(0))
            appendCap(type: 0x000A, payload: p)
        }
        // Glyph Cache (0x0010)
        do {
            var p = Data()
            for (entries, maxSize) in [(254,4),(254,4),(254,8),(254,8),(254,16),(254,32),(254,64),(254,128),(254,256),(64,2048)] as [(UInt16,UInt16)] {
                p.append(le16(entries)); p.append(le16(maxSize))
            }
            p.append(le16(256)); p.append(le16(256))  // fragCache
            p.append(le16(0)); p.append(le16(0))  // glyphSupportLevel, pad
            appendCap(type: 0x0010, payload: p)
        }
        // BitmapCodecs (0x001D) — deliberately omitted.
        // By not advertising any bitmap codecs (NSCodec, RemoteFX, etc.) the
        // server is forced to use the classic RLE / raw bitmap path which is
        // the only path this client fully implements.  This avoids codec-
        // negotiation issues and simplifies debugging.
        delegate?.logger.log(content: "RDP activation: BitmapCodecs capability omitted (classic bitmap path only)")

        if !dropped.isEmpty {
            let droppedText = dropped.map { String(format: "0x%04x", $0) }.joined(separator: ",")
            delegate?.logger.log(content: "RDP activation: dropped caps=[\(droppedText)]")
        }
        delegate?.logger.log(content: "RDP activation: built \(count) caps (\(out.count) bytes, \(includedTypes.count) unique types)")
        return (out, count)
    }

    private func sendSynchronizeDataPDU() {
        var payload = Data()
        payload.append(le16(1))
        payload.append(le16(rdpClientChannelId))
        sendActivationDataPDU(pduType2: 0x1F, payload: payload)
    }

    private func sendControlDataPDU(action: UInt16) {
        var payload = Data()
        payload.append(le16(action))
        payload.append(le16(0))
        payload.append(le32(0))
        sendActivationDataPDU(pduType2: 0x14, payload: payload)
    }

    private func sendFontListDataPDU() {
        var payload = Data()
        payload.append(le16(0))
        payload.append(le16(0))
        payload.append(le16(0x0003))
        payload.append(le16(0x0032))
        sendActivationDataPDU(pduType2: 0x27, payload: payload)
    }

    private func sendActivationDataPDU(pduType2: UInt8, payload: Data) {
        if suppressOutboundSends {
            if pduType2 == 0x38 {
                delegate?.logger.log(content: "RDP frame-ack PDU dropped: transport is closing")
            }
            return
        }
        guard let initiator = mcsUserId else {
            if pduType2 == 0x38 {
                delegate?.logger.log(content: "RDP frame-ack dropped: missing MCS initiator")
            }
            return
        }
        let shareData = buildShareDataPDU(pduType2: pduType2, payload: payload)
        let mcsPDU = buildMCSSendDataRequest(initiator: initiator, channelId: 1003, userData: shareData)
        sendX224DataTPDU(mcsPDU)
        if pduType2 == 0x38 {
            delegate?.logger.log(content: "RDP frame-ack PDU emitted: payload=\(payload.count) bytes initiator=\(initiator)")
        }
    }
}
