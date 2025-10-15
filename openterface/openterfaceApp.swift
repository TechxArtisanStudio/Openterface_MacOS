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
import Foundation
import Vision
import AppKit
import WebKit
import PDFKit
import KeyboardShortcuts
import CoreTransferable
import AVFoundation
import CoreAudio

@main
struct openterfaceApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    
    // Protocol-based dependencies - using computed properties since App structs are immutable
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    private var audioManager: AudioManagerProtocol { DependencyContainer.shared.resolve(AudioManagerProtocol.self) }
    private var mouseManager: MouseManagerProtocol { DependencyContainer.shared.resolve(MouseManagerProtocol.self) }
    private var keyboardManager: KeyboardManagerProtocol { DependencyContainer.shared.resolve(KeyboardManagerProtocol.self) }
    private var hidManager: HIDManagerProtocol { DependencyContainer.shared.resolve(HIDManagerProtocol.self) }
    private var serialPortManager: SerialPortManagerProtocol { DependencyContainer.shared.resolve(SerialPortManagerProtocol.self) }
    private var floatingKeyboardManager: FloatingKeyboardManagerProtocol { DependencyContainer.shared.resolve(FloatingKeyboardManagerProtocol.self) }
    private var tipLayerManager: TipLayerManagerProtocol { DependencyContainer.shared.resolve(TipLayerManagerProtocol.self) }
    private var cameraManager: CameraManagerProtocol { DependencyContainer.shared.resolve(CameraManagerProtocol.self) }
    private var permissionManager: PermissionManagerProtocol { DependencyContainer.shared.resolve(PermissionManagerProtocol.self) }
    
    init() {
        // Setup dependencies before UI construction to ensure they're available
        AppDelegate.setupDependencies(container: DependencyContainer.shared)
    }
    
    @State private var logModeTitle = "No logging ✓"
    @State private var mouseHideTitle = "Auto-hide in Control Mode"
    @State private var pasteBehaviorTitle = "Ask Every Time"
    
    @State private var _isSwitchToggleOn = false
    @State private var _isLockSwitch = true
    @State private var _isRecording = false
    @State private var _canTakePicture = false
    @State private var _isAudioEnabled = UserSettings.shared.isAudioEnabled  // Initialize with saved preference
    @State private var _isShowingAudioSourceDropdown = false
    
    @State private var  _hasHdmiSignal: Bool?
    @State private var  _isKeyboardConnected: Bool?
    @State private var  _isMouseConnected: Bool?
    @State private var  _isSwitchToHost: Bool?
    @State private var  _isMouseLoopRunning: Bool = false
    
    // Add state debounce cache variables
    @State private var lastUpdateTime: Date = Date()
    @State private var updateDebounceInterval: TimeInterval = 0.5 // 500ms debounce time
    
    @State private var showButtons = false
    
    @State private var _resolution = (width: "", height: "")
    @State private var _fps = ""
    @State private var _ms2109version = ""
    @State private var _pixelClock = ""
    
    // Add serial port information state variables
    @State private var _serialPortName: String = "N/A"
    @State private var _serialPortBaudRate: Int = 0

    @State private var audioInitialized = false

    var log: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    
    var body: some Scene {
        WindowGroup(id: UserSettings.shared.mainWindownName) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading){}
                .padding()
                .background(Color.gray.opacity(0))
                .cornerRadius(10)
                .opacity(showButtons ? 1 : 0)
                .offset(y: showButtons ? 20 : -100)
                .animation(.easeInOut(duration: 0.5), value: showButtons)
                .zIndex(100)
                ContentView()
                    .navigationTitle("Openterface Mini-KVM")
                    .toolbar {
                        ToolbarItemGroup(placement: .automatic) {
                            Button {
                                logger.log(content: "🎹 Floating keyboard button pressed")
                                print("🎹 DEBUG: Floating keyboard button pressed") // Additional debug
                                floatingKeyboardManager.showFloatingKeysWindow()
                            } label: {
                                Image(systemName: showButtons ? "keyboard" : "keyboard.chevron.compact.down.fill")
                            }
                            
                            Button(action: {}) {
                                Image(systemName: "poweron") // spacer
                            }
                            .disabled(true)
                            .buttonStyle(PlainButtonStyle())
                            
                            Menu {
                                Button(action: {
                                    toggleAudio(isEnabled: !_isAudioEnabled)
                                }) {
                                    Label(_isAudioEnabled ? "Mute Audio" : "Unmute Audio", 
                                          systemImage: _isAudioEnabled ? "speaker.slash" : "speaker.wave.3")
                                }
                                
                                Divider()

                                Menu("Audio Settings") {
                                    AudioSourceMenuContent(audioManager: audioManager as! AudioManager)
                                }
                            } label: {
                                Image(systemName: _isAudioEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(_isAudioEnabled ? .green : .red)
                            }
                            .help("""
                                Audio controls - Click to toggle audio or change settings
                                
                                Status: \(_isAudioEnabled ? "Enabled" : "Disabled")
                                Input: \((audioManager as! AudioManager).selectedInputDevice?.name ?? "None")
                                Output: \((audioManager as! AudioManager).selectedOutputDevice?.name ?? "None")
                                """)
                            
                            Button {
                                cameraManager.takePicture()
                            } label: {
                                Image(systemName: "camera.fill")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(_canTakePicture ? .blue : .gray)
                            }
                            .help("Take Picture")
                            .disabled(!_canTakePicture)
                            
                            Button {
                                if _isRecording {
                                    cameraManager.stopVideoRecording()
                                } else {
                                    cameraManager.startVideoRecording()
                                }
                            } label: {
                                Image(systemName: _isRecording ? "record.circle.fill" : "record.circle")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(_isRecording ? .red : (_canTakePicture ? .blue : .gray))
                            }
                            .help(_isRecording ? "Stop Recording" : "Start Video Recording")
                            .disabled(!_canTakePicture)
                            
                            Button(action: {
                                showAspectRatioSelectionWindow()
                            }) {
                                Image(systemName: "display")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundColor(colorForConnectionStatus(_hasHdmiSignal))
                            }
                            .help("Click to view Target Aspect Ratio...")
                        }
                        
                        ToolbarItem(placement: .primaryAction) {
                            ResolutionView(
                                width: _resolution.width, 
                                height: _resolution.height,
                                fps: _fps,
                                helpText:   "Input Resolution: \(_resolution.width)x\(_resolution.height)\n" +
                                            "Capture Resolution: 1920x1080\n" +
                                            "Refresh Rate: \(_fps) Hz\n" +
                                            "Pixel Clock: \(_pixelClock) MHz\n" +
                                            "HTotal: \(AppStatus.hidInputHTotal)\n" + 
                                            "VTotal: \(AppStatus.hidInputVTotal)\n" +
                                            "Hst: \(AppStatus.hidInputHst)\n" +
                                            "Vst: \(AppStatus.hidInputVst)\n" +
                                            "Hsync Width: \(AppStatus.hidInputHsyncWidth)\n" +
                                            "Vsync Width: \(AppStatus.hidInputVsyncWidth)"
                            )
                        }
                        
                        ToolbarItem(placement: .automatic) {
                            Button(action: {
                                // Add your code to execute when the button is clicked, e.g., open a window
                                showUSBDevicesWindow()
                            }) {
                                HStack {
                                    Image(systemName: "keyboard.fill")
                                        .resizable()
                                        .frame(width: 16, height: 12)
                                        .foregroundColor(colorForConnectionStatus(_isKeyboardConnected))
                                    Image(systemName: _isMouseLoopRunning ? "cursor.rays" : "computermouse.fill")
                                        .resizable()
                                        .frame(width: _isMouseLoopRunning ? 14 : 10, height: 12)
                                        .foregroundColor(colorForConnectionStatus(_isMouseConnected))
                                }
                            }
                            .help(
                                """
                                KeyBoard: \(
                                    _isKeyboardConnected == true ? "Connected" :
                                    _isKeyboardConnected == false ? "Not found" : "Unknown"
                                )
                                Mouse: \(
                                    _isMouseConnected == true ? "Connected" :
                                    _isMouseConnected == false ? "Not found" : "Unknown"
                                )

                                Click to view USB device details
                                """
                            )
                        }
                    
                        
                        // Add serial port information display
                        ToolbarItem(placement: .automatic) {
                            SerialInfoView(portName: _serialPortName, baudRate: _serialPortBaudRate)
                        }
                        ToolbarItem(placement: .automatic) {
                            Button(action: {}) {
                                Image(systemName: "poweron") // spacer
                            }
                            .disabled(true)
                            .buttonStyle(PlainButtonStyle())
                        }
                        ToolbarItemGroup(placement: .automatic) {
                            Toggle(isOn: $_isSwitchToggleOn) {
                                Image(_isSwitchToggleOn ? "Target_icon" : "Host_icon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 15)
                                Text(_isSwitchToggleOn ? "Target" : "Host")
                            }
                            .toggleStyle(SwitchToggleStyle(width: 30, height: 16))
                            .onChange(of: _isSwitchToggleOn) { newValue in
                                handleSwitchToggle(isOn: newValue)
                            }
                        }
                    }
                    .onReceive(timer) { _ in
                        // Initialize paste behavior title on first run
                        if pasteBehaviorTitle == "Ask Every Time" {
                            pasteBehaviorTitle = UserSettings.shared.pasteBehavior.menuDisplayName
                        }
                        
                        // Add debounce mechanism to avoid frequent status updates
                        let now = Date()
                        guard now.timeIntervalSince(lastUpdateTime) >= updateDebounceInterval else {
                            return // Skip this update if not enough time has passed since last update
                        }
                        
                        // Only update UI variables when status actually changes
                        let newKeyboardConnected = AppStatus.isKeyboardConnected
                        let newMouseConnected = AppStatus.isMouseConnected
                        let newSwitchToggleOn = AppStatus.isSwitchToggleOn
                        let newHdmiSignal = AppStatus.hasHdmiSignal
                        let newSerialPortName = AppStatus.serialPortName
                        let newSerialPortBaudRate = AppStatus.serialPortBaudRate
                        let newAudioEnabled = AppStatus.isAudioEnabled
                        
                        // Update camera status
                        cameraManager.updateStatus()
                        let newIsRecording = cameraManager.isRecording
                        let newCanTakePicture = cameraManager.canTakePicture

                        
                        var stateChanged = false
                        
                        if _isKeyboardConnected != newKeyboardConnected {
                            _isKeyboardConnected = newKeyboardConnected
                            stateChanged = true
                        }
                        
                        if _isMouseConnected != newMouseConnected {
                            _isMouseConnected = newMouseConnected
                            stateChanged = true
                        }
                        
                        if _isSwitchToggleOn != newSwitchToggleOn {
                            _isSwitchToggleOn = newSwitchToggleOn
                            stateChanged = true
                        }
                        
                        if _hasHdmiSignal != newHdmiSignal {
                            _hasHdmiSignal = newHdmiSignal
                            stateChanged = true
                        }
                        
                        if _serialPortName != newSerialPortName {
                            _serialPortName = newSerialPortName
                            stateChanged = true
                        }
                        
                        if _serialPortBaudRate != newSerialPortBaudRate {
                            _serialPortBaudRate = newSerialPortBaudRate
                            stateChanged = true
                        }
                        
                        if !audioInitialized && newSerialPortName != "N/A" && !newSerialPortName.isEmpty {
                            audioManager.initializeAudio()
                            audioInitialized = true
                        }
                        
                        if _isAudioEnabled != newAudioEnabled {
                            _isAudioEnabled = newAudioEnabled
                            stateChanged = true
                        }
                        
                        if _isRecording != newIsRecording {
                            _isRecording = newIsRecording
                            stateChanged = true
                        }
                        
                        if _canTakePicture != newCanTakePicture {
                            _canTakePicture = newCanTakePicture
                            stateChanged = true
                        }
                        
                        // Check mouse loop status
                        let isMouseRunning = mouseManager.getMouseLoopRunning()
                        if _isMouseLoopRunning != isMouseRunning {
                            _isMouseLoopRunning = isMouseRunning
                            stateChanged = true
                        }
                        
                        let pixelClockValue = Double(AppStatus.hidReadPixelClock) / 100.0
                        _pixelClock = String(format: "%.2f", pixelClockValue)

                        // Only update resolution display when state changes or HDMI signal status needs updating
                        if stateChanged || _hasHdmiSignal != nil {
                            if _hasHdmiSignal == nil {
                                _resolution.width = "-"
                                _resolution.height = "-"
                                _fps = "-"
                            } else if _hasHdmiSignal == false {
                                _resolution.width = "?"
                                _resolution.height = "?"
                                _fps = "?"
                            } else {
                                _resolution.width = "\(AppStatus.hidReadResolusion.width)"
                                _resolution.height = "\(AppStatus.hidReadResolusion.height)"
                                _fps = "\(AppStatus.hidReadFps)"
                            }
                        }
                        
                        // If state has changed, update the last update time
                        if stateChanged {
                            lastUpdateTime = now
                        }
                    }
            }
        }
        .commands {
            // Customize menu
            CommandMenu("Settings") {
                Menu("Cursor Behavior") {
                    Button(action: {
                        UserSettings.shared.isAbsoluteModeMouseHide = !UserSettings.shared.isAbsoluteModeMouseHide
                        if UserSettings.shared.isAbsoluteModeMouseHide {
                            mouseHideTitle = "Always Show Host Cursor"
                        } else {
                            mouseHideTitle = "Auto-hide Host Cursor"
                        }
                    }, label: {
                        Text(mouseHideTitle)
                    })
                }
                Menu("Mouse Mode"){
                    Button(action: {
                        // Check permissions for HID mode
                        if !permissionManager.isAccessibilityPermissionGranted() {
                            permissionManager.requestAccessibilityPermission()
                            return
                        }
                        
                        UserSettings.shared.MouseControl = .relativeHID
                        appState.updateMenuTitles(for: .relativeHID)
                        NotificationCenter.default.post(name: .enableRelativeModeNotification, object: nil)
                        
                        // Enable HID mouse monitoring
                        mouseManager.enableHIDMouseMode()
                        NSCursor.hide()
                    }) {
                        Text(appState.relativeHIDTitle)
                    }
                    
                    Button(action: {
                        UserSettings.shared.MouseControl = .relativeEvents
                        appState.updateMenuTitles(for: .relativeEvents)
                        NotificationCenter.default.post(name: .enableRelativeModeNotification, object: nil)
                        
                        // Disable HID mouse monitoring for Events mode
                        mouseManager.disableHIDMouseMode()
                        NSCursor.hide()
                    }) {
                        Text(appState.relativeEventsTitle)
                    }
                    
                    Button(action: {
                        UserSettings.shared.MouseControl = .absolute
                        appState.updateMenuTitles(for: .absolute)
                        
                        // Disable HID mouse monitoring for Absolute mode
                        mouseManager.disableHIDMouseMode()
                        NSCursor.unhide()
                    }) {
                        Text(appState.absoluteTitle)
                    }
                    
                    Divider()
                    
                    Button(action: {
                        permissionManager.showPermissionStatus()
                    }) {
                        Text("Check HID Permissions...")
                    }
                }                         
                Menu("Audio Control") {
                    Button(action: {
                        toggleAudio(isEnabled: true)
                    }) {
                        Text("Enable Audio")
                    }
                    .disabled(_isAudioEnabled)
                    
                    Button(action: {
                        toggleAudio(isEnabled: false)
                    }) {
                        Text("Disable Audio")
                    }
                    .disabled(!_isAudioEnabled)
                    
                    Divider()
                    
                    Menu("Audio Input Devices") {
                        if (audioManager as! AudioManager).availableInputDevices.isEmpty {
                            Text("No input devices available")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach((audioManager as! AudioManager).availableInputDevices) { device in
                                Button(action: {
                                    (audioManager as! AudioManager).selectInputDevice(device)
                                }) {
                                    HStack {
                                        Text(device.name)
                                        if (audioManager as! AudioManager).selectedInputDevice?.deviceID == device.deviceID {
                                            Text("✓")
                                        }
                                    }
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button("Refresh Input Devices") {
                            (audioManager as! AudioManager).updateAvailableAudioDevices()
                        }
                    }
                    
                    Menu("Audio Output Devices") {
                        Text("Output devices: \((audioManager as! AudioManager).availableOutputDevices.count)")
                            .foregroundColor(.blue)
                        
                        if (audioManager as! AudioManager).availableOutputDevices.isEmpty {
                            Text("No output devices available")
                                .foregroundColor(.secondary)
                        } else {
                            Button("List Output Devices") {
                                print("Settings: Output devices available:")
                                for device in (audioManager as! AudioManager).availableOutputDevices {
                                    print("Settings: - \(device.name)")
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button("Refresh Output Devices") {
                            print("Settings: Refreshing output devices")
                            (audioManager as! AudioManager).updateAvailableAudioDevices()
                        }
                    }
                }
                Menu("Camera Control") {
                    Button(action: {
                        cameraManager.takePicture()
                    }) {
                        Text("Take Picture")
                    }
                    .disabled(!_canTakePicture)
                    
                    Button(action: {
                        if _isRecording {
                            cameraManager.stopVideoRecording()
                        } else {
                            cameraManager.startVideoRecording()
                        }
                    }) {
                        Text(_isRecording ? "Stop Recording" : "Start Recording")
                    }
                    .disabled(!_canTakePicture)
                    
                    Divider()
                    
                    Button(action: {
                        if let capturesURL = cameraManager.getSavedFilesDirectory() {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: capturesURL.path)
                        }
                    }) {
                        Text("Show Captures Folder")
                    }
                }
                Menu("Logging Setting"){
                    Button(action: {
                        AppStatus.isLogMode = false
                        logModeTitle = "No logging ✓"
                        log.writeLogFile(string: "Disable Log Mode!")
                        log.closeLogFile()
                        log.logToFile = false
                    }) {
                        Text(logModeTitle == "No logging ✓" ? "No logging ✓" : "No logging")
                    }
                    
                    Button(action: {
                        AppStatus.isLogMode = true
                        logModeTitle = "Log to file ✓"
                        if log.checkLogFileExist() {
                            log.openLogFile()
                        } else {
                            log.createLogFile()
                        }
                        log.logToFile = true
                        log.writeLogFile(string: "Enable Log Mode!")
                    }) {
                        Text(logModeTitle == "Log to file ✓" ? "Log to file ✓" : "Log to file")
                    }
                    
                    Divider()
                    
                    Button(action: {
                        var infoFilePath: URL?
                        let fileManager = FileManager.default
                        
                        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                            infoFilePath = documentsDirectory.appendingPathComponent(AppStatus.logFileName)
                        }
                        
                        NSWorkspace.shared.selectFile(infoFilePath?.relativePath, inFileViewerRootedAtPath: "")
                    }) {
                        Text("Reveal in Finder")
                    }
                }
                Button(action: {
                    showUSBDevicesWindow()
                }) {
                    Text("USB Info")
                }
                Divider()
                Button(action: {
                    showResetFactoryWindow()
                }) {
                    Text("Serial Reset Tool...")
                }
                Button(action: {
                    showFirmwareUpdateWindow()
                }) {
                    Text("Firmware Update Tool...")
                }
                Button(action: {
                    showEdidNameWindow()
                }) {
                    Text("EDID Display Name Editor...")
                }
                Divider()
                Button(action: {
                    showSetKeyWindow()
                }) {
                    Text("Settings...")
                }
            }
            CommandGroup(replacing: CommandGroupPlacement.undoRedo) {
                EmptyView()
            }
            CommandGroup(replacing: CommandGroupPlacement.pasteboard){
                Button(action: {
                    let clipboardManager = DependencyContainer.shared.resolve(ClipboardManagerProtocol.self)
                    clipboardManager.handlePasteRequest()
                }) {
                    Text("Paste")
                }
                .keyboardShortcut("v", modifiers: .command)
                
                Button(action: {
                    if #available(macOS 12.3, *) {
                        let ocrManager = DependencyContainer.shared.resolve(OCRManagerProtocol.self)
                        ocrManager.startAreaSelection()
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Feature Unavailable"
                        alert.informativeText = "OCR functionality requires macOS 12.3 or later."
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }) {
                    Text("OCR Copy")
                }
                
                Divider()
                
                Button(action: {
                    ClipboardWindowController.shared.toggle()
                }) {
                    Text("Open Clipboard Manager")
                }
                
                Button(action: {
                    if let capturesURL = cameraManager.getSavedFilesDirectory() {
                                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: capturesURL.path)
                    }
                }) {
                    Text("Show Capture Folder")
                }
                
                Divider()
                
                Menu("Paste Behavior: \(pasteBehaviorTitle)") {
                    Button("Ask Every Time\(UserSettings.shared.pasteBehavior == .askEveryTime ? " ✓" : "")") {
                        UserSettings.shared.pasteBehavior = .askEveryTime
                        pasteBehaviorTitle = "Ask Every Time"
                        log.log(content: "Paste behavior set to: Ask Every Time")
                    }
                    
                    Button("Host Paste\(UserSettings.shared.pasteBehavior == .alwaysPasteToTarget ? " ✓" : "")") {
                        UserSettings.shared.pasteBehavior = .alwaysPasteToTarget
                        pasteBehaviorTitle = "Host Paste"
                        log.log(content: "Paste behavior set to: Auto Host Paste")
                    }
                    
                    Button("Local Paste\(UserSettings.shared.pasteBehavior == .alwaysPassToTarget ? " ✓" : "")") {
                        UserSettings.shared.pasteBehavior = .alwaysPassToTarget
                        pasteBehaviorTitle = "Local Paste"
                        log.log(content: "Paste behavior set to: Local Paste")
                    }
                }
                
                Button(action: {
                    if _isMouseLoopRunning {
                        mouseManager.stopMouseLoop()
                    } else {
                        mouseManager.runMouseLoop()
                    }
                }) {
                    Text(_isMouseLoopRunning ? "Prevent screen saver ✓" : "Prevent screen saver")
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Divider()

            }
            CommandGroup(after: CommandGroupPlacement.sidebar) {
                Button(action: {
                    showAspectRatioSelectionWindow()
                }) {
                    Text("Target Aspect Ratio...")
                }
            }
        }
    }
    
    func showSetKeyWindow(){
        NSApp.activate(ignoringOtherApps: true)
        let detailView = SettingsScreen()
        let controller = SettingsScreenWC(rootView: detailView)
        controller.window?.title = "Settings"
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: false)
    }
    
   func colorForConnectionStatus(_ isConnected: Bool?) -> Color {
        switch isConnected {
        case .some(true):
            return Color(red: 124 / 255.0, green: 205 / 255.0, blue: 124 / 255.0)
        case .some(false):
            return .orange
        case .none:
            return .gray
        }
    }
    
    func handleSwitchToggle(isOn: Bool) {
        logger.log(content: "🔄 USB switch toggle called: \(isOn ? "Target" : "Host")")
        
        if isOn {
            logger.log(content: "Setting USB to Target")
            hidManager.setUSBtoTarget()
        } else {
            logger.log(content: "Setting USB to Host")
            hidManager.setUSBtoHost()
        }
        
        // update AppStatus
        AppStatus.isSwitchToggleOn = isOn
        logger.log(content: "Updated AppStatus.isSwitchToggleOn to: \(isOn)")
        
        // Only apply DTR signal for MS2109 chipset
        if AppStatus.videoChipsetType == .ms2109 {
            let ser = serialPortManager
            logger.log(content: "Raising DTR signal")
            ser.raiseDTR()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.logger.log(content: "Lowering DTR signal")
                ser.lowerDTR()
            }
        }else{
            //TODO: Consider adding support for other chipsets if needed
            logger.log(content: "Skipping DTR signal for non-MS2109 chipset")
        }
    }
    
    private func toggleAudio(isEnabled: Bool) {
        // Update audio status
        _isAudioEnabled = isEnabled
        AppStatus.isAudioEnabled = isEnabled
        audioManager.setAudioEnabled(isEnabled)
    }
    
    func showAspectRatioSelectionWindow() {
        WindowUtils.shared.showAspectRatioSelector { shouldUpdateWindow in
            if shouldUpdateWindow {
                // Notify AppDelegate to update window size
                WindowUtils.shared.updateWindowSizeThroughNotification()
            }
        }
    }
}


