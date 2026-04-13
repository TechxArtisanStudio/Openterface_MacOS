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

    private struct ProtocolPreferences {
        let useZLIBCompression: Bool
        let useTightCompression: Bool
    }

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

    private enum FallbackLevel {
        case full      // honour user settings
        case zlibOnly  // Tight failed; advertise ZLIB only
        case rawOnly   // ZLIB also failed; advertise Raw only
    }
    private var fallbackLevel: FallbackLevel = .full

    var logger: LoggerProtocol { loggerStorage }

    private init() {
        let preferences = currentProtocolPreferences()
        protocolHandler = makeProtocolHandler(preferences: preferences)
    }

    func connect(host: String, port: Int, password: String?) {
        queue.async { [weak self] in
            self?.fallbackLevel = .full
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
        // NSEvent.charactersIgnoringModifiers requires the main thread (TSM/Carbon).
        // Extract all properties here before dispatching to the background queue.
        let keyCode = event.keyCode
        let chars = event.charactersIgnoringModifiers
        queue.async { [weak self] in
            self?.protocolHandler.handleKeyEvent(keyCode: keyCode, charactersIgnoringModifiers: chars, isDown: isDown)
        }
    }

    func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifierFlags = event.modifierFlags
        queue.async { [weak self] in
            self?.protocolHandler.handleFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags)
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

        let preferences = currentProtocolPreferences()
        protocolHandler = makeProtocolHandler(preferences: preferences)

        self.host = trimmedHost
        self.port = port
        isConnected = false
        AppStatus.resetRemoteNetworkStats(host: trimmedHost, port: port)

        AppStatus.protocolSessionState = .connecting
        AppStatus.protocolLastErrorMessage = ""
        protocolHandler.startHandshake()

        let nwConnection = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: .tcp)
        connection = nwConnection

        let attemptLabel: String
        switch fallbackLevel {
        case .full:     attemptLabel = "attempt=1 (user settings)"
        case .zlibOnly: attemptLabel = "attempt=2 (Tight failed, using ZLIB fallback)"
        case .rawOnly:  attemptLabel = "attempt=3 (ZLIB failed, using Raw fallback)"
        }
        logger.log(content: "VNC connecting to \(trimmedHost):\(port) \(attemptLabel)")
        logger.log(content: "VNC effective preferences: zlib=\(preferences.useZLIBCompression) tight=\(preferences.useTightCompression)")

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
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .protocolErrorOccurred,
                object: nil,
                userInfo: [
                    ProtocolErrorUserInfoKeys.mode: ConnectionProtocolMode.vnc,
                    ProtocolErrorUserInfoKeys.message: message
                ]
            )
        }
    }

    private func currentProtocolPreferences() -> ProtocolPreferences {
        switch fallbackLevel {
        case .full:
            return ProtocolPreferences(
                useZLIBCompression: UserSettings.shared.vncEnableZLIBCompression,
                useTightCompression: UserSettings.shared.vncEnableTightCompression
            )
        case .zlibOnly:
            return ProtocolPreferences(useZLIBCompression: true, useTightCompression: false)
        case .rawOnly:
            return ProtocolPreferences(useZLIBCompression: false, useTightCompression: false)
        }
    }

    private func makeProtocolHandler(preferences: ProtocolPreferences) -> RFBProtocolHandler {
        RFBProtocolHandler(
            delegate: self,
            useZLIBCompression: preferences.useZLIBCompression,
            useTightCompression: preferences.useTightCompression
        )
    }

    private func receiveData() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.log(content: "VNC receive error: \(error.localizedDescription)")
                self.setError("VNC receive error: \(error.localizedDescription)")
                self.stopConnection(reason: "receive error")
                return
            }

            if let data = data, !data.isEmpty {
                AppStatus.addRemoteRxBytes(data.count)
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
        AppStatus.addRemoteTxBytes(data.count)
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
        let isTightFailure = reason.contains("tight")
        let isZlibFailure  = reason.contains("zlib") || reason == "unsupported rect encoding"

        switch fallbackLevel {
        case .full where isTightFailure:
            fallbackLevel = .zlibOnly
            logger.log(content: "VNC Tight failed (\(reason)); retrying with ZLIB")
            let h = host; let p = port
            stopConnection(reason: "tight fallback to zlib")
            performConnect(host: h, port: p)
        case .full where isZlibFailure:
            fallbackLevel = .rawOnly
            logger.log(content: "VNC ZLIB failed (\(reason)); retrying with Raw")
            let h = host; let p = port
            stopConnection(reason: "zlib fallback to raw")
            performConnect(host: h, port: p)
        case .zlibOnly where isZlibFailure || isTightFailure:
            fallbackLevel = .rawOnly
            logger.log(content: "VNC ZLIB failed (\(reason)); retrying with Raw")
            let h = host; let p = port
            stopConnection(reason: "zlib fallback to raw")
            performConnect(host: h, port: p)
        default:
            stopConnection(reason: reason)
        }
    }

    func rfbMarkConnected() {
        isConnected = true
        AppStatus.protocolSessionState = .connected
        AppStatus.protocolLastErrorMessage = ""
        switch fallbackLevel {
        case .full:     logger.log(content: "VNC connected successfully using user settings (Tight=\(UserSettings.shared.vncEnableTightCompression) ZLIB=\(UserSettings.shared.vncEnableZLIBCompression))")
        case .zlibOnly: logger.log(content: "VNC connected using ZLIB fallback (Tight encoding was not supported by server)")
        case .rawOnly:  logger.log(content: "VNC connected using Raw fallback (neither Tight nor ZLIB were supported)")
        }
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
        AppStatus.setRemoteFramebufferSize(width: width, height: height)
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
    static let protocolErrorOccurred = Notification.Name("ProtocolErrorOccurred")
}

enum ProtocolErrorUserInfoKeys {
    static let mode = "mode"
    static let message = "message"
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
