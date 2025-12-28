import SwiftUI
import Foundation

struct MouseHIDSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var hidManager = HIDManager.shared
    @ObservedObject private var serialPortManager = SerialPortManager.shared
    @State private var hidConnectionStatus = false
    @State private var switchStatus = false
    @State private var hdmiStatus = false
    @State private var resolution = "Unknown"
    @State private var frameRate = "Unknown"
    @State private var selectedPreset: PerformancePreset = .custom
    @State private var isUpdatingBaudrate = false

    enum PerformancePreset: String, CaseIterable {
        case lowPerformance = "Low Performance Target"
        case casual = "Casual Use"
        case gaming = "Gaming"
        case maxPerformance = "Max Performance"
        case custom = "Custom"

        var description: String {
            switch self {
            case .lowPerformance:
                return "For Raspberry Pi and low-performance targets (30 Hz, 9600 baud)"
            case .casual:
                return "Balanced settings for everyday use (80 Hz, 9600 baud)"
            case .gaming:
                return "Optimized for gaming and fast interactions (250 Hz, 115200 baud)"
            case .maxPerformance:
                return "Maximum responsiveness for professional use (1000 Hz, 115200 baud)"
            case .custom:
                return "Manually configured settings"
            }
        }

        var throttleHz: Int {
            switch self {
            case .lowPerformance: return 30
            case .casual: return 80
            case .gaming: return 250
            case .maxPerformance: return 1000
            case .custom: return 60 // default
            }
        }

        var baudrate: BaudrateOption {
            switch self {
            case .lowPerformance: return .lowSpeed
            case .casual: return .lowSpeed
            case .gaming: return .highSpeed
            case .maxPerformance: return .highSpeed
            case .custom: return .highSpeed // default
            }
        }

        var mouseMode: MouseControlMode {
            switch self {
            case .lowPerformance: return .absolute
            case .casual: return .absolute
            case .gaming: return .relativeHID
            case .maxPerformance: return .relativeHID
            case .custom: return .absolute // default
            }
        }

        var icon: String {
            switch self {
            case .lowPerformance: return "tortoise.fill"
            case .casual: return "desktopcomputer"
            case .gaming: return "gamecontroller.fill"
            case .maxPerformance: return "hare.fill"
            case .custom: return "slider.horizontal.3"
            }
        }
    }

    private var mouseControlDescription: String {
        switch userSettings.MouseControl {
        case .absolute:
            return "Absolute mode: Mouse cursor position directly matches target screen position"
        case .relativeHID:
            return "Relative (HID) mode: Precise mouse control via HID interface - requires accessibility permissions"
        case .relativeEvents:
            return "Relative (Events) mode: Mouse control via window events - no extra permissions required"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Mouse & HID Control")
                .font(.title2)
                .fontWeight(.bold)

            // Performance Presets
            GroupBox("Performance Presets") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick settings for different use cases")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        ForEach(PerformancePreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                            Button(action: {
                                applyPreset(preset)
                            }) {
                                VStack(spacing: 8) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 24))
                                        .foregroundColor(selectedPreset == preset ? .white : .blue)

                                    Text(preset.rawValue)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(selectedPreset == preset ? .white : .primary)

                                    VStack(spacing: 2) {
                                        Text("\(preset.throttleHz) Hz")
                                            .font(.system(size: 10, design: .monospaced))
                                        Text("Baudrate: \(preset.baudrate.rawValue)")
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .foregroundColor(selectedPreset == preset ? .white : .secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(selectedPreset == preset ? Color.blue : Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    if selectedPreset != .custom {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text(selectedPreset.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    } else {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.orange)
                            Text("Custom configuration - manually adjust throttling and baudrate below")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox("Mouse Event Throttling") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Event Rate Limit (Hz):")
                        Spacer()
                        Text("\(userSettings.mouseEventThrottleHz) Hz")
                            .foregroundColor(.blue)
                            .fontWeight(.semibold)
                    }

                    Slider(
                        value: Binding<Double>(
                            get: { Double(userSettings.mouseEventThrottleHz) },
                            set: { userSettings.mouseEventThrottleHz = Int($0) }
                        ),
                        in: 30...1000,
                        step: 10
                    )

                    Text("Higher values allow more mouse events per second. Exceeding events will be dropped to maintain the specified rate limit.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Recommended: 60-120 Hz for stable performance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            GroupBox("Mouse Control Mode") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mouse mode", selection: $userSettings.MouseControl) {
                        Text("Absolute").tag(MouseControlMode.absolute)
                        Text("Relative (HID)").tag(MouseControlMode.relativeHID)
                        Text("Relative (Events)").tag(MouseControlMode.relativeEvents)
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    Text(mouseControlDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if userSettings.MouseControl == .relativeHID {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Requires accessibility permissions")
                                .font(.caption)
                                .foregroundColor(.orange)

                            Button("Check Permissions") {
                                let permissionManager = DependencyContainer.shared.resolve(PermissionManagerProtocol.self)
                                permissionManager.showPermissionStatus()
                            }
                            .font(.caption)
                        }
                    }

                    Toggle("Auto-hide host cursor in absolute mode", isOn: $userSettings.isAbsoluteModeMouseHide)
                }
                .padding(.vertical, 8)
            }

            GroupBox("HID Device Status") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Hardware Connection:")
                        Spacer()
                        Text(hidConnectionStatus ? "Connected" : "Disconnected")
                            .foregroundColor(hidConnectionStatus ? .green : .red)
                        Button("Refresh") {
                            updateHIDStatus()
                        }
                    }

                    HStack {
                        Text("HDMI Status:")
                        Spacer()
                        Text(hdmiStatus ? "Active" : "No Signal")
                            .foregroundColor(hdmiStatus ? .green : .red)
                    }

                    HStack {
                        Text("Resolution:")
                        Spacer()
                        Text(resolution)
                    }

                    HStack {
                        Text("Frame Rate:")
                        Spacer()
                        Text(frameRate)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            updateHIDStatus()
            detectCurrentPreset()
        }
        .onChange(of: userSettings.mouseEventThrottleHz) { _ in
            detectCurrentPreset()
        }
        .onChange(of: userSettings.preferredBaudrate) { _ in
            detectCurrentPreset()
        }
    }

    private func updateHIDStatus() {
        hidConnectionStatus = hidManager.getSoftwareSwitchStatus()
        switchStatus = hidManager.getSwitchStatus()
        hdmiStatus = hidManager.getHDMIStatus()

        if let res = hidManager.getResolution() {
            resolution = "\(res.width)x\(res.height)"
        }

        if let fps = hidManager.getFps() {
            frameRate = String(format: "%.1f fps", fps)
        }
    }

    private func applyPreset(_ preset: PerformancePreset) {
        selectedPreset = preset
        userSettings.mouseEventThrottleHz = preset.throttleHz

        // Set mouse mode for the preset
        let targetMouseMode = preset.mouseMode
        if userSettings.MouseControl != targetMouseMode {
            userSettings.MouseControl = targetMouseMode

            // Set configuring state on serial port manager when mouse mode changes
            if let serialMgr = serialPortManager as? SerialPortManager {
                serialMgr.isConfiguring = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    serialMgr.isConfiguring = false
                }
            }
        }

        // Apply baudrate change if device is ready
        let targetBaudrate = preset.baudrate
        if userSettings.preferredBaudrate != targetBaudrate {
            userSettings.preferredBaudrate = targetBaudrate

            if serialPortManager.isDeviceReady {
                isUpdatingBaudrate = true
                applyBaudrateChange(targetBaudrate: targetBaudrate.rawValue)
            }

        }
    }

    private func applyBaudrateChange(targetBaudrate: Int) {
        isUpdatingBaudrate = true

        // Delegate to SerialPortManager which handles chipset-specific logic
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.serialPortManager.resetDeviceToBaudrate(targetBaudrate)

            // Reset the updating flag after operation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.isUpdatingBaudrate = false
            }
        }
    }

    private func detectCurrentPreset() {
        // Check if current settings match any preset
        for preset in PerformancePreset.allCases where preset != .custom {
            if userSettings.mouseEventThrottleHz == preset.throttleHz &&
               userSettings.preferredBaudrate == preset.baudrate {
                selectedPreset = preset
                return
            }
        }
        // If no match, it's custom
        selectedPreset = .custom
    }
}
