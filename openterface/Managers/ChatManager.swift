import SwiftUI
import AppKit

struct ChatTaskTraceEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let title: String
    let body: String
    let imageFilePath: String?

    init(id: UUID = UUID(), timestamp: Date = Date(), title: String, body: String, imageFilePath: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.body = body
        self.imageFilePath = imageFilePath
    }
}

struct GuideAutoNextStatus: Equatable {
    enum Phase: Equatable {
        case thinking
        case completed
        case failed
        case cancelled
    }

    let phase: Phase
    let text: String
}

private struct ChatCompletionResult {
    let content: String
    let inputTokenCount: Int?
    let outputTokenCount: Int?
}

struct MacroAIDraftRequest {
    let goal: String
    let targetSystem: MacroTargetSystem
    let currentLabel: String
    let currentDescription: String
    let currentData: String
}

struct MacroAIDraft {
    let label: String
    let description: String
    let data: String
    let intervalMs: Int
}

private enum AIInputRouter {
    private static var trackedMouseX: Int = 2048
    private static var trackedMouseY: Int = 2048
    private static let animatedClickDurationSeconds: Double = 2.0
    private static let animatedClickSteps: Int = 24

    private static func clampedAbsolute(_ value: Int) -> Int {
        min(max(value, 0), 4096)
    }

    private static func mapToVNCFramebuffer(absX: Int, absY: Int) -> (x: Int, y: Int) {
        let x = clampedAbsolute(absX)
        let y = clampedAbsolute(absY)
        let framebuffer = VNCClientManager.shared.framebufferSize
        let width = max(Int(framebuffer.width.rounded()), 1)
        let height = max(Int(framebuffer.height.rounded()), 1)

        let mappedX = width <= 1 ? 0 : Int((Double(x) / 4096.0) * Double(width - 1))
        let mappedY = height <= 1 ? 0 : Int((Double(y) / 4096.0) * Double(height - 1))
        return (mappedX, mappedY)
    }

    private static func keySym(for keyCode: UInt16) -> UInt32? {
        let named: [UInt16: UInt32] = [
            53: 0xFF1B,  // esc
            36: 0xFF0D,  // enter
            48: 0xFF09,  // tab
            49: 0x0020,  // space
            51: 0xFF08,  // backspace
            115: 0xFF50, // home
            119: 0xFF57, // end
            116: 0xFF55, // page up
            121: 0xFF56, // page down
            126: 0xFF52, // up
            125: 0xFF54, // down
            123: 0xFF51, // left
            124: 0xFF53, // right
            122: 0xFFBE, // f1
            120: 0xFFBF, // f2
            99:  0xFFC0, // f3
            118: 0xFFC1, // f4
            96:  0xFFC2, // f5
            97:  0xFFC3, // f6
            98:  0xFFC4, // f7
            100: 0xFFC5, // f8
            101: 0xFFC6, // f9
            109: 0xFFC7, // f10
            103: 0xFFC8, // f11
            111: 0xFFC9  // f12
        ]
        if let symbol = named[keyCode] {
            return symbol
        }

        let alphaNumeric: [UInt16: UInt32] = [
            0: 0x0061, 11: 0x0062, 8: 0x0063, 2: 0x0064, 14: 0x0065,
            3: 0x0066, 5: 0x0067, 4: 0x0068, 34: 0x0069, 38: 0x006A,
            40: 0x006B, 37: 0x006C, 46: 0x006D, 45: 0x006E, 31: 0x006F,
            35: 0x0070, 12: 0x0071, 15: 0x0072, 1: 0x0073, 17: 0x0074,
            32: 0x0075, 9: 0x0076, 13: 0x0077, 7: 0x0078, 16: 0x0079,
            6: 0x007A,
            29: 0x0030, 18: 0x0031, 19: 0x0032, 20: 0x0033, 21: 0x0034,
            23: 0x0035, 22: 0x0036, 26: 0x0037, 28: 0x0038, 25: 0x0039
        ]
        return alphaNumeric[keyCode]
    }

    private static func keySym(for scalar: UnicodeScalar) -> UInt32 {
        switch scalar {
        case "\n", "\r":
            return 0xFF0D
        case "\t":
            return 0xFF09
        default:
            return scalar.value
        }
    }

    private static func modifierKeySyms(from modifiers: NSEvent.ModifierFlags) -> [UInt32] {
        let filtered = modifiers.intersection(.deviceIndependentFlagsMask)
        var symbols: [UInt32] = []
        if filtered.contains(.control) { symbols.append(0xFFE3) }
        if filtered.contains(.option) { symbols.append(0xFFE9) }
        if filtered.contains(.shift) { symbols.append(0xFFE1) }
        if filtered.contains(.command) { symbols.append(0xFFEB) }
        return symbols
    }

    static func sendMouseMove(absX: Int, absY: Int) {
        let clampedX = clampedAbsolute(absX)
        let clampedY = clampedAbsolute(absY)
        trackedMouseX = clampedX
        trackedMouseY = clampedY

        if AppStatus.activeConnectionProtocol == .vnc {
            let point = mapToVNCFramebuffer(absX: clampedX, absY: clampedY)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            return
        }

        HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
    }

    static func animatedClick(button: UInt8, absX: Int, absY: Int, isDoubleClick: Bool = false) {
        let targetX = clampedAbsolute(absX)
        let targetY = clampedAbsolute(absY)
        let startX = trackedMouseX
        let startY = trackedMouseY

        if startX != targetX || startY != targetY {
            let stepDelay = animatedClickDurationSeconds / Double(max(animatedClickSteps, 1))
            for step in 1...animatedClickSteps {
                let progress = Double(step) / Double(animatedClickSteps)
                let interpolatedX = Int((Double(startX) + Double(targetX - startX) * progress).rounded())
                let interpolatedY = Int((Double(startY) + Double(targetY - startY) * progress).rounded())
                sendMouseMove(absX: interpolatedX, absY: interpolatedY)
                Thread.sleep(forTimeInterval: stepDelay)
            }
        } else {
            sendMouseMove(absX: targetX, absY: targetY)
        }

        showClickOverlay(absX: targetX, absY: targetY)
        click(button: button, absX: targetX, absY: targetY, isDoubleClick: isDoubleClick)
    }

    private static func showClickOverlay(absX: Int, absY: Int) {
        let normalizedX = min(max(CGFloat(absX) / 4096.0, 0.0), 1.0)
        let normalizedY = min(max(CGFloat(absY) / 4096.0, 0.0), 1.0)
        let token = UUID()

        DispatchQueue.main.async {
            AppStatus.aiClickPointNormalized = CGPoint(x: normalizedX, y: normalizedY)
            AppStatus.aiClickOverlayToken = token
            AppStatus.showAIClickOverlay = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard AppStatus.aiClickOverlayToken == token else { return }
            AppStatus.showAIClickOverlay = false
        }
    }

    static func click(button: UInt8, absX: Int, absY: Int, isDoubleClick: Bool = false) {
        if AppStatus.activeConnectionProtocol == .vnc {
            let point = mapToVNCFramebuffer(absX: absX, absY: absY)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: button)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)

            guard isDoubleClick else { return }
            Thread.sleep(forTimeInterval: 0.12)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: button)
            Thread.sleep(forTimeInterval: 0.04)
            VNCClientManager.shared.sendPointerEvent(x: point.x, y: point.y, buttonMask: 0x00)
            return
        }

        let x = clampedAbsolute(absX)
        let y = clampedAbsolute(absY)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)

        guard isDoubleClick else { return }
        Thread.sleep(forTimeInterval: 0.12)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.04)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
    }

    static func sendText(_ text: String) {
        guard !text.isEmpty else { return }

        if AppStatus.activeConnectionProtocol == .vnc {
            for scalar in text.unicodeScalars {
                let keySym = keySym(for: scalar)
                VNCClientManager.shared.sendKeyEvent(keySym: keySym, isDown: true)
                Thread.sleep(forTimeInterval: 0.015)
                VNCClientManager.shared.sendKeyEvent(keySym: keySym, isDown: false)
                Thread.sleep(forTimeInterval: 0.015)
            }
            return
        }

        KeyboardManager.shared.sendTextToKeyboard(text: text)
    }

    static func sendShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if AppStatus.activeConnectionProtocol == .vnc {
            guard let mainKeySym = keySym(for: keyCode) else { return false }
            let modifierSymbols = modifierKeySyms(from: modifiers)

            for symbol in modifierSymbols {
                VNCClientManager.shared.sendKeyEvent(keySym: symbol, isDown: true)
            }

            VNCClientManager.shared.sendKeyEvent(keySym: mainKeySym, isDown: true)
            Thread.sleep(forTimeInterval: 0.05)
            VNCClientManager.shared.sendKeyEvent(keySym: mainKeySym, isDown: false)

            for symbol in modifierSymbols.reversed() {
                VNCClientManager.shared.sendKeyEvent(keySym: symbol, isDown: false)
            }

            return true
        }

        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: true)
        Thread.sleep(forTimeInterval: 0.05)
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: false)
        return true
    }
}

@MainActor
final class ChatManager: ObservableObject, ChatManagerProtocol {
    static let shared = ChatManager()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentPlan: ChatExecutionPlan?
    @Published private(set) var plannerTraceEntries: [ChatTaskTraceEntry] = []
    @Published private(set) var guideAutoNextStatuses: [UUID: GuideAutoNextStatus] = [:]

    private var currentTask: Task<Void, Never>?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let historyURL: URL
    private let aiTraceURL: URL
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    private let plannerAgent = MainPlannerAgent(maxPlannerTasks: 6)
    private let taskAgentRegistry = TaskAgentRegistry(agents: [
        ScreenTaskAgent(),
        TypeTextTaskAgent(),
        MacroTaskAgent(),
        MouseTaskAgent(toolName: "move_mouse"),
        MouseTaskAgent(toolName: "left_click"),
        MouseTaskAgent(toolName: "right_click"),
        MouseTaskAgent(toolName: "double_click")
    ])
    private let taskStateConfirmationInstruction = """
You are Openterface Task State Verifier.

Your job is to verify whether the current target screen state matches the expected outcome of one completed task.

Rules:
- Return ONLY JSON.
- Do not suggest new actions.
- If the image is unclear, mark confirmed=false and explain why.

Schema:
{
  "confirmed": true | false,
  "result_summary": "short verification summary"
}
"""
    private let taskConfirmationAttemptCount = 3
    private let taskConfirmationRetryDelayNanoseconds: UInt64 = 900_000_000
    private let macroGeneratorSupportedTokens: Set<String> = [
        "<CTRL>", "</CTRL>", "<SHIFT>", "</SHIFT>", "<ALT>", "</ALT>", "<CMD>", "</CMD>",
        "<ESC>", "<BACK>", "<ENTER>", "<TAB>", "<SPACE>", "<LEFT>", "<RIGHT>", "<UP>", "<DOWN>",
        "<HOME>", "<END>", "<DEL>", "<PGUP>", "<PGDN>",
        "<F1>", "<F2>", "<F3>", "<F4>", "<F5>", "<F6>", "<F7>", "<F8>", "<F9>", "<F10>", "<F11>", "<F12>",
        "<DELAY05s>", "<DELAY1S>", "<DELAY2S>", "<DELAY5S>", "<DELAY10S>"
    ]
    private let macroGenerationInstruction = """
You generate Openterface keyboard macros.

Return ONLY JSON with this schema:
{
  "label": "short macro name",
  "description": "one sentence tooltip",
  "data": "macro sequence using Openterface tokens",
  "intervalMs": 80
}

Macro authoring rules:
- Use only plain characters plus these tokens: <CTRL>, </CTRL>, <SHIFT>, </SHIFT>, <ALT>, </ALT>, <CMD>, </CMD>, <ESC>, <BACK>, <ENTER>, <TAB>, <SPACE>, <LEFT>, <RIGHT>, <UP>, <DOWN>, <HOME>, <END>, <DEL>, <PGUP>, <PGDN>, <F1>..<F12>, <DELAY05s>, <DELAY1S>, <DELAY2S>, <DELAY5S>, <DELAY10S>.
- Do not invent tokens.
- Do not use <MACRO:...> references.
- Use <ENTER> instead of a literal newline.
- Wrap modified key presses with opening and closing modifier tags, for example <CTRL>c</CTRL>.
- Whenever a macro finishes typing a plain-text burst and then continues with another action, insert a short delay such as <DELAY05s> before the next action so visual effects and UI updates can settle.
- Prefer the shortest stable shortcut for the requested target OS.
- Keep label short and description practical.
- Use intervalMs 80 unless the flow is timing-sensitive.
- Return JSON only, with no markdown or explanation.
"""
    private var agentMouseX: Int = 2048
    private var agentMouseY: Int = 2048
    private var pendingCapturePreviewSuppressions = 0
    private var taskStepTraces: [UUID: [ChatTaskTraceEntry]] = [:]
    private var guideCapturePathsByMessageID: [UUID: String] = [:]
    private var pendingGuideAutoNextStarts: [UUID: Date] = [:]
    private let agentToolInstruction = """
When action is required, you may call tools by returning ONLY JSON (no markdown):
{"tool_calls":[{"tool":"capture_screen"},{"tool":"move_mouse","x":0.5,"y":0.5},{"tool":"left_click"},{"tool":"type_text","text":"hello"},{"tool":"run_verified_macro","macro_id":"UUID-or-label"}]}

The target OS has already been configured by the app. Do not ask the user to confirm the OS again.

Coordinate system:
- All x/y values are normalized floats from 0.0 to 1.0.
- 0.0 means the left/top edge of the screen; 1.0 means the right/bottom edge.
- Estimate the element's position as a fraction of the screenshot width and height.
- Example: if a button is at roughly 45% from left and 30% from top, use x=0.45, y=0.30.
- NEVER output raw pixel coordinates. Always use 0.0-1.0 normalized values.

Available tools:
- capture_screen: Capture latest target screen and use it for next reasoning step.
- move_mouse: Move target mouse. Args: x (Float), y (Float) in 0.0...1.0.
- left_click: Left click at current mouse location. Optional args: x (Float), y (Float) in 0.0...1.0.
- right_click: Right click at current mouse location. Optional args: x (Float), y (Float) in 0.0...1.0.
- double_click: Double left click. Optional args: x (Float), y (Float) in 0.0...1.0.
- type_text: Type text on target. Args: text (String).
- run_verified_macro: Execute one verified macro. Args: macro_id (String, preferred UUID) or macro_label (String).

Macro tool rules:
- Prefer run_verified_macro when a verified macro can jump directly to the requested state.
- Before using capture_screen or incremental mouse steps, check whether a verified macro already matches the user's current goal or sub-goal and use it first when it is a strong fit.
- Only call run_verified_macro with a verified macro from the provided macro inventory.
- Prefer macro_id over macro_label when available.
- IMPORTANT: After running a macro, always verify the result in a NEW tool_calls response. Never include capture_screen or any other tool in the same tool_calls array as run_verified_macro, because the macro needs time to complete on the target machine before a screenshot is useful.
- If the macro partially completes the job, continue with more tool calls until the task is actually complete.
- If no verified macro matches, continue with the normal screen-driven tools.

Mouse safety rules:
- Only click when the intended target is clearly visible in the latest screenshot.
- Do not guess hidden Dock icons, hidden windows, or off-screen control locations.
- If a macro or shortcut did not bring the expected app/window to the foreground, prefer another verified macro, keyboard-driven recovery, or another capture_screen step instead of a blind click.
- When the task is a settings change, verify the result from the full visible UI state before choosing another action.

After tool execution, you will receive a TOOL_RESULT message. Continue until task done, then return normal user-facing text (not JSON).
"""

