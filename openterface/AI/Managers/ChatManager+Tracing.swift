import Foundation

// MARK: - ChatManager + Tracing (thin delegation stub)
// Logic lives in ChatTracingService (AI/Services/ChatTracingService.swift).
// ChatManager retains these entry points for backward-compatible call sites and
// to satisfy the ChatContext protocol requirements.

extension ChatManager {

    // MARK: - Trace appenders (ChatContext requirements)

    func appendTaskStepTrace(taskID: UUID, title: String, body: String = "", imageFilePath: String? = nil) {
        tracing.appendTaskStepTrace(taskID: taskID, title: title, body: body, imageFilePath: imageFilePath)
    }

    func appendPlannerTrace(title: String, body: String = "", imageFilePath: String? = nil) {
        tracing.appendPlannerTrace(title: title, body: body, imageFilePath: imageFilePath)
    }

    func appendAITrace(title: String, headerPrefix: String? = nil, body: String) {
        tracing.appendAITrace(title: title, headerPrefix: headerPrefix, body: body)
    }

    // MARK: - Readable formatting helpers

    func readableTraceParts(from messages: [ChatCompletionsRequest.Message]) -> String {
        tracing.readableTraceParts(from: messages)
    }

    func traceBodyForLogging(data: Data, contentType: String?) -> String {
        tracing.traceBodyForLogging(data: data, contentType: contentType)
    }

    // MARK: - Guide trace helpers

    func guideActionDescription(for message: ChatMessage) -> String { tracing.guideActionDescription(for: message) }
    func guideShortcutText(for message: ChatMessage) -> String?      { tracing.guideShortcutText(for: message) }
    func guideTargetBoxText(for message: ChatMessage) -> String?     { tracing.guideTargetBoxText(for: message) }
    func guideTimestampText(_ date: Date) -> String                  { tracing.guideTimestampText(date) }

    // MARK: - Static helpers (forwarded from service)

    static func makeTraceURL(fileName: String) -> URL { ChatTracingService.makeTraceURL(fileName: fileName) }
    static func traceDurationHeader(from duration: TimeInterval) -> String { ChatTracingService.traceDurationHeader(from: duration) }

    // MARK: - Error presentation

    func presentAIErrorToUser(_ message: String)              { tracing.presentAIErrorToUser(message) }
    func userFacingErrorMessage(from error: Error) -> String  { tracing.userFacingErrorMessage(from: error) }

    // MARK: - Agent request status lifecycle

    func startAgentRequestStatus(for messageID: UUID)                                    { tracing.startAgentRequestStatus(for: messageID) }
    func completeAgentRequestStatus(for messageID: UUID)                                 { tracing.completeAgentRequestStatus(for: messageID) }
    func failAgentRequestStatus(for messageID: UUID, errorDescription: String)           { tracing.failAgentRequestStatus(for: messageID, errorDescription: errorDescription) }
    func cancelAgentRequestStatus(for messageID: UUID)                                   { tracing.cancelAgentRequestStatus(for: messageID) }

    // MARK: - Guide auto-next status lifecycle

    func startGuideAutoNextStatus(for messageID: UUID)                                   { tracing.startGuideAutoNextStatus(for: messageID) }
    func completeGuideAutoNextStatus(for messageID: UUID)                                { tracing.completeGuideAutoNextStatus(for: messageID) }
    func failGuideAutoNextStatus(for messageID: UUID, errorDescription: String)          { tracing.failGuideAutoNextStatus(for: messageID, errorDescription: errorDescription) }
    func cancelGuideAutoNextStatus(for messageID: UUID)                                  { tracing.cancelGuideAutoNextStatus(for: messageID) }
}
