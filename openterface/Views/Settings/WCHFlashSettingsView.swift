import SwiftUI

struct WCHFlashSettingsView: View {
    @StateObject private var ispManager = WCHISPManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("WCH Firmware Flash")
                .font(.title2)
                .bold()

            Text("Flash firmware to WCH chips (CH32F103 / CH32V20x series) via USB ISP mode.\nConnect the device in ISP/bootloader mode before scanning.")
                .font(.callout)
                .foregroundColor(.secondary)

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

                    HStack(spacing: 10) {
                        Button("Scan") {
                            ispManager.scanDevices()
                        }
                        .disabled(ispManager.isOperationInProgress)

                        if ispManager.availableDeviceCount > 0 {
                            Text("\(ispManager.availableDeviceCount) device(s) found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(ispManager.isConnected ? "Disconnect" : "Connect") {
                            Task { await ispManager.connect() }
                        }
                        .disabled(ispManager.isOperationInProgress || (!ispManager.isConnected && ispManager.availableDeviceCount == 0))
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

                        // Dump button
                        Button {
                            Task { await ispManager.dumpFirmware() }
                        } label: {
                            Label("Dump", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!ispManager.isConnected || ispManager.isOperationInProgress)
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
                        ProgressView(value: ispManager.operationProgress)
                            .progressViewStyle(.linear)
                    }

                    HStack(spacing: 6) {
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
                        }
                        Text(ispManager.statusMessage)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ispManager.isError ? .red : .primary)
                            .lineLimit(3)
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
