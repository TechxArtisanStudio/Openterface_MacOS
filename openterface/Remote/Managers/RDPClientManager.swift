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
import AppKit
import os.log

private let rdpMgrLog = OSLog(subsystem: "com.openterface.rdp", category: "manager")

final class RDPClientManager: RDPClientManagerProtocol {

    static let shared = RDPClientManager()

    private(set) var isConnected: Bool = false
    private(set) var host: String = ""
    private(set) var port: Int = 3389
    private(set) var currentFrame: CGImage?
    private(set) var framebufferSize: CGSize = CGSize(width: 1920, height: 1080)

    private let queue = DispatchQueue(label: "com.openterface.rdp")
    private(set) var channel: RDPTLSChannel?
    // Expose the active TLS channel for CredSSP to access server public key
    var tlsChannel: RDPTLSChannel? { channel }
    private let loggerStorage: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var protocolHandler: RDPProtocolHandler!
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    var logger: LoggerProtocol { loggerStorage }

    private init() {
        protocolHandler = RDPProtocolHandler(delegate: self)
        protocolHandler.schedulingQueue = queue
    }

    func connect(host: String, port: Int, username: String, password: String, domain: String) {
        os_log(.error, log: rdpMgrLog, "[RDPMgr] connect() called host=%{public}@ port=%d", host, port)
        NSLog("[RDP] connect() called, dispatching to queue")
        queue.async { [weak self] in
            os_log(.error, log: rdpMgrLog, "[RDPMgr] queue block executing")
            NSLog("[RDP] queue block executing")
            self?.logger.log(content: "RDP connect requested: host=\(host) port=\(port) username=\(username)")
            self?.performConnect(host: host, port: port, username: username, password: password, domain: domain)
            NSLog("[RDP] performConnect returned")
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.logger.log(content: "RDP disconnect requested.")
            self?.stopConnection(reason: "manual disconnect")
        }
    }

    func sendPointerEvent(x: Int, y: Int, flags: UInt16) {
        queue.async { [weak self] in
            self?.protocolHandler.sendPointerEvent(x: x, y: y, flags: flags)
        }
    }

    func sendKeyEvent(scanCode: UInt16, flags: UInt16) {
        queue.async { [weak self] in
            self?.protocolHandler.sendKeyEvent(scanCode: scanCode, flags: flags)
        }
    }

    func sendClipboardText(_ text: String) {
        queue.async { [weak self] in
            self?.protocolHandler.sendClipboardText(text)
        }
    }

    func handleKeyEvent(_ event: NSEvent, isDown: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let (scanCode, isExtended) = self.rdpScanCode(for: event.keyCode) else {
                self.logger.log(content: "RDP key event skipped: unmapped keyCode=\(event.keyCode)")
                return
            }

            var flags: UInt16 = 0
            if isExtended { flags |= 0x0100 }
            if !isDown { flags |= 0x4000 }
            self.protocolHandler.sendKeyEvent(scanCode: scanCode, flags: flags)
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        queue.async { [weak self] in
            guard let self = self else { return }

            func emitModifier(_ mask: NSEvent.ModifierFlags, scanCode: UInt16, isExtended: Bool) {
                let wasDown = self.lastModifierFlags.contains(mask)
                let isDown = event.modifierFlags.contains(mask)
                guard wasDown != isDown else { return }

                var flags: UInt16 = 0
                if isExtended { flags |= 0x0100 }
                if !isDown { flags |= 0x4000 }
                self.protocolHandler.sendKeyEvent(scanCode: scanCode, flags: flags)
            }

            emitModifier(.shift, scanCode: 0x2A, isExtended: false)
            emitModifier(.control, scanCode: 0x1D, isExtended: false)
            emitModifier(.option, scanCode: 0x38, isExtended: false)
            emitModifier(.command, scanCode: 0x5B, isExtended: true)

            self.lastModifierFlags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        }
    }

