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
    
    // Progress signals - similar to Qt signals
    private let firmwareWriteProgressSubject = PassthroughSubject<Int, Never>()
    private let firmwareWriteCompleteSubject = PassthroughSubject<Bool, Never>()
    
    var firmwareWriteProgress: AnyPublisher<Int, Never> {
        firmwareWriteProgressSubject.eraseToAnyPublisher()
    }
    
    var firmwareWriteComplete: AnyPublisher<Bool, Never> {
        firmwareWriteCompleteSubject.eraseToAnyPublisher()
    }
    
    private let chunkSize = 64 // EEPROM write chunk size
    private let eepromStartAddress: UInt16 = 0x0000 // Starting address for firmware
    
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
        var writtenBytes = 0
        var currentAddress = address
        
        // Write data in chunks
        while writtenBytes < totalSize {
            let remainingBytes = totalSize - writtenBytes
            let currentChunkSize = min(chunkSize, remainingBytes)
            
            let startIndex = writtenBytes
            let endIndex = startIndex + currentChunkSize
            let chunk = data.subdata(in: startIndex..<endIndex)
            
            // Write chunk to EEPROM
            let success = await writeEepromChunk(address: currentAddress, data: chunk)
            if !success {
                Logger.shared.log(content: "Failed to write EEPROM chunk at address 0x\(String(format: "%04X", currentAddress))")
                return false
            }
            
            writtenBytes += currentChunkSize
            currentAddress += UInt16(currentChunkSize)
            
            // Update progress
            let progressPercent = (writtenBytes * 100) / totalSize
            
            DispatchQueue.main.async {
                self.updateProgress = Double(writtenBytes) / Double(totalSize)
                self.updateStatus = "Writing firmware to EEPROM... \(progressPercent)%"
                self.firmwareWriteProgressSubject.send(progressPercent)
            }
            
            // Small delay to prevent overwhelming the device
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms delay
        }
        
        Logger.shared.log(content: "EEPROM write completed successfully")
        DispatchQueue.main.async {
            self.updateProgress = 1.0
            self.updateStatus = "Firmware update completed successfully!"
        }
        
        return true
    }
    
    private func writeEepromChunk(address: UInt16, data: Data) async -> Bool {
        // Use HID commands for EEPROM writing (not serial commands)
        let hidManager = HIDManager.shared
        let success = hidManager.writeEeprom(address: address, data: data)
        
        // Wait for response 
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay
        
        return success
    }
}

// MARK: - Error Types

enum FirmwareError: LocalizedError {
    case invalidURL
    case invalidResponse
    case downloadFailed(Int)
    case writeFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid firmware URL"
        case .invalidResponse:
            return "Invalid server response"
        case .downloadFailed(let statusCode):
            return "Download failed with status code: \(statusCode)"
        case .writeFailed:
            return "Failed to write firmware to device"
        }
    }
}
