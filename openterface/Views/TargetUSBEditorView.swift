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

struct TargetUSBEditorView: View {
    private static let defaultManufacturer = "TechxArtisan"
    private static let defaultProductName = "KVM Keyboard & Mouse"
    private static let defaultSerialNumber = "SN123456"
    private static let defaultOperatingMode = 0x82
    private static let defaultVid = "86 1A"
    private static let defaultPid = "29 E1"
    
    @State private var vid: String = ""
    @State private var pid: String = ""
    @State private var enableFlag: String = ""
    @State private var manufacturer: String = ""
    @State private var productName: String = ""
    @State private var serialNumber: String = ""
    @State private var operatingMode: Int = 0x82
    
    @State private var enableOverrideManufacturer: Bool = false
    @State private var enableOverrideProductName: Bool = false
    @State private var enableOverrideSerialNumber: Bool = false
    @State private var enableOverridePidVid: Bool = false
    
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var alertMessage = ""
    
    private let userDefaults = UserDefaults.standard
    
    var body: some View {
        TabView {
            // Operating Mode Tab
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    GroupBox("Operating Mode") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The Operating Mode determines how the device presents itself to the connected system. To adapt to different application requirements, the software will automatically reset the device to the corresponding operating mode when it detects the device is connected. Choose the mode that best fits your use case.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 4)
                            Text("Select the operating mode for the keyboad and mouse emulation:")
                                .font(.headline)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach([
                                    (0x00, "[Performance] Standard USB keyboard + USB mouse device + USB custom HID device", "The target USB port is a multi-functional composite device supporting a keyboard, mouse, and custom HID device. It performs best, though the mouse may have compatibility issues with Mac OS and Linux."),
                                    (0x01, "[Keyboard Only] Standard USB keyboard device", "The target USB port is a standard keyboard device without multimedia keys, supporting full keyboard mode and suitable for systems that don't support composite devices."),
                                    (0x02, "[Compatibility] Standard USB keyboard + USB mouse device", "The target USB port is a multi-functional composite device for keyboard and mouse. Best compatibility with Mac OS, Android, and Linux.")
                                ], id: \.0) { mode in
                                    Button(action: {
                                        operatingMode = mode.0
                                    }) {
                                        HStack {
                                            Image(systemName: operatingMode == mode.0 ? "largecircle.fill.circle" : "circle")
                                                .foregroundColor(operatingMode == mode.0 ? .accentColor : .secondary)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(mode.1)
                                                    .font(.body)
                                                    .foregroundColor(.primary)
                                                    .multilineTextAlignment(.leading)
                                                Text(mode.2)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(operatingMode == mode.0 ? Color.accentColor.opacity(0.1) : Color.clear)
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(10)
                    }
                    
                    // Action Buttons for Operating Mode
                    HStack(spacing: 15) {
                        Spacer()
                        
                        Button("Load Defaults") {
                            loadDefaultValues()
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Save Configuration") {
                            saveConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Apply Operating Mode") {
                            applyOperatingMode()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!SerialPortManager.shared.isDeviceReady)
                    }
                }
                .padding(20)
            }
            .tabItem {
                Image(systemName: "gear")
                Text("Operating Mode")
            }
            
            // USB Configuration Tab
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("The USB Configuration section allows you to customize the device's USB identifiers and string descriptors. These settings control how the device is recognized by the target OS. For most users, the default values are recommended. Only change these settings if you have specific requirements for device identification or compatibility.\n\nNote: These settings are saved to the chip and will not be automatically applied when the device is detected. You must manually apply the configuration for changes to take effect.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    
                    // USB Identifiers Section
                    GroupBox("USB Identifiers") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Override VID & PID", isOn: $enableOverridePidVid)
                                .help("Enable to allow editing of Vendor ID (VID) and Product ID (PID)")
                            HStack {
                                Text("VID (Vendor ID):")
                                    .frame(width: 120, alignment: .leading)
                                TextField("e.g., 86 1A", text: $vid)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .help("Vendor ID in hex format (e.g., 86 1A)")
                                    .disabled(!enableOverridePidVid)
                            }
                            HStack {
                                Text("PID (Product ID):")
                                    .frame(width: 120, alignment: .leading)
                                TextField("e.g., 29 E1", text: $pid)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .help("Product ID in hex format (e.g., 29 E1)")
                                    .disabled(!enableOverridePidVid)
                            }
                        }
                        .padding(10)
                    }
                    
                    // USB Descriptors Section
                    GroupBox("USB Descriptors") {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("Manufacturer", isOn: $enableOverrideManufacturer)
                                        .frame(width: 120)
                                    TextField("Manufacturer name", text: $manufacturer)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(!enableOverrideManufacturer)
                                }
                                
                                HStack {
                                    Toggle("Product", isOn: $enableOverrideProductName)
                                        .frame(width: 120)
                                    TextField("Product name", text: $productName)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(!enableOverrideProductName)
                                }
                                
