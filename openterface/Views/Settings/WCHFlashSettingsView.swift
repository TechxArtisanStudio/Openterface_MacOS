import SwiftUI

struct WCHFlashSettingsView: View {
    @StateObject private var ispManager = WCHISPManager.shared
    @State private var selectedDeviceIndex: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard & Mouse Chip Firmware Flash")
                .font(.title2)
                .bold()

            Text("Flash firmware to compatible chips via USB ISP mode.")
                .font(.callout)
                .foregroundColor(.secondary)

            if !ispManager.isConnected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("⚠️ Important: Entering Bootloader Mode")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    Text("1. Disconnect the Target USB port from your host computer\n2. Press and hold the on-board BOOT button\n3. While holding BOOT, connect Target USB to your host\n4. Release BOOT after USB connection is established")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            // MARK: - Device
            GroupBox("Device") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        deviceStatusIndicator
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ispManager.isConnected ? "Connected" : "Not connected")
                                .fontWeight(.medium)
                            if !ispManager.chipInfo.isEmpty {
                                Text(ispManager.chipInfo)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                            }
                        }
                        Spacer()
                    }

                    // Device picker when multiple devices found
                    if ispManager.scannedDevices.count > 1 {
                        Picker("Device:", selection: $selectedDeviceIndex) {
                            ForEach(ispManager.scannedDevices) { device in
                                Text(device.displayName).tag(device.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(ispManager.isConnected || ispManager.isOperationInProgress)
                    }

                    // Show VID/PID and details for scanned devices
                    if !ispManager.scannedDevices.isEmpty {
                        let displayDevice: ScannedDevice? = ispManager.scannedDevices.count > 1
                            ? ispManager.scannedDevices.first(where: { $0.id == selectedDeviceIndex })
                            : ispManager.scannedDevices.first
                        if let device = displayDevice {
                            Text(device.detailedInfo)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(6)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Scan") {
                            ispManager.scanDevices()
                            // Auto-select first device after scan
                            if !ispManager.scannedDevices.isEmpty {
                                selectedDeviceIndex = ispManager.scannedDevices[0].id
                            }
                        }
                        .disabled(ispManager.isOperationInProgress)

                        if ispManager.scannedDevices.count > 1 {
                            Text("\(ispManager.scannedDevices.count) devices found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(ispManager.isConnected ? "Disconnect" : "Connect") {
                            Task { await ispManager.connect(deviceIndex: selectedDeviceIndex) }
                        }
                        .disabled(ispManager.isOperationInProgress || (!ispManager.isConnected && ispManager.scannedDevices.isEmpty))
                    }
                }
                .padding(6)
            }

            // MARK: - Firmware file
            GroupBox("Firmware File") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "doc.badge.ellipsis")
                            .foregroundColor(.secondary)
                        if let url = ispManager.selectedFirmwareURL {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .fontWeight(.medium)
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Text("No file selected")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Choose…") {
                            ispManager.selectFirmwareFile()
                        }
                        .disabled(ispManager.isOperationInProgress)
                    }

                    if let url = ispManager.selectedFirmwareURL {
                        let ext = url.pathExtension.lowercased()
                        HStack(spacing: 4) {
                            Image(systemName: ext == "hex" ? "textformat.123" : "square.and.arrow.down")
                                .font(.caption)
                            Text(ext == "hex" ? "Intel HEX format" : "Binary format")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .padding(6)
            }

            // MARK: - Operations
            GroupBox("Operations") {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        // Flash button
                        Button {
                            Task { await ispManager.flashFirmware() }
                        } label: {
                            Label("Flash Firmware", systemImage: "bolt.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!canOperate)

                        // Verify button
                        Button {
                            Task { await ispManager.verifyFirmware() }
                        } label: {
                            Label("Verify", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!canOperate)
                    }

                    let flashWarning = "⚠ Flashing will erase and overwrite the chip firmware."
                    Text(flashWarning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
            }

            // MARK: - Progress / Status
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    if ispManager.isOperationInProgress {
                        HStack(spacing: 10) {
                            ProgressView(value: ispManager.operationProgress)
                                .progressViewStyle(.linear)
                            Text("\(Int(ispManager.operationProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    HStack(alignment: .top, spacing: 6) {
                        if ispManager.isError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        } else if ispManager.isOperationInProgress {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else if ispManager.operationProgress >= 1.0 && !ispManager.statusMessage.contains("failed") {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if !ispManager.isConnected {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                        Text(ispManager.statusMessage)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ispManager.isError ? .red : .primary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                        if ispManager.isError {
                            Button(action: copyStatusToClipboard) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy error message to clipboard")
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private var canOperate: Bool {
        ispManager.isConnected &&
        !ispManager.isOperationInProgress &&
        ispManager.selectedFirmwareURL != nil
    }

    private func copyStatusToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ispManager.statusMessage, forType: .string)
    }

    private var deviceStatusIndicator: some View {
        Circle()
            .fill(ispManager.isConnected ? Color.green : Color.gray.opacity(0.4))
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(ispManager.isConnected ? Color.green.opacity(0.4) : Color.clear, lineWidth: 4)
                    .scaleEffect(1.5)
            )
    }
}
