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

struct AspectRatioSettingsView: View {
    @State private var selectedGravity: GravityOption
    @State private var selectedAspectRatioMode: AspectRatioMode
    @State private var selectedCustomAspectRatio: AspectRatioOption
    
    let onConfirm: (GravityOption, AspectRatioMode, AspectRatioOption) -> Void
    let onCancel: () -> Void
    
    init(onConfirm: @escaping (GravityOption, AspectRatioMode, AspectRatioOption) -> Void, 
         onCancel: @escaping () -> Void) {
        self._selectedGravity = State(initialValue: UserSettings.shared.gravity)
        self._selectedAspectRatioMode = State(initialValue: UserSettings.shared.aspectRatioMode)
        self._selectedCustomAspectRatio = State(initialValue: UserSettings.shared.customAspectRatio)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Title
            Text("Aspect Ratio & Video Settings")
                .font(.title2)
                .bold()
            
            // Scaling/Gravity Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Scaling:")
                    .font(.headline)
                
                Picker("Scaling Mode", selection: $selectedGravity) {
                    ForEach(GravityOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                
                Text(selectedGravity.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Aspect Ratio Mode Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Aspect Ratio Source:")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 10) {
                    // Custom Mode
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: selectedAspectRatioMode == .custom ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedAspectRatioMode == .custom ? .blue : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom Aspect Ratio")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text("Use a custom aspect ratio specified by the user")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAspectRatioMode = .custom
                        }
                        
                        if selectedAspectRatioMode == .custom {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Aspect Ratio", selection: $selectedCustomAspectRatio) {
                                    ForEach(AspectRatioOption.allCases, id: \.self) { ratio in
                                        Text(ratio.toString).tag(ratio)
                                    }
                                }
                                
                                Text("Current ratio: \(String(format: "%.3f", selectedCustomAspectRatio.widthToHeightRatio))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                
                                Text("Common resolutions: \(getCommonResolutions(for: selectedCustomAspectRatio))")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                            .padding(.top, 8)
                            .padding(.leading, 20)
                        }
                    }
                    .padding(10)
                    .background(selectedAspectRatioMode == .custom ? Color.blue.opacity(0.05) : Color.clear)
                    .cornerRadius(8)
                    
                    // HID Resolution Mode
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: selectedAspectRatioMode == .hidResolution ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedAspectRatioMode == .hidResolution ? .blue : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("HID Resolution (Device Info)")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text("From HID resolution query (may have blank areas)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAspectRatioMode = .hidResolution
                        }
                    }
                    .padding(10)
                    .background(selectedAspectRatioMode == .hidResolution ? Color.blue.opacity(0.05) : Color.clear)
                    .cornerRadius(8)
                    
                    // Active Resolution Mode
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: selectedAspectRatioMode == .activeResolution ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedAspectRatioMode == .activeResolution ? .blue : .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active Resolution (Auto-Detect)")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text("Detect active video area periodically")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAspectRatioMode = .activeResolution
                        }
                    }
                    .padding(10)
                    .background(selectedAspectRatioMode == .activeResolution ? Color.blue.opacity(0.05) : Color.clear)
                    .cornerRadius(8)
                }
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Buttons
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                Button(action: {
                    onConfirm(selectedGravity, selectedAspectRatioMode, selectedCustomAspectRatio)
                }) {
                    Text("OK")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding(24)
        .frame(width: 500, alignment: .topLeading)
    }
    
    private func getCommonResolutions(for aspectRatio: AspectRatioOption) -> String {
        switch aspectRatio {
        case .ratio16_9:
            return "1920×1080, 2560×1440, 3840×2160"
        case .ratio16_10:
            return "1920×1200, 2560×1600, 1440×900"
        case .ratio21_9:
            return "2560×1080, 3440×1440"
        case .ratio32_15:
            return "1920×900, 1280×600"
        case .ratio211_135:
            return "1280×768"
        case .ratio211_180:
            return "1266×1080"
        case .ratio5_3:
            return "2560×1536, 1920×1152"
        case .ratio3_2:
            return "1200×800"
        case .ratio5_4:
            return "1280×1024, 2560×2048"
        case .ratio4_3:
            return "1600×1200, 1920×1440, 2560×1920"
        case .ratio9_16:
            return "1080×1920, 1440×2560"
        case .ratio9_19_5:
            return "1080×2340"
        case .ratio9_20:
            return "1080×2400"
        case .ratio9_21:
            return "1080×2520"
        case .ratio9_5:
            return "4096×2160"
        case .ratio228_487:
            return "456×974"
        }
    }
}

#Preview {
    AspectRatioSettingsView(
        onConfirm: { _, _, _ in },
        onCancel: { }
    )
}
