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

import SwiftUI
import Foundation
import Combine
import IOKit
import IOKit.hid
import AVFoundation
import UniformTypeIdentifiers
import AppKit

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

struct FirmwareUpdateView: View {
    @State private var currentVersion: String = "Unknown"
    @State private var latestVersion: String = "Unknown"
    @State private var isUpdateInProgress: Bool = false
    @State private var updateProgress: Double = 0.0
    @State private var updateStatus: String = ""
    @State private var showingConfirmation: Bool = false
    @State private var isBackupInProgress: Bool = false
    @State private var backupStatus: String = ""
    @State private var showingBackupAlert: Bool = false
    @State private var backupAlertMessage: String = ""
    @State private var selectedBackupURL: URL?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
    
            if !isUpdateInProgress {
                // Firmware version information and confirmation dialog
                VStack(alignment: .leading, spacing: 15) {
                    // Version information
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current firmware version:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(currentVersion)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Latest firmware version:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(latestVersion)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Divider()
                    
                    // Show status message
                    VStack(alignment: .center, spacing: 12) {
                        if currentVersion != "Unknown" && latestVersion != "Unknown" {
                            if currentVersion == latestVersion {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Your firmware is already up to date!")
                                        .fontWeight(.medium)
                                        .foregroundColor(.green)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                            } else {
                                // Update process information
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("The update process will:")
                                        .fontWeight(.semibold)
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("1. Stop all video and USB operations")
                                        Text("2. Install new firmware")
                                        Text("3. Close the application automatically")
                                    }
                                    .padding(.leading, 10)
                                }
                            }
                        }
                    }
                    
