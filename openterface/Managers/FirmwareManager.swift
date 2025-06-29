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

class FirmwareManager: ObservableObject {
    static let shared = FirmwareManager()
    
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
    
    private let chunkSize = 64 // EEPROM write chunk size
    private let eepromStartAddress: UInt16 = 0x0000 // Starting address for firmware
    private let defaultFirmwareSize = 1453 // Default MS2109 firmware size
    
    private init() {}
    
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
        
        // Parse format: "25022713,Openterface_Firmware_250306.bin"
        let components = infoString.components(separatedBy: ",")
        guard components.count >= 2,
              let firmwareFileName = components.last?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FirmwareError.invalidResponse
        }
        
        // Download the firmware binary
        let firmwareUrlString = "https://assets.openterface.com/openterface/firmware/\(firmwareFileName)"
        guard let firmwareUrl = URL(string: firmwareUrlString) else {
            throw FirmwareError.invalidURL
        }
        
        Logger.shared.log(content: "Downloading firmware from: \(firmwareUrlString)")
        let (firmwareData, response) = try await URLSession.shared.data(from: firmwareUrl)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw FirmwareError.downloadFailed(httpResponse.statusCode)
        }
        
        Logger.shared.log(content: "Firmware downloaded successfully, size: \(firmwareData.count) bytes")
        return firmwareData
    }
    
    // MARK: - EEPROM Writing
    
    func loadFirmwareToEeprom() async {
        Logger.shared.log(content: "Starting firmware update process")
        
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
            Logger.shared.log(content: "Firmware update failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isUpdateInProgress = false
                self.updateStatus = "Firmware update failed: \(error.localizedDescription)"
                self.firmwareWriteCompleteSubject.send(false)
            }
        }
    }
    
    private func writeEeprom(address: UInt16, data: Data) async -> Bool {
        Logger.shared.log(content: "Writing \(data.count) bytes to EEPROM starting at address 0x\(String(format: "%04X", address))")
        
        let totalSize = data.count
        
        // Use HID commands for EEPROM writing with progress tracking
        let hidManager = HIDManager.shared
        let success = hidManager.writeEeprom(address: address, data: data) { progress in
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
        }
        
        if success {
            Logger.shared.log(content: "EEPROM write completed successfully")
        } else {
            Logger.shared.log(content: "EEPROM write failed")
        }
        
        return success
    }
    
    // MARK: - Firmware Backup
    
    /// Backup firmware from device to file
    /// - Parameter backupURL: The URL where to save the backup
    func backupFirmware(to backupURL: URL) async {
        Logger.shared.log(content: "Starting firmware backup process")
        
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
        guard let headerData = HIDManager.shared.readEeprom(address: 0x0000, length: 16) else {
            Logger.shared.log(content: "⚠ Failed to read firmware header, using default size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        // Check for valid MS2109 firmware signature (bytes 0x00-0x01 should be A5 5A)
        guard headerData.count >= 4 && headerData[0] == 0xA5 && headerData[1] == 0x5A else {
            Logger.shared.log(content: "⚠ Invalid firmware signature: \(String(format: "%02X %02X", headerData[0], headerData[1])) (expected: A5 5A)")
            Logger.shared.log(content: "Using default firmware size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        // Extract code size from bytes 2-3 (big-endian format)
        let codeSize = (Int(headerData[2]) << 8) | Int(headerData[3])
        
        // Total firmware size = Code size + 52 bytes
        // 52 bytes = 48 bytes (header + config sections 0x00-0x2F) + 4 bytes (checksums)
        let totalFirmwareSize = codeSize + 52
        
        // Sanity check: firmware should be reasonable size (between 1000 and 2048 bytes)
        if totalFirmwareSize < 1000 || totalFirmwareSize > 2048 {
            Logger.shared.log(content: "⚠ Detected firmware size \(totalFirmwareSize) seems unreasonable, using default")
            return defaultFirmwareSize
        }
        
        Logger.shared.log(content: "✓ Valid MS2109 firmware signature detected")
        Logger.shared.log(content: "Code size: \(codeSize) bytes (0x\(String(format: "%04X", codeSize)))")
        Logger.shared.log(content: "Total firmware size: \(totalFirmwareSize) bytes (0x\(String(format: "%04X", totalFirmwareSize)))")
        
        return totalFirmwareSize
    }
    
    /// Reads firmware data from EEPROM in chunks with progress updates and retry logic
    private func readFirmwareData(startAddress: UInt16, totalSize: Int) async -> Data? {
        var allFirmwareData = Data()
        var currentAddress = startAddress
        var remainingBytes = totalSize
        let maxRetries = 3
        
        Logger.shared.log(content: "Starting firmware read: \(totalSize) bytes from address 0x\(String(format: "%04X", startAddress))")
        
        while remainingBytes > 0 {
            let chunkSize = min(16, remainingBytes) // Max UInt8 value
            var retryCount = 0
            var chunkData: Data? = nil
            
            // Retry logic for each chunk
            while retryCount < maxRetries && chunkData == nil {
                if retryCount > 0 {
                    Logger.shared.log(content: "Retrying read at address 0x\(String(format: "%04X", currentAddress)), attempt \(retryCount + 1)/\(maxRetries)")
                    // Add longer delay before retry
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
                
                chunkData = HIDManager.shared.readEeprom(address: currentAddress, length: UInt8(chunkSize))
                
                if chunkData == nil {
                    retryCount += 1
                    Logger.shared.log(content: "Failed to read chunk at address 0x\(String(format: "%04X", currentAddress)), retry \(retryCount)/\(maxRetries)")
                }
            }
            
            guard let validChunkData = chunkData else {
                Logger.shared.log(content: "Failed to read firmware from device at address 0x\(String(format: "%04X", currentAddress)) after \(maxRetries) retries")
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
        
        Logger.shared.log(content: "Firmware read completed successfully: \(allFirmwareData.count) bytes")
        return allFirmwareData
    }
    
    /// Save firmware backup to file
    private func saveFirmwareBackup(data: Data, to url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    try data.write(to: url)
                    Logger.shared.log(content: "Firmware backup saved to: \(url.path)")
                    continuation.resume(returning: true)
                } catch {
                    Logger.shared.log(content: "Failed to save firmware backup: \(error)")
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
            Logger.shared.log(content: message)
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
        Logger.shared.log(content: "🔍 Last 4 checksum bytes: \(checksumBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        Logger.shared.log(content: "🔍 Checksum parsing (big-endian):")
        Logger.shared.log(content: "   Header MSB[0]: 0x\(String(format: "%02X", firmwareData[checksumOffset])), LSB[1]: 0x\(String(format: "%02X", firmwareData[checksumOffset+1]))")
        Logger.shared.log(content: "   Code MSB[2]: 0x\(String(format: "%02X", firmwareData[checksumOffset+2])), LSB[3]: 0x\(String(format: "%02X", firmwareData[checksumOffset+3]))")
        
        Logger.shared.log(content: "Stored checksums - Header: 0x\(String(format: "%04X", storedHeaderChecksum)), Code: 0x\(String(format: "%04X", storedCodeChecksum))")
        
        // Calculate expected checksums
        let (calculatedHeaderChecksum, calculatedCodeChecksum) = calculateMS2109Checksums(firmwareData: firmwareData)
        
        Logger.shared.log(content: "Calculated checksums - Header: 0x\(String(format: "%04X", calculatedHeaderChecksum)), Code: 0x\(String(format: "%04X", calculatedCodeChecksum))")
        
        let headerValid = storedHeaderChecksum == calculatedHeaderChecksum
        let codeValid = storedCodeChecksum == calculatedCodeChecksum
        
        var message: String
        if headerValid && codeValid {
            message = "✅ Firmware checksums are valid\nHeader: 0x\(String(format: "%04X", storedHeaderChecksum)) ✓\nCode: 0x\(String(format: "%04X", storedCodeChecksum)) ✓"
            Logger.shared.log(content: "✅ All firmware checksums verified successfully")
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
            Logger.shared.log(content: "❌ Firmware checksum verification failed")
        }
        
        return (headerValid && codeValid, message)
    }
    
    /// Calculates MS2109 firmware checksums based on the specification
    /// MS2109 checksum format: Simple 16-bit sum of bytes (little-endian storage)
    /// - Parameter firmwareData: The firmware data to calculate checksums for
    /// - Returns: Tuple of (headerChecksum, codeChecksum)
    private func calculateMS2109Checksums(firmwareData: Data) -> (headerChecksum: UInt16, codeChecksum: UInt16) {
        guard firmwareData.count >= 52 else {
            Logger.shared.log(content: "⚠ Firmware too small for checksum calculation")
            return (0, 0)
        }
        
        // Debug: Log first 16 bytes to verify data integrity
        let first16Bytes = firmwareData.prefix(16)
        Logger.shared.log(content: "🔍 First 16 bytes of firmware: \(first16Bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        
        // Header checksum: Based on analysis, MS2109 uses range 0x00-0x2E (47 bytes)
        // The difference between full 48 bytes (0x17FD) and expected (0x16FE) is 0xFF
        // This confirms the last byte at 0x2F should be excluded
        
        var headerSum: UInt32 = 0
        let headerData = firmwareData.prefix(48)
        
        // Sum bytes 0x00-0x2E (47 bytes) - exclude the last header byte at 0x2F
        for i in 0..<47 {
            headerSum += UInt32(headerData[i])
            if i < 8 {
                Logger.shared.log(content: "🔍 Header byte [0x\(String(format: "%02X", i))]: 0x\(String(format: "%02X", headerData[i])) (running sum: 0x\(String(format: "%08X", headerSum)))")
            }
        }
        
        let headerChecksum = UInt16(headerSum & 0xFFFF)
        
        Logger.shared.log(content: "🔍 Header checksum calculation:")
        Logger.shared.log(content: "   Range: 0x00-0x2E (47 bytes)")
        Logger.shared.log(content: "   Excluded byte [0x2F]: 0x\(String(format: "%02X", headerData[47]))")
        Logger.shared.log(content: "   Sum: 0x\(String(format: "%08X", headerSum)) -> checksum: 0x\(String(format: "%04X", headerChecksum))")
        
        // Debug: Log header data in hex format for comparison
        let headerHex = headerData.map { String(format: "%02X", $0) }.joined(separator: " ")
        Logger.shared.log(content: "🔍 Header data (48 bytes): \(headerHex)")
        Logger.shared.log(content: "🔍 Header sum calculation: sum=0x\(String(format: "%08X", headerSum)) -> checksum=0x\(String(format: "%04X", headerChecksum))")
        
        // Code checksum: Simple sum of code section (from byte 48 to end - 4 checksum bytes)
        var codeSum: UInt32 = 0
        let codeStart = 48
        let codeEnd = firmwareData.count - 4  // Exclude last 4 checksum bytes
        
        Logger.shared.log(content: "🔍 Code section range: 0x\(String(format: "%02X", codeStart)) to 0x\(String(format: "%02X", codeEnd-1)) (\(codeEnd - codeStart) bytes)")
        
        for i in codeStart..<codeEnd {
            codeSum += UInt32(firmwareData[i])
        }
        // Take only the lower 16 bits as the checksum
        let codeChecksum = UInt16(codeSum & 0xFFFF)
        
        // Debug: Log code section info
        Logger.shared.log(content: "🔍 Code sum calculation: sum=0x\(String(format: "%08X", codeSum)) -> checksum=0x\(String(format: "%04X", codeChecksum))")
        Logger.shared.log(content: "Checksum calculation - Header range: 0x00-0x2F (\(48) bytes), Code range: 0x\(String(format: "%02X", codeStart))-0x\(String(format: "%02X", codeEnd-1)) (\(codeEnd - codeStart) bytes)")
        
        return (headerChecksum, codeChecksum)
    }
    
    // MARK: - Firmware Restore
    
    func restoreFirmware(from fileURL: URL) async {
        Logger.shared.log(content: "Starting firmware restore process from file: \(fileURL.path)")
        
        await MainActor.run {
            isUpdateInProgress = true
            updateProgress = 0.0
            updateStatus = "Loading firmware file..."
        }
        
        do {
            // Read firmware data from file
            let firmwareData = try Data(contentsOf: fileURL)
            Logger.shared.log(content: "Loaded firmware file, size: \(firmwareData.count) bytes")
            
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
                    Logger.shared.log(content: "Firmware restore completed successfully")
                } else {
                    updateStatus = "Firmware restore failed!"
                    Logger.shared.log(content: "Firmware restore failed")
                }
            }
            
            firmwareWriteCompleteSubject.send(success)
            
        } catch {
            Logger.shared.log(content: "Error loading firmware file: \(error.localizedDescription)")
            await MainActor.run {
                updateStatus = "Failed to load firmware file: \(error.localizedDescription)"
                isUpdateInProgress = false
            }
            firmwareWriteCompleteSubject.send(false)
        }
    }

}