    private struct AgentToolCall {
        let tool: String
        let args: [String: Any]
    }

    private struct AgentToolExecutionResult {
        let summary: String
        let attachmentFilePath: String?
    }

    private struct TaskStateConfirmationPayload: Decodable {
        let confirmed: Bool
        let result_summary: String
    }

    private struct ClickTargetRefinementPayload: Decodable {
        let found: Bool?
        let x: Double?
        let y: Double?
        let matched_element: String?
        let confidence: Double?
    }

    private struct ChatAPIConfiguration {
        let baseURL: URL
        let model: String
        let apiKey: String
    }

    private struct ClickRefinementCropResult {
        let imageURL: URL
        let sourceWidth: Int
        let sourceHeight: Int
        let cropOriginX: Int
        let cropOriginYTop: Int
        let cropWidth: Int
        let cropHeight: Int
    }

    private struct MacroAIDraftPayload: Decodable {
        let label: String
        let description: String
        let data: String
        let intervalMs: Int?
    }

    private struct GuideResponsePayload: Decodable {
        struct TargetBox: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let next_step: String
        let tool: String?
        let tool_input: String?
        let target_box: TargetBox?
        let needs_clarification: Bool?
        let clarification: String?
    }

    private struct PersistedTaskTrace: Codable {
        let taskID: UUID
        let entries: [ChatTaskTraceEntry]
    }

    private struct PersistedChatState: Codable {
        let messages: [ChatMessage]
        let currentPlan: ChatExecutionPlan?
        let plannerTraceEntries: [ChatTaskTraceEntry]
        let taskTraces: [PersistedTaskTrace]
    }

    private struct VerifiedMacroMatch {
        let macro: Macro
        let matchedBy: String
    }

    @MainActor
    private final class CaptureScreenWaiter {
        var continuation: CheckedContinuation<URL?, Never>?
        var observer: NSObjectProtocol?
        var timeoutTask: Task<Void, Never>?

