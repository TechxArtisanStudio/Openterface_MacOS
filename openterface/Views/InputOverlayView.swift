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

struct InputOverlayView: View {
    @ObservedObject var inputMonitor = InputMonitorManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Host input section
            VStack(alignment: .leading, spacing: 2) {
                Text("Host Input:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Position: \(Int(inputMonitor.mouseLocation.x)), \(Int(inputMonitor.mouseLocation.y))")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse: \(inputMonitor.hostMouseButtons.isEmpty ? "None" : inputMonitor.hostMouseButtons)")
                    .font(.system(.caption, design: .monospaced))
                Text("  Keys: \(inputMonitor.hostKeys)")
                    .font(.system(.caption, design: .monospaced))
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Target output section
            VStack(alignment: .leading, spacing: 2) {
                Text("Target Output:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Position: \(inputMonitor.targetMouse)")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse: \(inputMonitor.targetMouseButtons.isEmpty ? "None" : inputMonitor.targetMouseButtons)")
                    .font(.system(.caption, design: .monospaced))
                Text("  Keys: \(inputMonitor.targetKeys)")
                    .font(.system(.caption, design: .monospaced))
                if !inputMonitor.targetScanCodes.isEmpty {
                    Text("  Scan: \(inputMonitor.targetScanCodes)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Acknowledgement latency section
            VStack(alignment: .leading, spacing: 2) {
                Text("Ack Latency:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Keyboard: \(String(format: "%.1f", inputMonitor.keyboardAckLatency))ms (Max: \(String(format: "%.1f", inputMonitor.keyboardMaxLatency))ms)")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse: \(String(format: "%.1f", inputMonitor.mouseAckLatency))ms (Max: \(String(format: "%.1f", inputMonitor.mouseMaxLatency))ms)")
                    .font(.system(.caption, design: .monospaced))
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Acknowledgement rate section
            VStack(alignment: .leading, spacing: 2) {
                Text("Ack Rate:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Keyboard: \(String(format: "%.1f", inputMonitor.keyboardAckRate))/s")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse: \(String(format: "%.1f", inputMonitor.mouseAckRate))/s")
                    .font(.system(.caption, design: .monospaced))
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // Statistics section
            VStack(alignment: .leading, spacing: 2) {
                Text("Statistics:")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text("  Mouse Input: \(String(format: "%.1f", inputMonitor.mouseEventsPerSecond))/s")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse Output: \(String(format: "%.1f", inputMonitor.mouseOutputEventRate))/s")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse Drop: \(String(format: "%.1f", inputMonitor.mouseEventDropRate))/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(inputMonitor.mouseEventDropRate > 0 ? .red : .white)
                Text("  Queue: \(inputMonitor.mouseEventQueueSize)/10(Peak:\(inputMonitor.mouseEventQueuePeakSize))")
                    .font(.system(.caption, design: .monospaced))
                Text("  Mouse Clicks: \(String(format: "%.1f", inputMonitor.mouseClicksPerSecond))/s")
                    .font(.system(.caption, design: .monospaced))
                Text("  Key Events: \(String(format: "%.1f", inputMonitor.keyEventsPerSecond))/s")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .fixedSize()
        .padding(8)
        .background(Color.black.opacity(0.6))
        .foregroundColor(.white)
        .cornerRadius(8)
        .allowsHitTesting(false) // Pass clicks through to the underlying view
    }
}
