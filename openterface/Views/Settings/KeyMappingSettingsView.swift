import SwiftUI
import Foundation
import KeyboardShortcuts

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
