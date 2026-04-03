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
import CoreGraphics
import AppKit

final class VNCClientManager: VNCClientManagerProtocol {

    static let shared = VNCClientManager()

    private(set) var isConnected: Bool = false
    private(set) var host: String = ""
    private(set) var port: Int = 5900
    private(set) var currentFrame: CGImage?
    var framebufferSize: CGSize {
        CGSize(width: framebufferWidth, height: framebufferHeight)
    }

    private let queue = DispatchQueue(label: "com.openterface.vnc")
    private var connection: NWConnection?
    private let loggerStorage: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var framebufferWidth: Int = 0
    private var framebufferHeight: Int = 0
    private var framebufferPixels = Data()
    private var protocolHandler: RFBProtocolHandler!

    var logger: LoggerProtocol { loggerStorage }

    private init() {
        protocolHandler = RFBProtocolHandler(delegate: self)
    }

    func connect(host: String, port: Int, password: String?) {
        queue.async { [weak self] in
            self?.logger.log(content: "VNC connect requested: host=\(host) port=\(port) passwordPresent=\(password != nil && !(password!.isEmpty))")
            self?.performConnect(host: host, port: port)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.logger.log(content: "VNC disconnect requested.")
            self?.stopConnection(reason: "manual disconnect")
        }
    }

    func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        queue.async { [weak self] in
            self?.protocolHandler.sendPointerEvent(x: x, y: y, buttonMask: buttonMask)
        }
    }

    func sendKeyEvent(keySym: UInt32, isDown: Bool) {
        queue.async { [weak self] in
            self?.protocolHandler.sendKeyEvent(keySym: keySym, isDown: isDown)
        }
    }

    func sendClipboardText(_ text: String) {
        queue.async { [weak self] in
            self?.protocolHandler.sendClipboardText(text)
        }
    }

    func sendScroll(x: Int, y: Int, deltaY: CGFloat, buttonMask: UInt8) {
        queue.async { [weak self] in
            self?.protocolHandler.sendScroll(x: x, y: y, deltaY: deltaY, buttonMask: buttonMask)
        }
    }

    func handleKeyEvent(_ event: NSEvent, isDown: Bool) {
        queue.async { [weak self] in
            self?.protocolHandler.handleKeyEvent(event, isDown: isDown)
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        queue.async { [weak self] in
            self?.protocolHandler.handleFlagsChanged(event)
        }
    }

    private func performConnect(host: String, port: Int) {
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
        protocolHandler.startHandshake()

        let nwConnection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .tcp)
        connection = nwConnection

        logger.log(content: "VNC connecting to \(trimmedHost):\(port)")

        nwConnection.stateUpdateHandler = { [weak self, weak nwConnection] state in
            guard let self = self else { return }
            guard self.connection === nwConnection else {
                self.logger.log(content: "VNC stale connection state ignored: \(state)")
                return
            }
            switch state {
            case .ready:
                self.logger.log(content: "VNC TCP connection ready")
                self.receiveData()
            case .preparing:
                self.logger.log(content: "VNC TCP connection preparing...")
            case .waiting(let error):
                self.logger.log(content: "VNC TCP connection waiting: \(error.localizedDescription)")
                self.setError("VNC connection waiting: \(error.localizedDescription)")
                self.stopConnection(reason: "connection waiting/unreachable")
            case .failed(let error):
                self.logger.log(content: "VNC connection failed: \(error.localizedDescription)")
                self.setError("VNC connection failed: \(error.localizedDescription)")
                self.stopConnection(reason: "connection failed")
            case .cancelled:
                self.logger.log(content: "VNC connection cancelled")
            case .setup:
                self.logger.log(content: "VNC TCP connection setup")
            @unknown default:
                self.logger.log(content: "VNC TCP connection unknown state: \(state)")
            }
        }

        nwConnection.start(queue: queue)
    }

    private func stopConnection(reason: String) {
        if connection != nil {
            logger.log(content: "VNC disconnect: \(reason)")
        }
        connection?.cancel()
        connection = nil
        protocolHandler.reset()
        isConnected = false
        framebufferWidth = 0
        framebufferHeight = 0
        framebufferPixels = Data()
        currentFrame = nil
        if AppStatus.activeConnectionProtocol == .vnc {
            AppStatus.protocolSessionState = .idle
        }
    }

    private func setError(_ message: String) {
        logger.log(content: "VNC error: \(message)")
        AppStatus.protocolSessionState = .error
        AppStatus.protocolLastErrorMessage = message
    }

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
                self.protocolHandler.ingest(data)
            }

            if isComplete {
                self.logger.log(content: "VNC remote endpoint closed connection")
                self.stopConnection(reason: "remote closed")
                return
            }

            self.receiveData()
        }
    }

    fileprivate func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.logger.log(content: "VNC send error: \(error.localizedDescription)")
                self?.setError("VNC send error: \(error.localizedDescription)")
                self?.stopConnection(reason: "send error")
            }
        })
    }
}

