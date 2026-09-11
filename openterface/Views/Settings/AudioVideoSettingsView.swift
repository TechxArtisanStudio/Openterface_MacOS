import SwiftUI
import CoreMedia

struct AudioVideoSettingsView: View {
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var videoManager = VideoManager.shared

    @State private var showFormatMismatchAlert = false
    @State private var formatMismatchMessage = ""

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

                    // Video Format Selection
                    if !videoManager.availableVideoFormats.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Video Capture Format")
                                .font(.system(size: 14, weight: .medium))

                            // Resolution Picker
                            HStack {
                                Text("Resolution:")
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { userSettings.selectedVideoResolution },
                                    set: { newValue in
                                        userSettings.selectedVideoResolution = newValue
                                        // Reset frame rate and pixel format to valid values for this resolution
                                        if let firstRate = frameRates(for: newValue).first {
                                            userSettings.selectedVideoFrameRate = firstRate
                                            if let firstFormat = pixelFormats(for: newValue, frameRate: firstRate).first {
                                                userSettings.selectedVideoPixelFormat = firstFormat
                                            }
                                        }
                                    }
                                )) {
                                    ForEach(uniqueResolutions, id: \.self) { resolution in
                                        Text("\(resolution.width)x\(resolution.height)").tag(resolution)
                                    }
                                }
                                .frame(width: 150)
                                .onChange(of: userSettings.selectedVideoResolution) { _ in
                                    applyVideoFormat()
                                }
                            }

                            // Frame Rate Picker - filtered by selected resolution
                            HStack {
                                Text("Frame Rate:")
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { userSettings.selectedVideoFrameRate },
                                    set: { newValue in
                                        userSettings.selectedVideoFrameRate = newValue
                                        // Reset pixel format to valid value for this resolution + frame rate
                                        if let firstFormat = pixelFormats(for: userSettings.selectedVideoResolution, frameRate: newValue).first {
                                            userSettings.selectedVideoPixelFormat = firstFormat
                                        }
                                    }
                                )) {
                                    ForEach(frameRates(for: userSettings.selectedVideoResolution), id: \.self) { rate in
                                        Text("\(Int(rate)) fps").tag(rate)
                                    }
                                }
                                .frame(width: 150)
                                .onChange(of: userSettings.selectedVideoFrameRate) { _ in
                                    applyVideoFormat()
                                }
                            }

                            // Pixel Format Picker - filtered by selected resolution + frame rate
                            HStack {
                                Text("Pixel Format:")
                                    .frame(width: 100, alignment: .leading)
                                Picker("", selection: Binding(
                                    get: { userSettings.selectedVideoPixelFormat },
                                    set: { userSettings.selectedVideoPixelFormat = $0 }
                                )) {
                                    ForEach(pixelFormats(for: userSettings.selectedVideoResolution, frameRate: userSettings.selectedVideoFrameRate), id: \.self) { format in
                                        Text(formatDisplayName(format)).tag(format)
                                    }
                                }
                                .frame(width: 150)
                                .onChange(of: userSettings.selectedVideoPixelFormat) { _ in
                                    applyVideoFormat()
                                }
                            }

                            Text("Current: \(videoManager.selectedVideoFormat.description)")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
        .alert("Video Format Not Supported", isPresented: $showFormatMismatchAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(formatMismatchMessage)
        }
    }

    // MARK: - Helper Properties

    private var uniqueResolutions: [VideoResolution] {
        let resolutions = Array(Set(videoManager.availableVideoFormats.map { $0.resolution }))
        return resolutions.sorted {
            if $0.width != $1.width {
                return $0.width > $1.width
            }
            return $0.height > $1.height
        }
    }

    /// Frame rates available for the given resolution
    private func frameRates(for resolution: VideoResolution) -> [Float] {
        let rates = Array(Set(
            videoManager.availableVideoFormats
                .filter { $0.resolution == resolution }
                .map { $0.frameRate }
        ))
        return rates.sorted(by: >)
    }

    /// Pixel formats available for the given resolution and frame rate
    private func pixelFormats(for resolution: VideoResolution, frameRate: Float) -> [String] {
        let formats = Array(Set(
            videoManager.availableVideoFormats
                .filter { $0.resolution == resolution && abs($0.frameRate - frameRate) < 1.0 }
                .map { $0.pixelFormat }
        ))
        return formats.sorted()
    }

    private func formatDisplayName(_ format: String) -> String {
        switch format {
        case String(format: "0x%X", kCVPixelFormatType_32BGRA):
            return "BGRA"
        case String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange):
            return "420v"
        case String(format: "0x%X", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange):
            return "420f"
        case String(format: "0x%X", kCVPixelFormatType_422YpCbCr8):
            return "422"
        case String(format: "0x%X", kCVPixelFormatType_422YpCbCr8_yuvs):
            return "422 (yuvs)"
        case String(format: "0x%X", kCMVideoCodecType_JPEG):
            return "MJPEG"
        case String(format: "0x%X", kCMVideoCodecType_H264):
            return "H.264"
        default:
            return format
        }
    }

    // MARK: - Actions

    private func applyVideoFormat() {
        let selected = videoManager.selectedVideoFormat

        // Check if the exact combination is supported
        let isSupported = videoManager.availableVideoFormats.contains { format in
            format.resolution == selected.resolution &&
            abs(format.frameRate - selected.frameRate) < 1.0 &&
            format.pixelFormat == selected.pixelFormat
        }

        if !isSupported {
            formatMismatchMessage = "The selected format combination is not supported by the target device.\n\n" +
                "Resolution: \(selected.resolution.width)x\(selected.resolution.height)\n" +
                "Frame Rate: \(Int(selected.frameRate)) fps\n" +
                "Pixel Format: \(formatDisplayName(selected.pixelFormat))\n\n" +
                "Please select a different combination from the available options."
            showFormatMismatchAlert = true
            return
        }

        // Restart video session to apply new format
        videoManager.stopVideoSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.videoManager.prepareVideo()
        }
    }
}