@MainActor
final class AppState: ObservableObject {
    private var  logger = DependencyContainer.shared.resolve(LoggerProtocol.self)
    
    // Published properties for menu titles
    @Published var relativeHIDTitle = "Relative (HID)"
    @Published var relativeEventsTitle = "Relative (Events)"
    @Published var absoluteTitle = "Absolute ✓"
    
    init() {
        // Set initial menu titles based on current setting
        updateMenuTitles(for: UserSettings.shared.MouseControl)
        
        KeyboardShortcuts.onKeyUp(for: .exitRelativeMode) {
            self.logger.log(content: "Exit Relative Mode...")
            // Only exit if currently in relative mode
            if UserSettings.shared.MouseControl == .relativeHID || UserSettings.shared.MouseControl == .relativeEvents {
                UserSettings.shared.MouseControl = .absolute
                
                // Disable HID mouse monitoring when exiting relative mode
                let mouseManager = DependencyContainer.shared.resolve(MouseManagerProtocol.self)
                mouseManager.disableHIDMouseMode()
                
                NSCursor.unhide()
                // Update menu titles to reflect the change
                self.updateMenuTitles(for: .absolute)
                self.logger.log(content: "Switched from relative to absolute mouse mode")
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .exitFullScreenMode) {
            self.logger.log(content: "Exit FullScreen Mode...")
            
            // Try to find the main window first
            var targetWindow: NSWindow?
            
            // Option 1: Use NSApplication.shared.mainWindow
            if let mainWindow = NSApplication.shared.mainWindow {
                targetWindow = mainWindow
                self.logger.log(content: "Found main window for full screen exit")
            }
            // Option 2: Look for window with main window identifier
            else if let mainWindow = NSApp.windows.first(where: { 
                $0.identifier?.rawValue.contains(UserSettings.shared.mainWindownName) == true 
            }) {
                targetWindow = mainWindow
                self.logger.log(content: "Found main window by identifier for full screen exit")
            }
            // Option 3: Use key window
            else if let keyWindow = NSApp.keyWindow {
                targetWindow = keyWindow
                self.logger.log(content: "Using key window for full screen exit")
            }
            // Option 4: Use first window
            else if let firstWindow = NSApp.windows.first {
                targetWindow = firstWindow
                self.logger.log(content: "Using first available window for full screen exit")
            }
            
            // Exit full screen if we found a window and it's in full screen mode
            if let window = targetWindow {
                let isFullScreen = window.styleMask.contains(.fullScreen)
                self.logger.log(content: "Window full screen status: \(isFullScreen)")
                
                if isFullScreen {
                    window.toggleFullScreen(nil)
                    self.logger.log(content: "Successfully triggered full screen exit")
                } else {
                    self.logger.log(content: "Window is not in full screen mode")
                }
            } else {
                self.logger.log(content: "No suitable window found for full screen exit")
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .triggerAreaOCR) {
            if #available(macOS 12.3, *) {
                let ocrManager = DependencyContainer.shared.resolve(OCRManagerProtocol.self)
                ocrManager.startAreaSelection()
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .toggleUSBSwitch) {
            self.logger.log(content: "USB Switch Toggle shortcut triggered")
            
            // Get current toggle state and flip it
            let currentState = AppStatus.isSwitchToggleOn
            let newState = !currentState
            
            // Update the global app state 
            AppStatus.isSwitchToggleOn = newState
            
            // Trigger the same logic as the UI toggle
            let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
            let serialPortManager = DependencyContainer.shared.resolve(SerialPortManagerProtocol.self)
            
            if newState {
                self.logger.log(content: "Shortcut: Setting USB to Target")
                hidManager.setUSBtoTarget()
            } else {
                self.logger.log(content: "Shortcut: Setting USB to Host")
                hidManager.setUSBtoHost()
            }
            
            // Raise and lower DTR signal only for MS2109 chipset
            if AppStatus.videoChipsetType != .ms2109 {
                self.logger.log(content: "Shortcut: Raising DTR signal")
                serialPortManager.raiseDTR()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.logger.log(content: "Shortcut: Lowering DTR signal")
                    serialPortManager.lowerDTR()
                }
            }
        }
        
        KeyboardShortcuts.onKeyUp(for: .toggleFloatingKeyboard) {
            self.logger.log(content: "Show Floating Keyboard shortcut triggered")
            let floatingKeyboardManager = DependencyContainer.shared.resolve(FloatingKeyboardManagerProtocol.self)
            floatingKeyboardManager.showFloatingKeysWindow()
        }
    }
    
    func updateMenuTitles(for mode: MouseControlMode) {
        switch mode {
        case .relativeHID:
            relativeHIDTitle = "Relative (HID) ✓"
            relativeEventsTitle = "Relative (Events)"
            absoluteTitle = "Absolute"
        case .relativeEvents:
            relativeHIDTitle = "Relative (HID)"
            relativeEventsTitle = "Relative (Events) ✓"
            absoluteTitle = "Absolute"
        case .absolute:
            relativeHIDTitle = "Relative (HID)"
            relativeEventsTitle = "Relative (Events)"
            absoluteTitle = "Absolute ✓"
        }
    }
}

func hexStringToDecimalInt(hexString: String) -> Int? {
    var cleanedHexString = hexString
    if hexString.hasPrefix("0x") {
        cleanedHexString = String(hexString.dropFirst(2))
    }
    
    guard let hexValue = UInt(cleanedHexString, radix: 16) else {
        return nil
    }
    
    return Int(hexValue)
}


struct SwitchToggleStyle: ToggleStyle {
    var width: CGFloat
    var height: CGFloat
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            RoundedRectangle(cornerRadius: height / 2)
                .fill(configuration.isOn ? Color.gray : Color.orange)
                .frame(width: width, height: height)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: height - 2, height: height - 2)
                        .offset(x: configuration.isOn ? (width / 2 - height / 2) : -(width / 2 - height / 2))
                        .animation(.linear(duration: 0.1), value: configuration.isOn)
                    )
                .onTapGesture {
                withAnimation(.spring(duration: 0.1)) { // withAnimation
                    configuration.isOn.toggle()
                }
            }
        }
        .frame(width: 105, height: 24)
    }
}