    private func rdpScanCode(for keyCode: UInt16) -> (UInt16, Bool)? {
        // Use macOS virtual keycode numeric values directly to avoid Carbon key constant dependencies.
        switch keyCode {
        case 0: return (0x1E, false)   // A
        case 11: return (0x30, false)  // B
        case 8: return (0x2E, false)   // C
        case 2: return (0x20, false)   // D
        case 14: return (0x12, false)  // E
        case 3: return (0x21, false)   // F
        case 5: return (0x22, false)   // G
        case 4: return (0x23, false)   // H
        case 34: return (0x17, false)  // I
        case 38: return (0x24, false)  // J
        case 40: return (0x25, false)  // K
        case 37: return (0x26, false)  // L
        case 46: return (0x32, false)  // M
        case 45: return (0x31, false)  // N
        case 31: return (0x18, false)  // O
        case 35: return (0x19, false)  // P
        case 12: return (0x10, false)  // Q
        case 15: return (0x13, false)  // R
        case 1: return (0x1F, false)   // S
        case 17: return (0x14, false)  // T
        case 32: return (0x16, false)  // U
        case 9: return (0x2F, false)   // V
        case 13: return (0x11, false)  // W
        case 7: return (0x2D, false)   // X
        case 16: return (0x15, false)  // Y
        case 6: return (0x2C, false)   // Z

        case 18: return (0x02, false)  // 1
        case 19: return (0x03, false)  // 2
        case 20: return (0x04, false)  // 3
        case 21: return (0x05, false)  // 4
        case 23: return (0x06, false)  // 5
        case 22: return (0x07, false)  // 6
        case 26: return (0x08, false)  // 7
        case 28: return (0x09, false)  // 8
        case 25: return (0x0A, false)  // 9
        case 29: return (0x0B, false)  // 0

        case 36: return (0x1C, false)  // Return
        case 76: return (0x1C, true)   // Keypad Enter
        case 53: return (0x01, false)  // Escape
        case 51: return (0x0E, false)  // Backspace
        case 48: return (0x0F, false)  // Tab
        case 49: return (0x39, false)  // Space
        case 27: return (0x0C, false)  // -
        case 24: return (0x0D, false)  // =
        case 33: return (0x1A, false)  // [
        case 30: return (0x1B, false)  // ]
        case 42: return (0x2B, false)  // \\
        case 41: return (0x27, false)  // ;
        case 39: return (0x28, false)  // '
        case 50: return (0x29, false)  // `
        case 43: return (0x33, false)  // ,
        case 47: return (0x34, false)  // .
        case 44: return (0x35, false)  // /
        case 57: return (0x3A, false)  // Caps Lock

        case 122: return (0x3B, false) // F1
        case 120: return (0x3C, false) // F2
        case 99: return (0x3D, false)  // F3
        case 118: return (0x3E, false) // F4
        case 96: return (0x3F, false)  // F5
        case 97: return (0x40, false)  // F6
        case 98: return (0x41, false)  // F7
        case 100: return (0x42, false) // F8
        case 101: return (0x43, false) // F9
        case 109: return (0x44, false) // F10
        case 103: return (0x57, false) // F11
        case 111: return (0x58, false) // F12

        case 115: return (0x47, true)  // Home
        case 119: return (0x4F, true)  // End
        case 116: return (0x49, true)  // Page Up
        case 121: return (0x51, true)  // Page Down
        case 117: return (0x53, true)  // Forward Delete
        case 114: return (0x52, true)  // Help/Insert
        case 123: return (0x4B, true)  // Left
        case 124: return (0x4D, true)  // Right
        case 125: return (0x50, true)  // Down
        case 126: return (0x48, true)  // Up

        case 56: return (0x2A, false)  // Left Shift
        case 60: return (0x36, false)  // Right Shift
        case 59: return (0x1D, false)  // Left Ctrl
        case 62: return (0x1D, true)   // Right Ctrl
        case 58: return (0x38, false)  // Left Alt
        case 61: return (0x38, true)   // Right Alt
        case 55: return (0x5B, true)   // Left Cmd
        case 54: return (0x5C, true)   // Right Cmd

        case 82: return (0x52, false)  // KP 0
        case 83: return (0x4F, false)  // KP 1
        case 84: return (0x50, false)  // KP 2
        case 85: return (0x51, false)  // KP 3
        case 86: return (0x4B, false)  // KP 4
        case 87: return (0x4C, false)  // KP 5
        case 88: return (0x4D, false)  // KP 6
        case 89: return (0x47, false)  // KP 7
        case 91: return (0x48, false)  // KP 8
        case 92: return (0x49, false)  // KP 9
        case 65: return (0x53, false)  // KP .
        case 67: return (0x37, false)  // KP *
        case 69: return (0x4E, false)  // KP +
        case 78: return (0x4A, false)  // KP -
        case 75: return (0x35, true)   // KP /

        default:
            return nil
        }
    }

