import Foundation

// MARK: - ChatContext
// Protocol that all ChatManager services depend on.
// ChatManager is the single conforming type; services hold a strong reference
// to it (intentional: ChatManager is a singleton that lives for the app lifetime).

@MainActor
protocol ChatContext: AnyObject {

    // MARK: - Published / mutable state

    var messages: [ChatMessage] { get set }
    var currentPlan: ChatExecutionPlan? { get set }
    var plannerTraceEntries: [ChatTaskTraceEntry] { get set }
    var taskStepTraces: [UUID: [ChatTaskTraceEntry]] { get set }
    /// Per-guide-message INPUT/OUTPUT prompt trace entries shown in GuideTraceDialog.
    var guidePromptTraces: [UUID: [ChatTaskTraceEntry]] { get set }
    /// Per-user-message REQUEST/RESPONSE prompt trace entries for standard/agentic chat.
    var agentPromptTraces: [UUID: [ChatTaskTraceEntry]] { get set }
    var lastError: String? { get set }
    var guideAutoNextStatuses: [UUID: GuideAutoNextStatus] { get set }
    var agentRequestStatuses: [UUID: GuideAutoNextStatus] { get set }
    var pendingGuideAutoNextStarts: [UUID: Date] { get set }
    var pendingAgentRequestStarts: [UUID: Date] { get set }

    // MARK: - Infrastructure

    var historyURL: URL { get }
    var aiTraceURL: URL { get }
    var encoder: JSONEncoder { get }
    var decoder: JSONDecoder { get }
    var logger: LoggerProtocol { get }

    // MARK: - Persistence (implemented by ChatPersistenceService via ChatManager)

    func persistHistory()

    // MARK: - Tracing (implemented by ChatTracingService via ChatManager)

    func appendAITrace(title: String, headerPrefix: String?, body: String)
    func appendTaskStepTrace(taskID: UUID, title: String, body: String, imageFilePath: String?)
    func appendPlannerTrace(title: String, body: String, imageFilePath: String?)

    // MARK: - Services (expose via protocol so routing/tool services can call them)

    var conversationBuilder: ChatConversationBuilderService { get }
    var tracing: ChatTracingService { get }
    var osVerification: ChatOSVerificationService { get }
    var screenCapture: ChatScreenCaptureService { get }
    var planExecution: ChatPlanExecutionService { get }

    // MARK: - Plan execution constants (ChatPlanExecutionService reads these)

    var taskAgentRegistry: TaskAgentRegistry { get }
    var taskStateConfirmationInstruction: String { get }
    var taskConfirmationAttemptCount: Int { get }
    var taskConfirmationRetryDelayNanoseconds: UInt64 { get }

    // MARK: - Routing state (ChatRoutingService reads and writes these)

    var isSending: Bool { get set }
    var currentTask: Task<Void, Never>? { get set }
    var guideCapturePathsByMessageID: [UUID: String] { get set }
    var plannerAgent: MainPlannerAgent { get }

    // MARK: - OS verification state (ChatOSVerificationService reads and writes these)

    var pendingPlanDetectedOS: ChatTargetSystem? { get set }
    var osContinuation: CheckedContinuation<Bool, Never>? { get set }

    // MARK: - Screen capture state (ChatScreenCaptureService reads and writes these)

    var pendingCapturePreviewSuppressions: Int { get set }

    // MARK: - Guide mode state (ChatGuideModeService reads and writes these)

    var agentMouseX: Int { get set }
    var agentMouseY: Int { get set }

    // MARK: - Methods still on ChatManager extensions (not yet extracted to services)
    // ChatRoutingService calls these via the context so it stays decoupled.

    func verifyAndConfirmTargetOS(baseURL: URL, model: String, apiKey: String) async -> Bool
    func captureScreenForAgent(timeoutSeconds: TimeInterval) async -> URL?
    func currentChatAPIConfiguration() -> ChatAPIConfiguration?
    func isGuideCompletionText(_ text: String) -> Bool
    func parseToolCalls(from text: String) -> [AgentToolCall]?
    func executeToolCalls(_ calls: [AgentToolCall]) async -> AgentToolExecutionResult
    func latestPlanningAttachmentURL(fallbackAttachmentPath: String?) async -> URL?
    func sendMessage(_ text: String, attachmentFileURL: URL?)
    func applyGuideOverlay(from targetBox: GuideResponsePayload.TargetBox?)
    func clearGuideOverlay()

    // MARK: - Tracing helpers (forwarded from ChatTracingService)

    func presentAIErrorToUser(_ message: String)
    func userFacingErrorMessage(from error: Error) -> String
    func startAgentRequestStatus(for messageID: UUID)
    func completeAgentRequestStatus(for messageID: UUID)
    func failAgentRequestStatus(for messageID: UUID, errorDescription: String)
    func cancelAgentRequestStatus(for messageID: UUID)
    func startGuideAutoNextStatus(for messageID: UUID)
    func completeGuideAutoNextStatus(for messageID: UUID)
    func failGuideAutoNextStatus(for messageID: UUID, errorDescription: String)
    func cancelGuideAutoNextStatus(for messageID: UUID)

    // MARK: - API (still on ChatManager until a dedicated APIClient service is extracted)

    func sendChatCompletion(
        baseURL: URL,
        model: String,
        apiKey: String,
        conversation: [ChatCompletionsRequest.Message],
        traceLabel: String,
        enableThinking: Bool?
    ) async throws -> ChatCompletionResult

    func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T
}

// MARK: - Default-parameter convenience

extension ChatContext {

    func appendAITrace(title: String, body: String) {
        appendAITrace(title: title, headerPrefix: nil, body: body)
    }

    func appendTaskStepTrace(taskID: UUID, title: String, body: String = "") {
        appendTaskStepTrace(taskID: taskID, title: title, body: body, imageFilePath: nil)
    }

    func appendPlannerTrace(title: String, body: String = "") {
        appendPlannerTrace(title: title, body: body, imageFilePath: nil)
    }

    func sendChatCompletion(
        baseURL: URL,
        model: String,
        apiKey: String,
        conversation: [ChatCompletionsRequest.Message],
        traceLabel: String
    ) async throws -> ChatCompletionResult {
        try await sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: traceLabel,
            enableThinking: nil
        )
    }

    func captureScreenForAgent() async -> URL? {
        await captureScreenForAgent(timeoutSeconds: 3.0)
    }

    func sendMessage(_ text: String) {
        sendMessage(text, attachmentFileURL: nil)
    }
}
