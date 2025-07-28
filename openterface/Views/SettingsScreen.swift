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
import KeyboardShortcuts
import Foundation
import UniformTypeIdentifiers

struct SettingsScreen: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var keyboardManager = KeyboardManager.shared
    @ObservedObject private var audioManager = AudioManager.shared
    @State private var selectedTab: SettingsTab = .keyMapping
    @State private var customShortcuts: [String: String] = [:]
    @State private var showingCustomKeyMapDialog = false
    
    enum SettingsTab: String, CaseIterable {
        case keyMapping = "Key Mapping & Shortcuts"
        case macros = "Key Macros"
        case mouse = "Mouse & HID"
        case audio = "Audio & Video"
        case clipboard = "Clipboard & OCR"
        case connection = "Device & Connection"
        case advanced = "Advanced & Debug"
        
        var icon: String {
            switch self {
            case .keyMapping: return "keyboard"
            case .macros: return "keyboard.badge.ellipsis"
            case .mouse: return "cursorarrow"
            case .audio: return "speaker.wave.3"
            case .clipboard: return "doc.on.clipboard"
            case .connection: return "externaldrive.connected.to.line.below"
            case .advanced: return "gearshape"
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Enhanced Sidebar
            VStack(alignment: .leading, spacing: 8) {
                Text("Openterface Settings")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                Text("Configure key mapping, device behavior, and advanced features")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: {
                        selectedTab = tab
                    }) {
                        HStack {
                            Image(systemName: tab.icon)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.rawValue)
                                    .font(.system(size: 11))
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(selectedTab == tab ? Color.blue.opacity(0.2) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .blue : .primary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Spacer()
            }
            .frame(width: 220)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .keyMapping:
                        KeyMappingSettingsView()
                    case .macros:
                        KeyMacrosSettingsView()
                    case .mouse:
                        MouseHIDSettingsView()
                    case .audio:
                        AudioVideoSettingsView()
                    case .clipboard:
                        ClipboardOCRSettingsView()
                    case .connection:
                        DeviceConnectionSettingsView()
                    case .advanced:
                        AdvancedDebugSettingsView()
                    }
                }
                .padding()
            }
        }
        .frame(width: 900, height: 700)
    }
}

// MARK: - Enhanced Key Mapping Settings
struct KeyMappingSettingsView: View {
    @ObservedObject private var keyboardManager = KeyboardManager.shared
    @State private var selectedSpecialKey: KeyboardMapper.SpecialKey?
    @State private var showingKeyTestDialog = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Key Mapping & Shortcuts")
                .font(.title2)
                .bold()
            
