import SwiftUI

// Advanced & Debug Settings extracted from `SettingsScreen.swift`
struct AdvancedDebugSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var showingLogViewer = false
    @State private var logEntryCount = 0
    @State private var showingExportSuccess = false
    @State private var showingImportSuccess = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingDiagnostics = false
    @StateObject private var diagnosticsViewModel = DiagnosticsViewModel()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Advanced & Debug Configuration")
                .font(.title2)
                .bold()
            
            GroupBox("Device Diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Run comprehensive hardware and connection tests")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        showingDiagnostics = true
                    }) {
                        HStack {
                            Image(systemName: "stethoscope.circle")
                            Text("Open Diagnostics Tool")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Text("Tests include cable detection, serial connection, baudrate configuration, and stress testing")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Debug & Logging") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable serial output logging", isOn: $userSettings.isSerialOutput)
                        .onChange(of: userSettings.isSerialOutput) { enabled in
                            Logger.shared.SerialDataPrint = enabled
                        }
                    
                    Toggle("Enable mouse event logging", isOn: $userSettings.isMouseEventPrintEnabled)
                        .onChange(of: userSettings.isMouseEventPrintEnabled) { enabled in
                            Logger.shared.MouseEventPrint = enabled
                        }
                    
                    Toggle("Enable HAL print logging", isOn: $userSettings.isHalPrintEnabled)
                        .onChange(of: userSettings.isHalPrintEnabled) { enabled in
                            Logger.shared.HalPrint = enabled
                        }
                    
                    HStack(spacing: 12) {
                        Button(action: { showingLogViewer = true }) {
                            HStack {
                                Image(systemName: "doc.plaintext")
                                Text("View Logs")
                            }
                        }
                        .buttonStyle(.bordered)

                        Button(action: { exportSettings() }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export Logs")
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    Text("Detailed logging helps troubleshoot connectivity and performance issues")
                        .font(.caption)
                        .foregroundColor(.secondary)
                
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Settings Management") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export or import your configuration settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 12) {
                        Button(action: exportSettings) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export Settings")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button(action: importSettings) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("Import Settings")
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                    }
                    
                    Text("Settings are saved as JSON files with timestamp. Import will overwrite current settings.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Reset & Restore") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reset application settings to default values")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Button("Reset All Settings") {
                            resetAllSettings()
                        }
                        .foregroundColor(.red)
                        
                        Spacer()
                        
                        Text("This will reset all preferences to default values")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Application Information") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version:")
                        Spacer()
                        Text(getAppVersionString())
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    HStack {
                        Text("Build:")
                        Spacer()
                        Text(getBuildDateString())
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    HStack {
                        Text("System:")
                        Spacer()
                        Text("\(ProcessInfo.processInfo.operatingSystemVersionString)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingLogViewer) {
            LogViewerDialog()
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView(viewModel: diagnosticsViewModel)
        }
        .alert("Export Successful", isPresented: $showingExportSuccess) {
            Button("OK") { }
        } message: {
            Text("Settings have been successfully exported.")
        }
        .alert("Import Successful", isPresented: $showingImportSuccess) {
            Button("OK") { }
        } message: {
            Text("Settings have been successfully imported and applied.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            // Load the logging settings from Logger to sync with UI
            Logger.shared.SerialDataPrint = userSettings.isSerialOutput
            Logger.shared.MouseEventPrint = userSettings.isMouseEventPrintEnabled
            Logger.shared.HalPrint = userSettings.isHalPrintEnabled
        }
    }
    
    private func getAppVersionString() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Openterface v\(version) (\(build))"
    }
    
    private func getBuildDateString() -> String {
        let bundle = Bundle.main
        if let buildDate = bundle.object(forInfoDictionaryKey: "CFBundleVersionDate") as? String {
            return buildDate
        }
        
        // Fallback to executable creation date
        if let executablePath = bundle.executablePath {
            let url = URL(fileURLWithPath: executablePath)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let creationDate = attributes[.creationDate] as? Date {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy.MM.dd"
                    return formatter.string(from: creationDate)
                }
            } catch {
                // Ignore error and fallback
            }
        }
        
        // Final fallback
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: Date())
    }
    
    private func resetAllSettings() {
        userSettings.MouseControl = .absolute
        userSettings.isAudioEnabled = false
        userSettings.pasteBehavior = .askEveryTime
        userSettings.aspectRatioMode = .hidResolution
        userSettings.customAspectRatio = .ratio16_9
        userSettings.isAbsoluteModeMouseHide = false
        userSettings.doNotShowHidResolutionAlert = false
        userSettings.edgeThreshold = 5
        userSettings.isSerialOutput = false
        userSettings.isMouseEventPrintEnabled = false
        userSettings.isHalPrintEnabled = false
        userSettings.mainWindownName = "main_openterface"
        userSettings.viewWidth = 1920.0
        userSettings.viewHeight = 1080.0
        userSettings.isFullScreen = false
    }
    
    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Openterface Settings"
        panel.nameFieldStringValue = "Openterface_Settings_\(getCurrentDateString()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let settingsData = createSettingsExportData()
                    let jsonData = try JSONSerialization.data(withJSONObject: settingsData, options: .prettyPrinted)
                    try jsonData.write(to: url)
                    showingExportSuccess = true
                } catch {
                    errorMessage = "Failed to export settings: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
    
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Openterface Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let jsonData = try Data(contentsOf: url)
                    let settingsData = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
                    
                    if let settings = settingsData {
                        applyImportedSettings(settings)
                        showingImportSuccess = true
                    } else {
                        errorMessage = "Invalid settings file format"
                        showingError = true
                    }
                } catch {
                    errorMessage = "Failed to import settings: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
    
    private func getCurrentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
    
    private func createSettingsExportData() -> [String: Any] {
        return [
            "version": "1.0",
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "appVersion": getAppVersionString(),
            "settings": [
                "mouseControl": userSettings.MouseControl.rawValue,
                "isAudioEnabled": userSettings.isAudioEnabled,
                "pasteBehavior": userSettings.pasteBehavior.rawValue,
                "aspectRatioMode": userSettings.aspectRatioMode.rawValue,
                "customAspectRatio": userSettings.customAspectRatio.rawValue,
                "isAbsoluteModeMouseHide": userSettings.isAbsoluteModeMouseHide,
                "doNotShowHidResolutionAlert": userSettings.doNotShowHidResolutionAlert,
                "edgeThreshold": userSettings.edgeThreshold,
                "isSerialOutput": userSettings.isSerialOutput,
                "isMouseEventPrintEnabled": userSettings.isMouseEventPrintEnabled,
                "isHalPrintEnabled": userSettings.isHalPrintEnabled,
                "mainWindowName": userSettings.mainWindownName,
                "viewWidth": userSettings.viewWidth,
                "viewHeight": userSettings.viewHeight,
                "isFullScreen": userSettings.isFullScreen
            ]
        ]
    }
    
    private func applyImportedSettings(_ data: [String: Any]) {
        // Validate the settings file format
        guard let version = data["version"] as? String,
              version == "1.0",
              let settings = data["settings"] as? [String: Any] else {
            errorMessage = "Invalid or incompatible settings file format"
            showingError = true
            return
        }
        
        // Apply mouse control setting
        if let mouseControlRaw = settings["mouseControl"] as? Int,
           let mouseControl = MouseControlMode(rawValue: mouseControlRaw) {
            userSettings.MouseControl = mouseControl
        }
        
        // Apply audio setting
        if let isAudioEnabled = settings["isAudioEnabled"] as? Bool {
            userSettings.isAudioEnabled = isAudioEnabled
        }
        
        // Apply paste behavior
        if let pasteBehaviorRaw = settings["pasteBehavior"] as? String,
           let pasteBehavior = PasteBehavior(rawValue: pasteBehaviorRaw) {
            userSettings.pasteBehavior = pasteBehavior
        }
        
        // Apply aspect ratio mode (new format) or migrate from old format
        if let aspectRatioModeRaw = settings["aspectRatioMode"] as? String,
           let aspectRatioMode = AspectRatioMode(rawValue: aspectRatioModeRaw) {
            userSettings.aspectRatioMode = aspectRatioMode
        } else if let useCustomAspectRatio = settings["useCustomAspectRatio"] as? Bool {
            // Migrate from old useCustomAspectRatio boolean setting
            userSettings.aspectRatioMode = useCustomAspectRatio ? .custom : .hidResolution
        }
        
        if let customAspectRatioRaw = settings["customAspectRatio"] as? String,
           let customAspectRatio = AspectRatioOption(rawValue: customAspectRatioRaw) {
            userSettings.customAspectRatio = customAspectRatio
        }
        
        // Apply mouse hide setting
        if let isAbsoluteModeMouseHide = settings["isAbsoluteModeMouseHide"] as? Bool {
            userSettings.isAbsoluteModeMouseHide = isAbsoluteModeMouseHide
        }
        
        // Apply HID resolution alert setting
        if let doNotShowHidResolutionAlert = settings["doNotShowHidResolutionAlert"] as? Bool {
            userSettings.doNotShowHidResolutionAlert = doNotShowHidResolutionAlert
        }
        
        // Apply edge threshold
        if let edgeThreshold = settings["edgeThreshold"] as? CGFloat {
            userSettings.edgeThreshold = edgeThreshold
        }
        
        // Apply serial output setting
        if let isSerialOutput = settings["isSerialOutput"] as? Bool {
            userSettings.isSerialOutput = isSerialOutput
        }
        
        // Apply mouse event print setting
        if let isMouseEventPrintEnabled = settings["isMouseEventPrintEnabled"] as? Bool {
            userSettings.isMouseEventPrintEnabled = isMouseEventPrintEnabled
        }
        
        // Apply HAL print setting
        if let isHalPrintEnabled = settings["isHalPrintEnabled"] as? Bool {
            userSettings.isHalPrintEnabled = isHalPrintEnabled
        }
        
        // Apply main window name
        if let mainWindowName = settings["mainWindowName"] as? String {
            userSettings.mainWindownName = mainWindowName
        }
        
        // Apply view dimensions
        if let viewWidth = settings["viewWidth"] as? Float {
            userSettings.viewWidth = viewWidth
        }
        
        if let viewHeight = settings["viewHeight"] as? Float {
            userSettings.viewHeight = viewHeight
        }
        
        // Apply full screen setting
        if let isFullScreen = settings["isFullScreen"] as? Bool {
            userSettings.isFullScreen = isFullScreen
        }
    }
}