    // MARK: - Private connection methods

    private func performConnect(host: String, port: Int, username: String, password: String, domain: String) {
        os_log(.error, log: rdpMgrLog, "[RDPMgr] performConnect host=%{public}@ port=%d", host, port)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            setError("RDP host is empty.")
            logger.log(content: "RDP connect skipped: empty host")
            return
        }

        let clampedPort = max(1, min(port, 65535))

        stopConnection(reason: "reconnect")

        self.host = trimmedHost
        self.port = clampedPort
        isConnected = false
        AppStatus.resetRemoteNetworkStats(host: trimmedHost, port: clampedPort)

        AppStatus.protocolSessionState = .connecting
        AppStatus.protocolLastErrorMessage = ""

        NSLog("[RDP] state=connecting, creating channel")
        logger.log(content: "RDP connecting to \(trimmedHost):\(clampedPort)")

        let ch = RDPTLSChannel(queue: queue)
        channel = ch

        ch.onData = { [weak self] data in
            guard let self = self, self.channel === ch else { return }
            os_log(.error, log: rdpMgrLog, "[RDPMgr] onData: %d bytes", data.count)
            AppStatus.addRemoteRxBytes(data.count)
            self.logger.log(content: "RDP received \(data.count) bytes")
            self.logger.log(content: "RDP data hex: \(data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " "))")
            self.protocolHandler.ingest(data)
        }
        ch.onError = { [weak self] errorMsg in
            guard let self = self, self.channel === ch else { return }
            let hsState = self.protocolHandler.handshakeState
            os_log(.error, log: rdpMgrLog, "[RDPMgr] onError: %{public}@ handshakeState=%{public}@", errorMsg, "\(hsState)")
            RDPProtocolHandler.trace("ch.onError: \(errorMsg), handshakeState=\(hsState)")
            self.logger.log(content: "RDP channel error: \(errorMsg) (handshakeState=\(hsState))")
            self.setError("RDP channel error: \(errorMsg) during \(hsState)")
            self.stopConnection(reason: "channel error")
        }
        ch.onEOF = { [weak self] in
            guard let self = self, self.channel === ch else { return }
            let hsState = self.protocolHandler.handshakeState
            // Check socket-level close reason for diagnostics
            var soErr: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            if let sockfd = self.channel?.socketFD, sockfd >= 0 {
                Darwin.getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
            }
            os_log(.error, log: rdpMgrLog, "[RDPMgr] onEOF: remote closed, handshakeState=%{public}@, SO_ERROR=%d", "\(hsState)", soErr)
            RDPProtocolHandler.trace("ch.onEOF: remote closed connection, handshakeState=\(hsState)")
            // Attempt to salvage any in-progress Fast-Path fragment train
            // (e.g. partially-received bitmap update) before tearing down.
            self.protocolHandler.flushOnEOF()
            // Process any remaining data in the buffer (may contain Set Error Info PDU)
            let remainingBytes = self.protocolHandler.receiveBufferCount
            if remainingBytes > 0 {
                self.logger.log(content: "RDP onEOF: \(remainingBytes) bytes still in receive buffer (may contain error PDU)")
            }
            self.logger.log(content: "RDP remote endpoint closed connection (handshakeState=\(hsState), SO_ERROR=\(soErr))")
            self.setError("Remote closed connection during \(hsState)")
            self.stopConnection(reason: "remote closed")
        }