            // Global Shortcuts Section
            GroupBox("Global Application Shortcuts") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These shortcuts work globally when Openterface is active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        KeyboardShortcuts.Recorder("Exit full screen mode", name: .exitFullScreenMode)
                        KeyboardShortcuts.Recorder("Exit relative mouse mode", name: .exitRelativeMode)
                        KeyboardShortcuts.Recorder("Trigger OCR text selection", name: .triggerAreaOCR)
                        KeyboardShortcuts.Recorder("Toggle USB switching", name: .toggleUSBSwitch)
                        KeyboardShortcuts.Recorder("Quick firmware update", name: .openFirmwareUpdate)
                        KeyboardShortcuts.Recorder("Show floating keyboard", name: .toggleFloatingKeyboard)
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Keyboard Layout Configuration
            GroupBox("Target Device Keyboard Layout") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Layout mode:")
                        Picker("", selection: $keyboardManager.currentKeyboardLayout) {
                            ForEach(KeyboardManager.KeyboardLayout.allCases, id: \.self) { layout in
                                Text(layout.rawValue.capitalized).tag(layout)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
                        
                        Spacer()
                        
                        Button("Test Layout") {
                            showingKeyTestDialog = true
                        }
                    }
                    
                    Text("Current modifier key mapping: \(keyboardManager.getModifierKeyLabel())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Windows mode maps Cmd → Ctrl, Mac mode preserves key meanings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            
            // Special Key Combinations
            GroupBox("Special Key Combinations") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick access to common key combinations for target device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        SpecialKeyButton(key: .CtrlAltDel, label: "Ctrl+Alt+Del")
                        SpecialKeyButton(key: .CmdSpace, label: "Cmd+Space")
                        SpecialKeyButton(key: .F1, label: "F1")
                        SpecialKeyButton(key: .F2, label: "F2")
                        SpecialKeyButton(key: .F4, label: "F4")
                        SpecialKeyButton(key: .F5, label: "F5")
                        SpecialKeyButton(key: .F11, label: "F11")
                        SpecialKeyButton(key: .F12, label: "F12")
                        SpecialKeyButton(key: .windowsWin, label: "Win Key")
                    }
                }
                .padding(.vertical, 8)
            }
            
            // Real-time Modifier Key Status
            GroupBox("Live Modifier Key Status") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Real-time status of modifier keys being tracked")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ModifierKeyStatus(name: "L-Shift", isActive: keyboardManager.isLeftShiftHeld)
                        ModifierKeyStatus(name: "R-Shift", isActive: keyboardManager.isRightShiftHeld)
                        ModifierKeyStatus(name: "L-Ctrl", isActive: keyboardManager.isLeftCtrlHeld)
                        ModifierKeyStatus(name: "R-Ctrl", isActive: keyboardManager.isRightCtrlHeld)
                        ModifierKeyStatus(name: "L-Alt", isActive: keyboardManager.isLeftAltHeld)
                        ModifierKeyStatus(name: "R-Alt", isActive: keyboardManager.isRightAltHeld)
                        ModifierKeyStatus(name: "Caps Lock", isActive: keyboardManager.isCapsLockOn)
                        ModifierKeyStatus(name: "Uppercase", isActive: keyboardManager.shouldShowUppercase)
                    }
                    
                    HStack {
                        Text("Case behavior:")
                        Text(keyboardManager.shouldShowUppercase ? "UPPERCASE" : "lowercase")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(keyboardManager.shouldShowUppercase ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 8)
            }
            
            // Special Behaviors
            GroupBox("Special Key Behaviors") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Escape Key:")
                            Text("Double press within 2 seconds to exit full screen")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("ESC ESC")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Paste Detection:")
                            Text("Cmd+V triggers clipboard management")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("⌘+V")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingKeyTestDialog) {
            KeyTestDialog()
        }
    }
}

struct SpecialKeyButton: View {
    let key: KeyboardMapper.SpecialKey
    let label: String
    
    var body: some View {
        Button(action: {
            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: key)
        }) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct KeyTestDialog: View {
    @State private var testText = "Hello World! 123"
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Keyboard Layout Test")
                .font(.headline)
            
            Text("Enter text to test keyboard layout mapping:")
                .font(.caption)
            
            TextField("Test text", text: $testText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            HStack {
                Button("Send to Target") {
                    KeyboardManager.shared.sendTextToKeyboard(text: testText)
                }
                
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 300, height: 150)
    }
}

struct ModifierKeyStatus: View {
    let name: String
    let isActive: Bool
    
    var body: some View {
        HStack {
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.caption)
                .foregroundColor(isActive ? .primary : .secondary)
        }
    }
}

// MARK: - Key Macros Settings
struct KeyMacrosSettingsView: View {
    @State private var savedMacros: [EnhancedKeyboardMacro] = []
    @State private var showingMacroCreator = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Key Macros & Automation")
                .font(.title2)
                .bold()
            
