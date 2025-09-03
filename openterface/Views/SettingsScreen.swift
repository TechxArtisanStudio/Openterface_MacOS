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
    @ObservedObject private var userSettings = UserSettings.shared
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
                        Picker("", selection: $userSettings.keyboardLayout) {
                            ForEach(KeyboardLayout.allCases, id: \.self) { layout in
                                Text(layout.displayName).tag(layout)
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
                    
                    // Replace this section with more detailed mapping information
                    VStack(alignment: .leading, spacing: 4) {
                        if userSettings.keyboardLayout == .windows {
                            Text("Windows Mode Key Mapping:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("• Cmd (⌘) → Ctrl")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Option (⌥) → Alt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Control (⌃) → Win Key")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Mac Mode Key Mapping:")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("• Cmd (⌘) → Cmd (⌘)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Option (⌥) → Option (⌥)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Control (⌃) → Control (⌃)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
            .onAppear {
                // Set window identifier for keyboard manager to recognize this dialog
                DispatchQueue.main.async {
                    if let window = NSApp.keyWindow {
                        window.identifier = NSUserInterfaceItemIdentifier("macroCreatorDialog")
                    }
                }
            }
        }
    }
    
    private func executeEnhancedKeyboardMacro(_ macro: EnhancedKeyboardMacro) {
        for input in macro.sequence {
            switch input.key {
            case .keyboardMapperSpecialKey(let specialKey):
                // Handle standalone modifier keys specially for macro execution
                if isModifierKey(specialKey) && input.modifiers.isEmpty {
                    executeStandaloneModifierKey(specialKey)
                } else {
                    KeyboardManager.shared.sendSpecialKeyToKeyboard(code: specialKey)
                }
            case .character(let char):
                // For character inputs with modifiers, we need to handle them properly
                if !input.modifiers.isEmpty {
                    executeCharacterWithModifiers(char, modifiers: input.modifiers)
                } else {
                    KeyboardManager.shared.sendTextToKeyboard(text: String(char))
                }
            case .specialKey(let specialKey):
                // Handle enhanced special keys with their modifiers
                executeSpecialKeyWithModifiers(specialKey, modifiers: input.modifiers)
            }
            Thread.sleep(forTimeInterval: 0.05) // Small delay between keys
        }
    }
    
    private func executeCharacterWithModifiers(_ char: Character, modifiers: NSEvent.ModifierFlags) {
        let keyboardManager = KeyboardManager.shared
        let kbm = keyboardManager.kbm
        
        // Convert character to key code
        let charCode = String(char).utf16.first ?? 0
        let keyCode = kbm.fromCharToKeyCode(char: charCode)
        
        // Press the key with modifiers
        kbm.pressKey(keys: [UInt16(keyCode)], modifiers: modifiers)
        Thread.sleep(forTimeInterval: 0.01) // Short press duration
        
        // Release the key
        kbm.releaseKey(keys: [UInt16(keyCode)])
        Thread.sleep(forTimeInterval: 0.01) // Brief pause after release
    }
    
    private func executeSpecialKeyWithModifiers(_ specialKey: EnhancedSpecialKey, modifiers: NSEvent.ModifierFlags) {
        let keyboardManager = KeyboardManager.shared
        let kbm = keyboardManager.kbm
        
        // Map Enhanced special keys to key codes
        var keyCode: UInt16?
        switch specialKey {
        case .enter: keyCode = 36
        case .tab: keyCode = 48
        case .escape: keyCode = 53
        case .space: keyCode = 49
        case .backspace: keyCode = 51
        case .delete: keyCode = 117
        case .arrowUp: keyCode = 126
        case .arrowDown: keyCode = 125
        case .arrowLeft: keyCode = 123
        case .arrowRight: keyCode = 124
        case .f1: keyCode = 122
        case .f2: keyCode = 120
        case .f3: keyCode = 99
        case .f4: keyCode = 118
        case .f5: keyCode = 96
        case .f6: keyCode = 97
        case .f7: keyCode = 98
        case .f8: keyCode = 100
        case .f9: keyCode = 101
        case .f10: keyCode = 109
        case .f11: keyCode = 103
        case .f12: keyCode = 111
        case .ctrlAltDel: keyCode = nil // Special combination, handle separately
        case .c: keyCode = 8 // 'c' key
        case .v: keyCode = 9 // 'v' key  
        case .s: keyCode = 1 // 's' key
        }
        
        if let code = keyCode {
            // Press the key with modifiers
            kbm.pressKey(keys: [code], modifiers: modifiers)
            Thread.sleep(forTimeInterval: 0.01) // Short press duration
            
            // Release the key
            kbm.releaseKey(keys: [code])
            Thread.sleep(forTimeInterval: 0.01) // Brief pause after release
        }
    }
    
    private func isModifierKey(_ key: KeyboardMapper.SpecialKey) -> Bool {
        return [.leftShift, .rightShift, .leftCtrl, .rightCtrl, .leftAlt, .rightAlt, .win].contains(key)
    }
    
    private func executeStandaloneModifierKey(_ key: KeyboardMapper.SpecialKey) {
        // For standalone modifier keys in macros, we want to press and immediately release
        let keyboardManager = KeyboardManager.shared
        
        // Get the key code for the modifier
        if let keyCode = keyboardManager.kbm.fromSpecialKeyToKeyCode(code: key) {
            // Press the modifier key
            keyboardManager.kbm.pressKey(keys: [keyCode], modifiers: [])
            Thread.sleep(forTimeInterval: 0.01) // Short press duration
            
            // Release the modifier key specifically
            keyboardManager.kbm.releaseKey(keys: [keyCode])
            Thread.sleep(forTimeInterval: 0.01) // Brief pause after release
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
    @State private var keyEventMonitor: Any?
    @State private var currentRecordingText = "Press keys to record..."
    @State private var lastModifierFlags: NSEvent.ModifierFlags = []
    @State private var modifierKeyPressed = false // Track if any regular key was pressed with modifiers
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Create Keyboard Macro")
                .font(.headline)
            
            Text("Create custom key sequences for repeated tasks. Click 'Start Recording', then press the keys you want to include in your macro.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            TextField("Macro name", text: $macroName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(isRecording)
            
            VStack(spacing: 8) {
                Text("Recorded sequence: \(recordedKeys.count) keys")
                    .font(.caption)
                
                if isRecording {
                    Text(currentRecordingText)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .italic()
                }
                
                // Display recorded keys preview
                if !recordedKeys.isEmpty {
                    ScrollView {
                        Text(getRecordedKeysPreview())
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                    .frame(maxHeight: 60)
                }
                
                Button(isRecording ? "Stop Recording" : "Start Recording") {
                    toggleRecording()
                }
                .foregroundColor(isRecording ? .red : .blue)
                
                if !recordedKeys.isEmpty && !isRecording {
                    Button("Clear Recording") {
                        recordedKeys.removeAll()
                    }
                    .font(.caption)
                    .foregroundColor(.gray)
                }
            }
            
            HStack {
                Button("Save Macro") {
                    if !macroName.isEmpty && !recordedKeys.isEmpty {
                        let macro = EnhancedKeyboardMacro(name: macroName, sequence: recordedKeys)
                        onSave(macro)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                .disabled(macroName.isEmpty || recordedKeys.isEmpty || isRecording)
                
                Button("Cancel") {
                    stopRecording()
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .padding()
        .frame(width: 450, height: 350)
        .onDisappear {
            stopRecording()
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        isRecording = true
        currentRecordingText = "Recording... Press ESC to stop"
        lastModifierFlags = [] // Initialize modifier state
        modifierKeyPressed = false // Reset the flag
        
        // Start monitoring keyboard events for both key presses and modifier changes
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                self.handleKeyEvent(event)
            } else if event.type == .flagsChanged {
                self.handleModifierEvent(event)
            }
            return nil // Consume the event to prevent it from being processed elsewhere
        }
    }
    
    private func stopRecording() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        isRecording = false
        currentRecordingText = "Press keys to record..."
        lastModifierFlags = [] // Reset modifier state
        modifierKeyPressed = false // Reset the flag
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        // Stop recording if ESC is pressed
        if event.keyCode == 53 { // ESC key
            stopRecording()
            return
        }
        
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        
        // Mark that a regular key was pressed (not just modifiers)
        modifierKeyPressed = true
        
        // Convert the key event to our EnhancedKeyboardInput format
        if let characters = event.characters, !characters.isEmpty {
            let char = characters.first!
            
            // Check if this is a special key that should be recorded as such
            if let specialKey = keyCodeToSpecialKey(event.keyCode) {
                let input = EnhancedKeyboardInput(
                    key: .specialKey(specialKey),
                    modifiers: modifiers
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: \(getKeyDescription(input))"
            } else if char.isPrintable || char == " " || char == "\t" || char == "\n" {
                // Record as character input
                let input = EnhancedKeyboardInput(
                    key: .character(char),
                    modifiers: modifiers
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: \(getKeyDescription(input))"
            } else {
                // Try to map to KeyboardMapper.SpecialKey
                if let kbSpecialKey = keyCodeToKeyboardMapperSpecialKey(event.keyCode) {
                    let input = EnhancedKeyboardInput(
                        key: .keyboardMapperSpecialKey(kbSpecialKey),
                        modifiers: modifiers
                    )
                    recordedKeys.append(input)
                    currentRecordingText = "Recorded: \(getKeyDescription(input))"
                }
            }
        }
    }
    
    private func keyCodeToSpecialKey(_ keyCode: UInt16) -> EnhancedSpecialKey? {
        switch keyCode {
        case 36: return .enter
        case 48: return .tab
        case 53: return .escape
        case 49: return .space
        case 51: return .backspace
        case 117: return .delete
        case 126: return .arrowUp
        case 125: return .arrowDown
        case 123: return .arrowLeft
        case 124: return .arrowRight
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        default: return nil
        }
    }
    
    private func keyCodeToKeyboardMapperSpecialKey(_ keyCode: UInt16) -> KeyboardMapper.SpecialKey? {
        switch keyCode {
        case 122: return .F1
        case 120: return .F2
        case 99: return .F3
        case 118: return .F4
        case 96: return .F5
        case 97: return .F6
        case 98: return .F7
        case 100: return .F8
        case 101: return .F9
        case 109: return .F10
        case 103: return .F11
        case 111: return .F12
        case 53: return .esc
        case 49: return .space
        case 36: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 117: return .delete
        case 126: return .arrowUp
        case 125: return .arrowDown
        case 123: return .arrowLeft
        case 124: return .arrowRight
        default: return nil
        }
    }
    
    private func handleModifierEvent(_ event: NSEvent) {
        let currentModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let previousModifiers = lastModifierFlags.intersection([.shift, .control, .option, .command])
        
        // Check which modifiers were released (removed)
        let releasedModifiers = previousModifiers.subtracting(currentModifiers)
        
        // Count how many modifiers were released by checking each flag
        let releasedCount = [releasedModifiers.contains(.shift), 
                           releasedModifiers.contains(.control),
                           releasedModifiers.contains(.option), 
                           releasedModifiers.contains(.command)].filter { $0 }.count
        
        // Only record standalone modifier keys when:
        // 1. All modifiers are released (currentModifiers.isEmpty)
        // 2. No regular key was pressed while modifiers were held (!modifierKeyPressed)
        // 3. Only one modifier was being held (releasedCount == 1)
        if !releasedModifiers.isEmpty && currentModifiers.isEmpty && !modifierKeyPressed && releasedCount == 1 {
            if releasedModifiers.contains(.shift) {
                let input = EnhancedKeyboardInput(
                    key: .keyboardMapperSpecialKey(.leftShift),
                    modifiers: []
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: Shift (standalone)"
            } else if releasedModifiers.contains(.control) {
                let input = EnhancedKeyboardInput(
                    key: .keyboardMapperSpecialKey(.leftCtrl),
                    modifiers: []
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: Ctrl (standalone)"
            } else if releasedModifiers.contains(.option) {
                let input = EnhancedKeyboardInput(
                    key: .keyboardMapperSpecialKey(.leftAlt),
                    modifiers: []
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: Alt (standalone)"
            } else if releasedModifiers.contains(.command) {
                let input = EnhancedKeyboardInput(
                    key: .keyboardMapperSpecialKey(.win),
                    modifiers: []
                )
                recordedKeys.append(input)
                currentRecordingText = "Recorded: Cmd (standalone)"
            }
        }
        
        // Reset the flag when all modifiers are released
        if currentModifiers.isEmpty {
            modifierKeyPressed = false
        }
        
        // Update the last modifier state
        lastModifierFlags = event.modifierFlags
    }
    
    private func getKeyDescription(_ input: EnhancedKeyboardInput) -> String {
        var description = ""
        
        // Add modifiers
        if input.modifiers.contains(.control) { description += "Ctrl+" }
        if input.modifiers.contains(.option) { description += "Alt+" }
        if input.modifiers.contains(.command) { description += "Cmd+" }
        if input.modifiers.contains(.shift) { description += "Shift+" }
        
        // Add key
        switch input.key {
        case .character(let char):
            if char == " " {
                description += "Space"
            } else if char == "\t" {
                description += "Tab"
            } else if char == "\n" {
                description += "Enter"
            } else {
                description += String(char).uppercased()
            }
        case .specialKey(let special):
            description += special.rawValue.capitalized
        case .keyboardMapperSpecialKey(let kbSpecial):
            description += kbSpecial.rawValue.uppercased()
        }
        
        return description
    }
    
    private func getRecordedKeysPreview() -> String {
        recordedKeys.map { getKeyDescription($0) }.joined(separator: " → ")
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
                        Text("• Always Host Paste: Automatically sends clipboard text as keystrokes")
                            .font(.caption)
                        Text("• Always Local Paste: Forwards the Cmd+V combination directly")
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
    @ObservedObject private var userSettings = UserSettings.shared
    @ObservedObject private var serialPortManager = SerialPortManager.shared
    @State private var firmwareVersion = "Unknown"
    @State private var serialNumber = "Unknown"
    @State private var connectionAttempts = 0
    @State private var showingFirmwareUpdate = false
    @State private var isUpdatingBaudrate = false
    
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
            
            GroupBox("Serial Port Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Preferred Baudrate:")
                        Spacer()
                        Picker("Baudrate", selection: $userSettings.preferredBaudrate) {
                            ForEach(BaudrateOption.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 200)
                        .onChange(of: userSettings.preferredBaudrate) { newBaudrate in
                            if serialPortManager.isDeviceReady {
                                isUpdatingBaudrate = true
                                applyBaudrateChange()
                            }
                        }
                    }
                    
                    Text(userSettings.preferredBaudrate.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("Current Connection:")
                        Spacer()
                        if isUpdatingBaudrate {
                            Text("Updating Baudrate...")
                                .foregroundColor(.orange)
                        } else if serialPortManager.isDeviceReady {
                            Text("Connected at \(serialPortManager.baudrate) bps")
                                .foregroundColor(.green)
                        } else {
                            Text("Disconnected")
                                .foregroundColor(.red)
                        }
                    }
                    .font(.caption)
                    
                    Text("Device will automatically reconnect when baudrate is changed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("⚠️ Important: When changing baudrate:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                        
                        Text("• Please wait a few seconds for the change to apply")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text("• If keyboard and mouse stop working, disconnect all cables and reconnect")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
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
        .onChange(of: serialPortManager.isDeviceReady) { isReady in
            // Reset the updating flag when device reconnects after baudrate change
            if isReady && isUpdatingBaudrate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isUpdatingBaudrate = false
                }
            }
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
    
    private func applyBaudrateChange() {
        let currentBaudrate = serialPortManager.baudrate
        let targetBaudrate = userSettings.preferredBaudrate.rawValue
        
        // Determine if this is a low-to-high or high-to-low change
        let isLowToHigh = (currentBaudrate == SerialPortManager.LOWSPEED_BAUDRATE && 
                          targetBaudrate == SerialPortManager.HIGHSPEED_BAUDRATE)
        let isHighToLow = (currentBaudrate == SerialPortManager.HIGHSPEED_BAUDRATE && 
                          targetBaudrate == SerialPortManager.LOWSPEED_BAUDRATE)
        
        // Give a brief moment for the port to close properly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if isHighToLow {
                // High speed to low speed requires factory reset
                self.serialPortManager.resetHidChipToFactory { success in
                    if success {
                        // After factory reset, try to reconnect with the new baudrate
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.serialPortManager.tryOpenSerialPort(priorityBaudrate: targetBaudrate)
                            // Reset the updating flag after attempting reconnection
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                self.isUpdatingBaudrate = false
                            }
                        }
                    } else {
                        // Reset the updating flag if factory reset failed
                        DispatchQueue.main.async {
                            self.isUpdatingBaudrate = false
                        }
                    }
                }
            } else if isLowToHigh {
                // Low speed to high speed uses regular reset
                self.serialPortManager.resetDeviceToBaudrate(targetBaudrate)
                // Reset the updating flag after the reset operation
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.isUpdatingBaudrate = false
                }
            } else {
                // Same baudrate or other cases, use regular reset
                self.serialPortManager.resetDeviceToBaudrate(targetBaudrate)
                // Reset the updating flag after the reset operation
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.isUpdatingBaudrate = false
                }
            }
        }
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
enum EnhancedSpecialKey: String {
    case enter = "enter"
    case tab = "tab"
    case escape = "escape"
    case space = "space"
    case delete = "delete"
    case backspace = "backspace"
    case arrowUp = "arrowUp"
    case arrowDown = "arrowDown"
    case arrowLeft = "arrowLeft"
    case arrowRight = "arrowRight"
    case f1 = "f1", f2 = "f2", f3 = "f3", f4 = "f4", f5 = "f5", f6 = "f6"
    case f7 = "f7", f8 = "f8", f9 = "f9", f10 = "f10", f11 = "f11", f12 = "f12"
    case ctrlAltDel = "ctrlAltDel"
    case c = "c", v = "v", s = "s"
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

// MARK: - Character Extensions
extension Character {
    var isPrintable: Bool {
        return unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            CharacterSet.punctuationCharacters.contains(scalar) ||
            CharacterSet.symbols.contains(scalar) ||
            scalar == UnicodeScalar(" ")
        }
    }
}
