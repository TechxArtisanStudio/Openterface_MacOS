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
        case ai = "AI Integration"
        case connection = "Device & Connection"
        case remoteControl = "Remote Control"
        case advanced = "Advanced & Debug"

        var icon: String {
            switch self {
            case .keyMapping: return "keyboard"
            case .macros: return "keyboard.badge.ellipsis"
            case .mouse: return "cursorarrow"
            case .audio: return "speaker.wave.3"
            case .clipboard: return "doc.on.clipboard"
            case .ai: return "sparkles"
            case .connection: return "externaldrive.connected.to.line.below"
            case .remoteControl: return "network"
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
                    case .ai:
                        AISettingsView()
                    case .connection:
                        DeviceConnectionSettingsView()
                    case .remoteControl:
                        RemoteControlSettingsView()
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

struct AISettingsView: View {
    @ObservedObject private var userSettings = UserSettings.shared
    @State private var isTestingConnection = false
    @State private var testConnectionMessage: String = ""
    @State private var testConnectionSucceeded = false

    enum AIProviderPreset: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case dashScope = "DashScope (Qwen)"
        case ollama = "Ollama (Local)"
        case custom = "Custom"

        var id: String { rawValue }

        var baseURL: String {
            switch self {
            case .openAI:
                return "https://api.openai.com/v1"
            case .dashScope:
                return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .ollama:
                return "http://localhost:11434/v1"
            case .custom:
                return ""
            }
        }

        var defaultModel: String {
            switch self {
            case .openAI:
                return "gpt-4o-mini"
            case .dashScope:
                return "qwen-plus"
            case .ollama:
                return "llama3.2"
            case .custom:
                return ""
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI Integration")
                .font(.title2)
                .bold()

            GroupBox("Provider Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure the OpenAI-compatible endpoint used by the docked chat window")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Presets")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            ForEach([AIProviderPreset.openAI, .dashScope, .ollama, .custom]) { preset in
                                Button(preset.rawValue) {
                                    applyPreset(preset)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Base URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://api.openai.com/v1", text: $userSettings.chatApiBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("sk-...", text: $userSettings.chatApiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Stored securely in macOS Keychain")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("gpt-4o-mini", text: $userSettings.chatModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    Toggle("Enable Agentic Mode (tool execution)", isOn: $userSettings.isChatAgenticModeEnabled)
                        .toggleStyle(.switch)

                    if userSettings.isChatAgenticModeEnabled {
                        Text("Agentic Mode allows the assistant to request tool actions like capture screen, move/click mouse, and type text.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Agentic Mode is off: chat will only return text guidance and will not execute tools.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Enable Multi-Agent Planning", isOn: $userSettings.isChatPlannerModeEnabled)
                        .toggleStyle(.switch)

                    if userSettings.isChatPlannerModeEnabled {
                        Text("Multi-Agent Planning captures the current screen, creates a task list for approval, then runs screen-only task agents one at a time.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Multi-Agent Planning is off: chat stays in the existing direct-response or legacy agentic workflow.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screen Capture Size")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("Screen Capture Size", selection: $userSettings.chatImageUploadLimit) {
                            ForEach(ChatImageUploadLimit.allCases) { limit in
                                Text(limit.displayName).tag(limit)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(userSettings.chatImageUploadLimit.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Text("Applies to screenshots attached in chat and to the agentic capture_screen tool before the image is sent to the AI service.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $userSettings.systemPrompt)
                            .frame(minHeight: 140)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Main Agent Planner Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $userSettings.plannerPrompt)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screen Task Agent Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $userSettings.screenAgentPrompt)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Typing Task Agent Prompt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $userSettings.typingAgentPrompt)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    Text("Text messages and captured screenshots from chat are sent to this configured AI service.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Button(action: {
                            Task {
                                await testConnection()
                            }
                        }) {
                            HStack(spacing: 6) {
                                if isTestingConnection {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isTestingConnection ? "Testing..." : "Test Connection")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTestingConnection || !canTestConnection)

                        if !testConnectionMessage.isEmpty {
                            Text(testConnectionMessage)
                                .font(.caption)
                                .foregroundColor(testConnectionSucceeded ? .green : .red)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var canTestConnection: Bool {
        !userSettings.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !userSettings.chatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !userSettings.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyPreset(_ preset: AIProviderPreset) {
        switch preset {
        case .custom:
            break
        default:
            userSettings.chatApiBaseURL = preset.baseURL
            userSettings.chatModel = preset.defaultModel
        }

        testConnectionMessage = ""
        testConnectionSucceeded = false
    }

    private func testConnection() async {
        let baseURLString = userSettings.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = userSettings.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = userSettings.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let baseURL = URL(string: baseURLString) else {
            Logger.shared.log(content: "AI Test Connection aborted: invalid base URL -> \(baseURLString)")
            await MainActor.run {
                testConnectionSucceeded = false
                testConnectionMessage = "Invalid base URL"
            }
            return
        }

        await MainActor.run {
            isTestingConnection = true
            testConnectionMessage = ""
            testConnectionSucceeded = false
        }

        defer {
            Task { @MainActor in
                isTestingConnection = false
            }
        }

        var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("models"))
        modelsRequest.httpMethod = "GET"
        modelsRequest.timeoutInterval = 12
        modelsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let modelsURL = modelsRequest.url?.absoluteString ?? "(nil)"
        Logger.shared.log(content: "AI Test Connection request -> GET \(modelsURL)")

        do {
            let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
            guard let modelsHTTP = modelsResponse as? HTTPURLResponse else {
                Logger.shared.log(content: "AI Test Connection response error: non-HTTP response")
                await MainActor.run {
                    testConnectionSucceeded = false
                    testConnectionMessage = "Invalid response"
                }
                return
            }

            Logger.shared.log(content: "AI Test Connection response <- status=\(modelsHTTP.statusCode), bytes=\(modelsData.count)")

            if (200...299).contains(modelsHTTP.statusCode) {
                await MainActor.run {
                    testConnectionSucceeded = true
                    testConnectionMessage = "Connection successful"
                }
                return
            }

            let modelsBody = String(data: modelsData, encoding: .utf8) ?? ""
            let modelsSnippet = String(modelsBody.prefix(500))
            Logger.shared.log(content: "AI Test Connection response error body: \(modelsSnippet)")

            // Some OpenAI-compatible providers do not expose /models. Fallback to
            // a minimal /chat/completions probe for compatibility checks.
            if modelsHTTP.statusCode == 404 {
                var probeRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                probeRequest.httpMethod = "POST"
                probeRequest.timeoutInterval = 12
                probeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                probeRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                let probePayload: [String: Any] = [
                    "model": model,
                    "messages": [["role": "user", "content": "ping"]],
                    "max_tokens": 1,
                    "stream": false
                ]
                probeRequest.httpBody = try JSONSerialization.data(withJSONObject: probePayload)

                let probeURL = probeRequest.url?.absoluteString ?? "(nil)"
                Logger.shared.log(content: "AI Test Connection fallback request -> POST \(probeURL)")

                let (probeData, probeResponse) = try await URLSession.shared.data(for: probeRequest)
                guard let probeHTTP = probeResponse as? HTTPURLResponse else {
                    await MainActor.run {
                        testConnectionSucceeded = false
                        testConnectionMessage = "Fallback probe invalid response"
                    }
                    return
                }

                Logger.shared.log(content: "AI Test Connection fallback response <- status=\(probeHTTP.statusCode), bytes=\(probeData.count)")

                if (200...299).contains(probeHTTP.statusCode) {
                    await MainActor.run {
                        testConnectionSucceeded = true
                        testConnectionMessage = "Connection successful (via chat endpoint)"
                    }
                    return
                }

                let probeBody = String(data: probeData, encoding: .utf8) ?? ""
                let probeSnippet = String(probeBody.prefix(500))
                Logger.shared.log(content: "AI Test Connection fallback error body: \(probeSnippet)")

                await MainActor.run {
                    testConnectionSucceeded = false
                    testConnectionMessage = "Failed (\(probeHTTP.statusCode)). Check base URL path."
                }
                return
            }

            await MainActor.run {
                testConnectionSucceeded = false
                testConnectionMessage = "Connection failed (\(modelsHTTP.statusCode))"
            }
        } catch {
            Logger.shared.log(content: "AI Test Connection failed with error: \(error.localizedDescription)")
            await MainActor.run {
                testConnectionSucceeded = false
                testConnectionMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
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
