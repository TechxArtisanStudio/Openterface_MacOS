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

    @Published var scannedDevices: [ScannedDevice] = []
    @Published var isConnected: Bool = false
    @Published var isOperationInProgress: Bool = false
    @Published var operationProgress: Double = 0.0
    @Published var statusMessage: String = "Not connected"
    @Published var isError: Bool = false
    @Published var chipInfo: String = ""
    @Published var selectedFirmwareURL: URL?

    /// Backward-compatible count
    var availableDeviceCount: Int { scannedDevices.count }

    // MARK: - Private

    private var flashing: WCHFlashing?

    private init() {}

    // MARK: - Device scanning

    func scanDevices() {
        let devices = WCHLibusbTransport.scanDevices()
        scannedDevices = devices
        if devices.isEmpty {
            statusMessage = "No WCH device found in ISP mode"
        } else {
            statusMessage = "Found \(devices.count) WCH device(s)"
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
            let transport = try WCHLibusbTransport(deviceIndex: deviceIndex)
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
        guard var f = flashing else {
            statusMessage = "Not connected"
            isError = true
            return
        }
        guard let url = selectedFirmwareURL else {
            statusMessage = "No firmware file selected"
            isError = true
            return
        }

        let binary: [UInt8]
        do {
            let data = try Data(contentsOf: url)
            binary = try resolveBinary(data: data, url: url)
        } catch {
            isError = true
            statusMessage = "Firmware load failed: \(error)"
            return
        }

        // Handle unprotect before performOperation (needs MainActor access)
        if f.isCodeFlashProtected() {
            statusMessage = "Reading config…"
            f.printConfig()
            statusMessage = "Unprotecting flash…"
            do {
                print("[WCH] Calling unprotect...")
                try f.unprotect(skipReset: false)  // Must reset after unprotect
                print("[WCH] Unprotect completed, device will reset")
                // After unprotect reset, device boots firmware
                // User needs to press BOOT button to enter bootloader mode
                statusMessage = "⚠️ Unprotect complete. Please press the BOOT button on the device to enter bootloader mode, and connect again.."
                flashing = nil
                isConnected = false

                // Wait for device to re-enumerate in bootloader mode
                var deviceFound = false
                for attempt in 1...30 {  // Wait up to 30 seconds
                    try await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1 second
                    let devices = WCHLibusbTransport.scanDevices()
                    print("[WCH] Waiting for BOOT press... attempt \(attempt)/30, found \(devices.count) devices")
                    if !devices.isEmpty {
                        deviceFound = true
                        break
                    }
                }
                guard deviceFound else {
                    isError = true
                    statusMessage = "Device not found after unprotect. Please press BOOT button and try again."
                    return
                }

                // Reconnect to device
                statusMessage = "Reconnecting..."
                try await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1 second for device to stabilize
                let transport = try WCHLibusbTransport(deviceIndex: 0)
                f = try WCHFlashing(transport: transport)
                flashing = f
                isConnected = true
                print("[WCH] Reconnected after BOOT press")
                f.printConfig()

                if f.isCodeFlashProtected() {
                    isError = true
                    statusMessage = "Device still protected after unprotect. Try again."
                    return
                }
                print("[WCH] Device successfully unprotected and reconnected")
                // Add a delay before flash operations to ensure device is ready
                try await Task.sleep(nanoseconds: 500_000_000)  // Wait 0.5 seconds
            } catch {
                isError = true
                statusMessage = "Unprotect failed: \(error)"
                return
            }
        }

        await performOperation("Flashing") {
            // Always dump config before flash
            await self.updateStatus("Reading config…", progress: 0.01)
            f.printConfig()

            await self.updateStatus("Erasing…", progress: 0.05)
            try f.eraseCodeFlash(firmwareSize: UInt32(binary.count))

            await self.updateStatus("Writing…", progress: 0.1)
            try f.flashCode(data: binary) { p in
                Task { @MainActor in
                    self.statusMessage = "Writing… \(Int(p * 100))%"
                    self.operationProgress = 0.1 + p * 0.5
                }
            }

            await self.updateStatus("Verifying…", progress: 0.6)
            try f.verifyCode(data: binary) { p in
                Task { @MainActor in
                    self.statusMessage = "Verifying… \(Int(p * 100))%"
                    self.operationProgress = 0.6 + p * 0.25
                }
            }

            if f.chip.supportsCodeFlashProtect {
                await self.updateStatus("Enabling flash protection…", progress: 0.88)
                try f.protect()
                await self.updateStatus("Config after protect:", progress: 0.90)
                f.printConfig()
                sleep(2)
            }

            await self.updateStatus("Resetting device…", progress: 0.95)
            try f.reset()
            await self.updateStatus("Flashing completed", progress: 1.0)
        }
        self.flashing = nil
        self.isConnected = false
    }

    // MARK: - Verify only

    func verifyFirmware() async {
        guard let f = flashing else {
            statusMessage = "Not connected"; isError = true; return
        }
        guard let url = selectedFirmwareURL else {
            statusMessage = "No firmware file selected"; isError = true; return
        }

        let binary: [UInt8]
        do {
            let data = try Data(contentsOf: url)
            binary = try resolveBinary(data: data, url: url)
        } catch {
            isError = true
            statusMessage = "Firmware load failed: \(error)"
            return
        }

        await performOperation("Verifying") {
            try f.verifyCode(data: binary) { p in
                Task { @MainActor in
                    self.statusMessage = "Verifying… \(Int(p * 100))%"
                    self.operationProgress = p
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

    private nonisolated func updateStatus(_ msg: String, progress: Double) async {
        await MainActor.run {
            self.statusMessage = msg
            self.operationProgress = progress
        }
    }

    private func performOperation(_ name: String, operation: @escaping @Sendable () async throws -> Void) async {
        isOperationInProgress = true
        operationProgress = 0
        isError = false
        statusMessage = "\(name)…"
        do {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    Task {
                        do {
                            try await operation()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            statusMessage = "\(name) completed"
            operationProgress = 1.0
        } catch {
            isError = true
            statusMessage = "\(name) failed: \(error)"
        }
        isOperationInProgress = false
    }
}
