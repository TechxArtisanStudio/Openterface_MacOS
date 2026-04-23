import SwiftUI
import AppKit

@MainActor
final class ChatManager: ObservableObject, ChatContext, ChatManagerProtocol {
    static let shared = ChatManager()

    // MARK: - Services
    // Each service owns a specific slice of ChatManager's behavior.
    // They depend on ChatManager through the ChatContext protocol.
    private(set) lazy var persistence          = ChatPersistenceService(context: self)
    private(set) lazy var tracing              = ChatTracingService(context: self)
    private(set) lazy var macroGeneration      = ChatMacroGenerationService(context: self)
    private(set) lazy var conversationBuilder  = ChatConversationBuilderService(context: self)
    private(set) lazy var routing              = ChatRoutingService(context: self)
    private(set) lazy var osVerification       = ChatOSVerificationService(context: self)
    private(set) lazy var screenCapture         = ChatScreenCaptureService(context: self)
    private(set) lazy var guideMode             = ChatGuideModeService(context: self)
    private(set) lazy var planExecution         = ChatPlanExecutionService(context: self)
    private(set) lazy var toolExecution         = ChatToolExecutionService(context: self)

    @Published var messages: [ChatMessage] = []
    @Published var isSending: Bool = false
    @Published var lastError: String?
    @Published var currentPlan: ChatExecutionPlan?
    @Published var plannerTraceEntries: [ChatTaskTraceEntry] = []
    @Published var guideAutoNextStatuses: [UUID: GuideAutoNextStatus] = [:]
    @Published var agentRequestStatuses: [UUID: GuideAutoNextStatus] = [:]
    /// The OS detected by the pre-execution screen scan. Non-nil while `currentPlan.status == .awaitingOSConfirmation`.
    @Published var pendingPlanDetectedOS: ChatTargetSystem?

    /// Continuation suspended during OS confirmation; resumed by `confirmPlanOS(confirmed:newSystem:)`.
    var osContinuation: CheckedContinuation<Bool, Never>?

