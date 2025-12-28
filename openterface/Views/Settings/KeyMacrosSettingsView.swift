import SwiftUI
import Foundation

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
                            let sChar: UInt16 = 115
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
                if isModifierKey(specialKey) && input.modifiers.isEmpty {
                    executeStandaloneModifierKey(specialKey)
                } else {
                    KeyboardManager.shared.sendSpecialKeyToKeyboard(code: specialKey)
                }
            case .character(let char):
                if !input.modifiers.isEmpty {
                    executeCharacterWithModifiers(char, modifiers: input.modifiers)
                } else {
                    KeyboardManager.shared.sendTextToKeyboard(text: String(char))
                }
            case .specialKey(let specialKey):
                executeSpecialKeyWithModifiers(specialKey, modifiers: input.modifiers)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func executeCharacterWithModifiers(_ char: Character, modifiers: NSEvent.ModifierFlags) {
        let keyboardManager = KeyboardManager.shared
        let kbm = keyboardManager.kbm
        let charCode = String(char).utf16.first ?? 0
        let keyCode = kbm.fromCharToKeyCode(char: charCode)
        kbm.pressKey(keys: [UInt16(keyCode)], modifiers: modifiers)
        Thread.sleep(forTimeInterval: 0.01)
        kbm.releaseKey(keys: [UInt16(keyCode)])
        Thread.sleep(forTimeInterval: 0.01)
    }

    private func executeSpecialKeyWithModifiers(_ specialKey: EnhancedSpecialKey, modifiers: NSEvent.ModifierFlags) {
        let keyboardManager = KeyboardManager.shared
        let kbm = keyboardManager.kbm
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
        case .ctrlAltDel: keyCode = nil
        case .c: keyCode = 8
        case .v: keyCode = 9
        case .s: keyCode = 1
        }

        if let code = keyCode {
            kbm.pressKey(keys: [code], modifiers: modifiers)
            Thread.sleep(forTimeInterval: 0.01)
            kbm.releaseKey(keys: [code])
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func isModifierKey(_ key: KeyboardMapper.SpecialKey) -> Bool {
        return [.leftShift, .rightShift, .leftCtrl, .rightCtrl, .leftAlt, .rightAlt, .win].contains(key)
    }

    private func executeStandaloneModifierKey(_ key: KeyboardMapper.SpecialKey) {
        let keyboardManager = KeyboardManager.shared
        if let keyCode = keyboardManager.kbm.fromSpecialKeyToKeyCode(code: key) {
            keyboardManager.kbm.pressKey(keys: [keyCode], modifiers: [])
            Thread.sleep(forTimeInterval: 0.01)
            keyboardManager.kbm.releaseKey(keys: [keyCode])
            Thread.sleep(forTimeInterval: 0.01)
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

            Button("Run") { onExecute() }
                .font(.caption)

            Button("Delete") { onDelete() }
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
    @State private var modifierKeyPressed = false
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

                Button(isRecording ? "Stop Recording" : "Start Recording") { toggleRecording() }
                    .foregroundColor(isRecording ? .red : .blue)

                if !recordedKeys.isEmpty && !isRecording {
                    Button("Clear Recording") { recordedKeys.removeAll() }
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

                Button("Cancel") { stopRecording(); presentationMode.wrappedValue.dismiss() }
            }
        }
        .padding()
        .frame(width: 450, height: 350)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() { if isRecording { stopRecording() } else { startRecording() } }

    private func startRecording() {
        isRecording = true
        currentRecordingText = "Recording... Press ESC to stop"
        lastModifierFlags = []
        modifierKeyPressed = false

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown { self.handleKeyEvent(event) }
            else if event.type == .flagsChanged { self.handleModifierEvent(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = keyEventMonitor { NSEvent.removeMonitor(monitor); keyEventMonitor = nil }
        isRecording = false
        currentRecordingText = "Press keys to record..."
        lastModifierFlags = []
        modifierKeyPressed = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        modifierKeyPressed = true

        if let characters = event.characters, !characters.isEmpty {
            let char = characters.first!
            if let specialKey = keyCodeToSpecialKey(event.keyCode) {
                let input = EnhancedKeyboardInput(key: .specialKey(specialKey), modifiers: modifiers)
                recordedKeys.append(input); currentRecordingText = "Recorded: \(getKeyDescription(input))"
            } else if char.isPrintable || char == " " || char == "\t" || char == "\n" {
                let input = EnhancedKeyboardInput(key: .character(char), modifiers: modifiers)
                recordedKeys.append(input); currentRecordingText = "Recorded: \(getKeyDescription(input))"
            } else {
                if let kbSpecialKey = keyCodeToKeyboardMapperSpecialKey(event.keyCode) {
                    let input = EnhancedKeyboardInput(key: .keyboardMapperSpecialKey(kbSpecialKey), modifiers: modifiers)
                    recordedKeys.append(input); currentRecordingText = "Recorded: \(getKeyDescription(input))"
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
        let releasedModifiers = previousModifiers.subtracting(currentModifiers)
        let releasedCount = [releasedModifiers.contains(.shift), releasedModifiers.contains(.control), releasedModifiers.contains(.option), releasedModifiers.contains(.command)].filter { $0 }.count

        if !releasedModifiers.isEmpty && currentModifiers.isEmpty && !modifierKeyPressed && releasedCount == 1 {
            if releasedModifiers.contains(.shift) {
                let input = EnhancedKeyboardInput(key: .keyboardMapperSpecialKey(.leftShift), modifiers: [])
                recordedKeys.append(input); currentRecordingText = "Recorded: Shift (standalone)"
            } else if releasedModifiers.contains(.control) {
                let input = EnhancedKeyboardInput(key: .keyboardMapperSpecialKey(.leftCtrl), modifiers: [])
                recordedKeys.append(input); currentRecordingText = "Recorded: Ctrl (standalone)"
            } else if releasedModifiers.contains(.option) {
                let input = EnhancedKeyboardInput(key: .keyboardMapperSpecialKey(.leftAlt), modifiers: [])
                recordedKeys.append(input); currentRecordingText = "Recorded: Alt (standalone)"
            } else if releasedModifiers.contains(.command) {
                let input = EnhancedKeyboardInput(key: .keyboardMapperSpecialKey(.win), modifiers: [])
                recordedKeys.append(input); currentRecordingText = "Recorded: Cmd (standalone)"
            }
        }

        if currentModifiers.isEmpty { modifierKeyPressed = false }
        lastModifierFlags = event.modifierFlags
    }

    private func getKeyDescription(_ input: EnhancedKeyboardInput) -> String {
        var description = ""
        if input.modifiers.contains(.control) { description += "Ctrl+" }
        if input.modifiers.contains(.option) { description += "Alt+" }
        if input.modifiers.contains(.command) { description += "Cmd+" }
        if input.modifiers.contains(.shift) { description += "Shift+" }

        switch input.key {
        case .character(let char):
            if char == " " { description += "Space" }
            else if char == "\t" { description += "Tab" }
            else if char == "\n" { description += "Enter" }
            else { description += String(char).uppercased() }
        case .specialKey(let special): description += special.rawValue.capitalized
        case .keyboardMapperSpecialKey(let kbSpecial): description += kbSpecial.rawValue.uppercased()
        }

        return description
    }

    private func getRecordedKeysPreview() -> String { recordedKeys.map { getKeyDescription($0) }.joined(separator: " → ") }

}
