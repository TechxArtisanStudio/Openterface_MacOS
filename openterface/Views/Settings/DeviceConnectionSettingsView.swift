import SwiftUI

struct DeviceConnectionSettingsView: View {
    @ObservedObject private var hidManager = HIDManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var serialPortManager = SerialPortManager.shared
    @State private var firmwareVersion = "Unknown"
    @State private var serialNumber = "Unknown"
    @State private var connectionAttempts = 0
    @State private var showingFirmwareUpdate = false
    @State private var isUpdatingBaudrate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Device & Connection Management")
                .font(.title2)
                .bold()

            GroupBox("Device Information") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Control Chipset Ready:")
                        Spacer()
                        Text(AppStatus.isControlChipsetReady ? "Ready" : "Not Ready")
                            .foregroundColor(AppStatus.isControlChipsetReady ? .green : .orange)
                    }

                    HStack {
                        Text("Control Chipset:")
                        Spacer()
                        Text(getControlChipsetDisplayName())
                            .foregroundColor(AppStatus.controlChipsetType != .unknown ? .green : .orange)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack {
                        Text("Video Chipset:")
                        Spacer()
                        Text(getVideoChipsetDisplayName())
                            .foregroundColor(AppStatus.videoChipsetType != .unknown ? .green : .orange)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack {
                        Text("Target Connected:")
                        Spacer()
                        Text(AppStatus.isTargetConnected ? "Connected" : "Disconnected")
                            .foregroundColor(AppStatus.isTargetConnected ? .green : .red)
                    }

                    HStack {
                        Text("Firmware Version:")
                        Spacer()
                        Text(firmwareVersion)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack {
                        Text("Serial Number:")
                        Spacer()
                        Text(serialNumber)
                            .font(.system(.caption, design: .monospaced))
                    }

                    if let resolution = hidManager.getResolution() {
                        HStack {
                            Text("Current Resolution:")
                            Spacer()
                            Text("\(resolution.width) × \(resolution.height)")
                        }
                    }

                    if let fps = hidManager.getFps() {
                        HStack {
                            Text("Refresh Rate:")
                            Spacer()
                            Text(String(format: "%.1f Hz", fps))
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox("Serial Port Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Preferred Baudrate:")
                        Spacer()
                        Picker("Baudrate", selection: $userSettings.preferredBaudrate) {
                            ForEach(BaudrateOption.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 200)
                        .onChange(of: userSettings.preferredBaudrate) { newBaudrate in
                            if serialPortManager.isDeviceReady {
                                isUpdatingBaudrate = true
                                applyBaudrateChange()
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        if serialPortManager.isDeviceReady {
                            Text("Current connected: \(serialPortManager.baudrate) bps")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(userSettings.preferredBaudrate.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Current Connection:")
                        Spacer()
                        if isUpdatingBaudrate {
                            Text("Updating Baudrate...")
                                .foregroundColor(.orange)
                        } else if serialPortManager.isDeviceReady {
                            Text("Connected at \(serialPortManager.baudrate) bps")
                                .foregroundColor(.green)
                        } else {
                            Text("Disconnected")
                                .foregroundColor(.red)
                        }
                    }
                    .font(.caption)

                    Text("Device will automatically reconnect when baudrate is changed")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("⚠️ Important: When changing baudrate:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)

                        Text("• Please wait a few seconds for the change to apply")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("• If keyboard and mouse stop working, disconnect all cables and reconnect")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            GroupBox("Control Mode Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select the operation mode for the HID chip:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ControlMode.allCases, id: \.self) { mode in
                            Button(action: {
                                userSettings.controlMode = mode
                                // Send the mode change command to device
                                if serialPortManager.isDeviceReady {
                                    SerialPortManager.shared.setControlMode(mode)
                                }
                            }) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.displayName)
                                            .font(.body)
                                            .fontWeight(.medium)

                                        Text(mode.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        Text("Mode: 0x\(String(format: "%02X", mode.rawValue))")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if userSettings.controlMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.title3)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundColor(.secondary)
                                            .font(.title3)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(userSettings.controlMode == mode ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                                .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ℹ️ Note:")
                            .font(.caption)
                            .fontWeight(.medium)

                        Text("• When changing to Compatibility Mode from another mode, the device will automatically use mode byte 0x02")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("• The device will reconnect after mode change")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            GroupBox("Connection Management") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Restart HID Operations") {
                            hidManager.restartHIDOperations()
                            connectionAttempts += 1
                        }

                        Button("Stop All HID Operations") {
                            hidManager.stopAllHIDOperations()
                        }

                        Spacer()

                        Text("Attempts: \(connectionAttempts)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("USB Control:")
                        Button("Switch to Host") {
                            hidManager.setUSBtoHost()
                        }
                        Button("Switch to Target") {
                            hidManager.setUSBtoTarget()
                        }

                        Spacer()

                        Text(hidManager.getSwitchStatus() ? "Current: Target" : "Current: Host")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            loadDeviceInfo()
        }
        .onChange(of: serialPortManager.isDeviceReady) { isReady in
            // Reset the updating flag when device reconnects after baudrate change
            if isReady && isUpdatingBaudrate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isUpdatingBaudrate = false
                }
            }
        }
        .sheet(isPresented: $showingFirmwareUpdate) {
            Text("Firmware Update Dialog")
                .frame(width: 400, height: 300)
        }
    }

    private func loadDeviceInfo() {
        // Load device information
        firmwareVersion = "v1.0.0" // Placeholder
        serialNumber = "OT001234567" // Placeholder
    }

    private func getControlChipsetDisplayName() -> String {
        switch AppStatus.controlChipsetType {
        case .ch9329:
            return "CH9329"
        case .ch32v208:
            return "CH32V208"
        case .unknown:
            return "Not Detected"
        }
    }

    private func getVideoChipsetDisplayName() -> String {
        switch AppStatus.videoChipsetType {
        case .ms2109:
            return "MS2109"
        case .ms2109s:
            return "MS2109S"
        case .ms2130s:
            return "MS2130S"
        case .unknown:
            return "Not Detected"
        }
    }

    private func applyBaudrateChange() {
        let targetBaudrate = userSettings.preferredBaudrate.rawValue

        if serialPortManager.isDeviceReady {
            isUpdatingBaudrate = true

            // Delegate all chipset-specific logic to SerialPortManager
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.serialPortManager.resetDeviceToBaudrate(targetBaudrate)

                // Reset the updating flag after operation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.isUpdatingBaudrate = false
                }
            }
        }
    }
}
