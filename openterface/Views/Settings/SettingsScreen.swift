import SwiftUI
import KeyboardShortcuts

// Top-level Settings container moved here for better organization.
// Subviews live in `SettingsComponents.swift` in the same folder.

struct SettingsScreen: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var selectedTab: SettingsTab = .keyMapping

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
            // Sidebar
            VStack(alignment: .leading, spacing: 8) {
                Text("Openterface KVM Settings")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                Text("Configure key mapping, device behavior, and advanced features")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
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

            // Content area
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 900, height: 700)
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

// KeyboardShortcuts names used by the settings UI
extension KeyboardShortcuts.Name {
    static let exitRelativeMode = Self("exitRelativeMode")
    static let exitFullScreenMode = Self("exitFullScreenMode")
    static let triggerAreaOCR = Self("triggerAreaOCR")
    static let toggleUSBSwitch = Self("toggleUSBSwitch")
    static let openFirmwareUpdate = Self("openFirmwareUpdate")
    static let toggleFloatingKeyboard = Self("toggleFloatingKeyboard")
}

// Shared notification
extension Notification.Name {
    static let ocrComplete = Notification.Name("ocrComplete")
}

// Small helper
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
