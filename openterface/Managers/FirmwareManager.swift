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
import Combine
import AVFoundation
import AppKit

class FirmwareManager: ObservableObject {
    static let shared = FirmwareManager()
    private var  logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    private var  hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)

    // Published properties for progress tracking
    @Published var updateProgress: Double = 0.0
    @Published var updateStatus: String = ""
    @Published var isUpdateInProgress: Bool = false
    @Published var backupProgress: Double = 0.0
    @Published var backupStatus: String = ""
    @Published var isBackupInProgress: Bool = false
    
    // Progress signals - similar to Qt signals
    private let firmwareWriteProgressSubject = PassthroughSubject<Int, Never>()
    private let firmwareWriteCompleteSubject = PassthroughSubject<Bool, Never>()
    private let firmwareBackupCompleteSubject = PassthroughSubject<(Bool, String), Never>()
    
    var firmwareWriteProgress: AnyPublisher<Int, Never> {
        firmwareWriteProgressSubject.eraseToAnyPublisher()
    }
    
    var firmwareWriteComplete: AnyPublisher<Bool, Never> {
        firmwareWriteCompleteSubject.eraseToAnyPublisher()
    }
    
    var firmwareBackupComplete: AnyPublisher<(Bool, String), Never> {
        firmwareBackupCompleteSubject.eraseToAnyPublisher()
    }
    
    /// Published properties for EDID name operations
    @Published var edidUpdateProgress: Double = 0.0
    @Published var edidUpdateStatus: String = ""
    @Published var isEdidUpdateInProgress: Bool = false
    
    /// Progress signals for EDID operations
    private let edidUpdateCompleteSubject = PassthroughSubject<(Bool, String), Never>()
    
    var edidUpdateComplete: AnyPublisher<(Bool, String), Never> {
        edidUpdateCompleteSubject.eraseToAnyPublisher()
    }
    
    private let chunkSize = 64 // EEPROM write chunk size
    private let eepromStartAddress: UInt16 = 0x0000 // Starting address for firmware
    private let defaultFirmwareSize = 1453 // Default MS2109 firmware size
    
    private init() {}
    
    // MARK: - Operation Management
    
    /// Stops all active operations and closes the main window
    /// This should be called before EDID patching to ensure a clean state
    func stopAllOperations() {
        let logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
        logger.log(content: "Stopping all operations before firmware/EDID operations...")
        
        // Stop video operations with complete session teardown
        let videoManager = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
        videoManager.stopVideoSession()
        
        // Remove all video inputs to ensure complete disconnection
        videoManager.captureSession.beginConfiguration()
        let videoInputs = videoManager.captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
        videoInputs.forEach { videoManager.captureSession.removeInput($0) }
        videoManager.captureSession.commitConfiguration()
        logger.log(content: "✓ Video operations stopped and session cleared")
        
        // Stop audio operations
        let audioManager = DependencyContainer.shared.resolve(AudioManagerProtocol.self)
        audioManager.stopAudioSession()
        logger.log(content: "✓ Audio operations stopped")
        
        // Stop HID operations
        self.hidManager.stopAllHIDOperations()
        logger.log(content: "✓ HID operations stopped")
        
        // Post notification to stop any other operations
        NotificationCenter.default.post(
            name: NSNotification.Name("StopAllOperationsBeforeFirmwareUpdate"),
            object: nil
        )
        
        // Close main window
        DispatchQueue.main.async {
            let windows = NSApplication.shared.windows
            for window in windows {
                // Close/hide main content windows, but not auxiliary tool windows
                if let identifier = window.identifier?.rawValue {
                    if identifier.contains("main_openterface") || 
                       (!identifier.contains("edidNameWindow") &&
                        !identifier.contains("firmwareUpdateWindow") &&
                        !identifier.contains("resetSerialToolWindow") &&
                        window.contentViewController != nil &&
                        window.isVisible) {
                        logger.log(content: "✓ Closing/hiding main window: \(window.title)")
                        window.orderOut(nil) // Hide the window
                    }
                } else if window.title.contains("Openterface Mini-KVM") {
                    logger.log(content: "✓ Closing/hiding main window: \(window.title)")
                    window.orderOut(nil) // Hide the window
                }
            }
        }
        
        logger.log(content: "All operations stopped successfully")
    }
    
    // MARK: - Firmware Download
    
    func downloadLatestFirmware() async throws -> Data {
        // First get the firmware info
        guard let infoUrl = URL(string: "https://assets.openterface.com/openterface/firmware/minikvm_latest_firmware2.txt") else {
            throw FirmwareError.invalidURL
        }
        
        let (infoData, _) = try await URLSession.shared.data(from: infoUrl)
        guard let infoString = String(data: infoData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FirmwareError.invalidResponse
        }
        
        // Parse the firmware info based on chipset type
        // Format: "25022713,Openterface_Firmware_250306.bin" for MS2109
        //         "25052210,Openterface_Firmware_2130s_250522.bin,2130s" for MS2130S
        let lines = infoString.components(separatedBy: .newlines)
        var selectedLine: String?
        
        // Select the appropriate line based on current chipset
        switch AppStatus.videoChipsetType {
        case .ms2130s:
            // Look for line containing "2130s"
            selectedLine = lines.first { line in
                line.contains("2130s")
            }
        default:
            // For MS2109 and MS2109S, use the first line without chipset suffix
            selectedLine = lines.first { line in
                !line.contains("2130s")
            }
        }
        
        guard let selectedLine = selectedLine else {
            throw FirmwareError.invalidResponse
        }
        
        // Parse format: "25022713,Openterface_Firmware_250306.bin"
        let components = selectedLine.components(separatedBy: ",")
        guard components.count >= 2,
              let firmwareFileName = components[1].trimmingCharacters(in: .whitespacesAndNewlines) as String? else {
            throw FirmwareError.invalidResponse
        }
        
        // Download the firmware binary
        let firmwareUrlString = "https://assets.openterface.com/openterface/firmware/\(firmwareFileName)"
        guard let firmwareUrl = URL(string: firmwareUrlString) else {
            throw FirmwareError.invalidURL
        }
        
        logger.log(content: "Downloading firmware from: \(firmwareUrlString)")
        let (firmwareData, response) = try await URLSession.shared.data(from: firmwareUrl)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw FirmwareError.downloadFailed(httpResponse.statusCode)
        }
        
        logger.log(content: "Firmware downloaded successfully, size: \(firmwareData.count) bytes")
        return firmwareData
    }
    
    /// Fetches the latest firmware version information from the remote server
    /// Selects the appropriate version based on current chipset type
    func fetchLatestFirmwareVersion() async -> String {
        guard let url = URL(string: "https://assets.openterface.com/openterface/firmware/minikvm_latest_firmware2.txt") else {
            logger.log(content: "Invalid firmware info URL")
            return "Unknown"
        }
        
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(from: url)
            
            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    logger.log(content: "Failed to fetch firmware version: HTTP \(httpResponse.statusCode)")
                    return "Unknown"
                }
            }
            
            guard let responseString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                logger.log(content: "Failed to decode firmware info response")
                return "Unknown"
            }
            
            logger.log(content: "Firmware info response: \(responseString)")
            
            // Parse the firmware info based on chipset type
            // Format: "25022713,Openterface_Firmware_250306.bin" for MS2109
            //         "25052210,Openterface_Firmware_2130s_250522.bin,2130s" for MS2130S
            let lines = responseString.components(separatedBy: .newlines)
            var selectedLine: String?
            
            // Select the appropriate line based on current chipset
            switch AppStatus.videoChipsetType {
            case .ms2130s:
                // Look for line containing "2130s"
                selectedLine = lines.first { line in
                    line.contains("2130s")
                }
            default:
                // For MS2109 and MS2109S, use the first line without chipset suffix
                selectedLine = lines.first { line in
                    !line.contains("2130s")
                }
            }
            
            guard let selectedLine = selectedLine else {
                logger.log(content: "Failed to find suitable firmware for current chipset")
                return "Unknown"
            }
            
            // Extract version number before the comma
            let components = selectedLine.components(separatedBy: ",")
            if let versionString = components.first, !versionString.isEmpty {
                logger.log(content: "Latest firmware version: \(versionString)")
                return versionString
            } else {
                logger.log(content: "Failed to parse firmware version from response")
                return "Unknown"
            }
        } catch {
            logger.log(content: "Failed to fetch latest firmware version: \(error.localizedDescription)")
            return "Unknown"
        }
    }
    
    /// Reads the current firmware version from the device
    func getCurrentFirmwareVersion() -> String {
        logger.log(content: "Reading current firmware version from device...")
        return hidManager.getVersion() ?? "Unknown"
    }
    
    // MARK: - EEPROM Writing
    
    func loadFirmwareToEeprom() async {
        logger.log(content: "Starting firmware update process")
        
        DispatchQueue.main.async {
            self.isUpdateInProgress = true
            self.updateProgress = 0.0
            self.updateStatus = "Downloading firmware..."
        }
        
        do {
            // Download firmware
            let firmwareData = try await downloadLatestFirmware()
            
            DispatchQueue.main.async {
                self.updateStatus = "Preparing to write firmware to EEPROM..."
                self.updateProgress = 0.1
            }
            
            // Write firmware to EEPROM
            let success = await writeEeprom(address: eepromStartAddress, data: firmwareData)
            
            // Signal completion
            DispatchQueue.main.async {
                self.isUpdateInProgress = false
                self.firmwareWriteCompleteSubject.send(success)
            }
            
        } catch {
            logger.log(content: "Firmware update failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isUpdateInProgress = false
                self.updateStatus = "Firmware update failed: \(error.localizedDescription)"
                self.firmwareWriteCompleteSubject.send(false)
            }
        }
    }
    
    private func writeEeprom(address: UInt16, data: Data) async -> Bool {
        logger.log(content: "Writing \(data.count) bytes to EEPROM starting at address 0x\(String(format: "%04X", address))")
        
        // Use HID commands for EEPROM writing with progress tracking
        let success = hidManager.writeEeprom(address: address, data: data, progressCallback: { progress in
            // Update the progress on main thread
            DispatchQueue.main.async {
                // Map the EEPROM write progress (0.1 to 1.0 of overall progress)
                // 0.1 is the initial progress from download, 0.9 is for EEPROM write
                let overallProgress = 0.1 + (progress * 0.9)
                self.updateProgress = overallProgress
                
                let progressPercent = Int(overallProgress * 100)
                self.updateStatus = "Writing firmware to EEPROM... \(progressPercent)%"
                self.firmwareWriteProgressSubject.send(progressPercent)
            }
        })
        
        if success {
            logger.log(content: "EEPROM write completed successfully")
        } else {
            logger.log(content: "EEPROM write failed")
        }
        
        return success
    }
    
    /// Public method to write firmware data to EEPROM with progress tracking
    /// This method is called from the View layer and handles progress updates
    func writeFirmwareToEeprom(_ data: Data) async -> Bool {
        logger.log(content: "Writing \(data.count) bytes to EEPROM using HID commands...")
        
        // Update progress to show start of EEPROM write
        await MainActor.run {
            self.updateProgress = 0.4
            self.updateStatus = "Installing firmware to EEPROM..."
        }
        
        // Use the internal writeEeprom method with progress tracking
        return await writeEeprom(address: 0x0000, data: data)
    }
    
    // MARK: - Firmware Backup
    
    /// Backup firmware from device to file
    /// - Parameter backupURL: The URL where to save the backup
    func backupFirmware(to backupURL: URL) async {
        logger.log(content: "Starting firmware backup process")
        
        await MainActor.run {
            isBackupInProgress = true
            backupProgress = 0.0
            backupStatus = "Determining firmware size..."
        }
        
        // First, try to determine the actual firmware size
        let firmwareSize = await determineFirmwareSize()
        
        await MainActor.run {
            backupStatus = "Reading \(firmwareSize) bytes of firmware from device..."
        }
        
        let firmwareStartAddress: UInt16 = 0x0000 // Start from beginning of EEPROM
        
        // Read firmware data from EEPROM using the HIDManager
        let allFirmwareData = await readFirmwareData(
            startAddress: firmwareStartAddress,
            totalSize: firmwareSize
        )
        
        guard let firmwareData = allFirmwareData else {
            await MainActor.run {
                isBackupInProgress = false
                let errorMessage = "Failed to read firmware from device. Please ensure the device is properly connected."
                firmwareBackupCompleteSubject.send((false, errorMessage))
            }
            return
        }
        
        await MainActor.run {
            backupStatus = "Verifying firmware checksums..."
        }
        
        // Verify firmware checksums
        let checksumResult = await verifyFirmwareChecksums(firmwareData: firmwareData)
        
        await MainActor.run {
            backupStatus = "Saving backup file..."
        }
        
        // Save firmware data to the selected file location
        let success = await saveFirmwareBackup(data: firmwareData, to: backupURL)
        
        await MainActor.run {
            isBackupInProgress = false
            if success {
                let checksumStatus = checksumResult.isValid ? "✅ Verified" : "⚠ Invalid"
                let message = "Firmware backup completed successfully!\n\nFile saved as: \(backupURL.lastPathComponent)\nSize: \(firmwareData.count) bytes\nLocation: \(backupURL.deletingLastPathComponent().path)\n\nChecksum Status: \(checksumStatus)\n\(checksumResult.message)"
                firmwareBackupCompleteSubject.send((true, message))
            } else {
                let message = "Failed to save firmware backup file. Please check permissions and try again."
                firmwareBackupCompleteSubject.send((false, message))
            }
        }
    }
    
    /// Determines the actual firmware size by reading the EEPROM header
    /// Based on the MS2109 firmware structure documented in the README
    private func determineFirmwareSize() async -> Int {
        // Read the firmware header (first 16 bytes) to check signature and get code size
        guard let headerData = hidManager.readEeprom(address: 0x0000, length: 16) else {
            logger.log(content: "⚠ Failed to read firmware header, using default size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        // Check for valid MS2109 firmware signature (bytes 0x00-0x01 should be A5 5A)
        guard headerData.count >= 4 && headerData[0] == 0xA5 && headerData[1] == 0x5A else {
            logger.log(content: "⚠ Invalid firmware signature: \(String(format: "%02X %02X", headerData[0], headerData[1])) (expected: A5 5A)")
            logger.log(content: "Using default firmware size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        // Extract code size from bytes 2-3 (big-endian format)
        let codeSize = (Int(headerData[2]) << 8) | Int(headerData[3])
        
        // Total firmware size = Code size + 52 bytes
        // 52 bytes = 48 bytes (header + config sections 0x00-0x2F) + 4 bytes (checksums)
        let totalFirmwareSize = codeSize + 52
        
        // Sanity check: firmware should be reasonable size (between 1000 and 2048 bytes)
        if totalFirmwareSize < 1000 || totalFirmwareSize > 2048 {
            logger.log(content: "⚠ Detected firmware size \(totalFirmwareSize) seems unreasonable, using default")
            return defaultFirmwareSize
        }
        
        logger.log(content: "✓ Valid MS2109 firmware signature detected")
        logger.log(content: "Code size: \(codeSize) bytes (0x\(String(format: "%04X", codeSize)))")
        logger.log(content: "Total firmware size: \(totalFirmwareSize) bytes (0x\(String(format: "%04X", totalFirmwareSize)))")
        
        return totalFirmwareSize
    }
    
    /// Reads firmware data from EEPROM in chunks with progress updates and retry logic
    private func readFirmwareData(startAddress: UInt16, totalSize: Int) async -> Data? {
        var allFirmwareData = Data()
        var currentAddress = startAddress
        var remainingBytes = totalSize
        let maxRetries = 3
        
        logger.log(content: "Starting firmware read: \(totalSize) bytes from address 0x\(String(format: "%04X", startAddress))")
        
        while remainingBytes > 0 {
            let chunkSize = min(16, remainingBytes) // Max UInt8 value
            var retryCount = 0
            var chunkData: Data? = nil
            
            // Retry logic for each chunk
            while retryCount < maxRetries && chunkData == nil {
                if retryCount > 0 {
                    logger.log(content: "Retrying read at address 0x\(String(format: "%04X", currentAddress)), attempt \(retryCount + 1)/\(maxRetries)")
                    // Add longer delay before retry
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
                
                chunkData = hidManager.readEeprom(address: currentAddress, length: UInt8(chunkSize))
                
                if chunkData == nil {
                    retryCount += 1
                    logger.log(content: "Failed to read chunk at address 0x\(String(format: "%04X", currentAddress)), retry \(retryCount)/\(maxRetries)")
                }
            }
            
            guard let validChunkData = chunkData else {
                logger.log(content: "Failed to read firmware from device at address 0x\(String(format: "%04X", currentAddress)) after \(maxRetries) retries")
                return nil
            }
            
            allFirmwareData.append(validChunkData)
            currentAddress += UInt16(validChunkData.count)
            remainingBytes -= validChunkData.count
            
            // Update progress
            let currentDataCount = allFirmwareData.count
            let progress = Double(currentDataCount) / Double(totalSize)
            await MainActor.run {
                backupProgress = progress
                backupStatus = "Reading firmware... \(Int(progress * 100))% (\(currentDataCount)/\(totalSize) bytes)"
            }
            
            // Add small delay between chunks for device stability
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        logger.log(content: "Firmware read completed successfully: \(allFirmwareData.count) bytes")
        return allFirmwareData
    }
    
    /// Save firmware backup to file
    private func saveFirmwareBackup(data: Data, to url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    try data.write(to: url)
                    self.logger.log(content: "Firmware backup saved to: \(url.path)")
                    continuation.resume(returning: true)
                } catch {
                    self.logger.log(content: "Failed to save firmware backup: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Verifies firmware checksums based on MS2109 specification
    /// - Parameter firmwareData: The firmware data to verify
    /// - Returns: Tuple indicating if checksums are valid and additional info
    private func verifyFirmwareChecksums(firmwareData: Data) async -> (isValid: Bool, message: String) {
        guard firmwareData.count >= 4 else {
            let message = "⚠ Firmware too small for checksum verification (\(firmwareData.count) bytes)"
            logger.log(content: message)
            return (false, message)
        }
        
        // Extract checksums from last 4 bytes
        // MS2109 firmware format: last 4 bytes are [HeaderChecksum_MSB, HeaderChecksum_LSB, CodeChecksum_MSB, CodeChecksum_LSB]
        let checksumOffset = firmwareData.count - 4
        let headerChecksumMSB = UInt16(firmwareData[checksumOffset])
        let headerChecksumLSB = UInt16(firmwareData[checksumOffset + 1])
        let codeChecksumMSB = UInt16(firmwareData[checksumOffset + 2])
        let codeChecksumLSB = UInt16(firmwareData[checksumOffset + 3])
        
        // MS2109 uses big-endian format for checksums (MSB first, then LSB)
        let storedHeaderChecksum = (headerChecksumMSB << 8) | headerChecksumLSB
        let storedCodeChecksum = (codeChecksumMSB << 8) | codeChecksumLSB
        
        // Debug: Log the raw checksum bytes
        let checksumBytes = firmwareData.suffix(4)
        logger.log(content: "🔍 Last 4 checksum bytes: \(checksumBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        logger.log(content: "🔍 Checksum parsing (big-endian):")
        logger.log(content: "   Header MSB[0]: 0x\(String(format: "%02X", firmwareData[checksumOffset])), LSB[1]: 0x\(String(format: "%02X", firmwareData[checksumOffset+1]))")
        logger.log(content: "   Code MSB[2]: 0x\(String(format: "%02X", firmwareData[checksumOffset+2])), LSB[3]: 0x\(String(format: "%02X", firmwareData[checksumOffset+3]))")
        
        logger.log(content: "Stored checksums - Header: 0x\(String(format: "%04X", storedHeaderChecksum)), Code: 0x\(String(format: "%04X", storedCodeChecksum))")
        
        // Calculate expected checksums
        let (calculatedHeaderChecksum, calculatedCodeChecksum) = calculateMS2109Checksums(firmwareData: firmwareData)
        
        logger.log(content: "Calculated checksums - Header: 0x\(String(format: "%04X", calculatedHeaderChecksum)), Code: 0x\(String(format: "%04X", calculatedCodeChecksum))")
        
        let headerValid = storedHeaderChecksum == calculatedHeaderChecksum
        let codeValid = storedCodeChecksum == calculatedCodeChecksum
        
        var message: String
        if headerValid && codeValid {
            message = "✅ Firmware checksums are valid\nHeader: 0x\(String(format: "%04X", storedHeaderChecksum)) ✓\nCode: 0x\(String(format: "%04X", storedCodeChecksum)) ✓"
            logger.log(content: "✅ All firmware checksums verified successfully")
        } else {
            var details: [String] = []
            if !headerValid {
                details.append("Header: 0x\(String(format: "%04X", storedHeaderChecksum)) ≠ 0x\(String(format: "%04X", calculatedHeaderChecksum))")
            } else {
                details.append("Header: 0x\(String(format: "%04X", storedHeaderChecksum)) ✓")
            }
            if !codeValid {
                details.append("Code: 0x\(String(format: "%04X", storedCodeChecksum)) ≠ 0x\(String(format: "%04X", calculatedCodeChecksum))")
            } else {
                details.append("Code: 0x\(String(format: "%04X", storedCodeChecksum)) ✓")
            }
            message = "❌ Firmware checksum mismatch detected\n\(details.joined(separator: "\n"))"
            logger.log(content: "❌ Firmware checksum verification failed")
        }
        
        return (headerValid && codeValid, message)
    }
    
    /// Calculates MS2109 firmware checksums based on the Python reference implementation
    /// MS2109 checksum format: Simple 16-bit sum of bytes, header excludes signature bytes
    /// - Parameter firmwareData: The firmware data to calculate checksums for
    /// - Returns: Tuple of (headerChecksum, codeChecksum)
    private func calculateMS2109Checksums(firmwareData: Data) -> (headerChecksum: UInt16, codeChecksum: UInt16) {
        guard firmwareData.count >= 52 else {
            logger.log(content: "⚠ Firmware too small for checksum calculation")
            return (0, 0)
        }
        
        // Debug: Log first 16 bytes to verify data integrity
        let first16Bytes = firmwareData.prefix(16)
        logger.log(content: "🔍 First 16 bytes of firmware: \(first16Bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Header checksum: Based on Python implementation for MS2109
        // Range: bytes 0x02-0x2F (from offset 2 to 47, total 46 bytes)
        // Excludes the first 2 signature bytes (A5 5A)
        var headerSum: UInt32 = 0
        
        // Sum bytes from 0x02 to 0x2F (46 bytes) - exclude signature bytes at 0x00-0x01
        for i in 2..<48 {
            if i < firmwareData.count {
                headerSum += UInt32(firmwareData[i])
                if i < 10 {
                    logger.log(content: "🔍 Header byte [0x\(String(format: "%02X", i))]: 0x\(String(format: "%02X", firmwareData[i])) (running sum: 0x\(String(format: "%08X", headerSum)))")
                }
            }
        }
        
        let headerChecksum = UInt16(headerSum & 0xFFFF)
        
        logger.log(content: "🔍 MS2109 Header checksum calculation:")
        logger.log(content: "   Range: 0x02-0x2F (46 bytes, excluding signature)")
        logger.log(content: "   Signature bytes [0x00-0x01]: 0x\(String(format: "%02X", firmwareData[0])) 0x\(String(format: "%02X", firmwareData[1])) (excluded)")
        logger.log(content: "   Sum: 0x\(String(format: "%08X", headerSum)) -> checksum: 0x\(String(format: "%04X", headerChecksum))")
        
        // Code checksum: Simple sum of code section (from byte 48 to end - 4 checksum bytes)
        var codeSum: UInt32 = 0
        let codeStart = 48
        let codeEnd = firmwareData.count - 4  // Exclude last 4 checksum bytes
        
        logger.log(content: "🔍 Code section range: 0x\(String(format: "%02X", codeStart)) to 0x\(String(format: "%02X", codeEnd-1)) (\(codeEnd - codeStart) bytes)")
        
        for i in codeStart..<codeEnd {
            if i < firmwareData.count {
                codeSum += UInt32(firmwareData[i])
            }
        }
        // Take only the lower 16 bits as the checksum
        let codeChecksum = UInt16(codeSum & 0xFFFF)
        
        // Debug: Log code section info
        logger.log(content: "🔍 Code sum calculation: sum=0x\(String(format: "%08X", codeSum)) -> checksum=0x\(String(format: "%04X", codeChecksum))")
        logger.log(content: "Checksum calculation - Header range: 0x02-0x2F (\(46) bytes), Code range: 0x\(String(format: "%02X", codeStart))-0x\(String(format: "%02X", codeEnd-1)) (\(codeEnd - codeStart) bytes)")
        
        return (headerChecksum, codeChecksum)
    }
    
    // MARK: - Firmware Restore
    
    func restoreFirmware(from fileURL: URL) async {
        logger.log(content: "Starting firmware restore process from file: \(fileURL.path)")
        
        await MainActor.run {
            isUpdateInProgress = true
            updateProgress = 0.0
            updateStatus = "Loading firmware file..."
        }
        
        do {
            // Read firmware data from file
            let firmwareData = try Data(contentsOf: fileURL)
            logger.log(content: "Loaded firmware file, size: \(firmwareData.count) bytes")
            
            await MainActor.run {
                updateProgress = 0.1
                updateStatus = "Validating firmware file..."
            }
            
            // Basic validation - check if file size is reasonable
            guard firmwareData.count > 100 && firmwareData.count < 10000 else {
                await MainActor.run {
                    updateStatus = "Invalid firmware file size"
                    isUpdateInProgress = false
                }
                firmwareWriteCompleteSubject.send(false)
                return
            }
            
            await MainActor.run {
                updateProgress = 0.2
                updateStatus = "Firmware file validated. Starting restore..."
            }
            
            // Write firmware to EEPROM
            let success = await writeEeprom(address: eepromStartAddress, data: firmwareData)
            
            await MainActor.run {
                isUpdateInProgress = false
                if success {
                    updateProgress = 1.0
                    updateStatus = "Firmware restore completed successfully!"
                    logger.log(content: "Firmware restore completed successfully")
                } else {
                    updateStatus = "Firmware restore failed!"
                    logger.log(content: "Firmware restore failed")
                }
            }
            
            firmwareWriteCompleteSubject.send(success)
            
        } catch {
            logger.log(content: "Error loading firmware file: \(error.localizedDescription)")
            await MainActor.run {
                updateStatus = "Failed to load firmware file: \(error.localizedDescription)"
                isUpdateInProgress = false
            }
            firmwareWriteCompleteSubject.send(false)
        }
    }
    
    // MARK: - EDID Name Management
    
    /// Read the current EDID monitor name from the device
    /// Based on MS2109Device.py get_edid_name() method
    /// - Returns: The current EDID name, or nil if failed to read
    func getEdidName() async -> String? {
        logger.log(content: "Reading EDID monitor name from device")
        
        // EDID name is at offset 0x0397 in the firmware (13 bytes)
        let edidNameAddress: UInt16 = 0x0397
        let nameLength: UInt8 = 13
        
        guard let nameData = hidManager.readEeprom(address: edidNameAddress, length: nameLength) else {
            logger.log(content: "Failed to read EDID name from device")
            return nil
        }
        
        // Decode the name (stop at newline 0x0A)
        var nameStr = ""
        for byte in nameData {
            if byte == 0x0A { // newline terminator
                break
            } else if byte >= 32 && byte <= 126 { // printable ASCII
                nameStr += String(Character(UnicodeScalar(byte)))
            } else {
                break
            }
        }
        
        logger.log(content: "Current EDID name: '\(nameStr)'")
        return nameStr.isEmpty ? nil : nameStr
    }
    
    /// Set the EDID monitor name and update firmware checksums
    /// Based on MS2109Device.py set_edid_name() method
    /// - Parameter name: The new EDID monitor name (max 13 characters)
    func setEdidName(_ name: String) async {
        logger.log(content: "Starting EDID name update process")
        
        // First stop all operations and close main window for clean EDID patching
        stopAllOperations()
        
        await MainActor.run {
            isEdidUpdateInProgress = true
            edidUpdateProgress = 0.0
            edidUpdateStatus = "Validating EDID name..."
        }
        
        // Validate name length
        guard name.count <= 13 else {
            await MainActor.run {
                isEdidUpdateInProgress = false
                let errorMessage = "EDID name must be 13 characters or less. Current length: \(name.count)"
                edidUpdateCompleteSubject.send((false, errorMessage))
            }
            return
        }
        
        // Validate ASCII characters
        guard name.allSatisfy({ $0.isASCII && $0.asciiValue! >= 32 && $0.asciiValue! <= 126 }) else {
            await MainActor.run {
                isEdidUpdateInProgress = false
                let errorMessage = "EDID name must contain only printable ASCII characters"
                edidUpdateCompleteSubject.send((false, errorMessage))
            }
            return
        }
        
        await MainActor.run {
            edidUpdateProgress = 0.1
            edidUpdateStatus = "Preparing EDID name data..."
        }
        
        let edidNameAddress: UInt16 = 0x0397
        let nameLength = 13
        
        // Create name data: pad name to 13 bytes with spaces, then add newline terminator
        var nameData = Data()
        let nameBytes = name.data(using: .ascii) ?? Data()
        nameData.append(nameBytes)
        
        // Pad with spaces and ensure newline terminator
        while nameData.count < nameLength - 1 {
            nameData.append(0x20) // space character
        }
        nameData.append(0x0A) // newline terminator
        
        // Ensure exactly 13 bytes
        if nameData.count > nameLength {
            nameData = nameData.prefix(nameLength)
        }
        
        await MainActor.run {
            edidUpdateProgress = 0.3
            edidUpdateStatus = "Writing EDID name to device..."
        }
        
        // Write the name data to EEPROM
        let writeSuccess = await writeEeprom(address: edidNameAddress, data: nameData)
        
        guard writeSuccess else {
            await MainActor.run {
                isEdidUpdateInProgress = false
                let errorMessage = "Failed to write EDID name to device EEPROM"
                edidUpdateCompleteSubject.send((false, errorMessage))
            }
            return
        }
        
        await MainActor.run {
            edidUpdateProgress = 0.7
            edidUpdateStatus = "Updating firmware checksums..."
        }
        
        // Update firmware checksums
        let checksumSuccess = await updateFirmwareChecksums()
        
        await MainActor.run {
            isEdidUpdateInProgress = false
            if checksumSuccess {
                edidUpdateProgress = 1.0
                edidUpdateStatus = "EDID name updated successfully!"
                let successMessage = """
                EDID monitor name has been updated to '\(name)'.
                
                IMPORTANT: To apply the changes, please follow these steps:
                1. Unplug ALL cables from the Openterface device
                2. Wait a few seconds
                3. Reconnect all cables to the device
                4. Close this application completely
                5. Restart the application
                
                The new monitor name will be visible after reconnection.
                """
                edidUpdateCompleteSubject.send((true, successMessage))
                logger.log(content: "EDID name update completed successfully")
            } else {
                let errorMessage = "EDID name was written but firmware checksum update failed. The device may not function properly."
                edidUpdateCompleteSubject.send((false, errorMessage))
                logger.log(content: "EDID name update failed during checksum update")
            }
        }
    }
    
    /// Update firmware header and code checksums after EDID modifications
    /// Based on MS2109Device.py _update_firmware_checksums() method
    /// - Returns: True if checksums were updated successfully, false otherwise
    private func updateFirmwareChecksums() async -> Bool {
        logger.log(content: "Updating firmware checksums after EDID modification")
        
        let firmwareSize = defaultFirmwareSize // 1453 bytes
        
        // Read the entire firmware in chunks (max 255 bytes per read)
        var completeFirmwareData = Data()
        var currentAddress: UInt16 = 0x0000
        let maxChunkSize: UInt8 = 255
        var remainingBytes = firmwareSize
        
        while remainingBytes > 0 {
            let chunkSize = UInt8(min(Int(maxChunkSize), remainingBytes))
            
            guard let chunk = hidManager.readEeprom(address: currentAddress, length: chunkSize) else {
                logger.log(content: "Failed to read firmware chunk at address 0x\(String(format: "%04X", currentAddress))")
                return false
            }
            
            completeFirmwareData.append(chunk)
            currentAddress += UInt16(chunk.count)
            remainingBytes -= chunk.count
        }
        
        logger.log(content: "Read \(completeFirmwareData.count) bytes of firmware for checksum calculation")
        
        // Calculate new checksums using the existing method
        let (headerChecksum, codeChecksum) = calculateMS2109Checksums(firmwareData: completeFirmwareData)
        
        // Update checksums in the last 4 bytes (big-endian format)
        let checksumAddress = UInt16(firmwareSize - 4)
        let headerBytes = [UInt8((headerChecksum >> 8) & 0xFF), UInt8(headerChecksum & 0xFF)]
        let codeBytes = [UInt8((codeChecksum >> 8) & 0xFF), UInt8(codeChecksum & 0xFF)]
        
        // Write the updated checksums
        let headerSuccess = await writeEeprom(address: checksumAddress, data: Data(headerBytes))
        let codeSuccess = await writeEeprom(address: checksumAddress + 2, data: Data(codeBytes))
        
        if headerSuccess && codeSuccess {
            logger.log(content: "Firmware header checksum updated to: 0x\(String(format: "%04X", headerChecksum))")
            logger.log(content: "Firmware code checksum updated to: 0x\(String(format: "%04X", codeChecksum))")
            return true
        } else {
            logger.log(content: "Failed to write updated checksums to firmware")
            return false
        }
    }

}
