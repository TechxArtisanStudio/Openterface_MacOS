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
                    
                    Spacer()
                    
                    // Action buttons
                    HStack {
                        Button("Cancel") {
                            dismiss()
                        }
                        .keyboardShortcut(.escape)
                        
                        Spacer()
                        
                        if currentVersion == latestVersion && currentVersion != "Unknown" && latestVersion != "Unknown" {
                            Button("Close") {
                                dismiss()
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
            updateStatus = "Stopping serial connections..."
        }
        
        // Post notification to stop all operations
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("StopAllOperationsBeforeFirmwareUpdate"),
                object: nil
            )
        }
        
        // Small delay to ensure all connections are properly closed
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds to ensure all operations stop
        
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
        
        // Post notification to write firmware using existing HID functionality
        return await withCheckedContinuation { continuation in
            Task {
                // Use NotificationCenter to trigger firmware write through HIDManager
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("WriteFirmwareToEEPROM"),
                        object: nil,
                        userInfo: ["firmwareData": data, "continuation": continuation]
                    )
                }
            }
        }
    }
    
}

#Preview {
    FirmwareUpdateView()
}

