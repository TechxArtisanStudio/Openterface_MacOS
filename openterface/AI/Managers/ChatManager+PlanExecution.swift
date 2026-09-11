import Foundation

// MARK: - ChatManager + PlanExecution
// Stubs delegating to ChatPlanExecutionService.

extension ChatManager {

    func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try planExecution.decodeJSONPayload(type, from: text)
    }

    func executeApprovedPlan() async {
        await planExecution.executeApprovedPlan()
    }

    func executeTask(at index: Int, in plan: ChatExecutionPlan, baseURL: URL, model: String, apiKey: String, systemPrompt: String) async throws -> ChatExecutionPlan {
        try await planExecution.executeTask(at: index, in: plan, baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt)
    }

    func confirmTaskState(task: ChatTask, plan: ChatExecutionPlan, postCaptureURL: URL, baseURL: URL, model: String, apiKey: String, systemPrompt: String, traceLabel: String) async throws -> String {
        try await planExecution.confirmTaskState(task: task, plan: plan, postCaptureURL: postCaptureURL, baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt, traceLabel: traceLabel)
    }

    func finalPlanSummary(for plan: ChatExecutionPlan) -> String {
        planExecution.finalPlanSummary(for: plan)
    }

    func latestPlanningAttachmentURL(fallbackAttachmentPath: String?) async -> URL? {
        await planExecution.latestPlanningAttachmentURL(fallbackAttachmentPath: fallbackAttachmentPath)
    }

    func sendChatCompletion(baseURL: URL, model: String, apiKey: String, conversation: [ChatCompletionsRequest.Message], traceLabel: String, enableThinking: Bool?) async throws -> ChatCompletionResult {
        try await planExecution.sendChatCompletion(baseURL: baseURL, model: model, apiKey: apiKey, conversation: conversation, traceLabel: traceLabel, enableThinking: enableThinking)
    }
}

