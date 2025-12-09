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
    @StateObject private var firmwareManager: FirmwareManager
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
    
    init() {
        self._firmwareManager = StateObject(wrappedValue: FirmwareManager.shared)
    }
    
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
                        
                        HStack {
                            Text("Current chipset:")
                                .fontWeight(.medium)
                            Spacer()
                            Text(getCurrentChipsetDisplay())
                                .foregroundColor(.secondary)
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
                            } else if isCurrentVersionNewer() {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Your firmware is newer than the latest available version!")
                                        .fontWeight(.medium)
                                        .foregroundColor(.orange)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    
                    // Show important instructions only when update is available
                    if currentVersion != latestVersion && currentVersion != "Unknown" && latestVersion != "Checking..." && !isCurrentVersionNewer() {
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
                    if !firmwareManager.isBackupInProgress && currentVersion != "Unknown" && currentVersion != latestVersion && latestVersion != "Unknown" && latestVersion != "Checking..." && !isCurrentVersionNewer() {
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
                        
                        if (currentVersion == latestVersion && currentVersion != "Unknown" && latestVersion != "Unknown") || isCurrentVersionNewer() {
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
                            .disabled(currentVersion == latestVersion || currentVersion == "Unknown" || latestVersion == "Unknown" || firmwareManager.isBackupInProgress || isCurrentVersionNewer())
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
        .frame(width: 500, height: 500)
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
        currentVersion = firmwareManager.getCurrentFirmwareVersion()
        
        // Load latest firmware version from remote URL
        Task {
            await fetchLatestFirmwareVersion()
        }
    }
    
    private func fetchLatestFirmwareVersion() async {
        let version = await firmwareManager.fetchLatestFirmwareVersion()
        await MainActor.run {
            latestVersion = version
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
    
    private func getCurrentChipsetDisplay() -> String {
        switch AppStatus.videoChipsetType {
        case .ms2109:
            return AppStatus.videoFirmwareVersion.isEmpty ? "MS2109" : AppStatus.videoFirmwareVersion
        case .ms2109s:
            return AppStatus.videoFirmwareVersion.isEmpty ? "MS2109S" : AppStatus.videoFirmwareVersion
        case .ms2130s:
            return "MS2130S"
        case .unknown:
            return "Unknown"
        }
    }
    
    private func isCurrentVersionNewer() -> Bool {
        guard currentVersion != "Unknown", latestVersion != "Unknown", currentVersion != latestVersion else {
            return false
        }
        // Assuming versions are comparable strings (e.g., date-based like "25022713")
        return currentVersion > latestVersion
    }
}

#Preview {
    FirmwareUpdateView()
}
