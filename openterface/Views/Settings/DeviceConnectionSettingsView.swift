import SwiftUI

struct DeviceConnectionSettingsView: View {
    @ObservedObject private var hidManager = HIDManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var serialPortManager = SerialPortManager.shared
    @ObservedObject private var serialStatus = SerialPortStatus.shared
    @State private var connectionAttempts = 0
    @State private var showingFirmwareUpdate = false
    @State private var isUpdatingBaudrate = false
    @State private var vncPortText: String = ""

    var firmwareVersion: String {
        "v\(serialStatus.chipVersion)"
    }

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
                        Text(serialStatus.isControlChipsetReady ? "Ready" : "Not Ready")
                            .foregroundColor(serialStatus.isControlChipsetReady ? .green : .orange)
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
                        Text(serialStatus.isTargetConnected ? "Connected" : "Disconnected")
                            .foregroundColor(serialStatus.isTargetConnected ? .green : .red)
                    }

                    HStack {
                        Text("Firmware Version:")
                        Spacer()
                        Text(firmwareVersion)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack {
                        Text("Current Resolution:")
                        Spacer()
                        Text("\(AppStatus.hidReadResolusion.width) × \(AppStatus.hidReadResolusion.height)")
                    }

                    HStack {
                        Text("Refresh Rate:")
                        Spacer()
                        Text(String(format: "%.1f Hz", AppStatus.hidReadFps))
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

            GroupBox("Remote Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure network-based remote access protocols.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    GroupBox("Remote Protocol") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("VNC (RFB 3.8)", systemImage: "network")
                                Spacer()
                                Text("Available")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }

                            HStack {
                                Label("RDP", systemImage: "network.badge.shield.half.filled")
                                Spacer()
                                Text("Coming Soon")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                        Text("Remote transport is not active yet. Current VNC fields are saved for upcoming implementation, but an actual VNC/RDP session cannot be started in this build.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ConnectionProtocolMode.allCases, id: \.self) { mode in
                            Button(action: {
                                userSettings.connectionProtocolMode = mode
                                AppStatus.activeConnectionProtocol = mode
                                NotificationCenter.default.post(name: Notification.Name("ConnectionProtocolModeChanged"), object: nil)
                            }) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.displayName)
                                            .font(.body)
                                            .fontWeight(.medium)

                                        Text(mode.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if userSettings.connectionProtocolMode == mode {
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
                                .background(userSettings.connectionProtocolMode == mode ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                                .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    if userSettings.connectionProtocolMode == .vnc {
                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("VNC Connection")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            HStack {
                                Text("Host")
                                    .frame(width: 80, alignment: .leading)
                                TextField("127.0.0.1", text: $userSettings.vncHost)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }

                            HStack {
                                Text("Port")
                                    .frame(width: 80, alignment: .leading)
                                TextField("5900", text: $vncPortText)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .onChange(of: vncPortText) { value in
                                        let filtered = value.filter { $0.isNumber }
                                        if filtered != value {
                                            vncPortText = filtered
                                            return
                                        }
                                        if let port = Int(filtered) {
                                            userSettings.vncPort = port
                                        }
                                    }
                            }

                               HStack {
                                   Text("Username")
                                       .frame(width: 80, alignment: .leading)
                                   TextField("Optional", text: $userSettings.vncUsername)
                                       .textFieldStyle(RoundedBorderTextFieldStyle())
                               }

                            HStack {
                                Text("Password")
                                    .frame(width: 80, alignment: .leading)
                                SecureField("Optional", text: $userSettings.vncPassword)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }

                            HStack {
                                Button("Connect") {
                                    NotificationCenter.default.post(name: Notification.Name("VNCConnectRequested"), object: nil)
                                }
                                .disabled(userSettings.vncHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button("Disconnect") {
                                    NotificationCenter.default.post(name: Notification.Name("VNCDisconnectRequested"), object: nil)
                                }

                                Spacer()

                                Text(vncConnectionStatusText)
                                    .font(.caption)
                                    .foregroundColor(vncConnectionStatusColor)
                            }

                            if !AppStatus.protocolLastErrorMessage.isEmpty {
                                Text(AppStatus.protocolLastErrorMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
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
        .onChange(of: serialPortManager.isDeviceReady) { isReady in
            // Reset the updating flag when device reconnects after baudrate change
            if isReady && isUpdatingBaudrate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isUpdatingBaudrate = false
                }
            }
        }
        .onAppear {
            vncPortText = "\(userSettings.vncPort)"
        }
        .sheet(isPresented: $showingFirmwareUpdate) {
            Text("Firmware Update Dialog")
                .frame(width: 400, height: 300)
        }
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