extension Color {
    init(red255: Double, green255: Double, blue255: Double, opacity: Double = 1.0) {
        self.init(red: red255 / 255.0, green: green255 / 255.0, blue: blue255 / 255.0, opacity: opacity)
    }
}

struct TransparentBackgroundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.blue) 
            .padding()
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.01))
                .opacity(configuration.isPressed ? 0.01 : 1))
                .scaleEffect(configuration.isPressed ? 1.2 : 1)
            .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 2))
    }
}

func showUSBDevicesWindow() {
    let usbDevicesView = USBDevicesView()
    let controller = NSHostingController(rootView: usbDevicesView)
    let window = NSWindow(contentViewController: controller)
    window.title = "USB Devices"
    window.setContentSize(NSSize(width: 400, height: 600))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

func showResetFactoryWindow() {
    if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "resetSerialToolWindow" }) {
        // If window already exists, make it shake and bring to front
        
        // Use system-provided attention request (will make window or Dock icon bounce)
        NSApp.requestUserAttention(.criticalRequest)
        
        // Bring window to front
        existingWindow.makeKeyAndOrderFront(nil)
        existingWindow.orderFrontRegardless()
        return
    }
    
    // If window doesn't exist, create a new one
    let resetFactoryView = ResetFactoryView()
    let controller = NSHostingController(rootView: resetFactoryView)
    let window = NSWindow(contentViewController: controller)
    window.title = "Serial Reset Tool"
    window.identifier = NSUserInterfaceItemIdentifier(rawValue: "resetSerialToolWindow")
    window.setContentSize(NSSize(width: 400, height: 760))
    window.styleMask = [.titled, .closable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    
    // Set callback when window closes to clear references
    window.isReleasedWhenClosed = false
//     NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
//         // aboutWindow = nil
// //        if let windown = NSApp.windows.first(where: { $0.identifier?.rawValue == "resetFactoryWindow" }) {
// //            windown.close()
// //        }
//     }
    
    // Save window reference
    // aboutWindow = window
    NSApp.activate(ignoringOtherApps: true)
}