            GroupBox("Macro Management") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Create and manage keyboard macros for common tasks")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button("Create New Macro") {
                            showingMacroCreator = true
                        }
                    }
                    
                    if savedMacros.isEmpty {
                        Text("No macros created yet. Click 'Create New Macro' to get started.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(savedMacros.indices, id: \.self) { index in
                            EnhancedMacroRow(macro: savedMacros[index]) {
                                executeEnhancedKeyboardMacro(savedMacros[index])
                            } onDelete: {
                                savedMacros.remove(at: index)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Common Macro Templates") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick templates for common scenarios")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                        MacroTemplateButton(name: "Windows Login", description: "Ctrl+Alt+Del → Enter") {
                            KeyboardManager.shared.sendSpecialKeyToKeyboard(code: .CtrlAltDel)
                        }
                        
                        MacroTemplateButton(name: "Switch Apps", description: "Alt+Tab sequence") {
                            let kbm = KeyboardMapper()
                            if let tabKey = kbm.fromSpecialKeyToKeyCode(code: .tab) {
                                kbm.pressKey(keys: [tabKey], modifiers: [.option])
                                Thread.sleep(forTimeInterval: 0.1)
                                kbm.releaseKey(keys: [255,255,255,255,255,255])
                            }
                        }
                        
                        MacroTemplateButton(name: "Copy & Paste", description: "Ctrl+C → Ctrl+V") {
                            KeyboardManager.shared.sendTextToKeyboard(text: "")
                        }
                        
                        MacroTemplateButton(name: "Save Document", description: "Ctrl+S sequence") {
                            let kbm = KeyboardMapper()
                            let sChar: UInt16 = 115 // ASCII value for 's'
                            let sKey = kbm.fromCharToKeyCode(char: sChar)
                            kbm.pressKey(keys: [UInt16(sKey)], modifiers: [.control])
                            Thread.sleep(forTimeInterval: 0.1)
                            kbm.releaseKey(keys: [255,255,255,255,255,255])
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showingMacroCreator) {
            EnhancedMacroCreatorDialog { macro in
                savedMacros.append(macro)
            }
        }
    }
    
    private func executeEnhancedKeyboardMacro(_ macro: EnhancedKeyboardMacro) {
        for input in macro.sequence {
            switch input.key {
            case .keyboardMapperSpecialKey(let specialKey):
                KeyboardManager.shared.sendSpecialKeyToKeyboard(code: specialKey)
            case .character(let char):
                KeyboardManager.shared.sendTextToKeyboard(text: String(char))
            case .specialKey(_):
                // Handle enhanced special keys if needed
                break
            }
            Thread.sleep(forTimeInterval: 0.05) // Small delay between keys
        }
    }
}

struct EnhancedMacroRow: View {
    let macro: EnhancedKeyboardMacro
    let onExecute: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(macro.name)
                    .font(.caption)
                    .bold()
                Text("\(macro.sequence.count) steps")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Run") {
                onExecute()
            }
            .font(.caption)
            
            Button("Delete") {
                onDelete()
            }
            .font(.caption)
            .foregroundColor(.red)
        }
        .padding(.vertical, 4)
    }
}