    var currentTask: Task<Void, Never>?
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let historyURL: URL
    let aiTraceURL: URL
    var logger: LoggerProtocol { DependencyContainer.shared.resolve(LoggerProtocol.self) }
    let plannerAgent = MainPlannerAgent(maxPlannerTasks: 6)
    let taskAgentRegistry = TaskAgentRegistry(agents: [
        ScreenTaskAgent(),
        TypeTextTaskAgent(),
        MacroTaskAgent(),
        MouseTaskAgent(toolName: "move_mouse"),
        MouseTaskAgent(toolName: "left_click"),
        MouseTaskAgent(toolName: "right_click"),
        MouseTaskAgent(toolName: "double_click"),
        MouseTaskAgent(toolName: "left_drag")
    ])
    let taskStateConfirmationInstruction = """
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
    let taskConfirmationAttemptCount = 3
    let taskConfirmationRetryDelayNanoseconds: UInt64 = 900_000_000
    // macroGeneratorSupportedTokens and macroGenerationInstruction moved to ChatMacroGenerationService
    var agentMouseX: Int = 2048
    var agentMouseY: Int = 2048
    var pendingCapturePreviewSuppressions = 0
    var taskStepTraces: [UUID: [ChatTaskTraceEntry]] = [:]
    var guidePromptTraces: [UUID: [ChatTaskTraceEntry]] = [:]
    var agentPromptTraces: [UUID: [ChatTaskTraceEntry]] = [:]
    var guideCapturePathsByMessageID: [UUID: String] = [:]
    var pendingGuideAutoNextStarts: [UUID: Date] = [:]
    var pendingAgentRequestStarts: [UUID: Date] = [:]
    // agentToolInstruction moved to ChatConversationBuilderService
    // AgentToolCall moved to ChatManagerTypes.swift



    // TaskStateConfirmationPayload moved to ChatManagerTypes.swift
    // ClickTargetRefinementPayload moved to ChatManagerTypes.swift
    // ClickRefinementCropResult moved to ChatManagerTypes.swift
    // GuideResponsePayload moved to ChatManagerTypes.swift

    struct PersistedTaskTrace: Codable {
        let taskID: UUID
        let entries: [ChatTaskTraceEntry]
    }

    struct PersistedChatState: Codable {
        let messages: [ChatMessage]
        let currentPlan: ChatExecutionPlan?
        let plannerTraceEntries: [ChatTaskTraceEntry]
        let taskTraces: [PersistedTaskTrace]
    }

    // VerifiedMacroMatch moved to ChatManagerTypes.swift
    // CaptureScreenWaiter moved to ChatManagerTypes.swift

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

    func currentChatAPIConfiguration() -> ChatAPIConfiguration? {
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

    func sendMessage(_ text: String, attachmentFileURL: URL? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachmentFileURL != nil else { return }
        guard !isSending else { return }

        lastError = nil
        let storedContent = trimmed.isEmpty ? "Attached screenshot" : trimmed
        let messageID = UUID()
        messages.append(ChatMessage(id: messageID, role: .user, content: storedContent, attachmentFilePath: attachmentFileURL?.path))
        if UserSettings.shared.isChatAgenticModeEnabled {
            startAgentRequestStatus(for: messageID)
        }
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

    /// Handle a quick-reply chip tap: submit the chip's sendText as a user message.
    func sendQuickReply(_ reply: ChatQuickReply) {
        sendMessage(reply.sendText)
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

            let messageID = UUID()
            self.messages.append(ChatMessage(
                id: messageID,
                role: .user,
                content: skill.prompt,
                attachmentFilePath: screenshotURL?.path
            ))
            if UserSettings.shared.isChatAgenticModeEnabled {
                self.startAgentRequestStatus(for: messageID)
            }
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
        guidePromptTraces.removeAll()
        agentPromptTraces.removeAll()
        guideCapturePathsByMessageID.removeAll()
        guideAutoNextStatuses.removeAll()
        agentRequestStatuses.removeAll()
        pendingGuideAutoNextStarts.removeAll()
        pendingAgentRequestStarts.removeAll()
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

    func bubbleStatus(for messageID: UUID) -> GuideAutoNextStatus? {
        if let guideStatus = guideAutoNextStatuses[messageID] {
            return guideStatus
        }

        guard let agentRequestMessageID = agentRequestMessageID(forBubbleMessageID: messageID),
              let agentStatus = agentRequestStatuses[agentRequestMessageID] else {
            return nil
        }

        return preferredAgentStatusBubbleMessageID(for: agentRequestMessageID) == messageID
            ? agentStatus
            : nil
    }

    private func agentRequestMessageID(forBubbleMessageID messageID: UUID) -> UUID? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        let message = messages[messageIndex]
        if message.role == .user {
            return agentRequestStatuses[messageID] != nil ? messageID : nil
        }

        guard message.role == .assistant else {
            return nil
        }

        guard messageIndex > 0,
              let precedingUserIndex = messages[..<messageIndex].lastIndex(where: { $0.role == .user }) else {
            return nil
        }

        let requestMessageID = messages[precedingUserIndex].id
        return agentRequestStatuses[requestMessageID] != nil ? requestMessageID : nil
    }

    private func preferredAgentStatusBubbleMessageID(for requestMessageID: UUID) -> UUID {
        guard let requestIndex = messages.firstIndex(where: { $0.id == requestMessageID }) else {
            return requestMessageID
        }

        let assistantSearchStart = requestIndex + 1
        guard assistantSearchStart < messages.endIndex else {
            return requestMessageID
        }

        let nextUserIndex = messages[assistantSearchStart..<messages.endIndex].firstIndex(where: { $0.role == .user }) ?? messages.endIndex
        guard assistantSearchStart < nextUserIndex else {
            return requestMessageID
        }

        let latestAssistantMessageID = messages[assistantSearchStart..<nextUserIndex]
            .last(where: { $0.role == .assistant })?
            .id

        return latestAssistantMessageID ?? requestMessageID
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
        return tracedMessages.enumerated().flatMap { index, msg -> [ChatTaskTraceEntry] in
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

            let stepEntry = ChatTaskTraceEntry(
                title: "Step \(index + 1)",
                body: bodyLines.joined(separator: "\n"),
                imageFilePath: guideCapturePathsByMessageID[msg.id]
            )
            let promptEntries = guidePromptTraces[msg.id] ?? []
            return [stepEntry] + promptEntries
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
            guidePromptTraces.removeAll()
            agentPromptTraces.removeAll()
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

        // Find the request/response entries for this specific message
        let traceEntries = agentPromptTraces[messageID]

        if let entries = traceEntries, !entries.isEmpty {
            for entry in entries {
                lines.append("")
                lines.append("--- \(entry.title) ---")
                lines.append(entry.body)
            }
        }
        
        let traceContent = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log(content: "Message Trace generated for message id=\(messageID)")
        return traceContent
    }

}