                    // Show important instructions only when update is available
                    if currentVersion != latestVersion && currentVersion != "Unknown" && latestVersion != "Unknown" {
                        Divider()
                        
                        // Important instructions
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Important:")
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("• Use a high-quality USB cable for host connection")
                                Text("• Disconnect the HDMI cable")
                                Text("• Do not interrupt power during update")
                                Text("• Restart application after completion")
                            }
                            .padding(.leading, 10)
                            .foregroundColor(.secondary)
                        }
                    }
                    
                    // Show backup status if backup is in progress
                    if isBackupInProgress {
                        VStack(spacing: 8) {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(backupStatus)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    // Action buttons
                    HStack {
                        Button("Cancel") {
                            // For standalone windows, we need to close the actual window
                            if let window = NSApp.keyWindow {
                                window.close()
                            } else {
                                dismiss()
                            }
                        }
                        .keyboardShortcut(.escape)
                        
                        // Backup button (always available when not updating)
                        Button("Backup Current Firmware") {
                            backupCurrentFirmware()
                        }
                        .disabled(currentVersion == "Unknown" || isBackupInProgress)
                        .overlay(
                            // Show progress indicator when backup is in progress
                            isBackupInProgress ? 
                            ProgressView()
                                .scaleEffect(0.6)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            : nil
                        )
                        
                        Spacer()
                        
                        if currentVersion == latestVersion && currentVersion != "Unknown" && latestVersion != "Unknown" {
                            Button("Close") {
                                // For standalone windows, we need to close the actual window
                                if let window = NSApp.keyWindow {
                                    window.close()
                                } else {
                                    dismiss()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Proceed with Update") {
                                showingConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(currentVersion == latestVersion || currentVersion == "Unknown" || latestVersion == "Unknown")
                        }
                    }
                }
                .padding()
            } else {
                // Update in progress view
                VStack(spacing: 20) {
                    Text("Firmware Update in Progress")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    ProgressView(value: updateProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 8)
                    
                    Text(updateStatus)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    if updateProgress < 1.0 {
                        Text("Please do not disconnect or power off the device")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Show close button when update is completed successfully
                    if updateProgress >= 1.0 {
                        VStack(spacing: 10) {
                            HStack {
                               
                                Button("Close Application") {
                                    NSApplication.shared.terminate(nil)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            
                            Text("Note: You may need to restart the application for the new firmware to take effect.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadFirmwareVersions()
        }
        .alert("Confirm Firmware Update", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Update Now", role: .destructive) {
                startFirmwareUpdate()
            }
        } message: {
            Text("Are you sure you want to proceed with the firmware update? This process cannot be undone.")
        }
        .alert("Firmware Backup", isPresented: $showingBackupAlert) {
            Button("OK") { }
        } message: {
            Text(backupAlertMessage)
        }
    }
    
    private func loadFirmwareVersions() {
        // Load current firmware version from device
        currentVersion = getCurrentFirmwareVersion()
        
        // Load latest firmware version from remote URL
        Task {
            await fetchLatestFirmwareVersion()
        }
    }
    
    private func getCurrentFirmwareVersion() -> String {
        // Read firmware version from device using HID commands
        // This would typically read from specific EEPROM addresses that contain version info
        print("Reading current firmware version from device...")
        return HIDManager.shared.getVersion() ?? "Unknown"
    }
    
    private func fetchLatestFirmwareVersion() async {
        guard let url = URL(string: "https://assets.openterface.com/openterface/firmware/minikvm_latest_firmware2.txt") else {
            await MainActor.run {
                latestVersion = "Unknown"
            }
            return
        }
        
        do {
            // Create URLSession with configuration that allows outbound connections
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(from: url)
            
            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                print("HTTP Status Code: \(httpResponse.statusCode)")
                
                if httpResponse.statusCode != 200 {
                    await MainActor.run {
                        latestVersion = "Unknown"
                    }
                    print("Failed to fetch firmware version: HTTP \(httpResponse.statusCode)")
                    return
                }
            }
            
            if let responseString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                print("Firmware response: \(responseString)")
                
                // Parse the format: "25022713,Openterface_Firmware_250306.bin"
                // Extract version number before the comma
                let components = responseString.components(separatedBy: ",")
                if let versionString = components.first, !versionString.isEmpty {
                    await MainActor.run {
                        latestVersion = versionString
                    }
                    print("Latest firmware version: \(versionString)")
                } else {
                    await MainActor.run {
                        latestVersion = "Unknown"
                    }
                    print("Failed to parse firmware version from response")
                }
            } else {
                await MainActor.run {
                    latestVersion = "Unknown"
                }
                print("Failed to decode response data")
            }
        } catch {
            await MainActor.run {
                latestVersion = "Unknown"
            }
            print("Failed to fetch latest firmware version: \(error)")
            if let urlError = error as? URLError {
                print("URLError code: \(urlError.code)")
                print("URLError description: \(urlError.localizedDescription)")
            }
            // TODO: Add logging when Logger scope issue is resolved
            // Logger.shared.log(content: "Failed to fetch latest firmware version: \(error.localizedDescription)")
        }
    }
    
    private func startFirmwareUpdate() {
        isUpdateInProgress = true
        updateProgress = 0.0
        updateStatus = "Preparing for update..."
        
        Task {
            await performFirmwareUpdate()
        }
    }
    
    private func performFirmwareUpdate() async {
        // Step 1: Stop all operations before firmware update
        updateStatus = "Stopping operations..."
        updateProgress = 0.05
        
        await stopAllOperations()
        
        // Step 2: Download and install firmware
        do {
            // Download firmware
            updateStatus = "Downloading firmware..."
            updateProgress = 0.2
            let firmwareData = try await downloadLatestFirmware()
            
            // Install firmware
            updateStatus = "Installing firmware to EEPROM..."
            updateProgress = 0.4
            let success = await writeFirmwareToEeprom(data: firmwareData)
            
            await MainActor.run {
                if success {
                    updateProgress = 1.0
                    updateStatus = "Firmware update completed successfully!\n\nPlease:\n1. Restart the application\n2. Disconnect and reconnect all cables"
                } else {
                    updateStatus = "Firmware update failed. Please try again."
                    isUpdateInProgress = false
                }
            }
        } catch {
            await MainActor.run {
                updateStatus = "Firmware update failed: \(error.localizedDescription)"
                isUpdateInProgress = false
            }
        }
    }
    
    /// Stops all operations before firmware update
    private func stopAllOperations() async {
        await MainActor.run {
            updateStatus = "Stopping video operations..."
        }
        
        // Stop video operations directly and completely
        await MainActor.run {
            let videoManager = VideoManager.shared
            
            // Stop the video session
            videoManager.stopVideoSession()
            
            // Remove all video inputs to ensure complete disconnection
            videoManager.captureSession.beginConfiguration()
            let videoInputs = videoManager.captureSession.inputs.filter { $0 is AVCaptureDeviceInput }
            videoInputs.forEach { videoManager.captureSession.removeInput($0) }
            videoManager.captureSession.commitConfiguration()
            
            updateStatus = "Video completely stopped. Closing main windows..."
        }
        
        // Close main application windows (except firmware update window)
        await MainActor.run {
            let windows = NSApplication.shared.windows
            for window in windows {
                // Only close the main content window, not the firmware update window
                if let identifier = window.identifier?.rawValue,
                   identifier.contains("main_openterface") || window.title.contains("Openterface Mini-KVM") {
                    window.orderOut(nil) // Hide the window instead of closing it completely
                }
            }
            updateStatus = "Main windows hidden. Stopping serial connections..."
        }
        
        // Add a small delay to ensure video session is completely stopped
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Post notification to stop all other operations (serial, audio, HID)
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("StopAllOperationsBeforeFirmwareUpdate"),
                object: nil
            )
            updateStatus = "Stopping other operations..."
        }
        
        // Additional delay to ensure all connections are properly closed
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds to ensure all operations stop
        
        await MainActor.run {
            updateStatus = "All operations stopped. Ready for firmware update..."
        }
    }
    
    private func downloadLatestFirmware() async throws -> Data {
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
        
        print("Downloading firmware from: \(firmwareUrlString)")
        let (firmwareData, response) = try await URLSession.shared.data(from: firmwareUrl)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw FirmwareError.downloadFailed(httpResponse.statusCode)
        }
        
        print("Firmware downloaded successfully, size: \(firmwareData.count) bytes")
        return firmwareData
    }
    
    private func writeFirmwareToEeprom(data: Data) async -> Bool {
        print("Writing \(data.count) bytes to EEPROM using HID commands...")
        
        // Update progress to show start of EEPROM write
        await MainActor.run {
            updateProgress = 0.4
            updateStatus = "Installing firmware to EEPROM..."
        }
        
        // Use HID Manager directly with progress tracking
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                let hidManager = HIDManager.shared
                let success = hidManager.writeEeprom(address: 0x0000, data: data) { progress in
                    // Update progress on main thread
                    DispatchQueue.main.async {
                        // Map progress from 0.4 to 1.0 (40% to 100%)
                        let overallProgress = 0.4 + (progress * 0.6)
                        self.updateProgress = overallProgress
                        
                        let progressPercent = Int(overallProgress * 100)
                        self.updateStatus = "Installing firmware to EEPROM... \(progressPercent)%"
                    }
                }
                
                continuation.resume(returning: success)
            }
        }
    }
    
    // MARK: - Firmware Backup Functions
    
    private func backupCurrentFirmware() {
        // Create filename with current date and version
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let defaultFilename = "Openterface_Firmware_Backup_v\(currentVersion)_\(timestamp).bin"
        
        // Show save dialog to let user choose backup location
        let savePanel = NSSavePanel()
        savePanel.title = "Save Firmware Backup"
        savePanel.message = "Choose location to save firmware backup"
        savePanel.nameFieldStringValue = defaultFilename
        savePanel.allowedContentTypes = [.data]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        // Set default directory to Desktop
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = desktopURL
        }
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                selectedBackupURL = url
                isBackupInProgress = true
                backupStatus = "Preparing to backup firmware..."
                
                Task {
                    await performFirmwareBackup()
                }
            }
        }
    }
    
    private func performFirmwareBackup() async {
        guard let backupURL = selectedBackupURL else {
            await MainActor.run {
                isBackupInProgress = false
                backupAlertMessage = "No backup location selected."
                showingBackupAlert = true
            }
            return
        }
        
        await MainActor.run {
            backupStatus = "Determining firmware size..."
        }
        
        // First, try to determine the actual firmware size
        let firmwareSize = await determineFirmwareSize()
        
        await MainActor.run {
            backupStatus = "Reading \(firmwareSize) bytes of firmware from device..."
        }
        
        let firmwareStartAddress: UInt16 = 0x0000 // Start from beginning of EEPROM
        
        // Read firmware data from EEPROM using the HIDManager
        // Need to split large reads into smaller chunks due to UInt8 length limitation
        let allFirmwareData = await readFirmwareData(
            startAddress: firmwareStartAddress,
            totalSize: firmwareSize,
            onProgress: { status in
                backupStatus = status
            },
            onError: { errorMessage in
                isBackupInProgress = false
                backupAlertMessage = errorMessage
                showingBackupAlert = true
            }
        )
        
        guard let firmwareData = allFirmwareData else {
            await MainActor.run {
                isBackupInProgress = false
                backupAlertMessage = "Failed to read firmware from device. Please ensure the device is properly connected."
                showingBackupAlert = true
            }
            return
        }
        
        await MainActor.run {
            backupStatus = "Saving backup file..."
        }
        
        // Save firmware data to the selected file location
        let success = await saveFirmwareBackup(data: firmwareData, to: backupURL)
        
        await MainActor.run {
            isBackupInProgress = false
            if success {
                backupAlertMessage = "Firmware backup completed successfully!\n\nFile saved as: \(backupURL.lastPathComponent)\nSize: \(firmwareData.count) bytes\nLocation: \(backupURL.deletingLastPathComponent().path)"
            } else {
                backupAlertMessage = "Failed to save firmware backup file. Please check permissions and try again."
            }
            showingBackupAlert = true
        }
    }
    
    /// Determines the actual firmware size by reading the EEPROM
    /// Based on the Python implementation which uses 0x05B0 (1456 bytes) as the full EEPROM size
    private func determineFirmwareSize() async -> Int {
        // The MS2109 EEPROM typically contains firmware up to address 0x05B0 (1456 bytes)
        // This is based on the Python implementation and actual device specifications
        let standardEepromSize = 0x05B0 // 1456 bytes
        
        // For now, we'll use the standard size. In the future, we could implement
        // dynamic size detection by reading until we find empty regions (0xFF patterns)
        // or by reading specific EEPROM headers that might contain size information
        
        Logger.shared.log(content: "Using standard MS2109 EEPROM size: \(standardEepromSize) bytes (0x\(String(format: "%04X", standardEepromSize)))")
        
        return standardEepromSize
    }
    
    /// Alternative method to detect firmware end by scanning for empty regions
    /// This could be used in the future for more accurate size detection
    private func detectFirmwareEndAddress() async -> Int? {
        // Start from a reasonable point and scan backwards for non-0xFF data
        // This would be useful for firmware that doesn't fill the entire EEPROM
        let maxScanAddress = 0x05B0
        let scanChunkSize = 16
        
        // Scan from the end backwards to find the last non-empty region
        for address in stride(from: maxScanAddress - scanChunkSize, through: 0, by: -scanChunkSize) {
            if let data = HIDManager.shared.readEeprom(address: UInt16(address), length: UInt8(min(scanChunkSize, maxScanAddress - address))) {
                // Check if this chunk contains non-0xFF data
                if data.contains(where: { $0 != 0xFF }) {
                    // Found non-empty data, the firmware likely extends to this point
                    Logger.shared.log(content: "Detected firmware end near address: 0x\(String(format: "%04X", address + scanChunkSize))")
                    return address + scanChunkSize
                }
            }
        }
        
        // If we couldn't detect the end, return nil to use the standard size
        return nil
    }
    
    private func saveFirmwareBackup(data: Data, to url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    // Write firmware data to the selected file location
                    try data.write(to: url)
                    
                    print("Firmware backup saved to: \(url.path)")
                    continuation.resume(returning: true)
                } catch {
                    print("Failed to save firmware backup: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Reads firmware data from EEPROM in chunks with progress updates
    private func readFirmwareData(
        startAddress: UInt16, 
        totalSize: Int,
        onProgress: @MainActor @escaping (String) -> Void = { _ in },
        onError: @MainActor @escaping (String) -> Void = { _ in }
    ) async -> Data? {
        var allFirmwareData = Data()
        var currentAddress = startAddress
        var remainingBytes = totalSize
        
        while remainingBytes > 0 {
            let chunkSize = min(255, remainingBytes) // Max UInt8 value
            
            guard let chunkData = HIDManager.shared.readEeprom(address: currentAddress, length: UInt8(chunkSize)) else {
                await onError("Failed to read firmware from device at address 0x\(String(format: "%04X", currentAddress)). Please ensure the device is properly connected.")
                return nil
            }
            
            allFirmwareData.append(chunkData)
            currentAddress += UInt16(chunkSize)
            remainingBytes -= chunkSize
            
            // Update progress
            let progress = Double(allFirmwareData.count) / Double(totalSize)
            await onProgress("Reading firmware... \(Int(progress * 100))% (\(allFirmwareData.count)/\(totalSize) bytes)")
        }
        
        return allFirmwareData
    }
    
}

#Preview {
    FirmwareUpdateView()
}

