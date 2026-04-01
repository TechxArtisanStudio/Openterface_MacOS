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

private struct ChatCompletionResult {
    let content: String
    let inputTokenCount: Int?
    let outputTokenCount: Int?
}

@MainActor
final class ChatManager: ObservableObject, ChatManagerProtocol {
    static let shared = ChatManager()

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isSending: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentPlan: ChatExecutionPlan?
    @Published private(set) var plannerTraceEntries: [ChatTaskTraceEntry] = []

    private var currentTask: Task<Void, Never>?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let historyURL: URL
    private let aiTraceURL: URL
    private var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    private let maxAgentIterations = 4
    private let plannerAgent = MainPlannerAgent(maxPlannerTasks: 6)
    private let taskAgentRegistry = TaskAgentRegistry(agents: [
        ScreenTaskAgent(),
        TypeTextTaskAgent(),
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
    private var agentMouseX: Int = 2048
    private var agentMouseY: Int = 2048
    private var pendingCapturePreviewSuppressions = 0
    private var taskStepTraces: [UUID: [ChatTaskTraceEntry]] = [:]
    private let agentToolInstruction = """
When action is required, you may call tools by returning ONLY JSON (no markdown):
{"tool_calls":[{"tool":"capture_screen"},{"tool":"move_mouse","x":2048,"y":2048},{"tool":"left_click"},{"tool":"type_text","text":"hello"}]}

Available tools:
- capture_screen: Capture latest target screen and use it for next reasoning step.
- move_mouse: Move target mouse. Args: x (Int), y (Int), both in absolute range 0...4096 where 4096 means 100% of screen width/height.
- left_click: Left click at current mouse location. Optional args: x (Int), y (Int) in 0...4096.
- right_click: Right click at current mouse location. Optional args: x (Int), y (Int) in 0...4096.
- double_click: Double left click. Optional args: x (Int), y (Int) in 0...4096.
- type_text: Type text on target. Args: text (String).

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

    private struct GuideResponsePayload: Decodable {
        struct TargetBox: Decodable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
        }

        let next_step: String
        let target_box: TargetBox?
        let keyboard_shortcut: String?
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

    func clearHistory() {
        cancelSending()
        messages.removeAll()
        currentPlan = nil
        plannerTraceEntries.removeAll()
        taskStepTraces.removeAll()
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

    func taskStepTraceEntries(for taskID: UUID) -> [ChatTaskTraceEntry] {
        taskStepTraces[taskID] ?? []
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
        let systemPrompt = UserSettings.shared.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    messages.append(ChatMessage(role: .assistant, content: "Tool result:\n\(toolResult.summary)", attachmentFilePath: toolResult.attachmentFilePath))
                    persistHistory()
                    continue
                }

                messages.append(ChatMessage(role: .assistant, content: assistantText))
                persistHistory()
                return
            }

            let timeoutMessage = "I executed the available steps but still need guidance to continue. Please provide a fresh screenshot or more detail."
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
            let plannerMessages = plannerAgent.buildPlanningConversation(
                systemPrompt: systemPrompt,
                plannerPrompt: UserSettings.shared.plannerPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                userRequest: latestUserMessage.content,
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

        do {
            currentPlan = nil
            let guideAttachment = await latestPlanningAttachmentURL(fallbackAttachmentPath: latestUserMessage.attachmentFilePath)
            var conversation: [ChatCompletionsRequest.Message] = []
            if !systemPrompt.isEmpty {
                conversation.append(.text(role: .system, text: systemPrompt))
            }

            let guidePrompt = UserSettings.shared.guidePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !guidePrompt.isEmpty {
                conversation.append(.text(role: .system, text: guidePrompt))
            }

            let initialGoalText = messages.first(where: { 
                $0.role == .user && 
                !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && 
                $0.content != "Attached screenshot" && 
                $0.content != "Guide me to the next action on the current screen." 
            })?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let pastAssistantSteps = messages
                .filter {
                    $0.role == .assistant &&
                    (($0.guideActionRect != nil || $0.guideShortcut != nil) || isGuideCompletionText($0.content))
                }
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var userText = latestUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Guide me to the next action on the current screen."
                : latestUserMessage.content

            if !pastAssistantSteps.isEmpty {
                let stepsList = pastAssistantSteps.enumerated()
                    .map { "- Step \($0.offset + 1): \($0.element.prefix(250))" }
                    .joined(separator: "\n")
                if !initialGoalText.isEmpty && initialGoalText != userText {
                    userText = "Original Goal: \(initialGoalText)\n\nPast Actions Taken:\n\(stepsList)\n\nCurrent Request: \(userText)"
                } else {
                    userText = "Past Actions Taken:\n\(stepsList)\n\nCurrent Request: \(userText)"
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

            let guideShortcut = payload.keyboard_shortcut?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedShortcut = (guideShortcut?.isEmpty == false) ? guideShortcut : nil
            let hasActionableGuidePayload = guideActionRect != nil || sanitizedShortcut != nil
            let baseGuideMessage = responseText.isEmpty ? payload.next_step : responseText
            let finalGuideMessage = isGuideCompletionText(baseGuideMessage) && !hasActionableGuidePayload
                ? "Task Complete\n\n\(baseGuideMessage)"
                : baseGuideMessage
            
            messages.append(ChatMessage(
                role: .assistant,
                content: finalGuideMessage,
                guideActionRect: guideActionRect,
                guideShortcut: sanitizedShortcut
            ))
            persistHistory()
        } catch {
            if Task.isCancelled { return }
            logger.log(content: "AI guide-mode request failed: \(error.localizedDescription)")
            appendAITrace(title: "GUIDE_ERROR", body: error.localizedDescription)
            clearGuideOverlay()
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

    func executeGuideAction(targetBox: CGRect?, shortcut: String?, messageContent: String, autoNext: Bool) {
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
                
                // Match explicit verbs, defaulting to left click
                let contentLower = messageContent.lowercased()
                let isRightClick = contentLower.contains("right click") || contentLower.contains("right-click")
                let isDoubleClick = (!isRightClick && (contentLower.contains("double click") || contentLower.contains("double-click")))
                
                let buttonEvent: UInt8 = isRightClick ? 0x02 : 0x01
                let actionName = isRightClick ? "right_click" : (isDoubleClick ? "double_click" : "left_click")
                
                let absX = Int(cx * 4096.0)
                let absY = Int(cy * 4096.0)
                
                let clampedX = clampAbsoluteCoordinate(absX)
                let clampedY = clampAbsoluteCoordinate(absY)
                agentMouseX = clampedX
                agentMouseY = clampedY
                
                logger.log(content: "Guide Action Preparing: \(actionName) at normalized(\(String(format: "%.3f", cx)), \(String(format: "%.3f", cy))) -> clamped(\(clampedX), \(clampedY))")
                
                HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
                try? await Task.sleep(nanoseconds: 50_000_000)
                HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: buttonEvent, wheelMovement: 0x00)
                try? await Task.sleep(nanoseconds: 50_000_000)
                HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
                
                if isDoubleClick {
                    logger.log(content: "Guide Action Executing: second click for double_click")
                    try? await Task.sleep(nanoseconds: 140_000_000) // Delay between clicks
                    HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: buttonEvent, wheelMovement: 0x00)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
                }
                
                actionDescription = "\(actionName) at x=\(clampedX), y=\(clampedY)"
                logger.log(content: "Guide Action Executed: \(actionDescription)")
            }
            
            let messageText = autoNext
                ? "Action executed: \(actionDescription). Auto-guiding the next step..."
                : "Action executed: \(actionDescription)."
            
            DispatchQueue.main.async {
                self.clearGuideOverlay()
                self.messages.append(ChatMessage(role: .assistant, content: messageText))
                self.persistHistory()
            }
            
            if autoNext {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                DispatchQueue.main.async {
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

        for step in sequenceSteps {
            if executeShortcut(step) {
                executedAny = true
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            logger.log(content: "AI Executing Text Input: '\(step)'")
            KeyboardManager.shared.sendTextToKeyboard(text: step)
            executedAny = true
            Thread.sleep(forTimeInterval: 0.05)
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

        for step in steps {
            switch step {
            case .shortcut(let shortcut):
                if executeShortcut(shortcut) {
                    executedAny = true
                }
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                logger.log(content: "AI Executing Text Input: '\(trimmed)'")
                KeyboardManager.shared.sendTextToKeyboard(text: trimmed)
                executedAny = true
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        return executedAny
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
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: true)
        Thread.sleep(forTimeInterval: 0.05)
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: false)
        return true
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
            conversation.append(.text(role: .system, text: agentToolInstruction))
        }

        let recent = sourceMessages.suffix(30)
        conversation.append(contentsOf: recent.map { message in
            if message.role == .user,
               let path = message.attachmentFilePath,
               let imageURL = dataURLForImage(atPath: path) {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Please analyze this screenshot."
                    : message.content
                return .multimodal(role: message.role, text: text, imageDataURL: imageURL)
            }
            return .text(role: message.role, text: message.content)
        })
        return conversation
    }

    private func dataURLForImage(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let imagePayload = preparedImagePayload(for: url) else { return nil }

        return "data:\(imagePayload.mimeType);base64,\(imagePayload.data.base64EncodedString())"
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

        guard let maxLongEdge = UserSettings.shared.chatImageUploadLimit.maxLongEdge else {
            return (originalData, originalMimeType)
        }

        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.log(content: "AI image scaling skipped: failed to load image at \(url.path)")
            return (originalData, originalMimeType)
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let longEdge = max(width, height)

        guard longEdge > maxLongEdge else {
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

        let bitmapRep = NSBitmapImageRep(cgImage: scaledCGImage)
        guard let scaledData = bitmapRep.representation(using: .png, properties: [:]) else {
            logger.log(content: "AI image scaling skipped: failed to encode scaled PNG for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        logger.log(content: "AI image scaled for upload: \(Int(width))x\(Int(height)) -> \(targetWidth)x\(targetHeight) [limit=\(UserSettings.shared.chatImageUploadLimit.rawValue)]")

        return (scaledData, "image/png")
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
        let systemPrompt = UserSettings.shared.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
        traceLabel: String
    ) async throws -> ChatCompletionResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ChatCompletionsRequest(model: model, messages: conversation)
        request.httpBody = try JSONEncoder().encode(payload)

        let requestURL = request.url?.absoluteString ?? "(nil)"
        logger.log(content: "AI Chat request -> POST \(requestURL), model=\(model), conversationMessages=\(conversation.count), trace=\(traceLabel), bodyBytes=\(request.httpBody?.count ?? 0)")
        appendAITrace(
            title: "\(traceLabel)_REQUEST",
            body: [
                "url: \(requestURL)",
                "model: \(model)",
                "conversationMessages: \(conversation.count)",
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

        logger.log(content: "AI Chat response <- status=\(http.statusCode), bytes=\(data.count), trace=\(traceLabel)")
        appendAITrace(
            title: "\(traceLabel)_RESPONSE",
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
                    summaries.append("capture_screen: success (file=\(fileURL.lastPathComponent))")
                    logger.log(content: "AI Tool executed: capture_screen -> \(fileURL.path)")
                } else {
                    summaries.append("capture_screen: failed (no image captured)")
                    logger.log(content: "AI Tool failed: capture_screen")
                }

            case "move_mouse":
                if let x = intArg(call.args["x"]), let y = intArg(call.args["y"]) {
                    let clampedX = clampAbsoluteCoordinate(x)
                    let clampedY = clampAbsoluteCoordinate(y)
                    HostManager.shared.handleAbsoluteMouseAction(x: clampedX, y: clampedY, mouseEvent: 0x00, wheelMovement: 0x00)
                    agentMouseX = clampedX
                    agentMouseY = clampedY
                    summaries.append("move_mouse: ok (x=\(clampedX), y=\(clampedY))")
                    logger.log(content: "AI Tool executed: move_mouse x=\(clampedX), y=\(clampedY) [abs 0...4096]")
                } else {
                    summaries.append("move_mouse: invalid args")
                    logger.log(content: "AI Tool failed: move_mouse invalid args")
                }

            case "left_click":
                let clickPoint = await click(button: 0x01, args: call.args)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "left_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("left_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("left_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: left_click at x=\(clickPoint.x), y=\(clickPoint.y)")

            case "right_click":
                let clickPoint = await click(button: 0x02, args: call.args)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "right_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("right_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("right_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: right_click at x=\(clickPoint.x), y=\(clickPoint.y)")

            case "double_click":
                let clickPoint = await click(button: 0x01, args: call.args)
                try? await Task.sleep(nanoseconds: 140_000_000)
                _ = await click(button: 0x01, args: call.args)
                if let annotatedURL = await captureAnnotatedClickForChat(absX: clickPoint.x, absY: clickPoint.y, actionName: "double_click") {
                    attachmentPath = annotatedURL.path
                    summaries.append("double_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=\(annotatedURL.lastPathComponent))")
                } else {
                    summaries.append("double_click: success (x=\(clickPoint.x), y=\(clickPoint.y), image=unavailable)")
                }
                logger.log(content: "AI Tool executed: double_click at x=\(clickPoint.x), y=\(clickPoint.y)")

            case "type_text":
                let text = (call.args["text"] as? String) ?? ""
                if text.isEmpty {
                    summaries.append("type_text: empty text")
                    logger.log(content: "AI Tool failed: type_text empty")
                } else {
                    KeyboardManager.shared.sendTextToKeyboard(text: text)
                    summaries.append("type_text: success (chars=\(text.count), text=\"\(text)\")")
                    logger.log(content: "AI Tool executed: type_text chars=\(text.count)")
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

    private func click(button: UInt8, args: [String: Any]) async -> (x: Int, y: Int) {
        let x = clampAbsoluteCoordinate(intArg(args["x"]) ?? agentMouseX)
        let y = clampAbsoluteCoordinate(intArg(args["y"]) ?? agentMouseY)
        agentMouseX = x
        agentMouseY = y

        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
        try? await Task.sleep(nanoseconds: 40_000_000)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        try? await Task.sleep(nanoseconds: 40_000_000)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
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
        let rep = NSBitmapImageRep(cgImage: annotatedCGImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        let outputDir = sourceURL.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileName = "\(actionName)_annotated_\(stamp).png"
        let outputURL = outputDir.appendingPathComponent(fileName)

        do {
            try pngData.write(to: outputURL, options: .atomic)
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

    private func appendAITrace(title: String, body: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: aiTraceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: aiTraceURL.path) {
                fileManager.createFile(atPath: aiTraceURL.path, contents: nil, attributes: nil)
            }

            let stamp = Self.traceDateFormatter.string(from: Date())
            let entry = "\n===== \(stamp) \(title) =====\n\(body)\n"
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
        userRequest: String,
        imageDataURL: String?
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: "Available task agent/tool pairs: screen/capture_screen, typing/type_text, mouse/move_mouse, mouse/left_click, mouse/right_click, mouse/double_click."))
        if !plannerPrompt.isEmpty {
            conversation.append(.text(role: .system, text: plannerPrompt))
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
        settings.screenAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
        settings.typingAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
                KeyboardManager.shared.sendTextToKeyboard(text: textToType)
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
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: true)
        Thread.sleep(forTimeInterval: 0.05)
        HostManager.shared.handleKeyboardEvent(keyCode: keyCode, modifierFlags: modifiers, isKeyDown: false)
        return true
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

private struct MouseTaskAgent: TaskAgentExecutor {
    private struct ResponsePayload: Decodable {
        let status: String
        let x: Int?
        let y: Int?
        let result_summary: String
    }

    let agentName: String = "mouse"
    let toolName: String

    func prompt(from settings: UserSettings) -> String {
        settings.screenAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
    - Always provide x and y in normalized target coordinates 0...4096.
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
        let targetX = clampAbsolute(rawX)
        let targetY = clampAbsolute(rawY)

        switch toolName {
        case "move_mouse":
            HostManager.shared.handleAbsoluteMouseAction(x: targetX, y: targetY, mouseEvent: 0x00, wheelMovement: 0x00)

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
            ? "Mouse task executed using \(toolName) at normalized coordinates (\(targetX), \(targetY))."
            : summary
    }

    private func performClick(button: UInt8, x: Int, y: Int, isDoubleClick: Bool) {
        // Give cursor movement and focus changes a brief moment to settle before click down.
        Thread.sleep(forTimeInterval: 0.08)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.06)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.08)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)

        guard isDoubleClick else { return }
        Thread.sleep(forTimeInterval: 0.12)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: button, wheelMovement: 0x00)
        Thread.sleep(forTimeInterval: 0.08)
        HostManager.shared.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: 0x00, wheelMovement: 0x00)
    }

    private func clampAbsolute(_ value: Int) -> Int {
        min(max(value, 0), 4096)
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