func showFirmwareUpdateWindow() {
    if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "firmwareUpdateWindow" }) {
        // If window already exists, make it shake and bring to front
        
        // Use system-provided attention request (will make window or Dock icon bounce)
        NSApp.requestUserAttention(.criticalRequest)
        
        // Bring window to front
        existingWindow.makeKeyAndOrderFront(nil)
        existingWindow.orderFrontRegardless()
        return
    }
    
    // If window doesn't exist, create a new one
    let firmwareUpdateView = FirmwareUpdateView()
    let controller = NSHostingController(rootView: firmwareUpdateView)
    let window = NSWindow(contentViewController: controller)
    window.title = "Firmware Update Tool"
    window.identifier = NSUserInterfaceItemIdentifier(rawValue: "firmwareUpdateWindow")
    window.setContentSize(NSSize(width: 400, height: 600))
    window.styleMask = [.titled, .closable]
    window.center()
    window.makeKeyAndOrderFront(nil)
    
    // Set callback when window closes to clear references
    window.isReleasedWhenClosed = false
    
    // Save window reference
    NSApp.activate(ignoringOtherApps: true)
}

func showEdidNameWindow() {
    if let existingWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "edidNameWindow" }) {
        // If window already exists, make it shake and bring to front
        
        // Use system-provided attention request (will make window or Dock icon bounce)
        NSApp.requestUserAttention(.criticalRequest)
        
        // Bring window to front
        existingWindow.makeKeyAndOrderFront(nil)
        existingWindow.orderFrontRegardless()
        return
    }
    
    // If window doesn't exist, create a new one
    let edidNameView = EdidNameView()
    let controller = NSHostingController(rootView: edidNameView)
    let window = NSWindow(contentViewController: controller)
    window.title = "EDID Monitor Name Editor"
    window.identifier = NSUserInterfaceItemIdentifier(rawValue: "edidNameWindow")
    window.setContentSize(NSSize(width: 450, height: 500))
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.center()
    
    // Ensure window can accept key events and become first responder
    window.acceptsMouseMovedEvents = true
    
    window.makeKeyAndOrderFront(nil)
    
    // Set callback when window closes to clear references
    window.isReleasedWhenClosed = false
    
    // Save window reference and activate app
    NSApp.activate(ignoringOtherApps: true)
}

