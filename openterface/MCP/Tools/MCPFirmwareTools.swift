import Foundation
import Combine

// MARK: - Firmware Upgrade Tool (OTA)

final class MCPFirmwareUpgradeTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "firmware_upgrade",
        description: "Upgrade the video chipset firmware to the latest version from the Openterface server. Downloads and flashes the firmware. The device will be unavailable during the update (typically 10-60 seconds). Supports MS2109, MS2109S, and MS2130S chipsets.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        let firmwareManager = FirmwareManager.shared

        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset != .unknown else {
            return MCPCallToolResult(
                content: [.text("No video chipset detected. Ensure the Openterface device is connected.")],
                isError: true
            )
        }

        let inProgress = await MainActor.run { firmwareManager.isUpdateInProgress }
        guard !inProgress else {
            return MCPCallToolResult(
                content: [.text("A firmware update is already in progress.")],
                isError: true
            )
        }

        let currentVersion = firmwareManager.getCurrentFirmwareVersion()
        let latestVersion = await firmwareManager.fetchLatestFirmwareVersion()

        let chipsetLabel: String
        switch chipset {
        case .ms2109: chipsetLabel = "MS2109"
        case .ms2109s: chipsetLabel = "MS2109S"
        case .ms2130s: chipsetLabel = "MS2130S"
        default: chipsetLabel = "Unknown"
        }

        // Pause all periodic operations that could interfere with firmware flash
        await MainActor.run { firmwareManager.stopAllOperations() }
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        SerialPortManager.shared.pauseSDCardPolling()
        
        let controlChipsetType = await MainActor.run { AppStatus.controlChipsetType }
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.pauseCTSMonitoring()
            }
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000)

        let success: Bool = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = firmwareManager.firmwareWriteComplete.sink { result in
                cancellable?.cancel()
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                await firmwareManager.loadFirmwareToEeprom()
            }
        }
        
        // Resume periodic operations after flash completes
        HALIntegrationManager.shared.resumePeriodicHALUpdates()
        SerialPortManager.shared.resumeSDCardPolling()
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.resumeCTSMonitoring()
            }
        }

        if success {
            // Verify firmware after flashing
            let verificationResult = await verifyFirmwareAfterFlash()
            
            var resultMessage = "Firmware upgrade completed.\nChipset: \(chipsetLabel)\nPrevious version: \(currentVersion)\nNew version: \(latestVersion)"
            
            if let verification = verificationResult {
                resultMessage += "\n\nVerification: \(verification)"
            }
            
            resultMessage += "\n\nPlease restart the app to reconnect the device."
            
            return MCPCallToolResult(
                content: [.text(resultMessage)],
                isError: nil
            )
        } else {
            let status = await MainActor.run { firmwareManager.updateStatus }
            return MCPCallToolResult(
                content: [.text("Firmware upgrade failed: \(status)")],
                isError: true
            )
        }
    }
    
    private func verifyFirmwareAfterFlash() async -> String? {
        let firmwareManager = FirmwareManager.shared
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        // Wait a bit for device to settle
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Read back firmware for verification (MS2109/MS2109S only for now)
        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset == .ms2109 || chipset == .ms2109s else {
            return "Verification skipped (not supported for \(chipset))"
        }
        
        // Determine firmware size
        let firmwareSize = await firmwareManager.determineFirmwareSize()
        guard firmwareSize > 0 else {
            return "Could not determine firmware size for verification"
        }
        
        // Pause all periodic operations that could interfere with firmware read
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        SerialPortManager.shared.pauseSDCardPolling()
        
        let controlChipsetType = await MainActor.run { AppStatus.controlChipsetType }
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.pauseCTSMonitoring()
            }
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Read firmware back from device in chunks (max 255 bytes per read)
        var readBackData = Data()
        var address: UInt16 = 0
        
        while readBackData.count < firmwareSize {
            let chunkSize = min(255, firmwareSize - readBackData.count)
            guard let chunk = hidManager.readEeprom(address: address, length: UInt8(chunkSize)) else {
                // Resume all operations
                HALIntegrationManager.shared.resumePeriodicHALUpdates()
                SerialPortManager.shared.resumeSDCardPolling()
                if controlChipsetType == .ch9329 {
                    if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                        ch9329.resumeCTSMonitoring()
                    }
                }
                return "Failed to read back firmware at address 0x\(String(format: "%04X", address))"
            }
            readBackData.append(chunk)
            address += UInt16(chunkSize)
            
            // Small delay between reads to ensure device stability
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        // Resume all periodic operations
        HALIntegrationManager.shared.resumePeriodicHALUpdates()
        SerialPortManager.shared.resumeSDCardPolling()
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.resumeCTSMonitoring()
            }
        }
        
        // Verify checksums
        let checksumResult = await firmwareManager.verifyFirmwareChecksumsPublic(firmwareData: readBackData)
        return checksumResult
    }
}

