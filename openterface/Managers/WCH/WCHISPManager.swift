/*
 * WCHISPManager - WCH chip ISP flashing manager for Openterface
 * High-level interface for detecting, connecting, and flashing WCH chips
 */

import Foundation
import Combine
import AppKit

@MainActor
class WCHISPManager: ObservableObject {
    static let shared = WCHISPManager()

    // MARK: - Published state

    @Published var availableDeviceCount: Int = 0
    @Published var isConnected: Bool = false
    @Published var isOperationInProgress: Bool = false
    @Published var operationProgress: Double = 0.0
    @Published var statusMessage: String = "Not connected"
    @Published var isError: Bool = false
    @Published var chipInfo: String = ""
    @Published var selectedFirmwareURL: URL?

    // MARK: - Private

    private var flashing: WCHFlashing?

    private init() {}

    // MARK: - Device scanning

    func scanDevices() {
        let count = WCHUSBTransport.scanDevices()
        availableDeviceCount = count
        if count == 0 {
            statusMessage = "No WCH device found in ISP mode"
        } else {
            statusMessage = "Found \(count) WCH device(s)"
        }
    }

    // MARK: - Connect / Disconnect

    func connect(deviceIndex: Int = 0) async {
        guard !isConnected else {
            disconnect()
            return
        }

        isOperationInProgress = true
        statusMessage = "Connecting…"
        isError = false

        do {
            let transport = try WCHUSBTransport(deviceIndex: deviceIndex)
            let f = try WCHFlashing(transport: transport)
            flashing = f
            chipInfo = f.getChipInfo()
            isConnected = true
            statusMessage = "Connected: \(f.chip.name)"
        } catch {
            isError = true
            statusMessage = "Connection failed: \(error)"
            flashing = nil
        }
        isOperationInProgress = false
    }

    func disconnect() {
        flashing = nil
        isConnected = false
        chipInfo = ""
        statusMessage = "Disconnected"
    }

    // MARK: - Firmware file selection

    func selectFirmwareFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [] // allow all
        panel.message = "Select firmware file (.hex or .bin)"
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            selectedFirmwareURL = panel.url
        }
    }

    // MARK: - Flash

    func flashFirmware() async {
        guard let f = flashing else {
            statusMessage = "Not connected"
            isError = true
            return
        }
        guard let url = selectedFirmwareURL else {
            statusMessage = "No firmware file selected"
            isError = true
            return
        }
        await performOperation("Flashing") {
            let data = try Data(contentsOf: url)
            let binary = try self.resolveBinary(data: data, url: url)

            if f.isCodeFlashProtected() {
                self.updateStatus("Unprotecting flash…", progress: 0.02)
                try f.unprotect(skipReset: true)
            }

            self.updateStatus("Erasing…", progress: 0.05)
            try f.eraseCodeFlash(firmwareSize: UInt32(binary.count))

            self.updateStatus("Writing…", progress: 0.1)
            try f.flashCode(data: binary) { p in
                self.updateStatus("Writing… \(Int(p * 100))%", progress: 0.1 + p * 0.5)
            }

            self.updateStatus("Verifying…", progress: 0.6)
            try f.verifyCode(data: binary) { p in
                self.updateStatus("Verifying… \(Int(p * 100))%", progress: 0.6 + p * 0.3)
            }

            self.updateStatus("Resetting device…", progress: 0.95)
            try f.reset()
            self.flashing = nil
            self.isConnected = false
        }
    }

    // MARK: - Verify only

    func verifyFirmware() async {
        guard let f = flashing else {
            statusMessage = "Not connected"; isError = true; return
        }
        guard let url = selectedFirmwareURL else {
            statusMessage = "No firmware file selected"; isError = true; return
        }
        await performOperation("Verifying") {
            let data = try Data(contentsOf: url)
            let binary = try self.resolveBinary(data: data, url: url)
            try f.verifyCode(data: binary) { p in
                self.updateStatus("Verifying… \(Int(p * 100))%", progress: p)
            }
        }
    }

    // MARK: - Dump firmware

    func dumpFirmware() async {
        guard let f = flashing else {
            statusMessage = "Not connected"; isError = true; return
        }
        await performOperation("Dumping firmware") {
            let dumpedData = try f.transport.dumpFirmware(flashSize: f.chip.flashSize) { p in
                self.updateStatus("Dumping… \(Int(p * 100))%", progress: p)
            }
            let saveData = Data(dumpedData)
            await MainActor.run {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(f.chip.name)_firmware.bin"
                if panel.runModal() == .OK, let saveURL = panel.url {
                    try? saveData.write(to: saveURL)
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolveBinary(data: Data, url: URL) throws -> [UInt8] {
        // Intel HEX files start with ':'
        if data.first == UInt8(ascii: ":") || url.pathExtension.lowercased() == "hex" {
            return try WCHHexFileParser.parse(data: data)
        }
        return [UInt8](data)
    }

    private nonisolated func updateStatus(_ msg: String, progress: Double) {
        Task { @MainActor in
            self.statusMessage = msg
            self.operationProgress = progress
        }
    }

    private func performOperation(_ name: String, operation: @escaping () async throws -> Void) async {
        isOperationInProgress = true
        operationProgress = 0
        isError = false
        statusMessage = "\(name)…"
        do {
            try await operation()
            statusMessage = "\(name) completed"
            operationProgress = 1.0
        } catch {
            isError = true
            statusMessage = "\(name) failed: \(error)"
        }
        isOperationInProgress = false
    }
}
