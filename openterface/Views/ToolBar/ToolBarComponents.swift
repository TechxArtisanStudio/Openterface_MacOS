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

struct ResolutionView: View {
    @ObservedObject var userSettings = UserSettings.shared
    
    let width: String
    let height: String
    let fps: String
    let helpText: String
    
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: -2) {
                Text("\(width)x\(height)").font(.system(size: 10, weight: .medium))
                HStack(spacing: 2) {
                    Text("\(fps)Hz").font(.system(size: 8, weight: .medium))
                    Text(userSettings.customAspectRatio.toString)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(
                            isAspectRatioMismatch ? .red : .primary // Conditional color
                        )
                }
            }
        }
        .frame(width: 66, alignment: .leading)
        .help(helpText)
    }
    
    private var isAspectRatioMismatch: Bool {
        guard let widthValue = Double(width),
              let heightValue = Double(height) else {
            return false
        }
        var calculatedAspectRatio = widthValue / heightValue
        // Special case for 4096x2160 aspect ratio, it should be 9:5 (1.8)
        if widthValue == 4096 && heightValue == 2160 {
            calculatedAspectRatio = 1.8
        }
        return abs(calculatedAspectRatio - userSettings.customAspectRatio.widthToHeightRatio) > 0.01
    }
}

// Add serial information view
struct SerialInfoView: View {
    let portName: String
    let baudRate: Int
    let processingHz: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cable.connector")
                .font(.system(size: 16))
                .foregroundColor(.primary)
            // always display port name and baud/Hz; ignore configuration state
            Text("\(portName)\n\(baudRate) bps, \(processingHz)Hz")
                .font(.system(size: 9, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(minWidth: 140, minHeight: 30, alignment: .leading)
    }
}

struct RemoteInfoView: View {
    let protocolMode: ConnectionProtocolMode

    @State private var lastSampleTime: Date = Date()
    @State private var lastRxTotal: UInt64 = 0
    @State private var lastTxTotal: UInt64 = 0
    @State private var rxBytesPerSecond: Double = 0
    @State private var txBytesPerSecond: Double = 0

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            if !compressionText.isEmpty {
                Text(compressionText)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.10))
                    .clipShape(Capsule())
            }
            Text("\(endpointText)\n↓ \(speedText(rxBytesPerSecond)) ↑ \(speedText(txBytesPerSecond))")
                .font(.system(size: 9, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(minWidth: 210, minHeight: 30, alignment: .leading)
        .help(tooltipText)
        .onAppear {
            lastSampleTime = Date()
            lastRxTotal = AppStatus.remoteRxBytesTotal
            lastTxTotal = AppStatus.remoteTxBytesTotal
        }
        .onReceive(timer) { now in
            let elapsed = max(now.timeIntervalSince(lastSampleTime), 0.001)
            let rxTotal = AppStatus.remoteRxBytesTotal
            let txTotal = AppStatus.remoteTxBytesTotal

            let rxDelta = rxTotal >= lastRxTotal ? (rxTotal - lastRxTotal) : 0
            let txDelta = txTotal >= lastTxTotal ? (txTotal - lastTxTotal) : 0

            rxBytesPerSecond = Double(rxDelta) / elapsed
            txBytesPerSecond = Double(txDelta) / elapsed

            lastSampleTime = now
            lastRxTotal = rxTotal
            lastTxTotal = txTotal
        }
    }

    private var endpointText: String {
        let host: String
        let port: Int

        if !AppStatus.remoteEndpointHost.isEmpty, AppStatus.remoteEndpointPort > 0 {
            host = AppStatus.remoteEndpointHost
            port = AppStatus.remoteEndpointPort
        } else {
            switch protocolMode {
            case .vnc:
                host = UserSettings.shared.vncHost.trimmingCharacters(in: .whitespacesAndNewlines)
                port = UserSettings.shared.vncPort
            case .rdp:
                host = UserSettings.shared.rdpHost.trimmingCharacters(in: .whitespacesAndNewlines)
                port = UserSettings.shared.rdpPort
            case .kvm:
                host = ""
                port = 0
            }
        }

        let proto = protocolMode == .rdp ? "RDP" : "VNC"
        if host.isEmpty || port <= 0 {
            return "\(proto) remote"
        }
        return "\(proto) \(host):\(port)"
    }

    private var compressionText: String {
        let liveCompression = AppStatus.remoteCompressionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveCompression.isEmpty {
            return liveCompression
        }

        switch protocolMode {
        case .vnc:
            return UserSettings.shared.vncEnableZLIBCompression ? "ZLIB?" : "RAW"
        case .rdp, .kvm:
            return ""
        }
    }

    private var tooltipText: String {
        var parts: [String] = [endpointText]

        if !compressionText.isEmpty {
            parts.append("Compression: \(compressionText)")
        }

        if AppStatus.remoteFramesPerSecond > 0 {
            parts.append(String(format: "fps=%.1f", AppStatus.remoteFramesPerSecond))
        }

        if AppStatus.remoteBandwidthMBps > 0 {
            parts.append(String(format: "bandwidth=%.2fMB/s", AppStatus.remoteBandwidthMBps))
        }

        return parts.joined(separator: "\n")
    }

    private func speedText(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

// Caps Lock indicator view - shows a small icon and label with color indicating Caps state
struct CapsLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        Button(action: {
            KeyboardManager.shared.toggleCapsLock()
        }) {
            Text("CAPS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isCapLockOn ? .blue : .secondary)
                .frame(width: 54, alignment: .center)
        }
        .buttonStyle(.plain)
        .help(serialPortStatus.isCapLockOn ? "Target Caps Lock is ON – click to toggle" : "Target Caps Lock is OFF – click to toggle")
    }
}

// Num Lock indicator view - shows label with color indicating Num Lock state
struct NumLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        Button(action: {
            KeyboardManager.shared.toggleNumLock()
        }) {
            Text("NUM")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isNumLockOn ? .blue : .secondary)
                .frame(width: 54, alignment: .center)
        }
        .buttonStyle(.plain)
        .help(serialPortStatus.isNumLockOn ? "Target Num Lock is ON – click to toggle" : "Target Num Lock is OFF – click to toggle")
    }
}

// Scroll Lock indicator view - shows label with color indicating Scroll Lock state
struct ScrollLockIndicatorView: View {
    @ObservedObject var serialPortStatus = SerialPortStatus.shared
    var body: some View {
        Button(action: {
            KeyboardManager.shared.toggleScrollLock()
        }) {
            Text("SCR")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(serialPortStatus.isScrollOn ? .blue : .secondary)
                .frame(width: 54, alignment: .center)
        }
        .buttonStyle(.plain)
        .help(serialPortStatus.isScrollOn ? "Target Scroll Lock is ON – click to toggle" : "Target Scroll Lock is OFF – click to toggle")
    }
}

