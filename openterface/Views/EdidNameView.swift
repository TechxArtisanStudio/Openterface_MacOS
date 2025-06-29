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
import AppKit

struct EdidNameView: View {
    @StateObject private var firmwareManager = FirmwareManager.shared
    @State private var currentEdidName: String = "Loading..."
    @State private var newEdidName: String = ""
    @State private var showingConfirmation: Bool = false
    @State private var showingCompletionAlert: Bool = false
    @State private var updateSuccess: Bool = false
    @State private var alertMessage: String = ""
    @State private var isNameValid: Bool = true
    @State private var validationMessage: String = ""
    @State private var cancellables = Set<AnyCancellable>()
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            
            if !firmwareManager.isEdidUpdateInProgress {
                // EDID name information and editor
                VStack(alignment: .leading, spacing: 15) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "tv")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                            Text("EDID Monitor Name Editor")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        
                        Text("Change the monitor name that appears to the target system")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Current EDID name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current Monitor Name:")
                            .fontWeight(.medium)
                        
                        HStack {
                            Text(currentEdidName)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                            
                            Spacer()
                            
                            Button(action: {
                                loadCurrentEdidName()
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.borderless)
                            .disabled(currentEdidName == "Loading...")
                            .help("Refresh Current Name")
                        }
                    }
                    
                    // New EDID name input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("New Monitor Name:")
                            .fontWeight(.medium)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Enter new monitor name", text: $newEdidName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .focused($isTextFieldFocused)
                                .onTapGesture {
                                    isTextFieldFocused = true
                                }
                                .onChange(of: newEdidName) { newValue in
                                    validateEdidName(newValue)
                                }
                            
                            HStack {
                                Text("\(newEdidName.count)/13 characters")
                                    .font(.caption)
                                    .foregroundColor(newEdidName.count > 13 ? .red : .secondary)
                                
                                Spacer()
                                
                                if !isNameValid {
                                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    
                    // Information section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Important Information:")
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Maximum 13 characters allowed", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Label("Only printable ASCII characters supported", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Label("Device must be reconnected after update", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.orange)
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
                        
                        Button("Update Monitor Name") {
                            showingConfirmation = true
                        }
                        .disabled(!isNameValid || newEdidName.isEmpty || newEdidName == currentEdidName)
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                
            } else {
                // Progress view during update
                VStack(spacing: 20) {
                    
                    Spacer()
                    
                    // Progress indicator
                    VStack(spacing: 15) {
                        Image(systemName: "tv.badge.wifi")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                            .opacity(0.8)
                        
                        Text("Updating Monitor Name")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        ProgressView(value: firmwareManager.edidUpdateProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 250)
                        
                        Text(firmwareManager.edidUpdateStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    Spacer()
                    
                    Text("Please do not disconnect the device during this process")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.bottom, 20)
                }
                .padding()
            }
        }
        .frame(width: 450, height: 500)
        .onAppear {
            loadCurrentEdidName()
            setupSubscriptions()
            // Auto-focus the text field after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
        .alert("Confirm EDID Name Update", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Update", role: .destructive) {
                updateEdidName()
            }
        } message: {
            Text("Are you sure you want to change the monitor name from '\(currentEdidName)' to '\(newEdidName)'?\n\nThis will modify the firmware and require a device reconnection.")
        }
        .alert(updateSuccess ? "Update Successful" : "Update Failed", isPresented: $showingCompletionAlert) {
            if updateSuccess {
                Button("Close App") {
                    NSApplication.shared.terminate(nil)
                }
                Button("OK") {
                    dismiss()
                }
            } else {
                Button("OK") {
                    // For failed updates, just dismiss
                }
            }
        } message: {
            Text(alertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // When window becomes key, focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func loadCurrentEdidName() {
        Task {
            let edidName = await firmwareManager.getEdidName()
            await MainActor.run {
                currentEdidName = edidName ?? "Default"
            }
        }
    }
    
    private func validateEdidName(_ name: String) {
        if name.count > 13 {
            isNameValid = false
            validationMessage = "Too long"
        } else if !name.allSatisfy({ $0.isASCII && $0.asciiValue! >= 32 && $0.asciiValue! <= 126 }) {
            isNameValid = false
            validationMessage = "Invalid characters"
        } else {
            isNameValid = true
            validationMessage = ""
        }
    }
    
    private func updateEdidName() {
        Task {
            await firmwareManager.setEdidName(newEdidName)
        }
    }
    
    private func setupSubscriptions() {
        // Subscribe to update completion
        firmwareManager.edidUpdateComplete
            .receive(on: DispatchQueue.main)
            .sink { (success, message) in
                updateSuccess = success
                alertMessage = message
                showingCompletionAlert = true
                
                if success {
                    // Update the current name display
                    currentEdidName = newEdidName
                    newEdidName = ""
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Preview
struct EdidNameView_Previews: PreviewProvider {
    static var previews: some View {
        EdidNameView()
    }
}
