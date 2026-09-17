import SwiftUI

struct AudioVideoSettingsView: View {
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var videoManager = VideoManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Audio & Video Configuration")
                .font(.title2)
                .bold()

            // Audio Settings
            GroupBox("Audio Control") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable audio streaming", isOn: $userSettings.isAudioEnabled)
                        .onChange(of: userSettings.isAudioEnabled) { enabled in
                            audioManager.setAudioEnabled(enabled)
                        }


                        Text("Status: \(audioManager.statusMessage)")
                            .font(.caption)
                            .foregroundColor(audioManager.isAudioDeviceConnected ? .green : .orange)

                        HStack {
                            Text("Available input devices: \(audioManager.availableInputDevices.count)")
                            Spacer()
                            Button("Refresh Devices") {
                                audioManager.updateAvailableAudioDevices()
                            }
                        }
                        .font(.caption)

                        if let selectedDevice = audioManager.selectedInputDevice {
                            Text("Input: \(selectedDevice.name)")
                                .font(.caption)
                        }

                        if let selectedDevice = audioManager.selectedOutputDevice {
                            Text("Output: \(selectedDevice.name)")
                                .font(.caption)
                        }

                }
                .padding(.vertical, 8)
            }

            // Video Settings
            GroupBox("Display & Video Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Full screen mode", isOn: $userSettings.isFullScreen)

                    // Aspect Ratio Mode Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aspect Ratio Mode")
                            .font(.system(size: 14, weight: .medium))

                        Picker("", selection: $userSettings.aspectRatioMode) {
                            ForEach(AspectRatioMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(userSettings.aspectRatioMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Custom Aspect Ratio Picker - only show when in custom mode
                    if userSettings.aspectRatioMode == .custom {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Aspect ratio:")
                                Picker("", selection: $userSettings.customAspectRatio) {
                                    ForEach(AspectRatioOption.allCases, id: \.self) { ratio in
                                        Text(ratio.toString).tag(ratio)
                                    }
                                }
                                .frame(width: 120)
                            }

                            Text("Current ratio: \(String(format: "%.3f", userSettings.customAspectRatio.widthToHeightRatio))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Video Format Selection - Single unified picker
                    if !videoManager.availableVideoFormats.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Video Capture Format")
                                .font(.system(size: 14, weight: .medium))

                            Picker("Format:", selection: Binding(
                                get: { videoManager.selectedVideoFormat },
                                set: { newValue in
                                    videoManager.selectedVideoFormat = newValue
                                    applyVideoFormat()
                                }
                            )) {
                                ForEach(sortedVideoFormats, id: \.self) { format in
                                    Text(format.description).tag(format)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Toggle("Show HID resolution change alerts", isOn: Binding(
                        get: { !userSettings.doNotShowHidResolutionAlert },
                        set: { userSettings.doNotShowHidResolutionAlert = !$0 }
                    ))
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func applyVideoFormat() {
        // Restart video session to apply new format
        videoManager.stopVideoSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.videoManager.prepareVideo()
        }
    }

    // MARK: - Helper Properties

    private var sortedVideoFormats: [VideoFormat] {
        videoManager.availableVideoFormats.sorted {
            if $0.pixelFormat != $1.pixelFormat {
                return $0.pixelFormat < $1.pixelFormat
            }
            if $0.resolution.width != $1.resolution.width {
                return $0.resolution.width > $1.resolution.width
            }
            if $0.resolution.height != $1.resolution.height {
                return $0.resolution.height > $1.resolution.height
            }
            return $0.frameRate > $1.frameRate
        }
    }
}
