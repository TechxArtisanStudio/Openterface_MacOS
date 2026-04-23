import Foundation

// MARK: - Public chat types used across the UI and managers

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

// MARK: - Internal types shared across ChatManager extensions

/// Returned by sendChatCompletion; bridged between the AI request layer and callers.
struct ChatCompletionResult {
    let content: String
    let inputTokenCount: Int?
    let outputTokenCount: Int?
}

/// Returned by executeToolCalls and forwarded into the agent loop conversation.
struct AgentToolExecutionResult {
    let summary: String
    let attachmentFilePath: String?
    /// Non-nil when every tool call in the batch was a keyboard-only action.
    /// Contains the joined text/key tokens so the UI can offer to save them as a macro.
    let keyboardOnlyMacroData: String?

    init(summary: String, attachmentFilePath: String?, keyboardOnlyMacroData: String? = nil) {
        self.summary = summary
        self.attachmentFilePath = attachmentFilePath
        self.keyboardOnlyMacroData = keyboardOnlyMacroData
    }
}

/// Resolved API credentials used in screen-capture refinement and other one-off requests.
struct ChatAPIConfiguration {
    let baseURL: URL
    let model: String
    let apiKey: String
}

/// Matched macro returned by conversation-builder macro lookup helpers.
struct VerifiedMacroMatch {
    let macro: Macro
    let matchedBy: String
}

/// Parsed agent tool call from the assistant's JSON response.
struct AgentToolCall {
    let tool: String
    let args: [String: Any]
}

/// Payload decoded from the task-state confirmation AI call.
struct TaskStateConfirmationPayload: Decodable {
    let confirmed: Bool
    let result_summary: String
}

/// Payload returned by the click-refinement AI call.
struct ClickTargetRefinementPayload: Decodable {
    let found: Bool?
    let x: Double?
    let y: Double?
    let matched_element: String?
    let confidence: Double?
}

/// Result of cropping a screenshot around a click target.
struct ClickRefinementCropResult {
    let imageURL: URL
    let sourceWidth: Int
    let sourceHeight: Int
    let cropOriginX: Int
    let cropOriginYTop: Int
    let cropWidth: Int
    let cropHeight: Int
}

/// Handles the continuation/observer pattern for single-frame screen captures.
@MainActor
final class CaptureScreenWaiter {
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

/// Decoded payload returned by the guide-mode API call.
struct GuideResponsePayload: Decodable {
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
