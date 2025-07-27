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

struct AudioSourceSelectionView: View {
    @ObservedObject var audioManager: AudioManager
    @Binding var isPresented: Bool
    @State private var selectedTab: AudioDeviceType = .input
    
    enum AudioDeviceType: String, CaseIterable {
        case input = "Input"
        case output = "Output"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Devices")
                .font(.headline)
                .padding(.bottom, 4)
            
            // Tab selector for Input/Output
            Picker("Device Type", selection: $selectedTab) {
                ForEach(AudioDeviceType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.bottom, 8)
            
            // Device list based on selected tab
            Group {
                if selectedTab == .input {
                    inputDevicesView
                } else {
                    outputDevicesView
                }
            }
            
            // Volume controls
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .padding(.vertical, 4)
                
                if selectedTab == .input {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input Volume (Microphone Gain)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "mic")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            
                            Slider(
                                value: Binding(
                                    get: { audioManager.inputVolume },
                                    set: { audioManager.setInputVolume($0) }
                                ),
                                in: 0...1
                            )
                            
                            Text("\(audioManager.getInputVolumePercentage())%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output Volume (Speaker Volume)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Image(systemName: "speaker")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            
                            Slider(
                                value: Binding(
                                    get: { audioManager.outputVolume },
                                    set: { audioManager.setOutputVolume($0) }
                                ),
                                in: 0...1
                            )
                            
                            Text("\(audioManager.getOutputVolumePercentage())%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(radius: 8)
        .frame(minWidth: 300, maxWidth: 400)
    }
    
    private var inputDevicesView: some View {
        Group {
            if audioManager.availableInputDevices.isEmpty {
                Text("No audio input devices available")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(audioManager.availableInputDevices) { device in
                    AudioDeviceRow(
                        device: device,
                        isSelected: audioManager.selectedInputDevice?.deviceID == device.deviceID,
                        deviceType: .input,
                        onSelect: {
                            audioManager.selectInputDevice(device)
                        }
                    )
                }
            }
        }
    }
    
    private var outputDevicesView: some View {
        Group {
            if audioManager.availableOutputDevices.isEmpty {
                Text("No audio output devices available")
                    .foregroundColor(.secondary)
                    .padding()
                    .onAppear {
                        print("AudioSourceSelectionView: No output devices available")
                    }
            } else {
                ForEach(audioManager.availableOutputDevices) { device in
                    AudioDeviceRow(
                        device: device,
                        isSelected: audioManager.selectedOutputDevice?.deviceID == device.deviceID,
                        deviceType: .output,
                        onSelect: {
                            print("AudioSourceSelectionView: Selecting output device: \(device.name)")
                            audioManager.selectOutputDevice(device)
                        }
                    )
                }
                .onAppear {
                    print("AudioSourceSelectionView: Rendering \(audioManager.availableOutputDevices.count) output devices")
                    for device in audioManager.availableOutputDevices {
                        print("AudioSourceSelectionView: Output device: \(device.name)")
                    }
                }
            }
        }
    }
}

struct AudioDeviceRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let deviceType: AudioSourceSelectionView.AudioDeviceType
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: deviceType == .input ? "mic" : "speaker.wave.2")
                    .foregroundColor(isSelected ? .blue : .primary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .truncationMode(.tail)
                        .foregroundColor(isSelected ? .blue : .primary)
                        .font(.system(size: 13))
                    
                    Text(deviceType == .input ? "Input Device" : "Output Device")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
        .help("Select \(device.name) as audio \(deviceType.rawValue.lowercased()) device")
    }
}

#Preview {
    AudioSourceSelectionView(
        audioManager: AudioManager.shared,
        isPresented: .constant(true)
    )
}