        os_log(.error, log: rdpMgrLog, "[RDPMgr] calling ch.connect()")
        NSLog("[RDP] calling ch.connect()")
        ch.connect(host: trimmedHost, port: clampedPort) { [weak self] err in
            os_log(.error, log: rdpMgrLog, "[RDPMgr] ch.connect callback err=%{public}@", err?.localizedDescription ?? "nil")
            NSLog("[RDP] ch.connect callback, err=%@", err?.localizedDescription ?? "nil")
            guard let self = self, self.channel === ch else {
                NSLog("[RDP] ch.connect callback: self/channel mismatch, ignoring")
                return
            }
            if let err = err {
                self.logger.log(content: "RDP TCP connect failed: \(err.localizedDescription)")
                self.setError("RDP connection failed: \(err.localizedDescription)")
                self.stopConnection(reason: "TCP connect failed")
            } else {
                self.logger.log(content: "RDP TCP connection ready; starting handshake username=\(username)")
                NSLog("[RDP] TCP connected, starting handshake")
                self.protocolHandler.startHandshake(username: username, password: password, domain: domain)
            }
        }
    }

    private func stopConnection(reason: String) {
        RDPProtocolHandler.trace("RDPClientManager.stopConnection: reason=\(reason), activeProto=\(AppStatus.activeConnectionProtocol), currentState=\(AppStatus.protocolSessionState)")
        NSLog("[RDP] stopConnection: %@, activeProto=%@", reason, "\(AppStatus.activeConnectionProtocol)")
        if channel != nil {
            logger.log(content: "RDP disconnect: \(reason)")
        }
        channel?.close()
        channel = nil
        protocolHandler.reset()
        isConnected = false
        currentFrame = nil
        if AppStatus.activeConnectionProtocol == .rdp {
            AppStatus.protocolSessionState = .idle
            NSLog("[RDP] state → idle")
        }
    }

    private func setError(_ message: String) {
        RDPProtocolHandler.trace("RDPClientManager.setError: \(message)")
        logger.log(content: "RDP error: \(message)")
        AppStatus.protocolSessionState = .error
        AppStatus.protocolLastErrorMessage = message
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .protocolErrorOccurred,
                object: nil,
                userInfo: [
                    ProtocolErrorUserInfoKeys.mode: ConnectionProtocolMode.rdp,
                    ProtocolErrorUserInfoKeys.message: message
                ]
            )
        }
    }

    fileprivate func send(_ data: Data) {
        guard let ch = channel else {
            logger.log(content: "RDP send: channel is nil, cannot send \(data.count) bytes")
            return
        }
        AppStatus.addRemoteTxBytes(data.count)
        logger.log(content: "RDP send: \(data.count) bytes, hex: \(data.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " "))")
        do {
            try ch.send(data)
        } catch {
            logger.log(content: "RDP send error: \(error.localizedDescription)")
            setError("RDP send error: \(error.localizedDescription)")
            stopConnection(reason: "send error")
        }
    }

    private func runOnRDPQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.currentQueueLabel == "com.openterface.rdp" {
            work()
        } else {
            queue.async(execute: work)
        }
    }
}

extension RDPClientManager: RDPProtocolHandlerDelegate {
    func rdpSend(_ data: Data) {
        runOnRDPQueue { [weak self] in
            self?.send(data)
        }
    }

    func rdpAttemptTLSUpgrade() -> Bool {
        guard let ch = channel else {
            logger.log(content: "RDP TLS upgrade: channel is nil")
            return false
        }
        logger.log(content: "RDP TLS upgrade: calling RDPTLSChannel.upgradeToTLS(hostname: \(host))")
        do {
            try ch.upgradeToTLS(hostname: host)
            logger.log(content: "RDP TLS upgrade: succeeded")
            return true
        } catch {
            logger.log(content: "RDP TLS upgrade failed: \(error.localizedDescription)")
            return false
        }
    }

    func rdpSetError(_ message: String) {
        runOnRDPQueue { [weak self] in
            self?.setError(message)
        }
    }

    func rdpStopConnection(reason: String) {
        runOnRDPQueue { [weak self] in
            self?.stopConnection(reason: reason)
        }
    }

    func rdpMarkConnected() {
        runOnRDPQueue { [weak self] in
            self?.isConnected = true
            AppStatus.protocolSessionState = .connected
            AppStatus.protocolLastErrorMessage = ""
        }
    }

    func rdpPublishFrame(_ frame: CGImage?) {
        runOnRDPQueue { [weak self] in
            self?.currentFrame = frame
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rdpFrameUpdated, object: nil)
            }
        }
    }

    func rdpSetFramebufferSize(width: Int, height: Int) {
        runOnRDPQueue { [weak self] in
            self?.framebufferSize = CGSize(width: width, height: height)
            AppStatus.setRemoteFramebufferSize(width: width, height: height)
        }
    }

    func rdpGetFramebufferSize() -> (width: Int, height: Int) {
        return (Int(framebufferSize.width), Int(framebufferSize.height))
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let rdpFrameUpdated = Notification.Name("RDPFrameUpdated")
}