// MARK: - Audio Source Menu Component
struct AudioSourceMenuContent: View {
    @ObservedObject var audioManager: AudioManager
    
    var body: some View {
        Group {
            // Input devices section
            Text("Microphone (Input)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if audioManager.availableInputDevices.isEmpty {
                Text("No input devices available")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(audioManager.availableInputDevices) { device in
                    Button(action: {
                        audioManager.selectInputDevice(device)
                    }) {
                        HStack {
                            if audioManager.selectedInputDevice?.deviceID == device.deviceID {
                                Image(systemName: "mic")
                                    .foregroundColor(.blue)
                                    .frame(width: 16)
                            }
                            Text(device.name)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            
            Divider()
            
            // Output devices section
            Text("Speakers (Output)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if audioManager.availableOutputDevices.isEmpty {
                Text("No output devices available")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(audioManager.availableOutputDevices) { device in
                    Button(action: {
                        audioManager.selectOutputDevice(device)
                    }) {
                        HStack {
                            if audioManager.selectedOutputDevice?.deviceID == device.deviceID {
                                Image(systemName: "speaker.wave.2")
                                    .foregroundColor(.blue)
                                    .frame(width: 16)
                            }
                            Text(device.name)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            
            Divider()
            
            Button("Refresh Audio Devices") {
                audioManager.updateAvailableAudioDevices()
            }
        }
        .onAppear {
//            audioManager.updateAvailableAudioDevices()
        }
    }
}