                                HStack {
                                    Toggle("Serial Number", isOn: $enableOverrideSerialNumber)
                                        .frame(width: 120)
                                    TextField("Serial number", text: $serialNumber)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .disabled(!enableOverrideSerialNumber)
                                }
                            }
                        }
                        .padding(10)
                    }
                    
                    // Action Buttons
                    HStack(spacing: 15) {
                        Spacer()
                        
                        Button("Load Defaults") {
                            loadDefaultValues()
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Save Configuration") {
                            saveConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Apply to Device") {
                            applyToDevice()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!SerialPortManager.shared.isDeviceReady)
                    }
                }
                .padding(20)
            }
            .tabItem {
                Image(systemName: "cable.connector")
                Text("USB Configuration")
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadCurrentValues()
        }
        .onChange(of: enableOverrideManufacturer) { _ in updateEnableFlag() }
        .onChange(of: enableOverrideProductName) { _ in updateEnableFlag() }
        .onChange(of: enableOverrideSerialNumber) { _ in updateEnableFlag() }
        .onChange(of: enableOverridePidVid) { _ in updateEnableFlag() }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func loadCurrentValues() {
        vid = userDefaults.string(forKey: "serial_vid") ?? Self.defaultVid
        pid = userDefaults.string(forKey: "serial_pid") ?? Self.defaultPid
        enableFlag = userDefaults.string(forKey: "serial_enableflag") ?? "00"
        manufacturer = userDefaults.string(forKey: "serial_customVIDDescriptor") ?? Self.defaultManufacturer
        productName = userDefaults.string(forKey: "serial_customPIDDescriptor") ?? Self.defaultProductName
        serialNumber = userDefaults.string(forKey: "serial_serialnumber") ?? Self.defaultSerialNumber
        operatingMode = userDefaults.integer(forKey: "hardware_operatingMode")
        if operatingMode == 0 { operatingMode = Self.defaultOperatingMode }
        
        // Parse enable flag to set toggles
        if let flag = UInt8(enableFlag, radix: 16) {
            enableOverrideManufacturer = (flag & 0x01) != 0
            enableOverrideProductName = (flag & 0x02) != 0
            enableOverrideSerialNumber = (flag & 0x04) != 0
            enableOverridePidVid = (flag & 0x08) != 0
        }
    }
    
    private func loadDefaultValues() {
        vid = Self.defaultVid
        pid = Self.defaultPid
        manufacturer = Self.defaultManufacturer
        productName = Self.defaultProductName
        serialNumber = Self.defaultSerialNumber
        operatingMode = Self.defaultOperatingMode
        enableOverrideManufacturer = false
        enableOverrideProductName = false
        enableOverrideSerialNumber = false
        enableOverridePidVid = false
        updateEnableFlag()
    }
    
    private func updateEnableFlag() {
        var flag: UInt8 = 0
        if enableOverrideManufacturer { flag |= 0x01 }
        if enableOverrideProductName { flag |= 0x02 }
        if enableOverrideSerialNumber { flag |= 0x04 }
        if enableOverridePidVid { flag |= 0x08 }
        enableFlag = String(format: "%02X", flag)
    }
    
    private func saveConfiguration() {
        // Validate VID and PID format
        if !isValidHexString(vid) || !isValidHexString(pid) {
            alertMessage = "Invalid VID or PID format. Please use hex format like '86 1A' (2 bytes, 4 hex digits)."
            showErrorAlert = true
            return
        }
        // Ensure VID and PID are exactly 2 bytes (4 hex digits, possibly with a space)
        let vidClean = vid.replacingOccurrences(of: " ", with: "")
        let pidClean = pid.replacingOccurrences(of: " ", with: "")
        if vidClean.count != 4 || pidClean.count != 4 {
            alertMessage = "VID and PID must be exactly 2 bytes (4 hex digits, e.g., '86 1A')."
            showErrorAlert = true
            return
        }
        // Validate length of Manufacturer, Product name, and Serial Number
        if manufacturer.count > 23 {
            alertMessage = "Manufacturer must be no more than 23 characters."
            showErrorAlert = true
            return
        }
        if productName.count > 23 {
            alertMessage = "Product name must be no more than 23 characters."
            showErrorAlert = true
            return
        }
        if serialNumber.count > 23 {
            alertMessage = "Serial Number must be no more than 23 characters."
            showErrorAlert = true
            return
        }
        
        updateEnableFlag()
        
        userDefaults.set(vid, forKey: "serial_vid")
        userDefaults.set(pid, forKey: "serial_pid")
        userDefaults.set(enableFlag, forKey: "serial_enableflag")
        userDefaults.set(manufacturer, forKey: "serial_customVIDDescriptor")
        userDefaults.set(productName, forKey: "serial_customPIDDescriptor")
        userDefaults.set(serialNumber, forKey: "serial_serialnumber")
        userDefaults.set(operatingMode, forKey: "hardware_operatingMode")
        
        alertMessage = "Configuration saved successfully!"
        showSuccessAlert = true
        
        Logger.shared.log(content: "USB configuration saved: VID=\(vid), PID=\(pid), EnableFlag=\(enableFlag)")
    }
    
    private func applyToDevice() {
        if !SerialPortManager.shared.isDeviceReady {
            alertMessage = "Device is not ready. Please ensure the device is connected."
            showErrorAlert = true
            return
        }
        
        saveConfiguration()
        
        // Apply configuration to device
        SerialPortManager.shared.setUSBConfiguration()
        
        alertMessage = "Configuration applied to device successfully!"
        showSuccessAlert = true
        
        Logger.shared.log(content: "USB configuration applied to device")
    }
    
    private func applyOperatingMode() {
        if !SerialPortManager.shared.isDeviceReady {
            alertMessage = "Device is not ready. Please ensure the device is connected."
            showErrorAlert = true
            return
        }
        
        // Save the operating mode setting
        userDefaults.set(operatingMode, forKey: "hardware_operatingMode")
        
        // Apply operating mode to device (this may require a factory reset)
//        SerialPortManager.shared.factoryResetHipChip()
        
        alertMessage = "Operating mode applied successfully! Device may restart."
        showSuccessAlert = true
        
        Logger.shared.log(content: "Operating mode changed to: \(String(format: "%02X", operatingMode))")
    }
    
    private func isValidHexString(_ string: String) -> Bool {
        let cleanString = string.replacingOccurrences(of: " ", with: "")
        return cleanString.count % 2 == 0 && cleanString.allSatisfy { $0.isHexDigit }
    }
}

#Preview {
    TargetUSBEditorView()
}
