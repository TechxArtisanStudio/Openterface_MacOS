import Foundation

// MARK: - ChatPlanExecutionService
// Multi-step plan execution: run approved plans, individual tasks, state-confirmation,
// the core sendChatCompletion HTTP call, and the decodeJSONPayload helper.
// Previously in ChatManager+PlanExecution.swift.
// Accessed through ChatManager's `planExecution` property.

@MainActor
final class ChatPlanExecutionService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - JSON decode helper

    func decodeJSONPayload<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else {
            throw NSError(domain: "ChatManager", code: 12, userInfo: [NSLocalizedDescriptionKey: "Assistant response did not contain JSON"])
        }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else {
            throw NSError(domain: "ChatManager", code: 13, userInfo: [NSLocalizedDescriptionKey: "Assistant JSON response was not UTF-8"])
        }
        return try context.decoder.decode(T.self, from: data)
    }

    // MARK: - Plan execution

    func executeApprovedPlan() async {
        defer {
            context.isSending  = false
            context.currentTask = nil
        }

        guard var plan = context.currentPlan else { return }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model         = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt  = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey        = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey

        guard !baseURLString.isEmpty,
              let baseURL = URL(string: baseURLString),
              !model.isEmpty,
              !apiKey.isEmpty else {
            context.lastError = "Chat settings are incomplete"
            return
        }

        let osVerified = await context.verifyAndConfirmTargetOS(baseURL: baseURL, model: model, apiKey: apiKey)
        guard osVerified, !Task.isCancelled else { return }

        plan.status = .running
        context.currentPlan = plan
        context.persistHistory()

        do {
            for index in plan.tasks.indices {
                if Task.isCancelled { return }
                plan = try await executeTask(
                    at: index,
                    in: plan,
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt
                )
                context.currentPlan = plan
                context.persistHistory()
            }

            plan.status = plan.tasks.contains(where: { $0.status == .failed }) ? .failed : .completed
            context.currentPlan = plan
            context.messages.append(ChatMessage(
                role: .assistant,
                content: finalPlanSummary(for: plan),
                quickReplies: nextActionQuickReplies(for: plan)
            ))
            context.persistHistory()
        } catch {
            if Task.isCancelled { return }
            context.logger.log(content: "AI task-agent execution failed: \(error.localizedDescription)")
            context.appendAITrace(title: "TASK_AGENT_ERROR", body: error.localizedDescription)
            context.presentAIErrorToUser(context.userFacingErrorMessage(from: error))

            if var failedPlan = context.currentPlan {
                failedPlan.status = .failed
                context.currentPlan = failedPlan
                context.persistHistory()
            }
        }
    }

    // MARK: - Individual task execution

    func executeTask(
        at index: Int,
        in plan: ChatExecutionPlan,
        baseURL: URL,
        model: String,
        apiKey: String,
        systemPrompt: String
    ) async throws -> ChatExecutionPlan {
        var updatedPlan = plan
        let taskID = updatedPlan.tasks[index].id
        context.appendTaskStepTrace(
            taskID: taskID,
            title: "Task started",
            body: "\(updatedPlan.tasks[index].title) [agent=\(updatedPlan.tasks[index].agentName), tool=\(updatedPlan.tasks[index].toolName)]"
        )

        guard let taskAgent = context.taskAgentRegistry.resolve(for: updatedPlan.tasks[index]) else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = "No task agent registered for agent=\(updatedPlan.tasks[index].agentName), tool=\(updatedPlan.tasks[index].toolName)."
            context.appendTaskStepTrace(taskID: taskID, title: "Failed", body: updatedPlan.tasks[index].resultSummary ?? "Unknown error")
            throw NSError(domain: "ChatManager", code: 6, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Unsupported task agent"])
        }

        guard let preCaptureURL = await context.captureScreenForAgent() else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = "Task aborted: unable to capture pre-task screen state."
            context.appendTaskStepTrace(taskID: taskID, title: "Failed", body: "Pre-task capture unavailable")
            context.currentPlan = updatedPlan
            context.persistHistory()
            throw NSError(domain: "ChatManager", code: 7, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Pre-task capture failed"])
        }
        context.appendTaskStepTrace(taskID: taskID, title: "Pre-task capture", body: preCaptureURL.lastPathComponent, imageFilePath: preCaptureURL.path)

        updatedPlan.tasks[index].status = .running
        context.currentPlan = updatedPlan
        context.persistHistory()

        let conversation = taskAgent.buildTaskConversation(
            systemPrompt: systemPrompt,
            taskPrompt: taskAgent.prompt(from: UserSettings.shared),
            plan: updatedPlan,
            task: updatedPlan.tasks[index],
            imageDataURL: context.conversationBuilder.dataURLForImage(atPath: preCaptureURL.path)
        )
        context.appendTaskStepTrace(taskID: taskID, title: "Task-agent request", body: context.tracing.readableTraceParts(from: conversation))
        let response = try await context.sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: "TASK_AGENT_\(index + 1)"
        )
        updatedPlan.tasks[index].inputTokenCount  = response.inputTokenCount
        updatedPlan.tasks[index].outputTokenCount = response.outputTokenCount
        context.appendTaskStepTrace(taskID: taskID, title: "Task-agent response", body: response.content)
        if let inputTokenCount = response.inputTokenCount, let outputTokenCount = response.outputTokenCount {
            context.appendTaskStepTrace(taskID: taskID, title: "Task-agent tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
        }
        context.currentPlan = updatedPlan
        context.persistHistory()

        taskAgent.applyResponse(response.content, to: &updatedPlan.tasks[index])

        if updatedPlan.tasks[index].status == .failed {
            context.appendTaskStepTrace(taskID: taskID, title: "Failed", body: updatedPlan.tasks[index].resultSummary ?? "Task agent execution failed")
            context.currentPlan = updatedPlan
            context.persistHistory()
            throw NSError(domain: "ChatManager", code: 8, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Task agent execution failed"])
        }

        var confirmationErrors: [String] = []
        var isConfirmed = false
        for attempt in 1...context.taskConfirmationAttemptCount {
            if attempt > 1 {
                context.appendTaskStepTrace(taskID: taskID, title: "Confirmation retry", body: "Attempt \(attempt)/\(context.taskConfirmationAttemptCount): waiting for UI state to settle")
                try? await Task.sleep(nanoseconds: context.taskConfirmationRetryDelayNanoseconds)
            }

            guard let postCaptureURL = await context.captureScreenForAgent() else {
                let reason = "Attempt \(attempt): post-task capture unavailable"
                confirmationErrors.append(reason)
                context.appendTaskStepTrace(taskID: taskID, title: "Verification capture failed", body: reason)
                continue
            }
            context.appendTaskStepTrace(
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
                context.appendTaskStepTrace(taskID: taskID, title: "Verification succeeded", body: "Attempt \(attempt): \(confirmationSummary)")
                isConfirmed = true
                break
            } catch {
                let reason = "Attempt \(attempt): confirmation failed: \(error.localizedDescription)"
                confirmationErrors.append(reason)
                context.appendTaskStepTrace(taskID: taskID, title: "Verification failed", body: reason)
            }
        }

        guard isConfirmed else {
            updatedPlan.tasks[index].status = .failed
            updatedPlan.tasks[index].resultSummary = confirmationErrors.isEmpty
                ? "Task state confirmation failed"
                : confirmationErrors.joined(separator: " | ")
            context.appendTaskStepTrace(taskID: taskID, title: "Failed", body: "Failed after \(context.taskConfirmationAttemptCount) confirmation attempt(s)")
            context.currentPlan = updatedPlan
            context.persistHistory()
            throw NSError(domain: "ChatManager", code: 9, userInfo: [NSLocalizedDescriptionKey: updatedPlan.tasks[index].resultSummary ?? "Post-task confirmation failed"])
        }

        context.appendTaskStepTrace(taskID: taskID, title: "Task completed", body: updatedPlan.tasks[index].resultSummary ?? "")
        return updatedPlan
    }

    // MARK: - Task-state confirmation

    func confirmTaskState(
        task: ChatTask,
        plan: ChatExecutionPlan,
        postCaptureURL: URL,
        baseURL: URL,
        model: String,
        apiKey: String,
        systemPrompt: String,
        traceLabel: String
    ) async throws -> String {
        guard let imageDataURL = context.conversationBuilder.dataURLForImage(atPath: postCaptureURL.path) else {
            throw NSError(domain: "ChatManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unable to encode post-task screenshot for state confirmation"])
        }

        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: context.taskStateConfirmationInstruction))

        let verifyInstruction = "Plan summary: \(plan.summary)\nTask title: \(task.title)\nTask detail: \(task.detail)\nAgent: \(task.agentName)\nTool: \(task.toolName)\n\nVerify whether the current state confirms the task outcome. Return confirmed=false if uncertain."
        conversation.append(.multimodal(role: .user, text: verifyInstruction, imageDataURL: imageDataURL))
        context.appendTaskStepTrace(taskID: task.id, title: "Verification request", body: context.tracing.readableTraceParts(from: conversation), imageFilePath: postCaptureURL.path)

        let response = try await context.sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: traceLabel
        )
        context.appendTaskStepTrace(taskID: task.id, title: "Verification response", body: response.content)
        if let inputTokenCount = response.inputTokenCount, let outputTokenCount = response.outputTokenCount {
            context.appendTaskStepTrace(taskID: task.id, title: "Verification tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
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

    // MARK: - Helpers

    func finalPlanSummary(for plan: ChatExecutionPlan) -> String {
        let lines = plan.tasks.enumerated().map { offset, task in
            let status = task.status.rawValue.replacingOccurrences(of: "_", with: " ")
            let result = task.resultSummary?.isEmpty == false ? task.resultSummary! : "No result recorded."
            return "\(offset + 1). [\(status)] \(task.title): \(result)"
        }
        return "Plan completed: \(plan.summary)\n\n" + lines.joined(separator: "\n")
    }

    /// Build quick-reply chips for a successfully completed plan.
    private func nextActionQuickReplies(for plan: ChatExecutionPlan) -> [ChatQuickReply] {
        guard !plan.tasks.contains(where: { $0.status == .failed }) else { return [] }
        return [
            ChatQuickReply(label: "Repeat this plan", sendText: "Please repeat the same plan: \(plan.summary)"),
            ChatQuickReply(label: "Take a screenshot", sendText: "Take a screenshot to show current state"),
            ChatQuickReply(label: "Something else…", sendText: "")
        ]
    }

    func latestPlanningAttachmentURL(fallbackAttachmentPath: String?) async -> URL? {
        if let liveCapture = await context.captureScreenForAgent() { return liveCapture }
        if let fallbackAttachmentPath { return URL(fileURLWithPath: fallbackAttachmentPath) }
        return nil
    }

    // MARK: - Core API call

    func sendChatCompletion(
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
        context.logger.log(content: "AI Chat request -> POST \(requestURL), model=\(model), conversationMessages=\(conversation.count), trace=\(traceLabel), bodyBytes=\(request.httpBody?.count ?? 0)")
        context.appendAITrace(
            title: "\(traceLabel)_REQUEST",
            body: [
                "url: \(requestURL)",
                "model: \(model)",
                "conversationMessages: \(conversation.count)",
                "timeoutSeconds: \(Int(request.timeoutInterval))",
                "bodyBytes: \(request.httpBody?.count ?? 0)",
                "readableParts:",
                context.tracing.readableTraceParts(from: conversation)
            ].joined(separator: "\n")
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChatManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        let responseDuration = Date().timeIntervalSince(requestStartedAt)

        context.logger.log(content: "AI Chat response <- status=\(http.statusCode), bytes=\(data.count), trace=\(traceLabel)")
        context.appendAITrace(
            title: "\(traceLabel)_RESPONSE",
            headerPrefix: ChatTracingService.traceDurationHeader(from: responseDuration),
            body: [
                "status: \(http.statusCode)",
                "contentType: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")",
                "responseTimeSeconds: \(String(format: "%.3f", responseDuration))",
                "bytes: \(data.count)",
                "body:",
                context.tracing.traceBodyForLogging(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
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
            inputTokenCount:  decoded.usage?.promptTokens,
            outputTokenCount: decoded.usage?.completionTokens
        )
    }
}