extension VNCClientManager: RFBProtocolHandlerDelegate {
    func rfbSend(_ data: Data) {
        send(data)
    }

    func rfbSetError(_ message: String) {
        setError(message)
    }

    func rfbStopConnection(reason: String) {
        stopConnection(reason: reason)
    }

    func rfbMarkConnected() {
        isConnected = true
        AppStatus.protocolSessionState = .connected
        AppStatus.protocolLastErrorMessage = ""
    }

    func rfbPublishFrame(_ frame: CGImage?) {
        currentFrame = frame
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vncFrameUpdated, object: nil)
        }
    }

    func rfbSetFramebufferSize(width: Int, height: Int) {
        framebufferWidth = width
        framebufferHeight = height
    }

    func rfbGetFramebufferSize() -> (width: Int, height: Int) {
        return (framebufferWidth, framebufferHeight)
    }

    func rfbSetFramebufferPixels(_ pixels: Data) {
        framebufferPixels = pixels
    }

    func rfbGetFramebufferPixels() -> Data {
        return framebufferPixels
    }

    func rfbGetVNCPassword() -> String {
        return UserSettings.shared.vncPassword
    }

    func rfbGetARDCredentials() -> (username: String, password: String) {
        return (UserSettings.shared.vncUsername, UserSettings.shared.vncPassword)
    }

    func rfbComputeARDResponse(generator: UInt16,
                               prime: [UInt8],
                               serverPublicKey: [UInt8],
                               username: String,
                               password: String,
                               completion: @escaping (Data?) -> Void) {
        logger.log(content: "VNC ARD compute dispatch: generator=\(generator) keyLen=\(prime.count) username=\(username)")
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let response = rfbARDResponse(generator: generator,
                                          prime: prime,
                                          serverPublicKey: serverPublicKey,
                                          username: username,
                                          password: password)
            self.queue.async {
                let elapsed = Date().timeIntervalSince(startedAt)
                self.logger.log(content: "VNC ARD compute complete: responseBytes=\(response?.count ?? 0) elapsed=\(String(format: "%.2f", elapsed))s")
                completion(response)
            }
        }
    }
}

extension Notification.Name {
    static let vncFrameUpdated = Notification.Name("VNCFrameUpdated")
}

extension VNCClientManager {
    func _test_modExp(base: [UInt8], exp: [UInt8], mod: [UInt8]) -> [UInt8] {
        return ardModExp(base: base, exp: exp, mod: mod)
    }

    func _test_ardDHResponse(generator: UInt16, prime: [UInt8], serverPublicKey: [UInt8],
                             username: String, password: String) -> Data? {
        return rfbARDResponse(generator: generator,
                              prime: prime,
                              serverPublicKey: serverPublicKey,
                              username: username,
                              password: password)
    }
}
