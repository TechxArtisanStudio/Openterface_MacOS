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
    @StateObject private var firmwareManager = FirmwareManager.shared
    @State private var currentVersion: String = "Unknown"
    @State private var latestVersion: String = "Unknown"
    @State private var showingConfirmation: Bool = false
    @State private var showingBackupAlert: Bool = false
    @State private var backupAlertMessage: String = ""
    @State private var showingUpdateCompletionAlert: Bool = false
    @State private var updateSuccess: Bool = false
    @State private var showingRestoreConfirmation: Bool = false
    @State private var showingRestoreWarning: Bool = false
    @State private var selectedRestoreFile: URL?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
    
            if !firmwareManager.isUpdateInProgress {
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
                            
                            // Backup button next to current version
                            Button(action: {
                                backupCurrentFirmware()
                            }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.borderless)
                            .disabled(currentVersion == "Unknown" || firmwareManager.isBackupInProgress)
                            .help("Backup Current Firmware")
                            .overlay(
                                // Show progress indicator when backup is in progress
                                firmwareManager.isBackupInProgress ? 
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                : nil
                            )
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
                            }
                        }
                    }
                    
                    // Show important instructions only when update is available
                    if currentVersion != latestVersion && currentVersion != "Unknown" && latestVersion != "Checking..." {
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
                    if firmwareManager.isBackupInProgress {
                        VStack(spacing: 8) {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(firmwareManager.backupStatus)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    
                    // Show update process information only when update is available and not in progress
                    if !firmwareManager.isBackupInProgress && currentVersion != "Unknown" && currentVersion != latestVersion && latestVersion != "Unknown" && latestVersion != "Checking..." {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Update process will:")
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("• Download the latest firmware from the official server")
                                Text("• Install the new firmware to your device")
                                Text("• Please disconnect and reconnect all cables after update")
                            }
                            .padding(.leading, 10)
                            .foregroundColor(.secondary)
                        }
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
                        
                        Button("Restore Firmware...") {
                            showingRestoreWarning = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(firmwareManager.isUpdateInProgress || firmwareManager.isBackupInProgress)
                        .help("Restore firmware from a backup file")
                        
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
                            .disabled(currentVersion == latestVersion || currentVersion == "Unknown" || latestVersion == "Unknown" || firmwareManager.isBackupInProgress)
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
                    
                    ProgressView(value: firmwareManager.updateProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 8)
                    
                    Text(firmwareManager.updateStatus)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    if firmwareManager.updateProgress < 1.0 {
                        Text("Please do not disconnect or power off the device")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                    
                    // Show close button when update is completed successfully
                    if firmwareManager.updateProgress >= 1.0 {
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
            setupFirmwareManagerObservers()
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
        .alert("Firmware Update Complete", isPresented: $showingUpdateCompletionAlert) {
            Button("I Understand") {
                // Exit the application
                NSApplication.shared.terminate(nil)
            }
        } message: {
            if updateSuccess {
                Text("Firmware update completed successfully!\n\nTo ensure the new firmware takes effect, please:\n• Unplug all cables from the device\n• Wait 5 seconds\n• Reconnect all cables\n\nThe application will now close.")
            } else {
                Text("Firmware update failed. Please try again or contact support.")
            }
        }
        .alert("⚠️ Firmware Restore Warning", isPresented: $showingRestoreWarning) {
            Button("Cancel", role: .cancel) { }
            Button("I Understand the Risks", role: .destructive) {
                showRestoreFileSelector()
            }
        } message: {
            Text("WARNING: Restoring firmware from a file is a potentially dangerous operation that could permanently damage your device.\n\n• Only use firmware files specifically designed for your device\n• Ensure the file is from a trusted source\n• Do not interrupt the process once started\n• The device may become unusable if incorrect firmware is installed\n\nProceed only if you understand these risks.")
        }
        .alert("Confirm Firmware Restore", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore Now", role: .destructive) {
                startFirmwareRestore()
            }
        } message: {
            Text("Are you sure you want to restore firmware from the selected file? This process cannot be undone and may render your device unusable if the firmware is incompatible.")
        }
    }
    
    private func setupFirmwareManagerObservers() {
        // Observe backup completion
        firmwareManager.firmwareBackupComplete
            .receive(on: DispatchQueue.main)
            .sink { (success, message) in
                backupAlertMessage = message
                showingBackupAlert = true
            }
            .store(in: &cancellables)
        
        // Observe firmware update completion
        firmwareManager.firmwareWriteComplete
            .receive(on: DispatchQueue.main)
            .sink { success in
                updateSuccess = success
                showingUpdateCompletionAlert = true
            }
            .store(in: &cancellables)
    }
    
    @State private var cancellables = Set<AnyCancellable>()
    
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
        Task {
            await performFirmwareUpdate()
        }
    }
    
    private func performFirmwareUpdate() async {
        // Step 1: Stop all operations before firmware update
        await MainActor.run {
            firmwareManager.updateStatus = "Stopping operations..."
            firmwareManager.updateProgress = 0.05
        }
        
        await stopAllOperations()
        
        // Step 2: Use FirmwareManager to handle the update
        await firmwareManager.loadFirmwareToEeprom()
    }
    
    /// Stops all operations before firmware update
    private func stopAllOperations() async {
        await MainActor.run {
            firmwareManager.updateStatus = "Stopping all operations..."
        }
        
        // Use the centralized stopAllOperations function from FirmwareManager
        firmwareManager.stopAllOperations()
        
        // Add a delay to ensure all operations have stopped
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        await MainActor.run {
            firmwareManager.updateStatus = "All operations stopped. Ready for firmware update..."
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
            firmwareManager.updateProgress = 0.4
            firmwareManager.updateStatus = "Installing firmware to EEPROM..."
        }
        
        // Use HID Manager directly with progress tracking
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                let hidManager = HIDManager.shared
                let firmwareManagerRef = self.firmwareManager
                let success = hidManager.writeEeprom(address: 0x0000, data: data) { progress in
                    // Update progress on main thread
                    DispatchQueue.main.async {
                        // Map progress from 0.4 to 1.0 (40% to 100%)
                        let overallProgress = 0.4 + (progress * 0.6)
                        firmwareManagerRef.updateProgress = overallProgress
                        
                        let progressPercent = Int(overallProgress * 100)
                        firmwareManagerRef.updateStatus = "Installing firmware to EEPROM... \(progressPercent)%"
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
        let versionString = currentVersion != "Unknown" ? currentVersion : "Unknown"
        let defaultFilename = "Openterface_Firmware_Backup_v\(versionString)_\(timestamp).bin"
        
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
                Task {
                    await performFirmwareBackup(to: url)
                }
            }
        }
    }
    
    private func performFirmwareBackup(to backupURL: URL) async {
        // Step 1: Stop all operations before firmware backup to avoid conflicts
        await MainActor.run {
            firmwareManager.backupStatus = "Stopping operations before backup..."
        }
        
        await stopAllOperations()
        
        // Step 2: Use FirmwareManager to handle the backup process
        await firmwareManager.backupFirmware(to: backupURL)
    }
    
    // MARK: - Firmware Restore Functions
    
    private func showRestoreFileSelector() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Firmware File to Restore"
        openPanel.message = "Choose the firmware backup file (.bin) to restore"
        openPanel.allowedContentTypes = [.data]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        
        // Set default directory to Desktop
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            openPanel.directoryURL = desktopURL
        }
        
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                selectedRestoreFile = url
                showingRestoreConfirmation = true
            }
        }
    }
    
    private func startFirmwareRestore() {
        guard let restoreFile = selectedRestoreFile else { return }
        
        Task {
            await performFirmwareRestore(from: restoreFile)
        }
    }
    
    private func performFirmwareRestore(from fileURL: URL) async {
        // Step 1: Stop all operations before firmware restore
        await MainActor.run {
            firmwareManager.updateStatus = "Stopping operations..."
            firmwareManager.updateProgress = 0.0
        }
        
        await stopAllOperations()
        
        // Step 2: Use FirmwareManager to handle the restore process
        await firmwareManager.restoreFirmware(from: fileURL)
    }
}

#Preview {
    FirmwareUpdateView()
}
