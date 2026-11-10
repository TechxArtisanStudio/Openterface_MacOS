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
    
    /// Cached EDID block offset, discovered by scanning the firmware image.
    /// Avoids re-reading the entire firmware on every EDID query.
    private var cachedEdidOffset: Int?

    /// Returns the default EDID block offset for known chip types.
    /// This allows skipping the full firmware scan on first access.
    private func defaultEdidOffset() -> Int? {
        let chipType = AppStatus.videoChipsetType
        switch chipType {
        case .ms2109:
            return 0x326
        case .ms2109s:
            return 0x2F4
        default:
            return nil
        }
    }
    
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

        // Pause HAL periodic updates to avoid I/O conflict with direct flash access
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        
        // Post notification asynchronously to avoid blocking
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("StopAllOperationsBeforeFirmwareUpdate"),
                object: nil
            )
            
            // Close main window
            let windows = NSApplication.shared.windows
            for window in windows {
                // Close/hide main content windows, but not auxiliary tool windows
                if let identifier = window.identifier?.rawValue {
                    if identifier.contains("main_openterface") || 
                       (!identifier.contains("edidNameWindow") &&
                        !identifier.contains("firmwareUpdateWindow") &&
                        window.contentViewController != nil &&
                        window.isVisible) {
                        logger.log(content: "✓ Closing/hiding main window: \(window.title)")
                        window.orderOut(nil) // Hide the window
                    }
                } else if window.title.contains("Openterface KVM") {
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
        //         "25022713,Openterface_Firmware_2109s_250306.bin,2109s" for MS2109S
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
        case .ms2109s:
            // Look for line containing "2109s"
            selectedLine = lines.first { line in
                line.contains("2109s")
            }
        default:
            // For MS2109, use the line without a chipset suffix
            selectedLine = lines.first { line in
                !line.contains("2130s") && !line.contains("2109s")
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
        let urlString = "https://assets.openterface.com/openterface/firmware/minikvm_latest_firmware2.txt"
        guard let url = URL(string: urlString) else {
            logger.log(content: "Invalid firmware info URL: \(urlString)")
            return "Unknown"
        }

        logger.log(content: "Fetching firmware version from: \(urlString)")
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                logger.log(content: "HTTP response status: \(httpResponse.statusCode), contentLength: \(data.count) bytes")
                if httpResponse.statusCode != 200 {
                    let headers = httpResponse.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                    logger.log(content: "Headers: \(headers)")
                    logger.log(content: "Failed to fetch firmware version: HTTP \(httpResponse.statusCode)")
                    return "Unknown"
                }
            } else {
                logger.log(content: "Response is not an HTTPURLResponse (unexpected). Data length: \(data.count)")
            }

            guard let responseString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                logger.log(content: "Failed to decode firmware info response. First 16 bytes (hex): \(data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
                return "Unknown"
            }

            logger.log(content: "Firmware info response (\(responseString.count) chars): \(responseString)")

            // Parse the firmware info based on chipset type
            // Format: "25022713,Openterface_Firmware_250306.bin" for MS2109
            //         "25022713,Openterface_Firmware_2109s_250306.bin,2109s" for MS2109S
            //         "25052210,Openterface_Firmware_2130s_250522.bin,2130s" for MS2130S
            let lines = responseString.components(separatedBy: .newlines)
            logger.log(content: "Response contains \(lines.count) line(s)")
            var selectedLine: String?

            // Select the appropriate line based on current chipset
            switch AppStatus.videoChipsetType {
            case .ms2130s:
                logger.log(content: "Selecting firmware for chipset: ms2130s")
                // Look for line containing "2130s"
                selectedLine = lines.first { line in
                    line.contains("2130s")
                }
            case .ms2109s:
                logger.log(content: "Selecting firmware for chipset: ms2109s")
                // Look for line containing "2109s"
                selectedLine = lines.first { line in
                    line.contains("2109s")
                }
            default:
                logger.log(content: "Selecting firmware for chipset: ms2109 (no suffix)")
                // For MS2109, use the line without a chipset suffix
                selectedLine = lines.first { line in
                    !line.contains("2130s") && !line.contains("2109s")
                }
            }

            guard let selectedLine = selectedLine else {
                logger.log(content: "Failed to find suitable firmware for current chipset. Lines: \(lines)")
                return "Unknown"
            }

            logger.log(content: "Selected line: \(selectedLine)")

            // Extract version number before the comma
            let components = selectedLine.components(separatedBy: ",")
            if let versionString = components.first, !versionString.isEmpty {
                logger.log(content: "Latest firmware version: \(versionString)")
                return versionString
            } else {
                logger.log(content: "Failed to parse firmware version from response. Components: \(components)")
                return "Unknown"
            }
        } catch let error as URLError {
            // Deep diagnostics for URLError — surfaced only in the catch path
            logger.log(content: "❌ fetchLatestFirmwareVersion URLError code: \(error.code.rawValue) (\(error.code.rawValue.description))")
            logger.log(content: "❌ Localized: \(error.localizedDescription)")
            logger.log(content: "❌ Failure url string: \(error.failureURLString ?? "nil")")
            logger.log(content: "❌ User info keys: \(error.userInfo.keys.joined(separator: ", "))")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
                logger.log(content: "❌ Underlying error: \(underlying.localizedDescription)")
            }
            if let peerChain = error.userInfo["NSErrorPeerCertificateChain"] as? [SecCertificate] {
                for (i, cert) in peerChain.enumerated() {
                    let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? "<unknown subject>"
                    logger.log(content: "❌ Peer cert [\(i)]: \(subject)")
                }
            }
            if let trust = error.userInfo["NSErrorPeerTrust"] {
                // 'as? SecTrust' is a no-op — SecTrust is an always-bridged CF type.
                // Call SecTrustEvaluateWithError directly to surface whether the chain validates.
                let trusted = SecTrustEvaluateWithError(trust as! SecTrust, nil)
                logger.log(content: "❌ Peer trust available — SecTrustEvaluateWithError: \(trusted ? "trusted" : "FAILED")")
            }
            // Inspect underlying CFNetwork error if any
            let nsError = error as NSError
            logger.log(content: "❌ NSError domain='\(nsError.domain)' code=\(nsError.code)")
            if let cfInfo = nsError.userInfo as? [String: Any] {
                for (k, v) in cfInfo {
                    logger.log(content: "   userInfo[\(k)] = \(v)")
                }
            }
            logger.log(content: "Failed to fetch latest firmware version: \(error.localizedDescription)")
            return "Unknown"
        } catch {
            logger.log(content: "❌ fetchLatestFirmwareVersion unexpected error type=\(type(of: error)), \(error.localizedDescription)")
            logger.log(content: "❌ Full error: \(error)")
            logger.log(content: "Failed to fetch latest firmware version: \(error.localizedDescription)")
            return "Unknown"
        }
    }
    
    /// Reads the current firmware version from the device
    func getCurrentFirmwareVersion() -> String {
        logger.log(content: "Reading current firmware version from device...")
        if AppStatus.videoChipsetType == .ms2130s {
            return MS2130SFlashManager.shared.getVersion() ?? "Unknown"
        }
        return hidManager.getVersion() ?? "Unknown"
    }

    // Direct protocol wrappers for external firmware operations
    func flashExternalFirmware(_ data: Data) async throws -> Bool {
        logger.log(content: "FirmwareManager: flashExternalFirmware start, size=\(data.count)")
        let success = await MS2130SFlashManager.shared.flashFirmware(data, progressCallback: { phase, pct in
            Task { @MainActor in
                self.updateStatus = phase
                self.updateProgress = pct
            }
        })
        logger.log(content: "FirmwareManager: flashExternalFirmware result=\(success)")
        if !success {
            throw NSError(domain: "Firmware", code: -1, userInfo: [NSLocalizedDescriptionKey: "MS2130S flash firmware failed"])
        }
        return success
    }

    func backupExternalFirmware(to url: URL, withTotalSize size: Int) async throws -> Bool {
        let success = await MS2130SFlashManager.shared.backupFirmware(totalSize: size, to: url, progressCallback: { phase, pct in
            Task { @MainActor in
                self.backupStatus = phase
                self.backupProgress = pct
            }
        })
        if !success { throw NSError(domain: "Firmware", code: -1, userInfo: [NSLocalizedDescriptionKey: "MS2130S backup firmware failed"]) }
        return success
    }

    func restoreExternalFirmware(from url: URL) async throws -> Bool {
        let success = await MS2130SFlashManager.shared.restoreFirmware(from: url, progressCallback: { phase, pct in
            Task { @MainActor in
                self.updateStatus = phase
                self.updateProgress = pct
            }
        })
        if !success { throw NSError(domain: "Firmware", code: -1, userInfo: [NSLocalizedDescriptionKey: "MS2130S restore firmware failed"]) }
        return success
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
            
            // Write firmware to target device
            let success: Bool
            if AppStatus.videoChipsetType == .ms2130s {
                success = await MS2130SFlashManager.shared.flashFirmware(firmwareData, progressCallback: { phaseProgress, phaseValue in
                    DispatchQueue.main.async {
                        let overall = 0.1 + (phaseValue * 0.9)
                        self.updateProgress = overall
                        self.updateStatus = phaseProgress
                        self.firmwareWriteProgressSubject.send(Int(overall*100))
                    }
                })
            } else {
                success = await writeEeprom(address: eepromStartAddress, data: firmwareData)
            }
            
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
        logger.log(content: "Writing \(data.count) bytes to device firmware using HID commands...")

        await MainActor.run {
            self.updateProgress = 0.4
            self.updateStatus = "Installing firmware..."
        }

        if AppStatus.videoChipsetType == .ms2130s {
            return await MS2130SFlashManager.shared.flashFirmware(data, progressCallback: { phase, pct in
                Task { @MainActor in
                    self.updateProgress = 0.4 + 0.6 * pct
                    self.updateStatus = phase
                }
            })
        }

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

        if AppStatus.videoChipsetType == .ms2130s {
            let defaultSize = 1024 * 1024 // fallback to 1MB
            await MainActor.run {
                self.backupStatus = "Reading \(defaultSize) bytes of firmware from MS2130S..."
            }

            let success = await MS2130SFlashManager.shared.backupFirmware(totalSize: defaultSize, to: backupURL, progressCallback: { step, pct in
                Task { @MainActor in
                    self.backupProgress = pct
                    self.backupStatus = step
                }
            })

            await MainActor.run {
                isBackupInProgress = false
            }

            let message = success ? "MS2130S firmware backup succeeded" : "MS2130S firmware backup failed"
            firmwareBackupCompleteSubject.send((success, message))
            return
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
                let message = "Firmware backup completed successfully!\n\nFile saved as: \(backupURL.lastPathComponent)\nSize: \(firmwareData.count) bytes\nLocation: \(backupURL.deletingLastPathComponent().path)\n\nChecksum Status:\n\(checksumStatus)\n\(checksumResult.message)"
                firmwareBackupCompleteSubject.send((true, message))
            } else {
                let message = "Failed to save firmware backup file. Please check permissions and try again."
                firmwareBackupCompleteSubject.send((false, message))
            }
        }
    }
    
    /// Parsed EEPROM firmware header. MS2109 and MS2109S images share the same
    /// layout except for the byte order of the 2-byte signature.
    private struct FirmwareHeader {
        let family: String
        let codeSize: Int

        /// 52 bytes = 48-byte header/config section (0x00-0x2F) + 4-byte checksums
        var totalSize: Int { codeSize + 52 }
    }

    /// MS2109 images start with `A5 5A`, MS2109S images with `5A A5`.
    /// Both store the code size big-endian at bytes 2-3.
    private func parseFirmwareHeader(_ header: Data) -> FirmwareHeader? {
        guard header.count >= 4 else { return nil }

        let family: String
        if header[0] == 0xA5 && header[1] == 0x5A {
            family = "MS2109"
        } else if header[0] == 0x5A && header[1] == 0xA5 {
            family = "MS2109S"
        } else {
            return nil
        }

        let codeSize = (Int(header[2]) << 8) | Int(header[3])
        let totalSize = codeSize + 52
        guard totalSize >= 256 && totalSize <= 8192 else { return nil }

        return FirmwareHeader(family: family, codeSize: codeSize)
    }

    /// Determines the actual firmware size by reading the EEPROM header
    /// Based on the MS2109/MS2109S firmware structure documented in the README
    private func determineFirmwareSize() async -> Int {
        // Read the firmware header (first 16 bytes) to check signature and get code size
        guard let headerData = hidManager.readEeprom(address: 0x0000, length: 16) else {
            logger.log(content: "⚠ Failed to read firmware header, using default size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        guard let header = parseFirmwareHeader(headerData) else {
            logger.log(content: "⚠ Unrecognized firmware signature: \(headerData.map { String(format: "%02X", $0) }.joined(separator: " "))")
            logger.log(content: "Using default firmware size: \(defaultFirmwareSize) bytes")
            return defaultFirmwareSize
        }
        
        logger.log(content: "✓ \(header.family) firmware signature detected")
        logger.log(content: "Code size: \(header.codeSize) bytes (0x\(String(format: "%04X", header.codeSize)))")
        logger.log(content: "Total firmware size: \(header.totalSize) bytes (0x\(String(format: "%04X", header.totalSize)))")
        
        return header.totalSize
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
        // Excludes the first 2 signature bytes (5A A5 on MS2109S, A5 5A on MS2109)
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
            
            // Write firmware to EEPROM or external flash
            let success: Bool
            if AppStatus.videoChipsetType == .ms2130s {
                success = await MS2130SFlashManager.shared.flashFirmware(firmwareData, progressCallback: { phase, pct in
                    Task { @MainActor in
                        self.updateProgress = 0.2 + pct * 0.8
                        self.updateStatus = phase
                    }
                })
            } else {
                success = await writeEeprom(address: eepromStartAddress, data: firmwareData)
            }
            
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
    
    /// Read the current EDID display name from the device
    /// - Returns: The current EDID name, or nil if failed to read
    func getEdidName() async -> String? {
        await readEdidIdentity()?.displayName
    }

    /// Read and parse the EDID identity from the device.
    /// Uses chip-type preset or cached EDID offset to read only 128 bytes.
    /// - Returns: Parsed identity, or nil if the read or parse failed
    func readEdidIdentity() async -> EdidIdentity? {
        logger.log(content: "Reading EDID identity from device")

        // Determine EDID offset: cached > chip preset > full scan
        let offset: Int
        if let cached = cachedEdidOffset {
            offset = cached
            logger.log(content: "Using cached EDID offset 0x\(String(format: "%04X", offset))")
        } else if let preset = defaultEdidOffset() {
            offset = preset
            logger.log(content: "Using chip-preset EDID offset 0x\(String(format: "%04X", offset))")
        } else {
            // Unknown chip type: must scan entire firmware
            guard let image = await readFirmwareImage() else {
                logger.log(content: "Failed to read firmware image for EDID info")
                return nil
            }
            guard let identity = EdidCodec.identity(from: image) else {
                logger.log(content: "No valid EDID block found in firmware image")
                return nil
            }
            cachedEdidOffset = identity.edidOffset
            logger.log(content: "Cached EDID offset 0x\(String(format: "%04X", identity.edidOffset))")
            logger.log(content: "EDID identity: \(identity.summary)")
            return identity
        }

        // Fast path: read only the EDID block (128 bytes)
        guard let blockData = hidManager.readEeprom(address: UInt16(offset), length: 128) else {
            logger.log(content: "Failed to read EDID block at offset 0x\(String(format: "%04X", offset))")
            cachedEdidOffset = nil
            return nil
        }

        // Construct a minimal image with just the EDID block at the correct offset
        var minimalImage = Data(count: offset)
        minimalImage.append(blockData)
        while minimalImage.count < offset + 128 {
            minimalImage.append(0)
        }

        guard let identity = EdidCodec.identity(from: minimalImage) else {
            logger.log(content: "No valid EDID block found at offset 0x\(String(format: "%04X", offset))")
            cachedEdidOffset = nil
            return nil
        }

        cachedEdidOffset = offset
        logger.log(content: "EDID identity: \(identity.summary)")
        return identity
    }

    /// Read the entire firmware image, sizing it from the header.
    /// Works for both MS2109 (`A5 5A`) and MS2109S (`5A A5`) images.
    private func readFirmwareImage() async -> Data? {
        let maxRetries = 3

        var headerData: Data?
        for attempt in 0..<maxRetries {
            headerData = hidManager.readEeprom(address: eepromStartAddress, length: 16)
            if headerData != nil { break }
            if attempt < maxRetries - 1 {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        guard var image = headerData, let header = parseFirmwareHeader(image) else {
            logger.log(content: "⚠ Failed to read a recognized MS2109/MS2109S firmware header")
            return nil
        }

        let totalSize = header.totalSize
        logger.log(content: "Reading \(header.family) firmware image: \(totalSize) bytes")

        var address = eepromStartAddress + UInt16(image.count)
        var remaining = totalSize - image.count

        while remaining > 0 {
            let chunkLength = UInt8(min(16, remaining))
            var chunk: Data?
            for attempt in 0..<maxRetries {
                chunk = hidManager.readEeprom(address: address, length: chunkLength)
                if chunk != nil { break }
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }

            guard let chunk else {
                logger.log(content: "Failed to read firmware chunk at address 0x\(String(format: "%04X", address)) after \(maxRetries) attempts")
                return nil
            }
            image.append(chunk)
            address += UInt16(chunk.count)
            remaining -= chunk.count
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        logger.log(content: "Read firmware image: \(image.count) bytes")
        return image
    }
    
    /// Set the EDID monitor name and update checksums
    /// Uses differential checksum update: only writes the modified EDID block (128 bytes)
    /// and updated code checksum (2 bytes), instead of the entire firmware image.
    /// - Parameters:
    ///   - name: The new EDID monitor name (max 12 ASCII characters)
    ///   - stopAllOperations: Stops video/audio and hides windows for a clean update.
    ///     Callers that manage device quiescing themselves (e.g. MCP, which only
    ///     pauses HAL polling) pass false so the app is not terminated by hiding
    ///     its last window.
    func setEdidName(_ name: String, stopAllOperations: Bool = true) async {
        logger.log(content: "Starting EDID name update process (differential write)")

        if stopAllOperations {
            self.stopAllOperations()
            // Wait for async cleanup to complete
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        await MainActor.run {
            isEdidUpdateInProgress = true
            edidUpdateProgress = 0.0
            edidUpdateStatus = "Validating EDID name..."
        }

        guard !name.isEmpty, name.count <= 12 else {
            finishEdidUpdate(success: false, message: "EDID name must be 1-12 characters. Current length: \(name.count)")
            return
        }

        guard name.allSatisfy({ $0.isASCII && $0.asciiValue! >= 32 && $0.asciiValue! <= 126 }) else {
            finishEdidUpdate(success: false, message: "EDID name must contain only printable ASCII characters")
            return
        }

        await MainActor.run {
            edidUpdateProgress = 0.1
            edidUpdateStatus = "Reading firmware header and EDID block..."
        }

        // Step 1: Read firmware header to get total size
        guard let headerData = hidManager.readEeprom(address: 0x0000, length: 16),
              let header = parseFirmwareHeader(headerData) else {
            finishEdidUpdate(success: false, message: "Failed to read firmware header")
            return
        }

        let firmwareSize = header.totalSize
        let checksumOffset = firmwareSize - 4
        logger.log(content: "Firmware size: \(firmwareSize) bytes, checksum at offset 0x\(String(format: "%04X", checksumOffset))")

        // Step 2: Read EDID block (128 bytes) using cached/preset offset or full scan
        let edidOffset: Int
        if let cached = cachedEdidOffset {
            edidOffset = cached
            logger.log(content: "Using cached EDID offset 0x\(String(format: "%04X", edidOffset))")
        } else if let preset = defaultEdidOffset() {
            edidOffset = preset
            cachedEdidOffset = edidOffset
            logger.log(content: "Using chip-preset EDID offset 0x\(String(format: "%04X", edidOffset))")
        } else {
            // Unknown chip type: must scan entire firmware
            guard let fullImage = await readFirmwareImage(),
                  let identity = EdidCodec.identity(from: fullImage) else {
                finishEdidUpdate(success: false, message: "Failed to locate EDID block in firmware")
                return
            }
            edidOffset = identity.edidOffset
            cachedEdidOffset = edidOffset
        }

        logger.log(content: "Reading EDID block at offset 0x\(String(format: "%04X", edidOffset))")
        guard let originalEdidBlock = hidManager.readEeprom(address: UInt16(edidOffset), length: 128) else {
            finishEdidUpdate(success: false, message: "Failed to read EDID block from device")
            return
        }

        // Verify EDID block checksum
        let edidChecksum = originalEdidBlock.reduce(0) { ($0 + Int($1)) & 0xFF }
        guard edidChecksum == 0 else {
            finishEdidUpdate(success: false, message: "EDID block has invalid checksum. Aborting write to protect the device; please retry.")
            return
        }

        // Step 3: Read original code checksum (last 2 bytes of firmware)
        guard let checksumData = hidManager.readEeprom(address: UInt16(checksumOffset), length: 4) else {
            finishEdidUpdate(success: false, message: "Failed to read firmware checksums")
            return
        }

        // Extract original code checksum (bytes 2-3, big-endian)
        let originalCodeChecksum = (UInt16(checksumData[2]) << 8) | UInt16(checksumData[3])
        logger.log(content: "Original code checksum: 0x\(String(format: "%04X", originalCodeChecksum))")

        // Save backup
        let backupName = "edid_backup_\(Int(Date().timeIntervalSince1970)).bin"
        let backupURL = FileManager.default.temporaryDirectory.appendingPathComponent(backupName)
        do {
            try originalEdidBlock.write(to: backupURL)
            logger.log(content: "Saved EDID block backup to \(backupURL.path)")
        } catch {
            logger.log(content: "⚠ Failed to save EDID backup: \(error.localizedDescription)")
        }

        // Step 4: Patch EDID block in memory
        var patchedEdidBlock = originalEdidBlock
        guard EdidCodec.patchDisplayName(in: &patchedEdidBlock, blockOffset: 0, name: name) else {
            finishEdidUpdate(success: false, message: "Failed to patch EDID display name descriptor")
            return
        }

        if patchedEdidBlock == originalEdidBlock {
            finishEdidUpdate(success: true, message: "EDID display name is already '\(name)'. No write needed.")
            return
        }

        let previousName = EdidCodec.extractDisplayName(from: originalEdidBlock) ?? "(not set)"

        // Step 5: Calculate differential checksum
        // diff = Σ(modified[i] - original[i]) for all bytes in EDID block
        var diff: Int32 = 0
        for i in 0..<128 {
            diff += Int32(patchedEdidBlock[i]) - Int32(originalEdidBlock[i])
        }

        // New code checksum = original + diff (mod 65536)
        let newCodeChecksum = UInt16((Int32(originalCodeChecksum) + diff) & 0xFFFF)
        logger.log(content: "EDID byte difference: \(diff), new code checksum: 0x\(String(format: "%04X", newCodeChecksum))")

        // Prepare checksum update data (only code checksum, bytes 2-3)
        var newChecksumData = Data(count: 2)
        newChecksumData[0] = UInt8((newCodeChecksum >> 8) & 0xFF)
        newChecksumData[1] = UInt8(newCodeChecksum & 0xFF)

        await MainActor.run {
            edidUpdateProgress = 0.3
            edidUpdateStatus = "Writing EDID block and checksum..."
        }

        // Step 6: Write only the modified EDID block (128 bytes)
        guard hidManager.writeEeprom(address: UInt16(edidOffset), data: patchedEdidBlock) else {
            finishEdidUpdate(success: false, message: "Failed to write EDID block to device EEPROM")
            return
        }

        // Step 7: Write only the updated code checksum (2 bytes)
        guard hidManager.writeEeprom(address: UInt16(checksumOffset + 2), data: newChecksumData) else {
            finishEdidUpdate(success: false, message: "EDID block written but checksum update failed")
            return
        }

        await MainActor.run {
            edidUpdateProgress = 0.9
            edidUpdateStatus = "Verifying written data..."
        }

        // Step 8: Verify by reading back EDID block
        guard let readBackEdid = hidManager.readEeprom(address: UInt16(edidOffset), length: 128) else {
            finishEdidUpdate(success: false, message: "Failed to read back EDID block for verification")
            return
        }

        let edidVerified = (readBackEdid == patchedEdidBlock)

        // Also verify checksum was written correctly
        guard let readBackChecksum = hidManager.readEeprom(address: UInt16(checksumOffset + 2), length: 2) else {
            finishEdidUpdate(success: false, message: "Failed to read back checksum for verification")
            return
        }

        let checksumVerified = (readBackChecksum == newChecksumData)

        if edidVerified && checksumVerified {
            cachedEdidOffset = edidOffset
            finishEdidUpdate(
                success: true,
                message: """
                EDID display name updated to '\(name)'.

                Before: \(previousName)
                Backup: \(backupURL.lastPathComponent)

                IMPORTANT: To apply the changes:
                1. Unplug ALL cables from the Openterface device
                2. Wait a few seconds
                3. Reconnect all cables to the device
                4. Close this application completely
                5. Restart the application

                The new monitor name will be visible after reconnection.
                """
            )
            logger.log(content: "EDID name update completed and verified (differential write: 130 bytes)")
        } else {
            let failReason = edidVerified ? "checksum" : "EDID block"
            finishEdidUpdate(success: false, message: "Write completed but \(failReason) verification failed. Backup: \(backupURL.lastPathComponent)")
            logger.log(content: "EDID name update failed verification: edid=\(edidVerified), checksum=\(checksumVerified)")
        }
    }

    private func finishEdidUpdate(success: Bool, message: String) {
        Task { @MainActor in
            self.isEdidUpdateInProgress = false
            self.edidUpdateProgress = success ? 1.0 : self.edidUpdateProgress
            self.edidUpdateStatus = success ? "EDID name updated successfully!" : message
            self.edidUpdateCompleteSubject.send((success, message))
        }
    }

    /// Clears the cached EDID offset. Call this when the device is disconnected
    /// or when the firmware is reflashed, as the EDID block location may change.
    func clearEdidOffsetCache() {
        cachedEdidOffset = nil
        logger.log(content: "Cleared EDID offset cache")
    }
}

// MARK: - EDID Model & Codec

/// Parsed EDID identity read from the firmware image.
struct EdidIdentity {
    let displayName: String?
    let serialString: String?
    let manufacturerId: String?
    let productCode: UInt16?
    let serialNumber: UInt32?
    let edidOffset: Int
    let firmwareSize: Int
    let checksumValid: Bool

    var summary: String {
        var parts: [String] = []
        if let displayName { parts.append("name='\(displayName)'") }
        if let manufacturerId { parts.append("mfr=\(manufacturerId)") }
        if let productCode { parts.append(String(format: "product=0x%04X", productCode)) }
        if let serialNumber { parts.append(String(format: "serial=0x%08X", serialNumber)) }
        parts.append(String(format: "edid@0x%04X", edidOffset))
        if !checksumValid { parts.append("checksum=INVALID") }
        return parts.joined(separator: ", ")
    }
}

/// Locates and patches the EDID block inside an EEPROM firmware image.
/// The block offset varies between chip revisions, so it is found by scanning
/// for the EDID magic header rather than assuming a fixed address.
enum EdidCodec {
    static let block0Magic: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    static func findBlock0(in image: Data) -> Int? {
        let bytes = [UInt8](image)
        guard bytes.count >= block0Magic.count else { return nil }
        for offset in 0...(bytes.count - block0Magic.count) {
            var matches = true
            for j in 0..<block0Magic.count where bytes[offset + j] != block0Magic[j] {
                matches = false
                break
            }
            if matches { return offset }
        }
        return nil
    }

    static func identity(from image: Data) -> EdidIdentity? {
        guard let offset = findBlock0(in: image), offset + 128 <= image.count else { return nil }
        let block = [UInt8](image[offset..<(offset + 128)])

        let mfgRaw = (Int(block[8]) << 8) | Int(block[9])
        let manufacturer = String([10, 5, 0].map { shift -> Character in
            let value = (mfgRaw >> shift) & 0x1F
            return Character(UnicodeScalar(UInt8(max(1, value) + 0x40)))
        })
        let product = UInt16(block[11]) << 8 | UInt16(block[10])
        let serial = UInt32(block[15]) << 24 | UInt32(block[14]) << 16 | UInt32(block[13]) << 8 | UInt32(block[12])

        return EdidIdentity(
            displayName: descriptorText(in: block, tag: 0xFC),
            serialString: descriptorText(in: block, tag: 0xFF),
            manufacturerId: manufacturer,
            productCode: product,
            serialNumber: serial,
            edidOffset: offset,
            firmwareSize: image.count,
            checksumValid: block.reduce(0) { ($0 + Int($1)) & 0xFF } == 0
        )
    }

    private static func descriptorText(in block: [UInt8], tag: UInt8) -> String? {
        guard block.count >= 128 else { return nil }
        for d in stride(from: 54, through: 108, by: 18) where block[d] == 0 && block[d + 1] == 0 && block[d + 2] == 0 && block[d + 3] == tag {
            var text = ""
            for i in (d + 5)..<(d + 18) {
                let byte = block[i]
                if byte == 0x0A { break }
                guard byte >= 32, byte <= 126 else { break }
                text.append(Character(UnicodeScalar(byte)))
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Extracts the display name from a raw 128-byte EDID block
    static func extractDisplayName(from block: Data) -> String? {
        guard block.count >= 128 else { return nil }
        return descriptorText(in: [UInt8](block), tag: 0xFC)
    }

    /// Patches the 0xFC display name descriptor in-place and fixes the block checksum.
    /// - Returns: false if the block is out of range or no descriptor slot is available
    static func patchDisplayName(in image: inout Data, blockOffset: Int, name: String) -> Bool {
        guard blockOffset >= 0, blockOffset + 128 <= image.count else { return false }
        var block = [UInt8](image[blockOffset..<(blockOffset + 128)])

        var slot: Int? = nil
        for d in stride(from: 54, through: 108, by: 18) where block[d] == 0 && block[d + 1] == 0 && block[d + 2] == 0 {
            if block[d + 3] == 0xFC { slot = d; break }
            if block[d + 3] == 0 && slot == nil { slot = d }
        }
        guard let d = slot else { return false }

        block[d] = 0; block[d + 1] = 0; block[d + 2] = 0
        block[d + 3] = 0xFC
        block[d + 4] = 0x00

        // EDID 0xFC descriptor data area is 13 bytes. Per EDID spec, the name
        // must be terminated with 0x0A. If name is 13 bytes, truncate to 12
        // to make room for the terminator.
        var textArea = Array(name.utf8.prefix(12))
        textArea.append(0x0A)
        while textArea.count < 13 { textArea.append(0x20) }
        for i in 0..<13 { block[d + 5 + i] = textArea[i] }

        let sum = block[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }
        block[127] = UInt8((256 - sum) & 0xFF)

        image.replaceSubrange(blockOffset..<(blockOffset + 128), with: block)
        return true
    }
}