// MARK: - Firmware Verify Tool

final class MCPFirmwareVerifyTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "firmware_verify",
        description: "Verify the integrity of the currently installed video firmware by reading it back from EEPROM and checking the checksums. Use this after a firmware update or if the device is not working correctly.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        let firmwareManager = FirmwareManager.shared
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)

        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset != .unknown else {
            return MCPCallToolResult(
                content: [.text("No video chipset detected. Ensure the Openterface device is connected.")],
                isError: true
            )
        }

        let chipsetLabel: String
        switch chipset {
        case .ms2109: chipsetLabel = "MS2109"
        case .ms2109s: chipsetLabel = "MS2109S"
        case .ms2130s: chipsetLabel = "MS2130S"
        default: chipsetLabel = "Unknown"
        }

        // MS2130S uses external SPI flash, different verification path
        guard chipset == .ms2109 || chipset == .ms2109s else {
            return MCPCallToolResult(
                content: [.text("Firmware verification is not yet supported for \(chipsetLabel) devices.")],
                isError: true
            )
        }

        let currentVersion = firmwareManager.getCurrentFirmwareVersion()

        // Pause all periodic operations that could interfere with firmware read
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        SerialPortManager.shared.pauseSDCardPolling()
        
        // Pause CTS monitoring for CH9329
        let controlChipsetType = await MainActor.run { AppStatus.controlChipsetType }
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.pauseCTSMonitoring()
            }
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Determine firmware size
        let firmwareSize = await firmwareManager.determineFirmwareSize()
        guard firmwareSize > 0 else {
            // Resume all operations
            HALIntegrationManager.shared.resumePeriodicHALUpdates()
            SerialPortManager.shared.resumeSDCardPolling()
            if controlChipsetType == .ch9329 {
                if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                    ch9329.resumeCTSMonitoring()
                }
            }
            return MCPCallToolResult(
                content: [.text("Could not determine firmware size.")],
                isError: true
            )
        }

        // Read firmware back from device in chunks (max 255 bytes per read)
        var readBackData = Data()
        var address: UInt16 = 0

        while readBackData.count < firmwareSize {
            let chunkSize = min(255, firmwareSize - readBackData.count)
            guard let chunk = hidManager.readEeprom(address: address, length: UInt8(chunkSize)) else {
                // Resume all operations
                HALIntegrationManager.shared.resumePeriodicHALUpdates()
                SerialPortManager.shared.resumeSDCardPolling()
                if controlChipsetType == .ch9329 {
                    if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                        ch9329.resumeCTSMonitoring()
                    }
                }
                return MCPCallToolResult(
                    content: [.text("Failed to read firmware at address 0x\(String(format: "%04X", address)). Device may not be responding.")],
                    isError: true
                )
            }
            readBackData.append(chunk)
            address += UInt16(chunkSize)
            
            // Small delay between reads to ensure device stability
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        // Resume all periodic operations after reading
        HALIntegrationManager.shared.resumePeriodicHALUpdates()
        SerialPortManager.shared.resumeSDCardPolling()
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.resumeCTSMonitoring()
            }
        }

        // Verify checksums
        let checksumResult = await firmwareManager.verifyFirmwareChecksumsPublic(firmwareData: readBackData)

        let resultMessage = """
        Firmware Verification Report
        ============================
        Chipset: \(chipsetLabel)
        Firmware version: \(currentVersion)
        Firmware size: \(firmwareSize) bytes
        Data read: \(readBackData.count) bytes

        Checksum Result:
        \(checksumResult)
        """

        let checksumValid = checksumResult.contains("✓") && !checksumResult.contains("≠")

        return MCPCallToolResult(
            content: [.text(resultMessage)],
            isError: !checksumValid
        )
    }
}

// MARK: - Firmware Flash Local Tool

final class MCPFirmwareFlashLocalTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "firmware_flash_local",
        description: "Flash a local firmware binary file to the video chipset. Use this to install a specific firmware version. The file must be a .bin firmware image. The device will be unavailable during flashing (typically 10-60 seconds).",
        inputSchema: MCPInputSchema(
            properties: [
                "file_path": AnyCodable(["type": "string", "description": "Absolute path to the firmware .bin file"])
            ],
            required: ["file_path"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return MCPCallToolResult(
                content: [.text("Invalid arguments: file_path (string) required")],
                isError: true
            )
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MCPCallToolResult(
                content: [.text("Firmware file not found: \(filePath)")],
                isError: true
            )
        }

        let firmwareManager = FirmwareManager.shared

        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset != .unknown else {
            return MCPCallToolResult(
                content: [.text("No video chipset detected. Ensure the Openterface device is connected.")],
                isError: true
            )
        }

        let inProgress = await MainActor.run { firmwareManager.isUpdateInProgress }
        guard !inProgress else {
            return MCPCallToolResult(
                content: [.text("A firmware update is already in progress.")],
                isError: true
            )
        }

        let currentVersion = firmwareManager.getCurrentFirmwareVersion()

        let chipsetLabel: String
        switch chipset {
        case .ms2109: chipsetLabel = "MS2109"
        case .ms2109s: chipsetLabel = "MS2109S"
        case .ms2130s: chipsetLabel = "MS2130S"
        default: chipsetLabel = "Unknown"
        }

        // Pause all periodic operations that could interfere with firmware flash
        await MainActor.run { firmwareManager.stopAllOperations() }
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        SerialPortManager.shared.pauseSDCardPolling()
        
        let controlChipsetType = await MainActor.run { AppStatus.controlChipsetType }
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.pauseCTSMonitoring()
            }
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000)

        let success: Bool = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = firmwareManager.firmwareWriteComplete.sink { result in
                cancellable?.cancel()
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                await firmwareManager.restoreFirmware(from: fileURL)
            }
        }
        
        // Resume periodic operations after flash completes
        HALIntegrationManager.shared.resumePeriodicHALUpdates()
        SerialPortManager.shared.resumeSDCardPolling()
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.resumeCTSMonitoring()
            }
        }

        if success {
            // Verify firmware after flashing
            let verificationResult = await verifyFirmwareAfterFlash()
            
            var resultMessage = "Firmware flash completed.\nChipset: \(chipsetLabel)\nFile: \(fileURL.lastPathComponent)\nPrevious version: \(currentVersion)"
            
            if let verification = verificationResult {
                resultMessage += "\n\nVerification: \(verification)"
            }
            
            resultMessage += "\n\nPlease restart the app to reconnect the device."
            
            return MCPCallToolResult(
                content: [.text(resultMessage)],
                isError: nil
            )
        } else {
            let status = await MainActor.run { firmwareManager.updateStatus }
            return MCPCallToolResult(
                content: [.text("Firmware flash failed: \(status)")],
                isError: true
            )
        }
    }
    
    private func verifyFirmwareAfterFlash() async -> String? {
        let firmwareManager = FirmwareManager.shared
        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        
        // Wait a bit for device to settle
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Read back firmware for verification (MS2109/MS2109S only for now)
        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset == .ms2109 || chipset == .ms2109s else {
            return "Verification skipped (not supported for \(chipset))"
        }
        
        // Determine firmware size
        let firmwareSize = await firmwareManager.determineFirmwareSize()
        guard firmwareSize > 0 else {
            return "Could not determine firmware size for verification"
        }
        
        // Pause all periodic operations that could interfere with firmware read
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        SerialPortManager.shared.pauseSDCardPolling()
        
        let controlChipsetType = await MainActor.run { AppStatus.controlChipsetType }
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.pauseCTSMonitoring()
            }
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        // Read firmware back from device in chunks (max 255 bytes per read)
        var readBackData = Data()
        var address: UInt16 = 0
        
        while readBackData.count < firmwareSize {
            let chunkSize = min(255, firmwareSize - readBackData.count)
            guard let chunk = hidManager.readEeprom(address: address, length: UInt8(chunkSize)) else {
                // Resume all operations
                HALIntegrationManager.shared.resumePeriodicHALUpdates()
                SerialPortManager.shared.resumeSDCardPolling()
                if controlChipsetType == .ch9329 {
                    if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                        ch9329.resumeCTSMonitoring()
                    }
                }
                return "Failed to read back firmware at address 0x\(String(format: "%04X", address))"
            }
            readBackData.append(chunk)
            address += UInt16(chunkSize)
            
            // Small delay between reads to ensure device stability
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        // Resume all periodic operations
        HALIntegrationManager.shared.resumePeriodicHALUpdates()
        SerialPortManager.shared.resumeSDCardPolling()
        if controlChipsetType == .ch9329 {
            if let ch9329 = HardwareAbstractionLayer.shared.getCurrentControlChipset() as? CH9329ControlChipset {
                ch9329.resumeCTSMonitoring()
            }
        }
        
        // Verify checksums
        let checksumResult = await firmwareManager.verifyFirmwareChecksumsPublic(firmwareData: readBackData)
        return checksumResult
    }
}