struct MacroTemplateButton: View {
    let name: String
    let description: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.caption)
                    .bold()
                Text(description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EnhancedMacroCreatorDialog: View {
    let onSave: (EnhancedKeyboardMacro) -> Void
    @State private var macroName = ""
    @State private var recordedKeys: [EnhancedKeyboardInput] = []
    @State private var isRecording = false
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Create Keyboard Macro")
                .font(.headline)
            
            TextField("Macro name", text: $macroName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            VStack {
                Text("Recorded sequence: \(recordedKeys.count) keys")
                    .font(.caption)
                
                Button(isRecording ? "Stop Recording" : "Start Recording") {
                    isRecording.toggle()
                }
                .foregroundColor(isRecording ? .red : .blue)
            }
            
            HStack {
                Button("Save Macro") {
                    if !macroName.isEmpty && !recordedKeys.isEmpty {
                        let macro = EnhancedKeyboardMacro(name: macroName, sequence: recordedKeys)
                        onSave(macro)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                .disabled(macroName.isEmpty || recordedKeys.isEmpty)
                
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

// MARK: - Mouse & HID Settings
struct MouseHIDSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var hidManager = HIDManager.shared
    @State private var hidConnectionStatus = false
    @State private var switchStatus = false
    @State private var hdmiStatus = false
    @State private var resolution = "Unknown"
    @State private var frameRate = "Unknown"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Mouse & HID Control")
                .font(.title2)
                .bold()
            
            GroupBox("Mouse Control Mode") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mouse mode", selection: $userSettings.MouseControl) {
                        Text("Absolute").tag(MouseControlMode.absolute)
                        Text("Relative").tag(MouseControlMode.relative)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    Text(userSettings.MouseControl == .absolute ? 
                         "Absolute mode: Mouse cursor position directly matches target screen position" :
                         "Relative mode: Mouse movements are relative, allows for precise control")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
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
                        Text("USB Switch Status:")
                        Spacer()
                        Text(switchStatus ? "Target" : "Host")
                            .foregroundColor(switchStatus ? .blue : .orange)
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
        }
    }
    
    private func updateHIDStatus() {
        hidConnectionStatus = hidManager.getHardwareConnetionStatus()
        switchStatus = hidManager.getSwitchStatus()
        hdmiStatus = hidManager.getHDMIStatus()
        
        if let res = hidManager.getResolution() {
            resolution = "\(res.width)x\(res.height)"
        }
        
        if let fps = hidManager.getFps() {
            frameRate = String(format: "%.1f fps", fps)
        }
    }
}

// MARK: - Audio & Video Settings  
struct AudioVideoSettingsView: View {
    @ObservedObject private var audioManager = AudioManager.shared
    @ObservedObject private var userSettings = UserSettings.shared
    
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
                    
                    Toggle("Use custom aspect ratio", isOn: $userSettings.useCustomAspectRatio)
                    
                    if userSettings.useCustomAspectRatio {
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
                    
                    Toggle("Show HID resolution change alerts", isOn: Binding(
                        get: { !userSettings.doNotShowHidResolutionAlert },
                        set: { userSettings.doNotShowHidResolutionAlert = !$0 }
                    ))
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Clipboard & OCR Settings
struct ClipboardOCRSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var lastOCRText = ""
    @State private var ocrAccuracy = "Unknown"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Clipboard & OCR Management")
                .font(.title2)
                .bold()
            
            GroupBox("Clipboard Behavior") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure how Cmd+V paste events are handled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker("When Cmd+V is pressed:", selection: $userSettings.pasteBehavior) {
                        ForEach(PasteBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Behavior explanations:")
                            .font(.headline)
                        
                        Text("• Ask Every Time: Shows a dialog to choose the action")
                            .font(.caption)
                        Text("• Always Paste text to Target: Automatically sends clipboard text as keystrokes")
                            .font(.caption)
                        Text("• Always Pass events to Target: Forwards the Cmd+V combination directly")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ocrComplete)) { notification in
            if let result = notification.object as? String {
                lastOCRText = result
                ocrAccuracy = "Success"
            }
        }
    }
}

// MARK: - Device & Connection Settings
struct DeviceConnectionSettingsView: View {
    @ObservedObject private var hidManager = HIDManager.shared
    @State private var firmwareVersion = "Unknown"
    @State private var serialNumber = "Unknown"
    @State private var connectionAttempts = 0
    @State private var showingFirmwareUpdate = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Device & Connection Management")
                .font(.title2)
                .bold()
            
            GroupBox("Device Information") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Hardware Status:")
                        Spacer()
                        Text(hidManager.getHardwareConnetionStatus() ? "Connected" : "Disconnected")
                            .foregroundColor(hidManager.getHardwareConnetionStatus() ? .green : .red)
                    }
                    
                    HStack {
                        Text("Firmware Version:")
                        Spacer()
                        Text(firmwareVersion)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    HStack {
                        Text("Serial Number:")
                        Spacer()
                        Text(serialNumber)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    if let resolution = hidManager.getResolution() {
                        HStack {
                            Text("Current Resolution:")
                            Spacer()
                            Text("\(resolution.width) × \(resolution.height)")
                        }
                    }
                    
                    if let fps = hidManager.getFps() {
                        HStack {
                            Text("Refresh Rate:")
                            Spacer()
                            Text(String(format: "%.1f Hz", fps))
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            
            GroupBox("Connection Management") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Restart HID Operations") {
                            hidManager.restartHIDOperations()
                            connectionAttempts += 1
                        }
                        
                        Button("Stop All HID Operations") {
                            hidManager.stopAllHIDOperations()
                        }
                        
                        Spacer()
                        
                        Text("Attempts: \(connectionAttempts)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("USB Control:")
                        Button("Switch to Host") {
                            hidManager.setUSBtoHost()
                        }
                        Button("Switch to Target") {
                            hidManager.setUSBtoTarget()
                        }
                        
                        Spacer()
                        
                        Text("Current: \(hidManager.getSwitchStatus() ? "Target" : "Host")")
                            .font(.caption)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .onAppear {
            loadDeviceInfo()
        }
        .sheet(isPresented: $showingFirmwareUpdate) {
            Text("Firmware Update Dialog")
                .frame(width: 400, height: 300)
        }
    }
    
    private func loadDeviceInfo() {
        // Load device information
        firmwareVersion = "v1.0.0" // Placeholder
        serialNumber = "OT001234567" // Placeholder
    }
}

// MARK: - Advanced & Debug Settings
struct AdvancedDebugSettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var showingLogViewer = false
    @State private var logEntryCount = 0
    @State private var showingExportSuccess = false
    @State private var showingImportSuccess = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Advanced & Debug Configuration")
                .font(.title2)
                .bold()
            
            GroupBox("Debug & Logging") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable serial output logging", isOn: $userSettings.isSerialOutput)
                    
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
        userSettings.useCustomAspectRatio = false
        userSettings.customAspectRatio = .ratio16_9
        userSettings.isAbsoluteModeMouseHide = false
        userSettings.doNotShowHidResolutionAlert = false
        userSettings.edgeThreshold = 5
        userSettings.isSerialOutput = false
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
    
    private func createSettingsExportData() -> [String: Any] {
        return [
            "version": "1.0",
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "appVersion": getAppVersionString(),
            "settings": [
                "mouseControl": userSettings.MouseControl.rawValue,
                "isAudioEnabled": userSettings.isAudioEnabled,
                "pasteBehavior": userSettings.pasteBehavior.rawValue,
                "useCustomAspectRatio": userSettings.useCustomAspectRatio,
                "customAspectRatio": userSettings.customAspectRatio.rawValue,
                "isAbsoluteModeMouseHide": userSettings.isAbsoluteModeMouseHide,
                "doNotShowHidResolutionAlert": userSettings.doNotShowHidResolutionAlert,
                "edgeThreshold": userSettings.edgeThreshold,
                "isSerialOutput": userSettings.isSerialOutput,
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
        
        // Apply aspect ratio settings
        if let useCustomAspectRatio = settings["useCustomAspectRatio"] as? Bool {
            userSettings.useCustomAspectRatio = useCustomAspectRatio
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
    
    private func getCurrentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

struct LogViewerDialog: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            Text("Application Logs")
                .font(.headline)
            
            ScrollView {
                Text("Sample log entries would appear here...")
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .background(Color.black)
            .foregroundColor(.green)
            .cornerRadius(4)
            
            Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }
        }
        .padding()
        .frame(width: 600, height: 400)
    }
}

class SettingsScreenWC<RootView : View>: NSWindowController, NSWindowDelegate {
    convenience init(rootView: RootView) {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
        window.title = "Openterface Settings"
        window.makeKey()
        window.orderFrontRegardless()
        window.setContentSize(NSSize(width: 900, height: 700))
        window.minSize = NSSize(width: 800, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]

        self.init(window: window)
        self.window?.delegate = self
        self.window?.center()
    }
}

// MARK: - KeyboardShortcuts Extensions
extension KeyboardShortcuts.Name {
    static let exitRelativeMode = Self("exitRelativeMode")
    static let exitFullScreenMode = Self("exitFullScreenMode")
    static let triggerAreaOCR = Self("triggerAreaOCR")
    static let toggleUSBSwitch = Self("toggleUSBSwitch")
    static let openFirmwareUpdate = Self("openFirmwareUpdate")
    static let toggleFloatingKeyboard = Self("toggleFloatingKeyboard")
}

// MARK: - Additional Protocol Definitions for Enhanced Key Mapping
enum EnhancedSpecialKey {
    case enter
    case tab
    case escape
    case space
    case delete
    case backspace
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case ctrlAltDel
    case c, v, s
}

struct EnhancedKeyboardInput {
    enum KeyType {
        case character(Character)
        case specialKey(EnhancedSpecialKey)
        case keyboardMapperSpecialKey(KeyboardMapper.SpecialKey)
    }
    
    let key: KeyType
    let modifiers: NSEvent.ModifierFlags
}

struct EnhancedKeyboardMacro {
    let name: String
    let sequence: [EnhancedKeyboardInput]
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let ocrComplete = Notification.Name("ocrComplete")
}
