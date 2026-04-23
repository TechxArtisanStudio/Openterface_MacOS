import Foundation
import AppKit

// MARK: - ChatCompletionsRequest / Response
// Thin Codable wrappers around the OpenAI-compatible chat completions API.

struct ChatCompletionsRequest: Encodable {
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
                case .text(let value):   try container.encode(value)
                case .parts(let value):  try container.encode(value)
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

struct ChatCompletionsResponse: Decodable {
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens    = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }

    let choices: [Choice]
    let usage: Usage?
}

// MARK: - MainPlannerAgent

struct MainPlannerAgent {
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
        conversation.append(.text(role: .system, text: "Available task agent/tool pairs: screen/capture_screen, typing/type_text, macro/run_verified_macro, mouse/move_mouse, mouse/left_click, mouse/left_drag, mouse/right_click, mouse/double_click."))
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
        }.filter { !$0.title.isEmpty && !$0.detail.isEmpty }

        guard !normalizedTasks.isEmpty else {
            throw NSError(domain: "MainPlannerAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "Planner returned an empty task list"])
        }

        return ChatExecutionPlan(
            goal: goal,
            summary: payload.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Review the current target screen in a few focused steps."
                : payload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
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

// MARK: - TaskAgentExecutor protocol

protocol TaskAgentExecutor {
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

// MARK: - TaskAgentRegistry

struct TaskAgentRegistry {
    private let exactMappings: [String: any TaskAgentExecutor]
    private let toolMappings:  [String: any TaskAgentExecutor]

    init(agents: [any TaskAgentExecutor]) {
        var exactMappings: [String: any TaskAgentExecutor] = [:]
        var toolMappings:  [String: any TaskAgentExecutor] = [:]

        for agent in agents {
            exactMappings[Self.makeExactKey(agentName: agent.agentName, toolName: agent.toolName)] = agent
            toolMappings[agent.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = agent
        }

        self.exactMappings = exactMappings
        self.toolMappings  = toolMappings
    }

    func resolve(for task: ChatTask) -> (any TaskAgentExecutor)? {
        let exactKey = Self.makeExactKey(agentName: task.agentName, toolName: task.toolName)
        if let exact = exactMappings[exactKey] { return exact }
        return toolMappings[task.toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private static func makeExactKey(agentName: String, toolName: String) -> String {
        let a = agentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let t = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(a)::\(t)"
    }
}

// MARK: - ScreenTaskAgent

struct ScreenTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let result_summary: String
    }

    let agentName: String = "screen"
    let toolName:  String = "capture_screen"

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
        if !systemPrompt.isEmpty { conversation.append(.text(role: .system, text: systemPrompt)) }
        if !taskPrompt.isEmpty   { conversation.append(.text(role: .system, text: taskPrompt)) }

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
            task.status = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "completed" ? .completed : .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        task.status = .completed
        task.resultSummary = response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "ScreenTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No JSON"])
        }
        guard let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw NSError(domain: "ScreenTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not UTF-8"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - TypeTextTaskAgent

struct TypeTextTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let text_to_type: String?
        let shortcut: String?
        let result_summary: String
    }

    let agentName: String = "typing"
    let toolName:  String = "type_text"

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
        if !systemPrompt.isEmpty { conversation.append(.text(role: .system, text: systemPrompt)) }
        if !taskPrompt.isEmpty   { conversation.append(.text(role: .system, text: taskPrompt)) }

        let instruction = "Plan summary: \(plan.summary)\n\nTask title: \(task.title)\nTask detail: \(task.detail)\nTool: \(task.toolName)\n\nReturn text_to_type containing the exact text that must be sent to target keyboard input."
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
            task.resultSummary = "Typing task failed: response was not valid JSON."
            return
        }

        let status = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textToType = payload.text_to_type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortcut   = payload.shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if status == "completed", !shortcut.isEmpty {
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

        if status == "completed", !textToType.isEmpty {
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
            case "win", "windows", "cmd", "command", "meta", "super": modifiers.insert(.command)
            case "ctrl", "control":  modifiers.insert(.control)
            case "alt", "option":    modifiers.insert(.option)
            case "shift":            modifiers.insert(.shift)
            default:                 return false
            }
        }

        guard let keyCode = keyCode(for: keyToken) else { return false }
        DependencyContainer.shared.resolve(LoggerProtocol.self).log(content: "AI Executing Shortcut: '\(shortcut)' -> mod: \(modifiers.rawValue), key: \(keyCode)")
        return AIInputRouter.sendShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    // swiftlint:disable:next function_body_length
    private func keyCode(for token: String) -> UInt16? {
        let named: [String: UInt16] = [
            "esc": 53, "escape": 53, "enter": 36, "return": 36, "tab": 48, "space": 49,
            "backspace": 51, "delete": 51, "home": 115, "end": 119, "pageup": 116,
            "pagedown": 121, "up": 126, "down": 125, "left": 123, "right": 124,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        if let mapped = named[token] { return mapped }

        let alphaNumeric: [String: UInt16] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return alphaNumeric[token]
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "TypeTextTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No JSON"])
        }
        guard let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw NSError(domain: "TypeTextTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not UTF-8"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - MacroTaskAgent

struct MacroTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let macro_id: String?
        let macro_label: String?
        let result_summary: String
    }

    let agentName: String = "macro"
    let toolName:  String = "run_verified_macro"

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
        if !systemPrompt.isEmpty { conversation.append(.text(role: .system, text: systemPrompt)) }
        if !taskPrompt.isEmpty   { conversation.append(.text(role: .system, text: taskPrompt)) }
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

        let status = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "completed" else {
            task.status = .failed
            task.resultSummary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Macro task failed: no verified macro was selected."
                : payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        guard let matched = matchedVerifiedMacro(id: payload.macro_id, label: payload.macro_label) else {
            task.status = .failed
            task.resultSummary = "Macro task failed: selected verified macro was not found."
            return
        }

        MainActor.assumeIsolated { MacroManager.shared.execute(matched) }
        task.status = .completed
        let summary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
        task.resultSummary = summary.isEmpty ? "Executed verified macro \(matched.label)." : summary
    }

    private func matchedVerifiedMacro(id: String?, label: String?) -> Macro? {
        let verified = MainActor.assumeIsolated { MacroManager.shared.macros.filter(\.isVerified) }

        if let id, let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if let matched = verified.first(where: { $0.id == uuid }) { return matched }
        }

        let normalizedLabel = (label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedLabel.isEmpty else { return nil }

        if let exact = verified.first(where: {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedLabel
        }) { return exact }

        let partial = verified.filter {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(normalizedLabel)
        }
        return partial.count == 1 ? partial.first : nil
    }

    private func macroInventoryPrompt() -> String {
        let verified = MainActor.assumeIsolated { MacroManager.shared.macros.filter(\.isVerified) }
        guard !verified.isEmpty else { return "Verified executable macros:\n- No verified macros are currently available." }

        let lines = verified.map { macro in
            let detail = macro.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? macro.data : macro.description
            return "- id=\(macro.id.uuidString), label=\(macro.label), target=\(macro.targetSystem.displayName), detail=\(detail)"
        }
        return "Verified executable macros:\n" + lines.joined(separator: "\n")
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "MacroTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No JSON"])
        }
        guard let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw NSError(domain: "MacroTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not UTF-8"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - MouseTaskAgent

struct MouseTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let x: Double?
        let y: Double?
        let start_x: Double?
        let start_y: Double?
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
        if !systemPrompt.isEmpty { conversation.append(.text(role: .system, text: systemPrompt)) }
        if !taskPrompt.isEmpty   { conversation.append(.text(role: .system, text: taskPrompt)) }

        let instruction = """
Plan summary: \(plan.summary)

Task title: \(task.title)
Task detail: \(task.detail)
Tool: \(task.toolName)

    Return JSON only.
    - Always provide x and y as normalized floats from 0.0 to 1.0 (fraction of screen width/height).
    - For click and move tools, x and y are required.
    - For left_drag, x and y are the drag destination and optional start_x/start_y specify the drag start point.
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

        let status = payload.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "completed" else {
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
            AIInputRouter.animatedClick(button: 0x01, absX: targetX, absY: targetY, isDoubleClick: false)
        case "left_drag":
            AIInputRouter.animatedDrag(
                startAbsX: payload.start_x.map(normalizedToAbsolute),
                startAbsY: payload.start_y.map(normalizedToAbsolute),
                endAbsX: targetX, endAbsY: targetY
            )
        case "right_click":
            AIInputRouter.animatedClick(button: 0x02, absX: targetX, absY: targetY, isDoubleClick: false)
        case "double_click":
            AIInputRouter.animatedClick(button: 0x01, absX: targetX, absY: targetY, isDoubleClick: true)
        default:
            task.status = .failed
            task.resultSummary = "Mouse task failed: unsupported tool \(toolName)."
            return
        }

        task.status = .completed
        let summary = payload.result_summary.trimmingCharacters(in: .whitespacesAndNewlines)
        task.resultSummary = summary.isEmpty
            ? "Mouse task executed using \(toolName) at normalized (\(String(format: "%.3f", rawX)), \(String(format: "%.3f", rawY)))."
            : summary
    }

    private func normalizedToAbsolute(_ value: Double) -> Int {
        min(max(Int((min(max(value, 0.0), 1.0) * 4096.0).rounded()), 0), 4096)
    }

    private func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "MouseTaskAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "No JSON"])
        }
        guard let data = String(trimmed[start...end]).data(using: .utf8) else {
            throw NSError(domain: "MouseTaskAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not UTF-8"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
