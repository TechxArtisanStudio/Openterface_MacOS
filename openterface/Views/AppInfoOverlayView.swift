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

struct AppInfoOverlayView: View {
    @State private var updateTrigger = UUID()
    
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 16) {
                // Column 1: Video & Control
                VStack(alignment: .leading, spacing: 8) {
                    // Video Chipset
                    sectionView(title: "Video Chipset", content: [
                        ("Type", formatVideoChipsetType(AppStatus.videoChipsetType)),
                        ("Firmware", AppStatus.videoFirmwareVersion.isEmpty ? "N/A" : AppStatus.videoFirmwareVersion),
                        ("HDMI Signal", AppStatus.hasHdmiSignal ?? false ? "Yes" : "No")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Control Chipset
                    sectionView(title: "Control Chipset", content: [
                        ("Type", formatControlChipsetType(AppStatus.controlChipsetType)),
                        ("Status", AppStatus.isControlChipsetReady ? "Ready" : "Not Ready"),
                        ("Version", String(AppStatus.chipVersion)),
                    ])
                }
                .frame(minWidth: 200, alignment: .topLeading)
                
                Divider()
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(0.3))
                
                // Column 2: Display & Resolution
                VStack(alignment: .leading, spacing: 8) {
                    // Video Resolution
                    sectionView(title: "Resolution", content: [
                        ("Size", "\(AppStatus.hidReadResolusion.width) x \(AppStatus.hidReadResolusion.height)"),
                        ("FPS", String(format: "%.1f", AppStatus.hidReadFps)),
                        ("Pixel Clock", "\(AppStatus.hidReadPixelClock) MHz"),
                        ("Display", "\(Int(AppStatus.videoDimensions.width)) x \(Int(AppStatus.videoDimensions.height))")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Video Timing
                    sectionView(title: "Timing", content: [
                        ("H Total", "\(AppStatus.hidInputHTotal) (HST: \(AppStatus.hidInputHst))"),
                        ("V Total", "\(AppStatus.hidInputVTotal) (VST: \(AppStatus.hidInputVst))"),
                        ("Hsync", String(AppStatus.hidInputHsyncWidth)),
                        ("Vsync", String(AppStatus.hidInputVsyncWidth))
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Video Rect
                    sectionView(title: "Active Video Rect", content: [
                        ("X", String(format: "%.0f", AppStatus.activeVideoRect.origin.x)),
                        ("Y", String(format: "%.0f", AppStatus.activeVideoRect.origin.y)),
                        ("W", String(format: "%.0f", AppStatus.activeVideoRect.width)),
                        ("H", String(format: "%.0f", AppStatus.activeVideoRect.height))
                    ])
                }
                .frame(minWidth: 200, alignment: .topLeading)
                
                Divider()
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(0.3))
                
                // Column 3: Connection & Switch
                VStack(alignment: .leading, spacing: 8) {
                    // Connection Status
                    sectionView(title: "Connection", content: [
                        ("Target", AppStatus.isTargetConnected ? "✓" : "✗"),
                        ("Keyboard", AppStatus.isKeyboardConnected ?? false ? "✓" : "✗"),
                        ("Mouse", AppStatus.isMouseConnected ?? false ? "✓" : "✗"),
                        ("HDMI", AppStatus.isHDMIConnected ? "✓" : "✗")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Switch Status
                    sectionView(title: "Switch", content: [
                        ("Hardware", AppStatus.isHardwareSwitchOn ? "Target" : "Host"),
                        ("Software", AppStatus.isSoftwareSwitchOn ? "Target" : "Host"),
                        ("USB", AppStatus.isUSBSwitchConnectToTarget ? "Target" : "Host")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Window & View
                    sectionView(title: "Window", content: [
                        ("X", String(format: "%.0f", AppStatus.currentWindow.origin.x)),
                        ("Y", String(format: "%.0f", AppStatus.currentWindow.origin.y)),
                        ("W", String(format: "%.0f", AppStatus.currentWindow.width)),
                        ("H", String(format: "%.0f", AppStatus.currentWindow.height))
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // View Rect
                    sectionView(title: "View", content: [
                        ("X", String(format: "%.0f", AppStatus.currentView.origin.x)),
                        ("Y", String(format: "%.0f", AppStatus.currentView.origin.y)),
                        ("W", String(format: "%.0f", AppStatus.currentView.width)),
                        ("H", String(format: "%.0f", AppStatus.currentView.height)),
                        ("Ratio", getMatchedAspectRatio())
                    ])
                }
                .frame(minWidth: 200, alignment: .topLeading)
                
                Divider()
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(0.3))
                
                // Column 4: Lock States & Misc
                VStack(alignment: .leading, spacing: 8) {
                    // Lock States
                    sectionView(title: "Locks", content: [
                        ("Num", AppStatus.isNumLockOn ? "On" : "Off"),
                        ("Caps", AppStatus.isCapLockOn ? "On" : "Off"),
                        ("H Caps", AppStatus.isHostCapLockOn ? "On" : "Off"),
                        ("Scroll", AppStatus.isScrollOn ? "On" : "Off")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // Misc
                    sectionView(title: "Misc", content: [
                        ("Audio", AppStatus.isAudioEnabled ? "On" : "Off"),
                        ("Serial", AppStatus.serialPortName),
                        ("Baud", String(AppStatus.serialPortBaudRate)),
                        ("Log Mode", AppStatus.isLogMode ? "On" : "Off")
                    ])
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                    
                    // UI States
                    sectionView(title: "UI", content: [
                        ("Mouse In", AppStatus.isMouseInView ? "Yes" : "No"),
                        ("Focus", AppStatus.isFouceWindow ? "Yes" : "No"),
                        ("Edge", AppStatus.isMouseEdge ? "Yes" : "No"),
                        ("Cursor", AppStatus.isCursorHidden ? "Hidden" : "Visible"),
                        ("OCR", AppStatus.isAreaOCRing ? "Running" : "Idle")
                    ])
                }
                .frame(minWidth: 200, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: false)
            .padding(8)
            .background(Color.black.opacity(0.75))
            .foregroundColor(.white)
            .cornerRadius(8)
            .allowsHitTesting(false)
            .id(updateTrigger)
        }
        .onReceive(timer) { _ in
            updateTrigger = UUID()
        }
    }
    
    private func sectionView(title: String, content: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.yellow)
            
            ForEach(content, id: \.0) { label, value in
                HStack(spacing: 4) {
                    Text(label + ":")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: 80, alignment: .leading)
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
            }
        }
    }
    
    private func formatVideoChipsetType(_ type: VideoChipsetType) -> String {
        switch type {
        case .ms2109:
            return "MS2109"
        case .ms2109s:
            return "MS2109S"
        case .ms2130s:
            return "MS2130S"
        case .unknown:
            return "Unknown"
        }
    }
    
    private func getMatchedAspectRatio() -> String {
        let view = AppStatus.currentView
        
        // Guard against zero dimensions
        guard view.width > 0 && view.height > 0 else {
            return "N/A"
        }
        
        let aspectRatio = view.width / view.height
        let tolerance: CGFloat = 0.01
        
        // Find the closest matching aspect ratio from AspectRatioOption
        var closestMatch: AspectRatioOption? = nil
        var closestDifference: CGFloat = CGFloat.infinity
        
        for option in AspectRatioOption.allCases {
            let difference = abs(aspectRatio - option.widthToHeightRatio)
            if difference < closestDifference {
                closestDifference = difference
                closestMatch = option
                
                // If within tolerance, use exact match
                if difference < tolerance {
                    break
                }
            }
        }
        
        let ratioString = String(format: "%.3f", aspectRatio)
        if let match = closestMatch {
            return "\(match.rawValue) (\(ratioString))"
        }
        
        return ratioString
    }
    
    private func formatControlChipsetType(_ type: ControlChipsetType) -> String {
        switch type {
        case .ch9329:
            return "CH9329"
        case .ch32v208:
            return "CH32V208"
        case .unknown:
            return "Unknown"
        }
    }
    
    private func formatSDCardDirection(_ direction: SDCardDirection) -> String {
        switch direction {
        case .host:
            return "Host"
        case .target:
            return "Target"
        case .unknown:
            return "Unknown"
        }
    }
}