        func resolve(with url: URL?) {
            guard let continuation else { return }
            self.continuation = nil

            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }

            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: url)
        }
    }

    private init() {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        self.historyURL = ChatManager.makeHistoryURL()
        self.aiTraceURL = ChatManager.makeTraceURL(fileName: AppStatus.aiTraceLogFileName)
        loadHistory()
    }

    private func currentChatAPIConfiguration() -> ChatAPIConfiguration? {
        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey

        guard !baseURLString.isEmpty,
              let baseURL = URL(string: baseURLString),
              !model.isEmpty,
              !apiKey.isEmpty else {
            return nil
        }

        return ChatAPIConfiguration(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func generateMacroDraft(from request: MacroAIDraftRequest) async throws -> MacroAIDraft {
        let trimmedGoal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw NSError(domain: "ChatManager", code: 40, userInfo: [NSLocalizedDescriptionKey: "Describe what the macro should do."])
        }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey

        guard !baseURLString.isEmpty, let baseURL = URL(string: baseURLString) else {
            throw NSError(domain: "ChatManager", code: 41, userInfo: [NSLocalizedDescriptionKey: "AI base URL is not configured."])
        }
        guard !model.isEmpty else {
            throw NSError(domain: "ChatManager", code: 42, userInfo: [NSLocalizedDescriptionKey: "AI model is not configured."])
        }
        guard !apiKey.isEmpty else {
            throw NSError(domain: "ChatManager", code: 43, userInfo: [NSLocalizedDescriptionKey: "AI API key is not configured."])
        }

        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: macroGenerationInstruction))
        conversation.append(.text(role: .system, text: macroGenerationTargetGuidance(for: request.targetSystem)))
        conversation.append(.text(role: .user, text: macroGenerationPrompt(for: request)))

        let response = try await sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: "MACRO_GENERATOR"
        )

        let payload = try decodeJSONPayload(MacroAIDraftPayload.self, from: response.content)
        return try normalizedMacroDraft(from: payload)
    }

    private func macroGenerationPrompt(for request: MacroAIDraftRequest) -> String {
        let currentLabel = request.currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDescription = request.currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentData = request.currentData.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
Generate an Openterface macro draft.

Target OS: \(request.targetSystem.displayName)
User goal: \(request.goal)
Current label: \(currentLabel.isEmpty ? "(empty)" : currentLabel)
Current description: \(currentDescription.isEmpty ? "(empty)" : currentDescription)
Current sequence: \(currentData.isEmpty ? "(empty)" : currentData)

Produce a draft that is ready to save in the Openterface macro editor.
If the macro types text and then continues, add a short delay token such as <DELAY05s> after the typing step so the UI can finish visual effects before the next action.
If timing matters for any other reason, add an explicit delay token and explain why in the description.
"""
    }

    private func macroGenerationTargetGuidance(for targetSystem: MacroTargetSystem) -> String {
        switch targetSystem {
        case .macOS:
            return "On macOS, treat <CMD> as the Command key. Prefer Command-based shortcuts such as <CMD>c</CMD>, <CMD>v</CMD>, and <CMD><SPACE></CMD> when they match the goal."
        case .windows:
            return "On Windows, treat <CMD> as the Windows key. Prefer Ctrl, Alt, and Windows-key shortcuts such as <CTRL>c</CTRL>, <CMD>r</CMD>, and <ALT><TAB></ALT>."
        case .linux:
            return "On Linux, treat <CMD> as the Super key. Prefer common desktop shortcuts such as <CTRL><ALT>t</ALT></CTRL>, <ALT><TAB></ALT>, and <CMD>l</CMD> when relevant."
        case .iPhone, .iPad:
            return "On iPhone and iPad with a hardware keyboard, treat <CMD> as the Command key. Prefer iPadOS-style shortcuts such as <CMD><SPACE></CMD>, <CMD><TAB></CMD>, and <CMD>h</CMD>."
        case .android:
            return "On Android, treat <CMD> as the Meta key. Prefer combinations that work with external keyboards, such as <ALT><TAB></ALT>, <CTRL>a</CTRL>, and <CTRL>c</CTRL> when relevant."
        }
    }

    private func normalizedMacroDraft(from payload: MacroAIDraftPayload) throws -> MacroAIDraft {
        let label = payload.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = payload.data.trimmingCharacters(in: .whitespacesAndNewlines)
        let intervalMs = min(max(payload.intervalMs ?? 80, 10), 500)

        guard !label.isEmpty else {
            throw NSError(domain: "ChatManager", code: 44, userInfo: [NSLocalizedDescriptionKey: "AI returned an empty macro name."])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "ChatManager", code: 45, userInfo: [NSLocalizedDescriptionKey: "AI returned an empty macro sequence."])
        }

        try validateGeneratedMacroSequence(data)
        return MacroAIDraft(label: label, description: description, data: data, intervalMs: intervalMs)
    }

    private func validateGeneratedMacroSequence(_ sequence: String) throws {
        let tokens = MacroManager.shared.tokenize(sequence)
        var balances: [String: Int] = ["CTRL": 0, "SHIFT": 0, "ALT": 0, "CMD": 0]

        for token in tokens where token.hasPrefix("<") && token.hasSuffix(">") {
            if token.hasPrefix("<MACRO:") {
                throw NSError(domain: "ChatManager", code: 46, userInfo: [NSLocalizedDescriptionKey: "AI returned a macro reference token, which is not allowed in Magic generation."])
            }
            guard macroGeneratorSupportedTokens.contains(token) else {
                throw NSError(domain: "ChatManager", code: 47, userInfo: [NSLocalizedDescriptionKey: "AI returned an unsupported macro token: \(token)"])
            }

            switch token {
            case "<CTRL>": balances["CTRL", default: 0] += 1
            case "</CTRL>":
                guard balances["CTRL", default: 0] > 0 else {
                    throw NSError(domain: "ChatManager", code: 48, userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </CTRL> tag."])
                }
                balances["CTRL", default: 0] -= 1
            case "<SHIFT>": balances["SHIFT", default: 0] += 1
            case "</SHIFT>":
                guard balances["SHIFT", default: 0] > 0 else {
                    throw NSError(domain: "ChatManager", code: 49, userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </SHIFT> tag."])
                }
                balances["SHIFT", default: 0] -= 1
            case "<ALT>": balances["ALT", default: 0] += 1
            case "</ALT>":
                guard balances["ALT", default: 0] > 0 else {
                    throw NSError(domain: "ChatManager", code: 50, userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </ALT> tag."])
                }
                balances["ALT", default: 0] -= 1
            case "<CMD>": balances["CMD", default: 0] += 1
            case "</CMD>":
                guard balances["CMD", default: 0] > 0 else {
                    throw NSError(domain: "ChatManager", code: 51, userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </CMD> tag."])
                }
                balances["CMD", default: 0] -= 1
            default:
                break
            }
        }

        let unclosedModifier = balances.first { $0.value != 0 }?.key
        if let unclosedModifier {
            throw NSError(domain: "ChatManager", code: 52, userInfo: [NSLocalizedDescriptionKey: "AI returned an unclosed <\(unclosedModifier)> modifier tag."])
        }
    }

    func sendMessage(_ text: String, attachmentFileURL: URL? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachmentFileURL != nil else { return }
        guard !isSending else { return }

        lastError = nil
        let storedContent = trimmed.isEmpty ? "Attached screenshot" : trimmed
        messages.append(ChatMessage(role: .user, content: storedContent, attachmentFilePath: attachmentFileURL?.path))
        persistHistory()
        isSending = true

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performSend()
        }
    }

    func cancelSending() {
        currentTask?.cancel()
        currentTask = nil
        isSending = false
    }

    /// Execute a skill from the Skills panel.
    func runSkill(_ skill: ChatSkill) {
        guard !isSending else { return }
        if skill.captureScreen {
            guard CameraManager.shared.canTakePicture else {
                presentAIErrorToUser("No video source. Connect the device and ensure the video feed is active.")
                return
            }
        }

        lastError = nil
        isSending = true

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            var screenshotURL: URL?
            if skill.captureScreen {
                screenshotURL = await self.captureScreenForAgent()
                if screenshotURL == nil {
                    self.presentAIErrorToUser("Could not capture screenshot from the target device.")
                    self.isSending = false
                    self.currentTask = nil
                    return
                }
            }

            self.messages.append(ChatMessage(
                role: .user,
                content: skill.prompt,
                attachmentFilePath: screenshotURL?.path
            ))
            self.persistHistory()

            await self.performSend()
        }
    }

    func clearHistory() {
        cancelSending()
        messages.removeAll()
        currentPlan = nil
        plannerTraceEntries.removeAll()
        taskStepTraces.removeAll()
        guideCapturePathsByMessageID.removeAll()
        guideAutoNextStatuses.removeAll()
        pendingGuideAutoNextStarts.removeAll()
        clearGuideOverlay()
        persistHistory()
    }

    func approveCurrentPlan() {
        guard var plan = currentPlan, plan.status == .awaitingApproval else { return }
        plan.status = .approved
        plan.tasks = plan.tasks.map { task in
            var updatedTask = task
            updatedTask.status = .approved
            return updatedTask
        }
        currentPlan = plan
        lastError = nil
        isSending = true
        persistHistory()

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.executeApprovedPlan()
        }
    }

    func clearCurrentPlan() {
        currentTask?.cancel()
        currentTask = nil
        if let currentPlan {
            for task in currentPlan.tasks {
                taskStepTraces.removeValue(forKey: task.id)
            }
        }
        currentPlan = nil
        plannerTraceEntries.removeAll()
        isSending = false
        persistHistory()
    }

    func guideAutoNextStatus(for messageID: UUID) -> GuideAutoNextStatus? {
        guideAutoNextStatuses[messageID]
    }

    func respondToOSConfirmation(confirmed: Bool, suggestedSystem: ChatTargetSystem?) {
        guard !isSending else { return }

        let fallbackSystem = UserSettings.shared.chatTargetSystem
        let resolvedSystem = suggestedSystem ?? fallbackSystem

        if confirmed {
            if UserSettings.shared.chatTargetSystem != resolvedSystem {
                UserSettings.shared.chatTargetSystem = resolvedSystem
            }

            sendMessage("Confirmed. Proceed with \(resolvedSystem.displayName)-specific guidance and continue the current task.")
            return
        }

        sendMessage("No, the target OS is not \(resolvedSystem.displayName). Please re-identify the OS from the current screen and ask me to confirm the correct target system before continuing.")
    }

    func taskStepTraceEntries(for taskID: UUID) -> [ChatTaskTraceEntry] {
        taskStepTraces[taskID] ?? []
    }

    func guideTraceEntries(messageID: UUID) -> [ChatTaskTraceEntry]? {
        guard let message = messages.first(where: { $0.id == messageID }) else { return nil }
        let isGuideMessage = (message.guideActionRect != nil || message.guideShortcut != nil)
        guard isGuideMessage else { return nil }

        let guideMessages = messages.filter {
            $0.role == .assistant && ($0.guideActionRect != nil || $0.guideShortcut != nil)
        }

        guard let traceIndex = guideMessages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        let tracedMessages = Array(guideMessages.prefix(through: traceIndex))
        return tracedMessages.enumerated().map { index, msg in
            var bodyLines: [String] = []
            bodyLines.append("Time: \(guideTimestampText(msg.createdAt))")
            bodyLines.append("Action: \(guideActionDescription(for: msg))")
            if let shortcut = guideShortcutText(for: msg) {
                bodyLines.append("Shortcut: \(shortcut)")
            }
            if let targetBox = guideTargetBoxText(for: msg) {
                bodyLines.append("Target: \(targetBox)")
            }
            bodyLines.append("Instruction: \(msg.content)")

            return ChatTaskTraceEntry(
                title: "Step \(index + 1)",
                body: bodyLines.joined(separator: "\n"),
                imageFilePath: guideCapturePathsByMessageID[msg.id]
            )
        }
    }

    func rerunLastPrompt(clearSequenceHistory: Bool = true) {
        guard !isSending else { return }

        let lastPromptMessage = messages.last(where: { message in
            message.role == .user && !message.content.hasPrefix("TOOL_RESULT:")
        })

        let fallbackGoal = currentPlan?.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptContent = lastPromptMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let replayText: String = {
            if let promptContent, !promptContent.isEmpty, promptContent != "Attached screenshot" {
                return promptContent
            }
            if let fallbackGoal, !fallbackGoal.isEmpty {
                return fallbackGoal
            }
            return ""
        }()

        let replayAttachmentURL: URL? = {
            guard let path = lastPromptMessage?.attachmentFilePath else { return nil }
            return URL(fileURLWithPath: path)
        }()

        guard !replayText.isEmpty || replayAttachmentURL != nil else { return }

        if clearSequenceHistory {
            messages.removeAll()
            currentPlan = nil
            lastError = nil
            plannerTraceEntries.removeAll()
            taskStepTraces.removeAll()
            guideCapturePathsByMessageID.removeAll()
            guideAutoNextStatuses.removeAll()
            pendingGuideAutoNextStarts.removeAll()
            persistHistory()
        }

        sendMessage(replayText, attachmentFileURL: replayAttachmentURL)
    }

    func traceMessage(messageID: UUID) -> String? {
        guard let message = messages.first(where: { $0.id == messageID }) else {
            logger.log(content: "Message Trace skipped: message id=\(messageID) not found")
            return nil
        }

        let isGuideMessage = (message.guideActionRect != nil || message.guideShortcut != nil)
        
        if isGuideMessage {
            let guideMessages = messages.filter {
                $0.role == .assistant && ($0.guideActionRect != nil || $0.guideShortcut != nil)
            }

            if let traceIndex = guideMessages.firstIndex(where: { $0.id == messageID }) {
                let tracedMessages = Array(guideMessages.prefix(through: traceIndex))
                var lines: [String] = []
                lines.append("Guide Step Trace")
                lines.append("Tracing step \(traceIndex + 1) of \(guideMessages.count)")
                lines.append("")

                for (index, msg) in tracedMessages.enumerated() {
                    lines.append("Step \(index + 1)")
                    lines.append("Time: \(guideTimestampText(msg.createdAt))")
                    lines.append("Action: \(guideActionDescription(for: msg))")
                    if let shortcut = guideShortcutText(for: msg) {
                        lines.append("Shortcut: \(shortcut)")
                    }
                    if let targetBox = guideTargetBoxText(for: msg) {
                        lines.append("Target: \(targetBox)")
                    }
                    lines.append("Instruction: \(msg.content)")
                    lines.append("")
                }

                let traceContent = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                logger.log(content: "Guide Trace generated for step=\(traceIndex + 1), message id=\(messageID)")
                return traceContent
            }
        }

        // Trace for standard Chat/Agentic messages
        var lines: [String] = []
        lines.append("Message Summary")
        lines.append("============================")
        lines.append("Time: \(guideTimestampText(message.createdAt))")
        lines.append("Role: \(message.role.rawValue.capitalized)")
        lines.append("Content: \(message.content)")
        if let attachment = message.attachmentFilePath {
            lines.append("Attachment: \(attachment)")
        }
        
        lines.append("")
        lines.append("Recent AI Session Trace Logs")
        lines.append("============================")
        
        // Fetch the last ~15,000 bytes of the trace log to show the recent AI interactions
        if let logData = try? Data(contentsOf: self.aiTraceURL) {
            let maxBytes = 15000
            let start = max(0, logData.count - maxBytes)
            let tailData = logData.subdata(in: start..<logData.count)
            if let tailString = String(data: tailData, encoding: .utf8) {
                if start > 0 {
                    lines.append("... [Log truncated for display] ...\n")
                }
                lines.append(tailString)
            } else {
                lines.append("Unable to decode trace log.")
            }
        } else {
            lines.append("No trace log found at \(self.aiTraceURL.path).")
        }
        
        let traceContent = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log(content: "Message Trace generated for message id=\(messageID)")
        return traceContent
    }

    private func appendTaskStepTrace(taskID: UUID, title: String, body: String = "", imageFilePath: String? = nil) {
        taskStepTraces[taskID, default: []].append(
            ChatTaskTraceEntry(title: title, body: body, imageFilePath: imageFilePath)
        )
        persistHistory()
    }

    private func guideActionDescription(for message: ChatMessage) -> String {
        var details: [String] = []

        if let shortcut = guideShortcutText(for: message) {
            details.append("shortcut=\(shortcut)")
        }

        if let targetBox = guideTargetBoxText(for: message) {
            details.append("target_box=\(targetBox)")
        }

        if details.isEmpty {
            return "none"
        }

        return details.joined(separator: ", ")
    }

    private func guideShortcutText(for message: ChatMessage) -> String? {
        let shortcut = message.guideShortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return shortcut.isEmpty ? nil : shortcut
    }

    private func guideTargetBoxText(for message: ChatMessage) -> String? {
        guard let rect = message.guideActionRect else { return nil }

        let x = String(format: "%.3f", rect.origin.x)
        let y = String(format: "%.3f", rect.origin.y)
        let width = String(format: "%.3f", rect.size.width)
        let height = String(format: "%.3f", rect.size.height)
        return "(x=\(x), y=\(y), w=\(width), h=\(height))"
    }

    private func guideTimestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func isGuideCompletionText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("result:") {
            return true
        }
        let completionPhrases = [
            "goal achieved",
            "task complete",
            "task completed",
            "already open and loaded",
            "already completed",
            "is already open",
            "is already loaded"
        ]

        return completionPhrases.contains { normalized.contains($0) }
    }

    private func appendPlannerTrace(title: String, body: String = "", imageFilePath: String? = nil) {
        plannerTraceEntries.append(
            ChatTaskTraceEntry(title: title, body: body, imageFilePath: imageFilePath)
        )
        persistHistory()
    }

    private func presentAIErrorToUser(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastError = trimmed
        let displayText = "AI request error: \(trimmed)"
        if messages.last?.role == .assistant, messages.last?.content == displayText {
            return
        }

        messages.append(ChatMessage(role: .assistant, content: displayText))
        persistHistory()
    }

    private func userFacingErrorMessage(from error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "AI model request timed out. Please retry."
            case .notConnectedToInternet:
                return "No internet connection. Please check your network and retry."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach AI server host. Please check API base URL and network."
            default:
                return urlError.localizedDescription
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return "AI model request timed out. Please retry."
        }

        return error.localizedDescription
    }

    private func loadHistory() {
        do {
            let data = try Data(contentsOf: historyURL)
            if let persistedState = try? decoder.decode(PersistedChatState.self, from: data) {
                messages = persistedState.messages
                currentPlan = persistedState.currentPlan
                plannerTraceEntries = persistedState.plannerTraceEntries
                taskStepTraces = Dictionary(uniqueKeysWithValues: persistedState.taskTraces.map { ($0.taskID, $0.entries) })
            } else {
                messages = try decoder.decode([ChatMessage].self, from: data)
                currentPlan = nil
                plannerTraceEntries = []
                taskStepTraces = [:]
            }
        } catch {
            messages = []
            currentPlan = nil
            plannerTraceEntries = []
            taskStepTraces = [:]
        }
    }

    private func persistHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let persistedState = PersistedChatState(
                messages: messages,
                currentPlan: currentPlan,
                plannerTraceEntries: plannerTraceEntries,
                taskTraces: taskStepTraces.map { PersistedTaskTrace(taskID: $0.key, entries: $0.value) }
            )
            let data = try encoder.encode(persistedState)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            // Intentionally ignore persistence errors for now to avoid breaking chat UI flow.
        }
    }

    private func performSend() async {
        defer {
            isSending = false
            currentTask = nil
        }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let agenticEnabled = UserSettings.shared.isChatAgenticModeEnabled
        let guideModeEnabled = UserSettings.shared.isChatGuideModeEnabled

        if !guideModeEnabled {
            clearGuideOverlay()
        }

        guard !baseURLString.isEmpty, let baseURL = URL(string: baseURLString) else {
            presentAIErrorToUser("Invalid Chat API base URL")
            logger.log(content: "AI Chat request aborted: invalid base URL -> \(baseURLString)")
            return
        }

        guard !model.isEmpty else {
            presentAIErrorToUser("Chat model is empty")
            logger.log(content: "AI Chat request aborted: model is empty")
            return
        }

        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey
        guard !apiKey.isEmpty else {
            presentAIErrorToUser("Missing AI API key in Settings")
            logger.log(content: "AI Chat request aborted: missing API key")
            return
        }

        if guideModeEnabled {
            await performGuideSend(baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt)
            return
        }

        if UserSettings.shared.isChatPlannerModeEnabled {
            await performMultiAgentSend(baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt)
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var workingMessages = messages

        do {
            let maxAgentIterations = UserSettings.shared.chatAgentMaxIterations
            for iteration in 1...maxAgentIterations {
                let conversation = buildConversation(
                    systemPrompt: systemPrompt,
                    sourceMessages: workingMessages,
                    includeAgentTools: agenticEnabled
                )
                let payload = ChatCompletionsRequest(model: model, messages: conversation)

                request.httpBody = try JSONEncoder().encode(payload)
                let attachmentCount = workingMessages.filter { $0.attachmentFilePath != nil }.count
                let requestURL = request.url?.absoluteString ?? "(nil)"
                logger.log(content: "AI Chat request -> POST \(requestURL), model=\(model), conversationMessages=\(conversation.count), attachments=\(attachmentCount), iteration=\(iteration), bodyBytes=\(request.httpBody?.count ?? 0)")
                appendAITrace(
                    title: "REQUEST iteration=\(iteration)",
                    body: [
                        "url: \(requestURL)",
                        "model: \(model)",
                        "conversationMessages: \(conversation.count)",
                        "attachments: \(attachmentCount)",
                        "bodyBytes: \(request.httpBody?.count ?? 0)",
                        "readableParts:",
                        readableTraceParts(from: conversation),
                        "body:",
                        traceBodyForLogging(data: request.httpBody ?? Data(), contentType: request.value(forHTTPHeaderField: "Content-Type"))
                    ].joined(separator: "\n")
                )

                let (data, response) = try await URLSession.shared.data(for: request)

                if Task.isCancelled { return }

                guard let http = response as? HTTPURLResponse else {
                    presentAIErrorToUser("Invalid server response")
                    logger.log(content: "AI Chat response error: non-HTTP response")
                    return
                }

                logger.log(content: "AI Chat response <- status=\(http.statusCode), bytes=\(data.count), iteration=\(iteration)")
                appendAITrace(
                    title: "RESPONSE iteration=\(iteration)",
                    body: [
                        "status: \(http.statusCode)",
                        "contentType: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")",
                        "bytes: \(data.count)",
                        "body:",
                        traceBodyForLogging(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
                    ].joined(separator: "\n")
                )

                guard (200...299).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let snippet = String(body.prefix(500))
                    logger.log(content: "AI Chat response error body: \(snippet)")
                    let detail = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = detail.isEmpty
                        ? "Chat API error \(http.statusCode)."
                        : "Chat API error \(http.statusCode): \(detail)"
                    presentAIErrorToUser(errorText)
                    return
                }

                let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
                guard let assistantText = decoded.choices.first?.message.content, !assistantText.isEmpty else {
                    presentAIErrorToUser("Empty assistant response")
                    logger.log(content: "AI Chat response decode succeeded but assistant content is empty")
                    return
                }

                logger.log(content: "AI Chat assistant response received: chars=\(assistantText.count), iteration=\(iteration)")

                if agenticEnabled, let toolCalls = parseToolCalls(from: assistantText), !toolCalls.isEmpty {
                    logger.log(content: "AI Chat agentic tool call count=\(toolCalls.count), iteration=\(iteration)")
                    let toolResult = await executeToolCalls(toolCalls)
                    appendAITrace(
                        title: "TOOL_RESULT iteration=\(iteration)",
                        body: toolResult.summary
                    )
                    workingMessages.append(ChatMessage(role: .assistant, content: assistantText))
                    let toolResultMessage = ChatMessage(role: .user, content: "TOOL_RESULT:\n\(toolResult.summary)", attachmentFilePath: toolResult.attachmentFilePath)
                    workingMessages.append(toolResultMessage)
                    messages.append(ChatMessage(role: .assistant, content: "Tool result:\n\(toolResult.summary)"))
                    persistHistory()
                    continue
                }

                messages.append(ChatMessage(role: .assistant, content: assistantText))
                persistHistory()
                return
            }

            let timeoutMessage = "I reached the configured Agent Mode iteration limit (\(UserSettings.shared.chatAgentMaxIterations)) and still need guidance to continue. Please provide a fresh screenshot, raise the iteration limit, or use a verified macro if one matches the task."
            messages.append(ChatMessage(role: .assistant, content: timeoutMessage))
            persistHistory()
        } catch {
            if Task.isCancelled { return }
            logger.log(content: "AI Chat request failed with error: \(error.localizedDescription)")
            appendAITrace(title: "ERROR", body: error.localizedDescription)
            presentAIErrorToUser(userFacingErrorMessage(from: error))
        }
    }

    private func performMultiAgentSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async {
        guard let latestUserMessage = messages.last(where: { $0.role == .user }) else {
            lastError = "Missing user request"
            return
        }

        do {
            plannerTraceEntries.removeAll()
            let planningAttachment = await latestPlanningAttachmentURL(fallbackAttachmentPath: latestUserMessage.attachmentFilePath)
            if let planningAttachment {
                appendPlannerTrace(
                    title: "Planning screen",
                    body: planningAttachment.lastPathComponent,
                    imageFilePath: planningAttachment.path
                )
            }
            let plannerUserRequest = shouldInjectOSConfirmationPrompt(in: messages)
                ? firstTurnOSConfirmationInstruction() + "\n\n" + latestUserMessage.content
                : latestUserMessage.content

            let plannerMessages = plannerAgent.buildPlanningConversation(
                systemPrompt: systemPrompt,
                plannerPrompt: UserSettings.shared.resolvedPlannerPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                macroInventoryPrompt: macroInventoryPrompt(),
                userRequest: plannerUserRequest,
                imageDataURL: planningAttachment.flatMap { dataURLForImage(atPath: $0.path) }
            )
            appendPlannerTrace(title: "Planner request", body: readableTraceParts(from: plannerMessages))
            let plannerResponse = try await sendChatCompletion(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                conversation: plannerMessages,
                traceLabel: "PLANNER"
            )
            appendPlannerTrace(title: "Planner response", body: plannerResponse.content)
            if let inputTokenCount = plannerResponse.inputTokenCount, let outputTokenCount = plannerResponse.outputTokenCount {
                appendPlannerTrace(title: "Planner tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
            }

            let plan = try plannerAgent.parsePlan(from: plannerResponse.content, goal: latestUserMessage.content)
            currentPlan = plan
            messages.append(ChatMessage(role: .assistant, content: "Plan ready: \(plan.summary)\nApprove the plan to run \(plan.tasks.count) screen task\(plan.tasks.count == 1 ? "" : "s")."))
            persistHistory()
        } catch {
            if Task.isCancelled { return }
            logger.log(content: "AI multi-agent planning failed: \(error.localizedDescription)")
            appendAITrace(title: "PLANNER_ERROR", body: error.localizedDescription)
            appendPlannerTrace(title: "Planner error", body: error.localizedDescription)
            presentAIErrorToUser(userFacingErrorMessage(from: error))
        }
    }

    private func performGuideSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async {
        guard let latestUserMessage = messages.last(where: { $0.role == .user }) else {
            lastError = "Missing user request"
            return
        }

        let pendingGuideStatusMessageID = pendingGuideAutoNextStarts.keys.max { lhs, rhs in
            (pendingGuideAutoNextStarts[lhs] ?? .distantPast) < (pendingGuideAutoNextStarts[rhs] ?? .distantPast)
        }

        do {
            currentPlan = nil
            let guideAttachment = await latestPlanningAttachmentURL(fallbackAttachmentPath: latestUserMessage.attachmentFilePath)
            var conversation: [ChatCompletionsRequest.Message] = []
            let compactGuideSystemPrompt = UserSettings.shared
                .promptProfile(for: UserSettings.shared.chatTargetSystem)
                .systemPrompt
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !compactGuideSystemPrompt.isEmpty {
                conversation.append(.text(role: .system, text: compactGuideSystemPrompt))
            }

            let guidePrompt = UserSettings.shared.resolvedGuidePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !guidePrompt.isEmpty {
                conversation.append(.text(role: .system, text: guidePrompt))
            }
            conversation.append(.text(role: .system, text: macroInventoryPrompt()))

            // Start a fresh mission context after the most recent completion marker.
            // This prevents old completed goals (for example, "open GitHub") from
            // leaking into a new user target in the same chat history.
            let latestUserIndex = messages.lastIndex(where: { $0.id == latestUserMessage.id })
            let contextMessages: [ChatMessage] = {
                guard let latestUserIndex else { return messages }
                let prefixToLatest = Array(messages[...latestUserIndex])
                if let lastCompletionIndex = prefixToLatest.lastIndex(where: { message in
                    message.role == .assistant && (message.content.hasPrefix("Task Complete") || isGuideCompletionText(message.content))
                }) {
                    let start = lastCompletionIndex + 1
                    if start <= latestUserIndex {
                        return Array(messages[start...latestUserIndex])
                    }
                }
                return prefixToLatest
            }()

            let initialGoalText = contextMessages.first(where: {
                $0.role == .user && 
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 
                $0.content != "Attached screenshot" && 
                $0.content != "Guide me to the next action on the current screen." 
            })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let pastAssistantSteps = contextMessages
                .filter {
                    $0.role == .assistant &&
                    (($0.guideActionRect != nil || $0.guideShortcut != nil) || isGuideCompletionText($0.content))
                }
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var userText = latestUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Guide me to the next action on the current screen."
                : latestUserMessage.content

            if shouldInjectOSConfirmationPrompt(in: messages) {
                userText = firstTurnOSConfirmationInstruction() + "\n\n" + userText
            }

            if !pastAssistantSteps.isEmpty {
                let stepsList = pastAssistantSteps.enumerated()
                    .map { "- Step \($0.offset + 1): \($0.element.prefix(250))" }
                    .joined(separator: "\n")
                let antiRepeatInstruction = "Past actions listed below were already executed. Do not repeat the same action unless the current screenshot clearly shows it is still pending. If the goal already appears complete, respond with Result:. If you cannot verify completion from this screenshot, ask for clarification instead of repeating the same step."
                if !initialGoalText.isEmpty && initialGoalText != userText {
                    userText = "Original Goal: \(initialGoalText)\n\n\(antiRepeatInstruction)\n\nPast Actions Taken:\n\(stepsList)\n\nCurrent Request: \(userText)"
                } else {
                    userText = "\(antiRepeatInstruction)\n\nPast Actions Taken:\n\(stepsList)\n\nCurrent Request: \(userText)"
                }
            } else {
                if !initialGoalText.isEmpty && initialGoalText != userText {
                    userText = "Original Goal: \(initialGoalText)\nCurrent Request: \(userText)"
                }
            }
            
            if let guideAttachment,
               let imageDataURL = dataURLForImage(atPath: guideAttachment.path) {
                conversation.append(.multimodal(role: .user, text: userText, imageDataURL: imageDataURL))
            } else {
                conversation.append(.text(role: .user, text: userText))
            }

            let guideResponse = try await sendChatCompletion(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                conversation: conversation,
                traceLabel: "GUIDE"
            )

            let payload = try decodeJSONPayload(GuideResponsePayload.self, from: guideResponse.content)
            applyGuideOverlay(from: payload.target_box)

            var responseLines: [String] = []
            responseLines.append(payload.next_step.trimmingCharacters(in: .whitespacesAndNewlines))
            if payload.needs_clarification == true {
                let clarification = payload.clarification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Please provide a clearer screenshot of the target area."
                if !clarification.isEmpty {
                    responseLines.append(clarification)
                }
            }

            let responseText = responseLines.filter { !$0.isEmpty }.joined(separator: "\n\n")
            
            var guideActionRect: CGRect?
            if let box = payload.target_box {
                let normalizedRect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
                if normalizedRect.width > 0.001, normalizedRect.height > 0.001 {
                    guideActionRect = normalizedRect
                }
            }

            let guideTool = payload.tool?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let guideShortcut = payload.tool_input?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedShortcut = (guideShortcut?.isEmpty == false) ? guideShortcut : nil
            let hasActionableGuidePayload = guideActionRect != nil || sanitizedShortcut != nil
            let baseGuideMessage = responseText.isEmpty ? payload.next_step : responseText
            let finalGuideMessage = isGuideCompletionText(baseGuideMessage) && !hasActionableGuidePayload
                ? "Task Complete\n\n\(baseGuideMessage)"
                : baseGuideMessage
            
            let guideMessageID = UUID()
            messages.append(ChatMessage(
                id: guideMessageID,
                role: .assistant,
                content: finalGuideMessage,
                guideActionRect: guideActionRect,
                guideShortcut: sanitizedShortcut,
                guideTool: guideTool
            ))
            if let capturePath = guideAttachment?.path {
                guideCapturePathsByMessageID[guideMessageID] = capturePath
            }
            if let pendingGuideStatusMessageID {
                completeGuideAutoNextStatus(for: pendingGuideStatusMessageID)
            }
            persistHistory()
        } catch {
            if Task.isCancelled { return }
            logger.log(content: "AI guide-mode request failed: \(error.localizedDescription)")
            appendAITrace(title: "GUIDE_ERROR", body: error.localizedDescription)
            clearGuideOverlay()
            if let pendingGuideStatusMessageID {
                failGuideAutoNextStatus(for: pendingGuideStatusMessageID, errorDescription: error.localizedDescription)
            }
            presentAIErrorToUser(userFacingErrorMessage(from: error))
        }
    }

    private func applyGuideOverlay(from targetBox: GuideResponsePayload.TargetBox?) {
        guard let targetBox else {
            clearGuideOverlay()
            return
        }

        let x = min(max(targetBox.x, 0.0), 1.0)
        let y = min(max(targetBox.y, 0.0), 1.0)
        let width = min(max(targetBox.width, 0.0), 1.0)
        let height = min(max(targetBox.height, 0.0), 1.0)

        guard width > 0.001, height > 0.001 else {
            clearGuideOverlay()
            return
        }

        AppStatus.guideHighlightRectNormalized = CGRect(x: x, y: y, width: width, height: height)
        AppStatus.showGuideOverlay = true
    }

    private func clearGuideOverlay() {
        AppStatus.showGuideOverlay = false
        AppStatus.guideHighlightRectNormalized = .zero
    }

    func executeGuideAction(messageID: UUID, targetBox: CGRect?, shortcut: String?, tool: String?, messageContent: String, autoNext: Bool) {
        let anchorUserMessageID = messages.last(where: { $0.role == .user })?.id
        Task {
            var actionDescription = "unknown"
            
            if let shortcut = shortcut, !shortcut.isEmpty {
                logger.log(content: "Guide Action Preparing: executing input sequence '\(shortcut)'")
                let success = executeGuideInputSequence(shortcut)
                actionDescription = "input sequence \(shortcut) (Success: \(success))"
                logger.log(content: "Guide Action Executed: \(actionDescription)")
            } else if let targetBox = targetBox {
                let cx = targetBox.midX
                let cy = targetBox.midY
                
                // Use the explicit tool first, then fall back to content heuristics.
                let normalizedTool = tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let contentLower = messageContent.lowercased()
                let isRightClick = normalizedTool == "right_click" || normalizedTool == "right-click" || contentLower.contains("right click") || contentLower.contains("right-click")
                let isDoubleClick = (!isRightClick && (normalizedTool == "double_click" || normalizedTool == "double-click" || contentLower.contains("double click") || contentLower.contains("double-click")))
                
                let buttonEvent: UInt8 = isRightClick ? 0x02 : 0x01
                let actionName = isRightClick ? "right_click" : (isDoubleClick ? "double_click" : "left_click")
                
                let absX = Int(cx * 4096.0)
                let absY = Int(cy * 4096.0)
                var clampedX = clampAbsoluteCoordinate(absX)
                var clampedY = clampAbsoluteCoordinate(absY)

                if let refinedPoint = await refineGuideClickTarget(absX: clampedX, absY: clampedY, instruction: messageContent) {
                    clampedX = refinedPoint.x
                    clampedY = refinedPoint.y
                    if let matchedElement = refinedPoint.matchedElement, !matchedElement.isEmpty {
                        logger.log(content: "Guide click refinement matched element: \(matchedElement)")
                    }
                }
                agentMouseX = clampedX
                agentMouseY = clampedY
                
                logger.log(content: "Guide Action Preparing: \(actionName) at normalized(\(String(format: "%.3f", cx)), \(String(format: "%.3f", cy))) -> clamped(\(clampedX), \(clampedY))")
                AIInputRouter.animatedClick(button: buttonEvent, absX: clampedX, absY: clampedY, isDoubleClick: isDoubleClick)
                
                actionDescription = "\(actionName) at x=\(clampedX), y=\(clampedY)"
                logger.log(content: "Guide Action Executed: \(actionDescription)")
            }
            
            let messageText = autoNext
                ? "Action executed: \(actionDescription). Auto-guiding the next step..."
                : "Action executed: \(actionDescription)."
            
            DispatchQueue.main.async {
                self.clearGuideOverlay()
                if autoNext {
                    self.startGuideAutoNextStatus(for: messageID)
                } else {
                    self.messages.append(ChatMessage(role: .assistant, content: messageText))
                }
                self.persistHistory()
            }
            
            if autoNext {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                DispatchQueue.main.async {
                    // If a newer user prompt was sent, do not continue the old mission.
                    let latestUserMessageID = self.messages.last(where: { $0.role == .user })?.id
                    guard latestUserMessageID == anchorUserMessageID else {
                        self.logger.log(content: "Guide auto-next canceled: detected newer user request (starting new mission context)")
                        self.cancelGuideAutoNextStatus(for: messageID)
                        return
                    }

                    if UserSettings.shared.isChatGuideModeEnabled {
                        self.sendMessage("Guide me to the next action on the current screen.")
                    }
                }
            }
        }
    }

    func completeGuideStepAndNext(stepDescription: String) {
        let firstLine = stepDescription
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let resultLine = firstLine.isEmpty
            ? "Result: I completed this guide step."
            : "Result: I completed this step: \(firstLine)"

        logger.log(content: "Guide Action User-Completed: \(resultLine)")
        clearGuideOverlay()
        sendMessage("\(resultLine)\nGuide me to the next action on the current screen.")
    }

    private func executeGuideInputSequence(_ inputSequence: String) -> Bool {
        let normalized = inputSequence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if normalized.contains("<") && normalized.contains(">") {
            return executeBracketedGuideInputSequence(normalized)
        }

        // Allow guide replies like "Cmd+L, baidu.com, Enter" to mix shortcuts and text input.
        let steps = normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let sequenceSteps = steps.isEmpty ? [normalized] : steps
        var executedAny = false

        for (index, step) in sequenceSteps.enumerated() {
            if executeShortcut(step) {
                executedAny = true
                let nextStep = index + 1 < sequenceSteps.count ? sequenceSteps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterPlainStep(step, nextStep: nextStep))
                continue
            }

            logger.log(content: "AI Executing Text Input: '\(step)'")
            AIInputRouter.sendText(step)
            executedAny = true
            let nextStep = index + 1 < sequenceSteps.count ? sequenceSteps[index + 1] : nil
            Thread.sleep(forTimeInterval: guideDelayAfterPlainTextStep(step, nextStep: nextStep))
        }

        return executedAny
    }

    private enum GuideInputStep {
        case shortcut(String)
        case text(String)
    }

    private func executeBracketedGuideInputSequence(_ input: String) -> Bool {
        let steps = parseBracketedGuideInputSteps(input)
        guard !steps.isEmpty else { return false }

        var executedAny = false

        for (index, step) in steps.enumerated() {
            switch step {
            case .shortcut(let shortcut):
                if executeShortcut(shortcut) {
                    executedAny = true
                }
                let nextStep = index + 1 < steps.count ? steps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterBracketedStep(step, nextStep: nextStep))
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                logger.log(content: "AI Executing Text Input: '\(trimmed)'")
                AIInputRouter.sendText(trimmed)
                executedAny = true
                let nextStep = index + 1 < steps.count ? steps[index + 1] : nil
                Thread.sleep(forTimeInterval: guideDelayAfterBracketedStep(step, nextStep: nextStep))
            }
        }

        return executedAny
    }

    private func guideDelayAfterPlainStep(_ step: String, nextStep: String?) -> TimeInterval {
        let normalized = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isGuideLauncherShortcut(normalized) {
            return 0.65
        }
        if isGuideNavigationShortcut(normalized) {
            return 0.22
        }
        if let nextStep,
           !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !looksLikeGuideShortcut(nextStep) {
            return 0.18
        }
        return 0.12
    }

    private func guideDelayAfterPlainTextStep(_ text: String, nextStep: String?) -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.12 }

        if let nextStep {
            let normalizedNextStep = nextStep.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedNextStep == "enter" || normalizedNextStep == "return" || normalizedNextStep == "tab" {
                return 0.3
            }
        }

        return 0.16
    }

    private func guideDelayAfterBracketedStep(_ step: GuideInputStep, nextStep: GuideInputStep?) -> TimeInterval {
        switch step {
        case .shortcut(let shortcut):
            if isGuideLauncherShortcut(shortcut) {
                return 0.65
            }
            if isGuideNavigationShortcut(shortcut) {
                return 0.22
            }
            return 0.12
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0.12 }

            if case .shortcut(let shortcut)? = nextStep {
                let normalized = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalized == "enter" || normalized == "return" || normalized == "tab" {
                    return 0.3
                }
            }

            return 0.16
        }
    }

    private func isGuideLauncherShortcut(_ shortcut: String) -> Bool {
        let normalized = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let launcherShortcuts: Set<String> = [
            "cmd+space",
            "cmd+h",
            "cmd+tab",
            "ctrl+alt+t",
            "win+r",
            "win+e"
        ]
        return launcherShortcuts.contains(normalized)
    }

    private func isGuideNavigationShortcut(_ shortcut: String) -> Bool {
        let normalized = shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let navigationShortcuts: Set<String> = [
            "enter",
            "return",
            "tab",
            "shift+tab",
            "up",
            "down",
            "left",
            "right",
            "esc",
            "escape"
        ]
        return navigationShortcuts.contains(normalized)
    }

    private func looksLikeGuideShortcut(_ step: String) -> Bool {
        let normalized = step.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized.contains("+") {
            return true
        }
        return isGuideNavigationShortcut(normalized) || isGuideLauncherShortcut(normalized)
    }

    private func parseBracketedGuideInputSteps(_ input: String) -> [GuideInputStep] {
        var steps: [GuideInputStep] = []
        var textBuffer = ""
        var pendingModifiers: [String] = []

        func flushTextBuffer() {
            if !textBuffer.isEmpty {
                steps.append(.text(textBuffer))
            }
            textBuffer = ""
        }

        func removePendingModifier(_ modifier: String) {
            if let index = pendingModifiers.lastIndex(of: modifier) {
                pendingModifiers.remove(at: index)
            }
        }

        func appendShortcut(using keyToken: String) {
            let key = keyToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            let comboTokens = pendingModifiers + [key]
            steps.append(.shortcut(comboTokens.joined(separator: "+")))
            pendingModifiers.removeAll()
        }

        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "<", let close = input[index...].firstIndex(of: ">") {
                let rawTag = String(input[input.index(after: index)..<close])
                let cleanedTag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)

                if cleanedTag.hasPrefix("/") {
                    let closingToken = normalizeBracketedKeyToken(String(cleanedTag.dropFirst()))
                    if isModifierToken(closingToken) {
                        removePendingModifier(closingToken)
                    }
                } else {
                    flushTextBuffer()
                    let normalizedTag = normalizeBracketedKeyToken(cleanedTag)
                    if !normalizedTag.isEmpty {
                        if isModifierToken(normalizedTag) {
                            pendingModifiers.append(normalizedTag)
                        } else {
                            appendShortcut(using: normalizedTag)
                        }
                    }
                }

                index = input.index(after: close)
            } else {
                let char = input[index]
                if !pendingModifiers.isEmpty,
                   !char.isWhitespace,
                   char.unicodeScalars.count == 1,
                   let scalar = char.unicodeScalars.first,
                   CharacterSet.alphanumerics.contains(scalar) {
                    appendShortcut(using: String(char))
                } else {
                    textBuffer.append(char)
                }
                index = input.index(after: index)
            }
        }

        flushTextBuffer()
        pendingModifiers.removeAll()
        return steps
    }

    private func isModifierToken(_ token: String) -> Bool {
        switch token {
        case "ctrl", "alt", "shift", "cmd":
            return true
        default:
            return false
        }
    }

    private func normalizeBracketedKeyToken(_ token: String) -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "del":
            return "delete"
        case "control":
            return "ctrl"
        case "command", "meta", "super", "windows", "win":
            return "cmd"
        case "option":
            return "alt"
        case "return":
            return "enter"
        default:
            return normalized
        }
    }

    private func executeShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let keyToken = parts.last else { return false }

        var modifiers: NSEvent.ModifierFlags = []
        for token in parts.dropLast() {
            switch token {
            case "win", "windows", "cmd", "command", "meta", "super":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                return false
            }
        }

        guard let keyCode = keyCode(for: keyToken) else { return false }

        DependencyContainer.shared.resolve(LoggerProtocol.self).log(content: "AI Executing Shortcut: '\(shortcut)' -> resolved mod: \(modifiers.rawValue), key: \(keyCode)")
        return AIInputRouter.sendShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCode(for token: String) -> UInt16? {
        let named: [String: UInt16] = [
            "esc": 53, "escape": 53,
            "enter": 36, "return": 36,
            "tab": 48,
            "space": 49,
            "backspace": 51, "delete": 51,
            "home": 115,
            "end": 119,
            "pageup": 116,
            "pagedown": 121,
            "up": 126,
            "down": 125,
            "left": 123,
            "right": 124,
            "f1": 122,
            "f2": 120,
            "f3": 99,
            "f4": 118,
            "f5": 96,
            "f6": 97,
            "f7": 98,
            "f8": 100,
            "f9": 101,
            "f10": 109,
            "f11": 103,
            "f12": 111
        ]
        if let mapped = named[token] {
            return mapped
        }

        let alphaNumeric: [String: UInt16] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return alphaNumeric[token]
    }

    private func buildConversation(
        systemPrompt: String,
        sourceMessages: [ChatMessage],
        includeAgentTools: Bool
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if includeAgentTools {
            conversation.append(.text(role: .system, text: agentToolInstruction + "\n\n" + macroInventoryPrompt()))
        }

        let recent = sourceMessages.suffix(30)
        let shouldInjectFirstTurnConfirmation = !includeAgentTools && shouldInjectOSConfirmationPrompt(in: sourceMessages)
        conversation.append(contentsOf: recent.map { message in
            let shouldPrefixUserMessage = shouldInjectFirstTurnConfirmation && message.role == .user
            if message.role == .user,
               let path = message.attachmentFilePath,
               let imageURL = dataURLForImage(atPath: path) {
                var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Please analyze this screenshot."
                    : message.content
                if shouldPrefixUserMessage {
                    text = firstTurnOSConfirmationInstruction() + "\n\n" + text
                }
                return .multimodal(role: message.role, text: text, imageDataURL: imageURL)
            }
            if shouldPrefixUserMessage {
                return .text(role: message.role, text: firstTurnOSConfirmationInstruction() + "\n\n" + message.content)
            }
            return .text(role: message.role, text: message.content)
        })
        return conversation
    }

    private func macroInventoryPrompt() -> String {
        let verifiedMacros = MacroManager.shared.macros.filter(\.isVerified)

        var sections: [String] = []

        if verifiedMacros.isEmpty {
            sections.append("Verified executable macros:\n- No verified macros are currently available.")
        } else {
            let verifiedLines = verifiedMacros.map { macro in
                let description = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = description.isEmpty ? macro.data : description
                return "- id=\(macro.id.uuidString), label=\(macro.label), target=\(macro.targetSystem.displayName), detail=\(detail)"
            }
            sections.append("Verified executable macros:\n" + verifiedLines.joined(separator: "\n"))
        }

        sections.append("Macro tool usage:\n- Use run_verified_macro only with a verified macro from the executable list above.\n- Prefer macro_id over macro_label when calling the tool.\n- IMPORTANT: After running a macro, always verify the result in a NEW tool_calls response. Never include capture_screen or any other tool in the same tool_calls array as run_verified_macro.\n- If the macro gets close but does not fully finish the job, continue with additional tool calls instead of assuming success.")

        return sections.joined(separator: "\n\n")
    }

    private func verifiedMacroMatch(from args: [String: Any]) -> VerifiedMacroMatch? {
        let verifiedMacros = MacroManager.shared.macros.filter(\.isVerified)
        guard !verifiedMacros.isEmpty else { return nil }

        let requestedID = ((args["macro_id"] as? String) ?? (args["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let macroID = UUID(uuidString: requestedID),
           let matched = verifiedMacros.first(where: { $0.id == macroID }) {
            return VerifiedMacroMatch(macro: matched, matchedBy: "id")
        }

        let requestedLabel = ((args["macro_label"] as? String) ?? (args["label"] as? String) ?? requestedID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedLabel.isEmpty else { return nil }

        let normalizedRequested = requestedLabel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = verifiedMacros.first(where: {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedRequested
        }) {
            return VerifiedMacroMatch(macro: exact, matchedBy: "label")
        }

        let partialMatches = verifiedMacros.filter {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(normalizedRequested)
        }
        if partialMatches.count == 1, let matched = partialMatches.first {
            return VerifiedMacroMatch(macro: matched, matchedBy: "partial-label")
        }

        return nil
    }

    private func shouldInjectOSConfirmationPrompt(in sourceMessages: [ChatMessage]) -> Bool {
        let userCount = sourceMessages.filter { $0.role == .user }.count
        let assistantCount = sourceMessages.filter { $0.role == .assistant }.count
        return userCount == 1 && assistantCount == 0
    }

    private func firstTurnOSConfirmationInstruction() -> String {
        let systemsList = ChatTargetSystem.allCases
            .map { "  - \($0.displayName): \($0.detail)" }
            .joined(separator: "\n")
        
        let selected = UserSettings.shared.chatTargetSystem
        return """
CRITICAL: Before proceeding with the user's request, examine the screenshot carefully to identify which operating system is running on the target device.

Available systems to identify:
\(systemsList)

After analyzing the screenshot, you MUST explicitly identify which system you detected by stating one of these exact phrases:
- "The target OS appears to be: macOS"
- "The target OS appears to be: Windows"
- "The target OS appears to be: Linux"
- "The target OS appears to be: iPhone"
- "The target OS appears to be: iPad"
- "The target OS appears to be: Android"

Immediately after that line, you MUST include a confirmation sentence in this exact format:
- "Please confirm whether the target system should be set to macOS."
- "Please confirm whether the target system should be set to Windows."
- "Please confirm whether the target system should be set to Linux."
- "Please confirm whether the target system should be set to iPhone."
- "Please confirm whether the target system should be set to iPad."
- "Please confirm whether the target system should be set to Android."

Do not replace that confirmation sentence with paraphrases such as "Shall I proceed" or "Does this match". The response must contain both the exact detection line and the exact confirmation sentence so the app can open the OS selection UI reliably.

Currently configured target system: \(selected.displayName)
"""
    }

    private func dataURLForImage(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let imagePayload = preparedImagePayload(for: url) else { return nil }

        return "data:\(imagePayload.mimeType);base64,\(imagePayload.data.base64EncodedString())"
    }

    private func hasTransparency(_ cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            break
        default:
            return false
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        var pixelData = [UInt8](repeating: 255, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for alphaIndex in stride(from: 3, to: pixelData.count, by: bytesPerPixel) {
            if pixelData[alphaIndex] < 255 {
                return true
            }
        }

        return false
    }

    private func preferredAIImageEncoding(for cgImage: CGImage, quality: Double = 0.92) -> (data: Data, mimeType: String)? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let hasAlpha = hasTransparency(cgImage)

        if !hasAlpha,
           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
            return (jpegData, "image/jpeg")
        }

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return (pngData, "image/png")
        }

        return nil
    }

    private func preparedImagePayload(for url: URL) -> (data: Data, mimeType: String)? {
        guard let originalData = try? Data(contentsOf: url) else { return nil }

        let ext = url.pathExtension.lowercased()
        let originalMimeType: String
        switch ext {
        case "jpg", "jpeg":
            originalMimeType = "image/jpeg"
        case "webp":
            originalMimeType = "image/webp"
        case "gif":
            originalMimeType = "image/gif"
        default:
            originalMimeType = "image/png"
        }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.log(content: "AI image scaling skipped: failed to load image at \(url.path)")
            return (originalData, originalMimeType)
        }

        guard let maxLongEdge = UserSettings.shared.chatImageUploadLimit.maxLongEdge else {
            if originalMimeType == "image/jpeg" {
                return (originalData, originalMimeType)
            }

            if let preferred = preferredAIImageEncoding(for: cgImage),
               preferred.mimeType == "image/jpeg" || preferred.data.count < originalData.count {
                logger.log(content: "AI image re-encoded for upload: \(url.lastPathComponent) -> \(preferred.mimeType) bytes=\(preferred.data.count) (from \(originalData.count))")
                return preferred
            }

            return (originalData, originalMimeType)
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longEdge = max(width, height)

        guard longEdge > maxLongEdge else {
            if originalMimeType == "image/jpeg" {
                return (originalData, originalMimeType)
            }

            if let preferred = preferredAIImageEncoding(for: cgImage),
               preferred.mimeType == "image/jpeg" || preferred.data.count < originalData.count {
                logger.log(content: "AI image re-encoded for upload without scaling: \(url.lastPathComponent) -> \(preferred.mimeType) bytes=\(preferred.data.count) (from \(originalData.count))")
                return preferred
            }

            return (originalData, originalMimeType)
        }

        let scale = maxLongEdge / longEdge
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.log(content: "AI image scaling skipped: failed to create drawing context for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let scaledCGImage = context.makeImage() else {
            logger.log(content: "AI image scaling skipped: failed to render scaled image for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        guard let scaledPayload = preferredAIImageEncoding(for: scaledCGImage) else {
            logger.log(content: "AI image scaling skipped: failed to encode scaled image for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        logger.log(content: "AI image scaled for upload: \(Int(width))x\(Int(height)) -> \(targetWidth)x\(targetHeight) [limit=\(UserSettings.shared.chatImageUploadLimit.rawValue), mime=\(scaledPayload.mimeType), bytes=\(scaledPayload.data.count)]")

        return scaledPayload
    }

    private func parseToolCalls(from text: String) -> [AgentToolCall]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("tool") else { return nil }

        let candidate: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            candidate = String(trimmed[start...end])
        } else {
            return nil
        }

        guard let data = candidate.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dict = json as? [String: Any],
           let calls = dict["tool_calls"] as? [[String: Any]] {
            return calls.compactMap { call in
                guard let tool = call["tool"] as? String else { return nil }
                var args = call
                args.removeValue(forKey: "tool")
                return AgentToolCall(tool: tool, args: args)
            }
        }

        if let dict = json as? [String: Any], let tool = dict["tool"] as? String {
            var args = dict
            args.removeValue(forKey: "tool")
            return [AgentToolCall(tool: tool, args: args)]
        }

        return nil
    }

    private func executeApprovedPlan() async {
        defer {
            isSending = false
            currentTask = nil
        }

        guard var plan = currentPlan else { return }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey

        guard !baseURLString.isEmpty, let baseURL = URL(string: baseURLString), !model.isEmpty, !apiKey.isEmpty else {
            lastError = "Chat settings are incomplete"
            return
        }

        plan.status = .running
        currentPlan = plan
        persistHistory()

        do {
            for index in plan.tasks.indices {
                if Task.isCancelled { return }

                plan = try await executeTask(at: index, in: plan, baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt)
                currentPlan = plan
                persistHistory()
            }

            plan.status = plan.tasks.contains(where: { $0.status == .failed }) ? .failed : .completed
            currentPlan = plan
            messages.append(ChatMessage(role: .assistant, content: finalPlanSummary(for: plan)))
            persistHistory()
        } catch {
            if Task.isCancelled { return }
            logger.log(content: "AI task-agent execution failed: \(error.localizedDescription)")
            appendAITrace(title: "TASK_AGENT_ERROR", body: error.localizedDescription)
            presentAIErrorToUser(userFacingErrorMessage(from: error))

            if var failedPlan = currentPlan {
                failedPlan.status = .failed
                currentPlan = failedPlan
                persistHistory()
            }
        }
    }

    private func executeTask(
        at index: Int,
        in plan: ChatExecutionPlan,
        baseURL: URL,
        model: String,
        apiKey: String,
        systemPrompt: String
    ) async throws -> ChatExecutionPlan {
        var updatedPlan = plan
        let taskID = updatedPlan.tasks[index].id
        appendTaskStepTrace(
            taskID: taskID,
            title: "Task started",
            body: "\(updatedPlan.tasks[index].title) [agent=\(updatedPlan.tasks[index].agentName), tool=\(updatedPlan.tasks[index].toolName)]"
        )

        guard let taskAgent = taskAgentRegistry.resolve(for: updatedPlan.tasks[index]) else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = "No task agent registered for agent=\(updatedPlan.tasks[index].agentName), tool=\(updatedPlan.tasks[index].toolName)."
            appendTaskStepTrace(taskID: taskID, title: "Failed", body: updatedPlan.tasks[index].resultSummary ?? "Unknown error")
            throw NSError(domain: "ChatManager", code: 6, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Unsupported task agent"])
        }

        guard let preCaptureURL = await captureScreenForAgent() else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = "Task aborted: unable to capture pre-task screen state."
            appendTaskStepTrace(taskID: taskID, title: "Failed", body: "Pre-task capture unavailable")
            currentPlan = updatedPlan
            persistHistory()
            throw NSError(domain: "ChatManager", code: 7, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Pre-task capture failed"])
        }
        appendTaskStepTrace(taskID: taskID, title: "Pre-task capture", body: preCaptureURL.lastPathComponent, imageFilePath: preCaptureURL.path)

        updatedPlan.tasks[index].status = .running
        currentPlan = updatedPlan
        persistHistory()

        let conversation = taskAgent.buildTaskConversation(
            systemPrompt: systemPrompt,
            taskPrompt: taskAgent.prompt(from: UserSettings.shared),
            plan: updatedPlan,
            task: updatedPlan.tasks[index],
            imageDataURL: dataURLForImage(atPath: preCaptureURL.path)
        )
        appendTaskStepTrace(taskID: taskID, title: "Task-agent request", body: readableTraceParts(from: conversation))
        let response = try await sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: "TASK_AGENT_\(index + 1)"
        )
        updatedPlan.tasks[index].inputTokenCount = response.inputTokenCount
        updatedPlan.tasks[index].outputTokenCount = response.outputTokenCount
        appendTaskStepTrace(taskID: taskID, title: "Task-agent response", body: response.content)
        if let inputTokenCount = response.inputTokenCount, let outputTokenCount = response.outputTokenCount {
            appendTaskStepTrace(taskID: taskID, title: "Task-agent tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
        }
        currentPlan = updatedPlan
        persistHistory()

        taskAgent.applyResponse(response.content, to: &updatedPlan.tasks[index])

        if updatedPlan.tasks[index].status == .failed {
            appendTaskStepTrace(taskID: taskID, title: "Failed", body: updatedPlan.tasks[index].resultSummary ?? "Task agent execution failed")
            currentPlan = updatedPlan
            persistHistory()
            throw NSError(domain: "ChatManager", code: 8, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Task agent execution failed"])
        }

        var confirmationErrors: [String] = []
        var isConfirmed = false
        for attempt in 1...taskConfirmationAttemptCount {
            if attempt > 1 {
                appendTaskStepTrace(taskID: taskID, title: "Confirmation retry", body: "Attempt \(attempt)/\(taskConfirmationAttemptCount): waiting for UI state to settle")
                try? await Task.sleep(nanoseconds: taskConfirmationRetryDelayNanoseconds)
            }

            guard let postCaptureURL = await captureScreenForAgent() else {
                let reason = "Attempt \(attempt): post-task capture unavailable"
                confirmationErrors.append(reason)
                appendTaskStepTrace(taskID: taskID, title: "Verification capture failed", body: reason)
                continue
            }
            appendTaskStepTrace(
                taskID: taskID,
                title: "Verification screen",
                body: "Attempt \(attempt): \(postCaptureURL.lastPathComponent)",
                imageFilePath: postCaptureURL.path
            )

            do {
                let confirmationSummary = try await confirmTaskState(
                    task: updatedPlan.tasks[index],
                    plan: updatedPlan,
                    postCaptureURL: postCaptureURL,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt,
                    traceLabel: "TASK_CONFIRM_\(index + 1)_TRY_\(attempt)"
                )
                updatedPlan.tasks[index].resultSummary = confirmationSummary
                appendTaskStepTrace(taskID: taskID, title: "Verification succeeded", body: "Attempt \(attempt): \(confirmationSummary)")
                isConfirmed = true
                break
            } catch {
                let reason = "Attempt \(attempt): confirmation failed: \(error.localizedDescription)"
                confirmationErrors.append(reason)
                appendTaskStepTrace(taskID: taskID, title: "Verification failed", body: reason)
            }
        }

        guard isConfirmed else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = confirmationErrors.isEmpty
                ? "Task state confirmation failed"
                : confirmationErrors.joined(separator: " | ")
            appendTaskStepTrace(taskID: taskID, title: "Failed", body: "Failed after \(taskConfirmationAttemptCount) confirmation attempt(s)")
            currentPlan = updatedPlan
            persistHistory()
            throw NSError(domain: "ChatManager", code: 9, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Post-task confirmation failed"])
        }

        appendTaskStepTrace(taskID: taskID, title: "Task completed", body: updatedPlan.tasks[index].resultSummary ?? "")

        return updatedPlan
    }

    private func confirmTaskState(
        task: ChatTask,
        plan: ChatExecutionPlan,
        postCaptureURL: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        systemPrompt: String,
        traceLabel: String
    ) async throws -> String {
        guard let imageDataURL = dataURLForImage(atPath: postCaptureURL.path) else {
            throw NSError(domain: "ChatManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unable to encode post-task screenshot for state confirmation"])
        }

        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: taskStateConfirmationInstruction))

        let verifyInstruction = "Plan summary: \(plan.summary)\nTask title: \(task.title)\nTask detail: \(task.detail)\nAgent: \(task.agentName)\nTool: \(task.toolName)\n\nVerify whether the current state confirms the task outcome. Return confirmed=false if uncertain."
        conversation.append(.multimodal(role: .user, text: verifyInstruction, imageDataURL: imageDataURL))
        appendTaskStepTrace(taskID: task.id, title: "Verification request", body: readableTraceParts(from: conversation), imageFilePath: postCaptureURL.path)

        let response = try await sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: traceLabel
        )
        appendTaskStepTrace(taskID: task.id, title: "Verification response", body: response.content)
        if let inputTokenCount = response.inputTokenCount, let outputTokenCount = response.outputTokenCount {
            appendTaskStepTrace(taskID: task.id, title: "Verification tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
        }

        let payload = try decodeJSONPayload(TaskStateConfirmationPayload.self, from: response.content)
        let summary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.confirmed else {
            throw NSError(
                domain: "ChatManager",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: summary.isEmpty ? "Task state confirmation failed" : summary]
            )
        }

        return summary.isEmpty ? "Task confirmed by post-action screen verification." : summary
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "ChatManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "ChatManager", code: 13, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try decoder.decode(T.self, from: data)
    }

    private func finalPlanSummary(for plan: ChatExecutionPlan) -> String {
        let lines = plan.tasks.enumerated().map { offset, task in
            let status = task.status.rawValue.replacingOccurrences(of: "_", with: " ")
            let result = task.resultSummary?.isEmpty == false ? task.resultSummary! : "No result recorded."
            return "\(offset + 1). [\(status)] \(task.title): \(result)"
        }

        return "Plan completed: \(plan.summary)\n\n" + lines.joined(separator: "\n")
    }

    private func latestPlanningAttachmentURL(fallbackAttachmentPath: String?) async -> URL? {
        if let liveCapture = await captureScreenForAgent() {
            return liveCapture
        }

        if let fallbackAttachmentPath {
            return URL(fileURLWithPath: fallbackAttachmentPath)
        }

        return nil
    }

    private func sendChatCompletion(
        baseURL: URL,
        model: String,
        apiKey: String,
        conversation: [ChatCompletionsRequest.Message],
        traceLabel: String,
        enableThinking: Bool? = nil
    ) async throws -> ChatCompletionResult {
        let requestStartedAt = Date()
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ChatCompletionsRequest(model: model, messages: conversation, enableThinking: enableThinking)
        request.httpBody = try JSONEncoder().encode(payload)

        let requestURL = request.url?.absoluteString ?? "(nil)"
        logger.log(content: "AI Chat request -> POST \(requestURL), model=\(model), conversationMessages=\(conversation.count), trace=\(traceLabel), bodyBytes=\(request.httpBody?.count ?? 0)")
        appendAITrace(
            title: "\(traceLabel)_REQUEST",
            body: [
                "url: \(requestURL)",
                "model: \(model)",
                "conversationMessages: \(conversation.count)",
                "timeoutSeconds: \(Int(request.timeoutInterval))",
                "bodyBytes: \(request.httpBody?.count ?? 0)",
                "readableParts:",
                readableTraceParts(from: conversation),
                "body:",
                traceBodyForLogging(data: request.httpBody ?? Data(), contentType: request.value(forHTTPHeaderField: "Content-Type"))
            ].joined(separator: "\n")
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        let responseDuration = Date().timeIntervalSince(requestStartedAt)

        logger.log(content: "AI Chat response <- status=\(http.statusCode), bytes=\(data.count), trace=\(traceLabel)")
        appendAITrace(
            title: "\(traceLabel)_RESPONSE",
            headerPrefix: Self.traceDurationHeader(from: responseDuration),
            body: [
                "status: \(http.statusCode)",
                "contentType: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")",
                "responseTimeSeconds: \(String(format: "%.3f", responseDuration))",
                "bytes: \(data.count)",
                "body:",
                traceBodyForLogging(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
            ].joined(separator: "\n")
        )

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ChatManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Chat API error \(http.statusCode): \(body)"])
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let assistantText = decoded.choices.first?.message.content, !assistantText.isEmpty else {
            throw NSError(domain: "ChatManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Empty assistant response"])
        }

        return ChatCompletionResult(
            content: assistantText,
            inputTokenCount: decoded.usage?.promptTokens,
            outputTokenCount: decoded.usage?.completionTokens
        )
    }

    private func executeToolCalls(_ calls: [AgentToolCall]) async -> AgentToolExecutionResult {
        var summaries: [String] = []
        var attachmentPath: String?

        for call in calls {
            let toolName = call.tool.lowercased()
            switch toolName {
            case "capture_screen", "take_screenshot", "screenshot":
                if let fileURL = await captureScreenForAgent() {
                    attachmentPath = fileURL.path
                    summaries.append("capture_screen: success")
                    logger.log(content: "AI Tool executed: capture_screen -> \(fileURL.path)")
                } else {
                    summaries.append("capture_screen: failed (no image captured)")
                    logger.log(content: "AI Tool failed: capture_screen")
                }

            case "move_mouse":
                if let nx = doubleArg(call.args["x"]), let ny = doubleArg(call.args["y"]) {
                    let absX = normalizedToAbsolute(nx)
                    let absY = normalizedToAbsolute(ny)
                    AIInputRouter.sendMouseMove(absX: absX, absY: absY)
                    agentMouseX = absX
                    agentMouseY = absY
                    summaries.append("move_mouse: ok (x=\(String(format: "%.3f", nx)), y=\(String(format: "%.3f", ny)))")
                    logger.log(content: "AI Tool executed: move_mouse normalized=(\(nx), \(ny)) abs=(\(absX), \(absY))")
                } else {
                    summaries.append("move_mouse: invalid args")
                    logger.log(content: "AI Tool failed: move_mouse invalid args")
                }

            case "left_click":
                let clickPoint = await click(button: 0x01, args: call.args)
                let lnx = absoluteToNormalized(clickPoint.x)
                let lny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "left_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("left_click: success (x=\(String(format: "%.3f", lnx)), y=\(String(format: "%.3f", lny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("left_click: success (x=\(String(format: "%.3f", lnx)), y=\(String(format: "%.3f", lny)), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: left_click normalized=(\(lnx), \(lny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "right_click":
                let clickPoint = await click(button: 0x02, args: call.args)
                let rnx = absoluteToNormalized(clickPoint.x)
                let rny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "right_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("right_click: success (x=\(String(format: "%.3f", rnx)), y=\(String(format: "%.3f", rny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("right_click: success (x=\(String(format: "%.3f", rnx)), y=\(String(format: "%.3f", rny)), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: right_click normalized=(\(rnx), \(rny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "double_click":
                let clickPoint = await click(button: 0x01, args: call.args, isDoubleClick: true)
                let dnx = absoluteToNormalized(clickPoint.x)
                let dny = absoluteToNormalized(clickPoint.y)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "double_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("double_click: success (x=\(String(format: "%.3f", dnx)), y=\(String(format: "%.3f", dny)), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("double_click: success (x=\(String(format: "%.3f", dnx)), y=\(String(format: "%.3f", dny)), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: double_click normalized=(\(dnx), \(dny)) abs=(\(clickPoint.x), \(clickPoint.y))")

            case "type_text":
                let text = (call.args["text"] as? String) ?? ""
                if text.isEmpty {
                    summaries.append("type_text: empty text")
                    logger.log(content: "AI Tool failed: type_text empty")
                } else {
                    AIInputRouter.sendText(text)
                    summaries.append("type_text: success (chars=\(text.count), text=\"\(text)\")")
                    logger.log(content: "AI Tool executed: type_text chars=\(text.count)")
                }

            case "run_verified_macro", "execute_verified_macro", "invoke_verified_macro":
                if let match = verifiedMacroMatch(from: call.args) {
                    let estimatedDuration = MacroManager.shared.estimatedExecutionDuration(for: match.macro)
                    MacroManager.shared.execute(match.macro)
                    // Wait for the macro keystrokes to finish executing on the target, plus a buffer for UI transitions.
                    let waitDuration = estimatedDuration + 2.0
                    logger.log(content: "AI Tool waiting \(String(format: "%.1f", waitDuration))s for macro completion (estimated=\(String(format: "%.1f", estimatedDuration))s)")
                    try? await Task.sleep(nanoseconds: UInt64(waitDuration * 1_000_000_000))
                    summaries.append("run_verified_macro: success (matchedBy=\(match.matchedBy), id=\(match.macro.id.uuidString), label=\"\(match.macro.label)\", waitedSeconds=\(String(format: "%.1f", waitDuration)))")
                    summaries.append("run_verified_macro_note: the macro keystrokes have finished; now verify the new screen state with capture_screen before any click")
                    logger.log(content: "AI Tool executed: run_verified_macro id=\(match.macro.id.uuidString), label=\(match.macro.label), matchedBy=\(match.matchedBy)")
                } else {
                    let available = MacroManager.shared.macros
                        .filter(\.isVerified)
                        .map { "\($0.label) [\($0.id.uuidString)]" }
                        .joined(separator: ", ")
                    let inventory = available.isEmpty ? "none" : available
                    summaries.append("run_verified_macro: no verified macro matched the request (available=\(inventory))")
                    logger.log(content: "AI Tool failed: run_verified_macro no verified macro matched; available=\(inventory)")
                }

            default:
                summaries.append("\(toolName): unsupported")
                logger.log(content: "AI Tool unsupported: \(toolName)")
            }
        }

        return AgentToolExecutionResult(summary: summaries.joined(separator: "\n"), attachmentFilePath: attachmentPath)
    }

    private func intArg(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }

    private func doubleArg(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    /// Convert AI-facing normalized 0.0...1.0 coordinate to internal 0...4096.
    private func normalizedToAbsolute(_ value: Double) -> Int {
        clampAbsoluteCoordinate(Int((min(max(value, 0.0), 1.0) * 4096.0).rounded()))
    }

    /// Convert internal 0...4096 coordinate back to AI-facing 0.0...1.0.
    private func absoluteToNormalized(_ value: Int) -> Double {
        min(max(Double(value) / 4096.0, 0.0), 1.0)
    }

    private func click(button: UInt8, args: [String: Any], isDoubleClick: Bool = false) async -> (x: Int, y: Int) {
        var x: Int
        var y: Int
        if let nx = doubleArg(args["x"]), let ny = doubleArg(args["y"]) {
            x = normalizedToAbsolute(nx)
            y = normalizedToAbsolute(ny)
        } else {
            x = agentMouseX
            y = agentMouseY
        }

        if let instruction = agenticClickRefinementInstruction(args: args, isDoubleClick: isDoubleClick, button: button),
           let refinedPoint = await refineClickTarget(
                absX: x,
                absY: y,
                instruction: instruction,
                tracePrefix: "AGENTIC_CLICK_REFINE",
                logPrefix: "Agentic click refinement"
           ) {
            x = refinedPoint.x
            y = refinedPoint.y
            if let matchedElement = refinedPoint.matchedElement, !matchedElement.isEmpty {
                logger.log(content: "Agentic click refinement matched element: \(matchedElement)")
            }
        }

        agentMouseX = x
        agentMouseY = y

        AIInputRouter.animatedClick(button: button, absX: x, absY: y, isDoubleClick: isDoubleClick)
        return (x, y)
    }

    private func clampAbsoluteCoordinate(_ value: Int) -> Int {
        max(0, min(4096, value))
    }

    private func captureScreenForAgent(timeoutSeconds: TimeInterval = 3.0) async -> URL? {
        guard CameraManager.shared.canTakePicture else {
            logger.log(content: "AI Tool capture_screen unavailable: camera not ready")
            return nil
        }

        logger.log(content: "AI Tool capture_screen starting")
        pendingCapturePreviewSuppressions += 1

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let waiter = CaptureScreenWaiter()
            waiter.continuation = continuation

            waiter.observer = NotificationCenter.default.addObserver(
                forName: .cameraPictureCaptured,
                object: nil,
                queue: .main
            ) { notification in
                Task { @MainActor in
                    waiter.resolve(with: notification.userInfo?["fileURL"] as? URL)
                }
            }

            waiter.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                waiter.resolve(with: nil)
            }

            CameraManager.shared.takePicture()
        }

        if let result {
            logger.log(content: "AI Tool capture_screen succeeded -> \(result.path)")
        } else {
            logger.log(content: "AI Tool capture_screen timed out waiting for notification")
            if pendingCapturePreviewSuppressions > 0 {
                pendingCapturePreviewSuppressions -= 1
            }
        }

        return result
    }

    private func captureAnnotatedClickForChat(absX: Int, absY: Int, actionName: String) async -> URL? {
        guard let screenshotURL = await captureScreenForAgent() else { return nil }
        guard let annotatedURL = makeAnnotatedClickImage(from: screenshotURL, absX: absX, absY: absY, actionName: actionName) else {
            logger.log(content: "AI Tool \(actionName) annotation failed; using raw screenshot")
            return screenshotURL
        }

        logger.log(content: "AI Tool \(actionName) annotation saved -> \(annotatedURL.path)")
        return annotatedURL
    }

    private func refineGuideClickTarget(absX: Int, absY: Int, instruction: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        await refineClickTarget(
            absX: absX,
            absY: absY,
            instruction: instruction,
            tracePrefix: "GUIDE_CLICK_REFINE",
            logPrefix: "Guide click refinement"
        )
    }

    private func refineClickTarget(absX: Int, absY: Int, instruction: String, tracePrefix: String, logPrefix: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        guard let configuration = currentChatAPIConfiguration() else {
            let reason = "\(logPrefix) skipped: chat API configuration is incomplete"
            logger.log(content: reason)
            appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let screenshotURL = await captureScreenForAgent() else {
            let reason = "\(logPrefix) skipped: screen capture unavailable"
            logger.log(content: reason)
            appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let crop = makeClickRefinementCrop(from: screenshotURL, absX: absX, absY: absY, cropSizePixels: 200) else {
            let reason = "\(logPrefix) skipped: failed to build crop"
            logger.log(content: reason)
            appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let imageDataURL = dataURLForImage(atPath: crop.imageURL.path) else {
            let reason = "\(logPrefix) skipped: failed to encode crop image"
            logger.log(content: reason)
            appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        appendAITrace(
            title: "\(tracePrefix)_CONTEXT",
            body: [
                "instruction: \(instruction)",
                "initialAbsPoint: x=\(absX), y=\(absY)",
                "screenshot: \(screenshotURL.path)",
                "crop: \(crop.imageURL.path)",
                "cropOriginTopLeft: x=\(crop.cropOriginX), y=\(crop.cropOriginYTop)",
                "cropSize: \(crop.cropWidth)x\(crop.cropHeight)",
                "sourceSize: \(crop.sourceWidth)x\(crop.sourceHeight)"
            ].joined(separator: "\n")
        )

        let conversation: [ChatCompletionsRequest.Message] = [
            .text(role: .system, text: """
You refine click targets inside a small screenshot crop.

Return ONLY JSON with this schema:
{
    "found": true,
    "x": 0.50,
    "y": 0.50,
    "matched_element": "short description of the matched icon/button/text",
    "confidence": 0.0
}

Rules:
- `x` and `y` must be normalized 0.0...1.0 within the provided crop image.
- The crop is centered near the initial predicted click point.
- Find the exact visible center of the icon, button, or text that best matches the instruction.
- If the target is not visible or not clear enough, return `found`: false and omit x/y.
- Do not return markdown or extra commentary.
"""),
            .multimodal(role: .user, text: """
Instruction for the target to click:
\(instruction)

This image is a 200x200 pixel crop around the model's initial click estimate.
Locate the exact visible center of the correct icon, button, or text inside this crop.
""", imageDataURL: imageDataURL)
        ]

        do {
            let response = try await sendChatCompletion(
                baseURL: configuration.baseURL,
                model: configuration.model,
                apiKey: configuration.apiKey,
                conversation: conversation,
                traceLabel: tracePrefix,
                enableThinking: UserSettings.shared.isClickRefinementThinkingEnabled
            )
            let payload = try decodeJSONPayload(ClickTargetRefinementPayload.self, from: response.content)
            guard payload.found != false,
                  let refinedX = payload.x,
                  let refinedY = payload.y else {
                let reason = "\(logPrefix) returned no confident target"
                logger.log(content: reason)
                appendAITrace(title: "\(tracePrefix)_RESULT", body: reason)
                return nil
            }

            let normalizedX = min(max(refinedX, 0.0), 1.0)
            let normalizedY = min(max(refinedY, 0.0), 1.0)
            let globalPixelX = Double(crop.cropOriginX) + Double(crop.cropWidth) * normalizedX
            let globalPixelYTop = Double(crop.cropOriginYTop) + Double(crop.cropHeight) * normalizedY
            let refinedAbsX = clampAbsoluteCoordinate(Int((globalPixelX / Double(max(crop.sourceWidth, 1))) * 4096.0))
            let refinedAbsY = clampAbsoluteCoordinate(Int((globalPixelYTop / Double(max(crop.sourceHeight, 1))) * 4096.0))

            let resultBody = "refinedAbsPoint: x=\(refinedAbsX), y=\(refinedAbsY)\nmatched: \(payload.matched_element ?? "unknown")\nconfidence: \(payload.confidence ?? -1)"
            logger.log(content: "\(logPrefix) succeeded: abs=(\(refinedAbsX), \(refinedAbsY)), matched=\(payload.matched_element ?? "unknown"), confidence=\(payload.confidence ?? -1)")
            appendAITrace(title: "\(tracePrefix)_RESULT", body: resultBody)
            return (refinedAbsX, refinedAbsY, payload.matched_element)
        } catch {
            let reason = "\(logPrefix) failed: \(error.localizedDescription)"
            logger.log(content: reason)
            appendAITrace(title: "\(tracePrefix)_FAILED", body: reason)
            return nil
        }
    }

    private func agenticClickRefinementInstruction(args: [String: Any], isDoubleClick: Bool, button: UInt8) -> String? {
        if let instruction = (args["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty {
            return instruction
        }

        if let description = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }

        if let latestGoal = messages.last(where: { $0.role == .user && !$0.content.hasPrefix("TOOL_RESULT:") })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !latestGoal.isEmpty {
            let actionName: String
            if button == 0x02 {
                actionName = "right click"
            } else if isDoubleClick {
                actionName = "double click"
            } else {
                actionName = "click"
            }
            return "\(actionName) the correct target needed for this task: \(latestGoal)"
        }

        return nil
    }

    private func makeClickRefinementCrop(from sourceURL: URL, absX: Int, absY: Int, cropSizePixels: Int) -> ClickRefinementCropResult? {
        guard let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let normalizedX = min(1.0, max(0.0, Double(absX) / 4096.0))
        let normalizedYTop = min(1.0, max(0.0, Double(absY) / 4096.0))
        let pixelX = Int((normalizedX * Double(sourceWidth)).rounded())
        let pixelYTop = Int((normalizedYTop * Double(sourceHeight)).rounded())

        let cropWidth = min(cropSizePixels, sourceWidth)
        let cropHeight = min(cropSizePixels, sourceHeight)
        let halfWidth = cropWidth / 2
        let halfHeight = cropHeight / 2

        let cropOriginX = max(0, min(sourceWidth - cropWidth, pixelX - halfWidth))
        let cropOriginYTop = max(0, min(sourceHeight - cropHeight, pixelYTop - halfHeight))

        // Captured screen images in this app are cropped in top-left image coordinates.
        // Do not flip Y here; otherwise the refinement crop lands on the wrong area.
        let cropRect = CGRect(x: cropOriginX, y: cropOriginYTop, width: cropWidth, height: cropHeight)

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }

        guard let encodedCrop = preferredAIImageEncoding(for: croppedCGImage) else { return nil }

        let outputDir = sourceURL.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileExtension = encodedCrop.mimeType == "image/jpeg" ? "jpg" : "png"
        let fileName = "click_refine_crop_\(stamp).\(fileExtension)"
        let outputURL = outputDir.appendingPathComponent(fileName)

        do {
            try encodedCrop.data.write(to: outputURL, options: .atomic)
            return ClickRefinementCropResult(
                imageURL: outputURL,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                cropOriginX: cropOriginX,
                cropOriginYTop: cropOriginYTop,
                cropWidth: cropWidth,
                cropHeight: cropHeight
            )
        } catch {
            logger.log(content: "Guide click refinement crop write failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeAnnotatedClickImage(from sourceURL: URL, absX: Int, absY: Int, actionName: String) -> URL? {
        guard let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let normalizedX = min(1.0, max(0.0, Double(absX) / 4096.0))
        let normalizedY = min(1.0, max(0.0, Double(absY) / 4096.0))
        let pixelX = normalizedX * Double(width)
        let pixelYFromTop = normalizedY * Double(height)
        let pixelY = Double(height) - pixelYFromTop

        let radius = max(12.0, min(Double(width), Double(height)) * 0.03)
        let circleRect = CGRect(x: pixelX - radius, y: pixelY - radius, width: radius * 2.0, height: radius * 2.0)

        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(3.0, radius * 0.2))
        context.strokeEllipse(in: circleRect)

        let centerDotRadius = max(3.0, radius * 0.14)
        let dotRect = CGRect(x: pixelX - centerDotRadius, y: pixelY - centerDotRadius, width: centerDotRadius * 2.0, height: centerDotRadius * 2.0)
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
        context.fillEllipse(in: dotRect)

        guard let annotatedCGImage = context.makeImage() else { return nil }
        guard let encodedImage = preferredAIImageEncoding(for: annotatedCGImage) else { return nil }

        let outputDir = sourceURL.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileExtension = encodedImage.mimeType == "image/jpeg" ? "jpg" : "png"
        let fileName = "\(actionName)_annotated_\(stamp).\(fileExtension)"
        let outputURL = outputDir.appendingPathComponent(fileName)

        do {
            try encodedImage.data.write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            logger.log(content: "AI Tool annotation write failed: \(error.localizedDescription)")
            return nil
        }
    }

    func consumePendingCapturePreviewSuppression() -> Bool {
        guard pendingCapturePreviewSuppressions > 0 else { return false }
        pendingCapturePreviewSuppressions -= 1
        return true
    }

    private static func makeHistoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Openterface", isDirectory: true)
            .appendingPathComponent("chat_history.json")
    }

    private func appendAITrace(title: String, headerPrefix: String? = nil, body: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: aiTraceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: aiTraceURL.path) {
                fileManager.createFile(atPath: aiTraceURL.path, contents: nil, attributes: nil)
            }

            let stamp = Self.traceDateFormatter.string(from: Date())
            let headerPrefixText = headerPrefix.map { "\($0) " } ?? ""
            let entry = "\n===== \(stamp) \(headerPrefixText)\(title) =====\n\(body)\n"
            let data = Data(entry.utf8)

            if let handle = try? FileHandle(forWritingTo: aiTraceURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: aiTraceURL, options: .atomic)
            }
        } catch {
            logger.log(content: "AI trace write failed: \(error.localizedDescription)")
        }
    }

    private func readableTraceParts(from messages: [ChatCompletionsRequest.Message]) -> String {
        var lines: [String] = []

        for (index, message) in messages.enumerated() {
            switch message.content {
            case .text(let value):
                lines.append("TRACE_TEXT|index=\(index)|role=\(message.role.rawValue)|text=\(escapedTraceValue(value))")

            case .parts(let parts):
                for part in parts {
                    if part.type == "text", let text = part.text {
                        lines.append("TRACE_TEXT|index=\(index)|role=\(message.role.rawValue)|text=\(escapedTraceValue(text))")
                    } else if part.type == "image_url", let imageURL = part.image_url?.url {
                        lines.append("TRACE_IMAGE|index=\(index)|role=\(message.role.rawValue)|image=\(escapedTraceValue(imageTraceDescriptor(from: imageURL)))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func imageTraceDescriptor(from url: String) -> String {
        guard url.hasPrefix("data:") else { return url }

        let mimeEnd = url.firstIndex(of: ";") ?? url.endIndex
        let mimeType = String(url[url.index(url.startIndex, offsetBy: 5)..<mimeEnd])
        let length = url.count
        return "data-url mime=\(mimeType) chars=\(length)"
    }

    private func escapedTraceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private func traceBodyForLogging(data: Data, contentType: String?) -> String {
        guard !data.isEmpty else { return "<empty body>" }

        let normalizedContentType = (contentType ?? "").lowercased()
        if normalizedContentType.contains("image/") || normalizedContentType.contains("octet-stream") {
            return "<binary payload omitted contentType=\(normalizedContentType.isEmpty ? "unknown" : normalizedContentType) bytes=\(data.count)>"
        }

        if let utf8 = String(data: data, encoding: .utf8) {
            let maxLength = 20000
            if utf8.count > maxLength {
                return String(utf8.prefix(maxLength)) + "\n...<payload truncated, too large to display (length=\(utf8.count))>"
            }
            return utf8
        }

        return "<non-utf8 payload omitted contentType=\(normalizedContentType.isEmpty ? "unknown" : normalizedContentType) bytes=\(data.count)>"
    }

    private static func makeTraceURL(fileName: String) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent(fileName)
    }

    private static let traceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func traceDurationHeader(from duration: TimeInterval) -> String {
        String(format: "[responseTime: %.3fs]", duration)
    }

    private func startGuideAutoNextStatus(for messageID: UUID) {
        let startedAt = Date()
        pendingGuideAutoNextStarts[messageID] = startedAt
        guideAutoNextStatuses[messageID] = GuideAutoNextStatus(phase: .thinking, text: "Thinking...")
    }

    private func completeGuideAutoNextStatus(for messageID: UUID) {
        let startedAt = pendingGuideAutoNextStarts.removeValue(forKey: messageID) ?? Date()
        let elapsed = Date().timeIntervalSince(startedAt)
        guideAutoNextStatuses[messageID] = GuideAutoNextStatus(
            phase: .completed,
            text: "Used time: \(String(format: "%.2fs", elapsed))"
        )
    }

    private func failGuideAutoNextStatus(for messageID: UUID, errorDescription: String) {
        pendingGuideAutoNextStarts.removeValue(forKey: messageID)
        guideAutoNextStatuses[messageID] = GuideAutoNextStatus(
            phase: .failed,
            text: "Failed: \(errorDescription)"
        )
    }

    private func cancelGuideAutoNextStatus(for messageID: UUID) {
        pendingGuideAutoNextStarts.removeValue(forKey: messageID)
        guideAutoNextStatuses[messageID] = GuideAutoNextStatus(
            phase: .cancelled,
            text: "Canceled"
        )
    }
}

private struct MainPlannerAgent {
    private struct PlannerTaskPayload: Decodable {
        let title: String
        let detail: String
        let agent: String
        let tool: String
    }

    private struct PlannerResponsePayload: Decodable {
        let summary: String
        let tasks: [PlannerTaskPayload]
    }

    let maxPlannerTasks: Int

    func buildPlanningConversation(
        systemPrompt: String,
        plannerPrompt: String,
        macroInventoryPrompt: String,
        userRequest: String,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: "Available task agent/tool pairs: screen/capture_screen, typing/type_text, macro/run_verified_macro, mouse/move_mouse, mouse/left_click, mouse/right_click, mouse/double_click."))
        if !plannerPrompt.isEmpty {
            conversation.append(.text(role: .system, text: plannerPrompt))
        }
        if !macroInventoryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.append(.text(role: .system, text: macroInventoryPrompt))
        }

        let requestText = "User request:\n\(userRequest)\n\nReturn a concise JSON plan with at most \(maxPlannerTasks) screen tasks."
        if let imageDataURL {
            conversation.append(.multimodal(role: .user, text: requestText, imageDataURL: imageDataURL))
        } else {
            conversation.append(.text(role: .user, text: requestText))
        }

        return conversation
    }

    func parsePlan(from responseText: String, goal: String) throws -> ChatExecutionPlan {
        let payload = try decodeJSONPayload(PlannerResponsePayload.self, from: responseText)
        let normalizedTasks = Array(payload.tasks.prefix(maxPlannerTasks)).map { task in
            ChatTask(
                title: task.title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: task.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                agentName: task.agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "screen" : task.agent.trimmingCharacters(in: .whitespacesAndNewlines),
                toolName: task.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "capture_screen" : task.tool.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.filter {
            !$0.title.isEmpty && !$0.detail.isEmpty
        }

        guard !normalizedTasks.isEmpty else {
            throw NSError(domain: "MainPlannerAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "Planner returned an empty task list"])
        }

        return ChatExecutionPlan(
            goal: goal,
            summary: payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Review the current target screen in a few focused steps." : payload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .awaitingApproval,
            tasks: normalizedTasks
        )
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "MainPlannerAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "MainPlannerAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private protocol TaskAgentExecutor {
    var agentName: String { get }
    var toolName: String { get }

    func prompt(from settings: UserSettings) -> String
    func buildTaskConversation(
        systemPrompt: String,
        taskPrompt: String,
        plan: ChatExecutionPlan,
        task: ChatTask,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message]
    func applyResponse(_ response: String, to task: inout ChatTask)
}

private struct TaskAgentRegistry {
    private let exactMappings: [String: any TaskAgentExecutor]
    private let toolMappings: [String: any TaskAgentExecutor]

    init(agents: [any TaskAgentExecutor]) {
        var exactMappings: [String: any TaskAgentExecutor] = [:]
        var toolMappings: [String: any TaskAgentExecutor] = [:]

        for agent in agents {
            exactMappings[Self.makeExactKey(agentName: agent.agentName, toolName: agent.toolName)] = agent
            toolMappings[agent.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = agent
        }

        self.exactMappings = exactMappings
        self.toolMappings = toolMappings
    }

    func resolve(for task: ChatTask) -> (any TaskAgentExecutor)? {
        let exactKey = Self.makeExactKey(agentName: task.agentName, toolName: task.toolName)
        if let exact = exactMappings[exactKey] {
            return exact
        }

        return toolMappings[task.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private static func makeExactKey(agentName: String, toolName: String) -> String {
        let normalizedAgent = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedAgent)::\(normalizedTool)"
    }
}

private struct ScreenTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let result_summary: String
    }

    let agentName: String = "screen"
    let toolName: String = "capture_screen"

    func prompt(from settings: UserSettings) -> String {
        settings.resolvedScreenAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildTaskConversation(
        systemPrompt: String,
        taskPrompt: String,
        plan: ChatExecutionPlan,
        task: ChatTask,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if !taskPrompt.isEmpty {
            conversation.append(.text(role: .system, text: taskPrompt))
        }

        let instruction = "Plan summary: \(plan.summary)\n\nTask title: \(task.title)\nTask detail: \(task.detail)\nTool: \(task.toolName)\n\nUse the latest screen image to complete only this task."
        if let imageDataURL {
            conversation.append(.multimodal(role: .user, text: instruction, imageDataURL: imageDataURL))
        } else {
            conversation.append(.text(role: .user, text: instruction))
        }

        return conversation
    }

    func applyResponse(_ response: String, to task: inout ChatTask) {
        if let payload = try? decodeJSONPayload(ResponsePayload.self, from: response) {
            let normalizedStatus = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            task.status = normalizedStatus == "completed" ? .completed : .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        task.status = .completed
        task.resultSummary = response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "ScreenTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "ScreenTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct TypeTextTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let text_to_type: String?
        let shortcut: String?
        let result_summary: String
    }

    let agentName: String = "typing"
    let toolName: String = "type_text"

    func prompt(from settings: UserSettings) -> String {
        settings.resolvedTypingAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildTaskConversation(
        systemPrompt: String,
        taskPrompt: String,
        plan: ChatExecutionPlan,
        task: ChatTask,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if !taskPrompt.isEmpty {
            conversation.append(.text(role: .system, text: taskPrompt))
        }

        let instruction = "Plan summary: \(plan.summary)\n\nTask title: \(task.title)\nTask detail: \(task.detail)\nTool: \(task.toolName)\n\nReturn text_to_type containing the exact text that must be sent to target keyboard input."
        if let imageDataURL {
            conversation.append(.multimodal(role: .user, text: instruction, imageDataURL: imageDataURL))
        } else {
            conversation.append(.text(role: .user, text: instruction))
        }

        return conversation
    }

    func applyResponse(_ response: String, to task: inout ChatTask) {
        if let payload = try? decodeJSONPayload(ResponsePayload.self, from: response) {
            let normalizedStatus = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let textToType = payload.text_to_type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shortcut = payload.shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if normalizedStatus == "completed", !shortcut.isEmpty {
                if executeShortcut(shortcut) {
                    task.status = .completed
                    task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Executed shortcut \(shortcut) on target."
                        : payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    task.status = .failed
                    task.resultSummary = "Typing task failed: unsupported or invalid shortcut \(shortcut)."
                }
                return
            }

            if normalizedStatus == "completed", !textToType.isEmpty {
                AIInputRouter.sendText(textToType)
                task.status = .completed
                task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Typed \(textToType.count) characters on target."
                    : payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }

            task.status = .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Typing task failed: missing text_to_type/shortcut or status not completed."
                : payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        task.status = .failed
        task.resultSummary = "Typing task failed: response was not valid JSON."
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "TypeTextTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "TypeTextTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func executeShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard let keyToken = parts.last else { return false }

        var modifiers: NSEvent.ModifierFlags = []
        for token in parts.dropLast() {
            switch token {
            case "win", "windows", "cmd", "command", "meta", "super":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                return false
            }
        }

        guard let keyCode = keyCode(for: keyToken) else { return false }

        DependencyContainer.shared.resolve(LoggerProtocol.self).log(content: "AI Executing Shortcut: '\(shortcut)' -> resolved mod: \(modifiers.rawValue), key: \(keyCode)")
        return AIInputRouter.sendShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCode(for token: String) -> UInt16? {
        let named: [String: UInt16] = [
            "esc": 53, "escape": 53,
            "enter": 36, "return": 36,
            "tab": 48,
            "space": 49,
            "backspace": 51, "delete": 51,
            "home": 115,
            "end": 119,
            "pageup": 116,
            "pagedown": 121,
            "up": 126,
            "down": 125,
            "left": 123,
            "right": 124,
            "f1": 122,
            "f2": 120,
            "f3": 99,
            "f4": 118,
            "f5": 96,
            "f6": 97,
            "f7": 98,
            "f8": 100,
            "f9": 101,
            "f10": 109,
            "f11": 103,
            "f12": 111
        ]
        if let mapped = named[token] {
            return mapped
        }

        let alphaNumeric: [String: UInt16] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return alphaNumeric[token]
    }
}

private struct MacroTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let macro_id: String?
        let macro_label: String?
        let result_summary: String
    }

    let agentName: String = "macro"
    let toolName: String = "run_verified_macro"

    func prompt(from settings: UserSettings) -> String {
        """
You are the Openterface Macro Task Agent.

You are responsible for one macro selection task and one tool only: run_verified_macro.

Rules:
- Return ONLY JSON.
- Focus only on the current task.
- Select only from the provided verified executable macro inventory.
- Prefer macro_id when available.
- If no verified macro matches, return status=failed and explain why.

Schema:
{
    "status": "completed" | "failed",
    "macro_id": "UUID if available (optional)",
    "macro_label": "fallback label (optional)",
    "result_summary": "short summary for the user"
}
"""
    }

    func buildTaskConversation(
        systemPrompt: String,
        taskPrompt: String,
        plan: ChatExecutionPlan,
        task: ChatTask,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if !taskPrompt.isEmpty {
            conversation.append(.text(role: .system, text: taskPrompt))
        }
        conversation.append(.text(role: .system, text: macroInventoryPrompt()))

        let instruction = "Plan summary: \(plan.summary)\n\nTask title: \(task.title)\nTask detail: \(task.detail)\nTool: \(task.toolName)\n\nSelect the single verified macro that best completes this task."
        if let imageDataURL {
            conversation.append(.multimodal(role: .user, text: instruction, imageDataURL: imageDataURL))
        } else {
            conversation.append(.text(role: .user, text: instruction))
        }

        return conversation
    }

    func applyResponse(_ response: String, to task: inout ChatTask) {
        guard let payload = try? decodeJSONPayload(ResponsePayload.self, from: response) else {
            task.status = .failed
            task.resultSummary = "Macro task failed: response was not valid JSON."
            return
        }

        let normalizedStatus = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedStatus == "completed" else {
            task.status = .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Macro task failed: no verified macro was selected."
                : payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        guard let matchedMacro = matchedVerifiedMacro(id: payload.macro_id, label: payload.macro_label) else {
            task.status = .failed
            task.resultSummary = "Macro task failed: selected verified macro was not found."
            return
        }

        MainActor.assumeIsolated {
            MacroManager.shared.execute(matchedMacro)
        }
        task.status = .completed
        let summary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
        task.resultSummary = summary.isEmpty
            ? "Executed verified macro \(matchedMacro.label)."
            : summary
    }

    private func matchedVerifiedMacro(id: String?, label: String?) -> Macro? {
        let verifiedMacros = MainActor.assumeIsolated {
            MacroManager.shared.macros.filter(\.isVerified)
        }

        if let id, let macroID = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if let matched = verifiedMacros.first(where: { $0.id == macroID }) {
                return matched
            }
        }

        let normalizedLabel = (label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedLabel.isEmpty else { return nil }

        if let exact = verifiedMacros.first(where: {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedLabel
        }) {
            return exact
        }

        let partialMatches = verifiedMacros.filter {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(normalizedLabel)
        }
        return partialMatches.count == 1 ? partialMatches.first : nil
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "MacroTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "MacroTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private func macroInventoryPrompt() -> String {
        let verifiedMacros = MainActor.assumeIsolated {
            MacroManager.shared.macros.filter(\.isVerified)
        }
        guard !verifiedMacros.isEmpty else {
            return "Verified executable macros:\n- No verified macros are currently available."
        }

        let lines = verifiedMacros.map { macro in
            let description = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = description.isEmpty ? macro.data : description
            return "- id=\(macro.id.uuidString), label=\(macro.label), target=\(macro.targetSystem.displayName), detail=\(detail)"
        }
        return "Verified executable macros:\n" + lines.joined(separator: "\n")
    }
}

private struct MouseTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let x: Double?
        let y: Double?
        let result_summary: String
    }

    let agentName: String = "mouse"
    let toolName: String

    func prompt(from settings: UserSettings) -> String {
        settings.resolvedScreenAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildTaskConversation(
        systemPrompt: String,
        taskPrompt: String,
        plan: ChatExecutionPlan,
        task: ChatTask,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if !taskPrompt.isEmpty {
            conversation.append(.text(role: .system, text: taskPrompt))
        }

        let instruction = """
Plan summary: \(plan.summary)

Task title: \(task.title)
Task detail: \(task.detail)
Tool: \(task.toolName)

    Return JSON only.
    - Always provide x and y as normalized floats from 0.0 to 1.0 (fraction of screen width/height).
    - For click tools, x and y are required (do not omit them).
    - Choose the center point of the exact UI element to interact with.
"""
        if let imageDataURL {
            conversation.append(.multimodal(role: .user, text: instruction, imageDataURL: imageDataURL))
        } else {
            conversation.append(.text(role: .user, text: instruction))
        }

        return conversation
    }

    func applyResponse(_ response: String, to task: inout ChatTask) {
        guard let payload = try? decodeJSONPayload(ResponsePayload.self, from: response) else {
            task.status = .failed
            task.resultSummary = "Mouse task failed: response was not valid JSON."
            return
        }

        let normalizedStatus = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedStatus == "completed" else {
            task.status = .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        guard let rawX = payload.x, let rawY = payload.y else {
            task.status = .failed
            task.resultSummary = "Mouse task failed: x and y are required for \(toolName)."
            return
        }
        let targetX = normalizedToAbsolute(rawX)
        let targetY = normalizedToAbsolute(rawY)

        switch toolName {
        case "move_mouse":
            AIInputRouter.sendMouseMove(absX: targetX, absY: targetY)

        case "left_click":
            performClick(button: 0x01, x: targetX, y: targetY, isDoubleClick: false)

        case "right_click":
            performClick(button: 0x02, x: targetX, y: targetY, isDoubleClick: false)

        case "double_click":
            performClick(button: 0x01, x: targetX, y: targetY, isDoubleClick: true)

        default:
            task.status = .failed
            task.resultSummary = "Mouse task failed: unsupported tool \(toolName)."
            return
        }

        task.status = .completed
        let summary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
        task.resultSummary = summary.isEmpty
            ? "Mouse task executed using \(toolName) at normalized coordinates (\(String(format: "%.3f", rawX)), \(String(format: "%.3f", rawY)))."
            : summary
    }

    private func performClick(button: UInt8, x: Int, y: Int, isDoubleClick: Bool) {
        AIInputRouter.animatedClick(button: button, absX: x, absY: y, isDoubleClick: isDoubleClick)
    }

    /// Convert AI-facing normalized 0.0...1.0 coordinate to internal 0...4096.
    private func normalizedToAbsolute(_ value: Double) -> Int {
        let clamped = min(max(value, 0.0), 1.0)
        return min(max(Int((clamped * 4096.0).rounded()), 0), 4096)
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "MouseTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }

        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "MouseTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        struct ContentPart: Encodable {
            struct ImageURLPayload: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let image_url: ImageURLPayload?

            static func text(_ text: String) -> ContentPart {
                ContentPart(type: "text", text: text, image_url: nil)
            }

            static func image(_ url: String) -> ContentPart {
                ContentPart(type: "image_url", text: nil, image_url: .init(url: url))
            }
        }

        let role: ChatRole
        let content: Content

        enum Content: Encodable {
            case text(String)
            case parts([ContentPart])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value):
                    try container.encode(value)
                case .parts(let value):
                    try container.encode(value)
                }
            }
        }

        static func text(role: ChatRole, text: String) -> Message {
            Message(role: role, content: .text(text))
        }

        static func multimodal(role: ChatRole, text: String, imageDataURL: String) -> Message {
            Message(role: role, content: .parts([.text(text), .image(imageDataURL)]))
        }
    }

    let model: String
    let messages: [Message]
    let stream: Bool = false
    let enableThinking: Bool?

    init(model: String, messages: [Message], enableThinking: Bool? = nil) {
        self.model = model
        self.messages = messages
        self.enableThinking = enableThinking
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case enableThinking = "enable_thinking"
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }

    let choices: [Choice]
    let usage: Usage?
}
