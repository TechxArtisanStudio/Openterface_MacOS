import Foundation

// MARK: - ChatRoutingService
// Owns the three main send paths: standard/agentic, multi-agent planner, and guide-mode.
// Previously in ChatManager+ChatRouting.swift.
// Accessed through ChatManager's `routing` property.

@MainActor
final class ChatRoutingService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Dispatch

    func performSend() async {
        let agenticEnabled = UserSettings.shared.isChatAgenticModeEnabled
        let pendingAgentStatusMessageID = agenticEnabled ? context.messages.last(where: { $0.role == .user })?.id : nil

        enum AgentRequestStatusDisposition {
            case none
            case completed
            case failed(String)
            case cancelled
        }

        var agentRequestStatusDisposition: AgentRequestStatusDisposition = .none

        defer {
            if let pendingAgentStatusMessageID {
                switch agentRequestStatusDisposition {
                case .none:
                    if Task.isCancelled { context.cancelAgentRequestStatus(for: pendingAgentStatusMessageID) }
                case .completed:
                    context.completeAgentRequestStatus(for: pendingAgentStatusMessageID)
                case .failed(let errorDescription):
                    context.failAgentRequestStatus(for: pendingAgentStatusMessageID, errorDescription: errorDescription)
                case .cancelled:
                    context.cancelAgentRequestStatus(for: pendingAgentStatusMessageID)
                }
            }
            context.isSending   = false
            context.currentTask = nil
        }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model         = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt  = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let guideModeEnabled = UserSettings.shared.isChatGuideModeEnabled

        if !guideModeEnabled { context.clearGuideOverlay() }

        guard !baseURLString.isEmpty, let baseURL = URL(string: baseURLString) else {
            agentRequestStatusDisposition = .failed("Invalid Chat API base URL")
            context.presentAIErrorToUser("Invalid Chat API base URL")
            context.logger.log(content: "AI Chat request aborted: invalid base URL -> \(baseURLString)")
            return
        }

        guard !model.isEmpty else {
            agentRequestStatusDisposition = .failed("Chat model is empty")
            context.presentAIErrorToUser("Chat model is empty")
            context.logger.log(content: "AI Chat request aborted: model is empty")
            return
        }

        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey
        guard !apiKey.isEmpty else {
            agentRequestStatusDisposition = .failed("Missing AI API key in Settings")
            context.presentAIErrorToUser("Missing AI API key in Settings")
            context.logger.log(content: "AI Chat request aborted: missing API key")
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

        // --- Standard / agentic loop ---

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var workingMessages = context.messages
        let latestUserMessage = context.messages.last(where: { $0.role == .user })

        if agenticEnabled {
            let osOK = await context.verifyAndConfirmTargetOS(baseURL: baseURL, model: model, apiKey: apiKey)
            guard osOK, !Task.isCancelled else {
                agentRequestStatusDisposition = .cancelled
                return
            }
        }

        var lastKeyboardOnlyMacroData: String? = nil
        do {
            let maxAgentIterations = UserSettings.shared.chatAgentMaxIterations
            for iteration in 1...maxAgentIterations {
                let conversation = context.conversationBuilder.buildConversation(
                    systemPrompt: systemPrompt,
                    sourceMessages: workingMessages,
                    includeAgentTools: agenticEnabled
                )
                let payload = ChatCompletionsRequest(model: model, messages: conversation)
                request.httpBody = try JSONEncoder().encode(payload)

                let attachmentCount = workingMessages.filter { $0.attachmentFilePath != nil }.count
                let requestURL = request.url?.absoluteString ?? "(nil)"
                context.logger.log(content: "AI Chat request -> POST \(requestURL), model=\(model), conversationMessages=\(conversation.count), attachments=\(attachmentCount), iteration=\(iteration), bodyBytes=\(request.httpBody?.count ?? 0)")
                context.appendAITrace(
                    title: "REQUEST iteration=\(iteration)",
                    body: [
                        "url: \(requestURL)",
                        "model: \(model)",
                        "conversationMessages: \(conversation.count)",
                        "attachments: \(attachmentCount)",
                        "bodyBytes: \(request.httpBody?.count ?? 0)",
                        "readableParts:",
                        context.tracing.readableTraceParts(from: conversation)
                    ].joined(separator: "\n")
                )
                let iterationReadableParts = context.tracing.readableTraceParts(from: conversation)

                let (data, response) = try await URLSession.shared.data(for: request)
                if Task.isCancelled { return }

                guard let http = response as? HTTPURLResponse else {
                    agentRequestStatusDisposition = .failed("Invalid server response")
                    context.presentAIErrorToUser("Invalid server response")
                    context.logger.log(content: "AI Chat response error: non-HTTP response")
                    return
                }

                context.logger.log(content: "AI Chat response <- status=\(http.statusCode), bytes=\(data.count), iteration=\(iteration)")
                context.appendAITrace(
                    title: "RESPONSE iteration=\(iteration)",
                    body: [
                        "status: \(http.statusCode)",
                        "contentType: \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown")",
                        "bytes: \(data.count)",
                        "body:",
                        context.tracing.traceBodyForLogging(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
                    ].joined(separator: "\n")
                )

                guard (200...299).contains(http.statusCode) else {
                    let body    = String(data: data, encoding: .utf8) ?? ""
                    let snippet = String(body.prefix(500))
                    context.logger.log(content: "AI Chat response error body: \(snippet)")
                    let detail    = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = detail.isEmpty
                        ? "Chat API error \(http.statusCode)."
                        : "Chat API error \(http.statusCode): \(detail)"
                    agentRequestStatusDisposition = .failed(errorText)
                    context.presentAIErrorToUser(errorText)
                    return
                }

                let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
                guard let assistantText = decoded.choices.first?.message.content, !assistantText.isEmpty else {
                    agentRequestStatusDisposition = .failed("Empty assistant response")
                    context.presentAIErrorToUser("Empty assistant response")
                    context.logger.log(content: "AI Chat response decode succeeded but assistant content is empty")
                    return
                }

                context.logger.log(content: "AI Chat assistant response received: chars=\(assistantText.count), iteration=\(iteration)")

                if agenticEnabled, let toolCalls = context.parseToolCalls(from: assistantText), !toolCalls.isEmpty {
                    context.logger.log(content: "AI Chat agentic tool call count=\(toolCalls.count), iteration=\(iteration)")
                    let toolResult = await context.executeToolCalls(toolCalls)
                    lastKeyboardOnlyMacroData = toolResult.keyboardOnlyMacroData
                    context.appendAITrace(title: "TOOL_RESULT iteration=\(iteration)", body: toolResult.summary)
                    workingMessages.append(ChatMessage(role: .assistant, content: assistantText))
                    let toolResultMessage = ChatMessage(
                        role: .user,
                        content: "TOOL_RESULT:\n\(toolResult.summary)",
                        attachmentFilePath: toolResult.attachmentFilePath
                    )
                    workingMessages.append(toolResultMessage)
                    let toolMsgID = UUID()
                    context.agentPromptTraces[toolMsgID] = [
                        ChatTaskTraceEntry(title: "Request (iteration \(iteration))", body: iterationReadableParts),
                        ChatTaskTraceEntry(title: "Response (iteration \(iteration))", body: assistantText)
                    ]
                    context.messages.append(ChatMessage(
                        id: toolMsgID,
                        role: .assistant,
                        content: "Tool result:\n\(toolResult.summary)",
                        attachmentFilePath: toolResult.attachmentFilePath
                    ))
                    context.persistHistory()
                    continue
                }

                agentRequestStatusDisposition = .completed
                var completionReplies = agenticEnabled ? nextActionQuickReplies() : []
                if let macroData = lastKeyboardOnlyMacroData {
                    let truncated = macroData.count > 200 ? String(macroData.prefix(200)) + "…" : macroData
                    completionReplies.insert(
                        ChatQuickReply(label: "⌨️ Save as macro", sendText: "Save the keyboard sequence \"\(truncated)\" as a new macro"),
                        at: 0
                    )
                }
                let finalMsgID = UUID()
                context.agentPromptTraces[finalMsgID] = [
                    ChatTaskTraceEntry(title: "Request (iteration \(iteration))", body: iterationReadableParts),
                    ChatTaskTraceEntry(title: "Response (iteration \(iteration))", body: assistantText)
                ]
                context.messages.append(ChatMessage(
                    id: finalMsgID,
                    role: .assistant,
                    content: assistantText,
                    quickReplies: completionReplies
                ))
                context.persistHistory()
                return
            }

            let timeoutMessage = "I reached the configured Agent Mode iteration limit (\(UserSettings.shared.chatAgentMaxIterations)) and still need guidance to continue. Please provide a fresh screenshot, raise the iteration limit, or use a verified macro if one matches the task."
            agentRequestStatusDisposition = .completed
            context.messages.append(ChatMessage(role: .assistant, content: timeoutMessage))
            context.persistHistory()
        } catch {
            if Task.isCancelled {
                agentRequestStatusDisposition = .cancelled
                return
            }
            context.logger.log(content: "AI Chat request failed with error: \(error.localizedDescription)")
            context.appendAITrace(title: "ERROR", body: error.localizedDescription)
            let errorMessage = context.userFacingErrorMessage(from: error)
            agentRequestStatusDisposition = .failed(errorMessage)
            context.presentAIErrorToUser(errorMessage)
        }
    }

    // MARK: - Quick-reply suggestions

    private func nextActionQuickReplies() -> [ChatQuickReply] {
        [
            ChatQuickReply(label: "Take a screenshot", sendText: "Take a screenshot to show current state"),
            ChatQuickReply(label: "Repeat last task",  sendText: "Please repeat the previous task"),
            ChatQuickReply(label: "Something else…",   sendText: "")
        ]
    }

    // MARK: - Multi-agent planner

    func performMultiAgentSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async {
        guard let latestUserMessage = context.messages.last(where: { $0.role == .user }) else {
            context.lastError = "Missing user request"
            return
        }

        do {
            context.plannerTraceEntries.removeAll()
            let planningAttachment = await context.latestPlanningAttachmentURL(fallbackAttachmentPath: latestUserMessage.attachmentFilePath)
            if let planningAttachment {
                context.appendPlannerTrace(
                    title: "Planning screen",
                    body: planningAttachment.lastPathComponent,
                    imageFilePath: planningAttachment.path
                )
            }
            let plannerUserRequest = context.conversationBuilder.shouldInjectOSConfirmationPrompt(in: context.messages)
                ? context.conversationBuilder.firstTurnOSConfirmationInstruction() + "\n\n" + latestUserMessage.content
                : latestUserMessage.content

            let plannerMessages = context.plannerAgent.buildPlanningConversation(
                systemPrompt: systemPrompt,
                plannerPrompt: UserSettings.shared.resolvedPlannerPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                macroInventoryPrompt: context.conversationBuilder.macroInventoryPrompt(),
                userRequest: plannerUserRequest,
                imageDataURL: planningAttachment.flatMap { context.conversationBuilder.dataURLForImage(atPath: $0.path) }
            )
            context.appendPlannerTrace(title: "Planner request", body: context.tracing.readableTraceParts(from: plannerMessages))
            let plannerResponse = try await context.sendChatCompletion(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                conversation: plannerMessages,
                traceLabel: "PLANNER"
            )
            context.appendPlannerTrace(title: "Planner response", body: plannerResponse.content)
            if let inputTokenCount = plannerResponse.inputTokenCount,
               let outputTokenCount = plannerResponse.outputTokenCount {
                context.appendPlannerTrace(title: "Planner tokens", body: "input=\(inputTokenCount), output=\(outputTokenCount)")
            }

            let plan = try context.plannerAgent.parsePlan(from: plannerResponse.content, goal: latestUserMessage.content)
            context.currentPlan = plan
            context.messages.append(ChatMessage(role: .assistant, content: "Plan ready: \(plan.summary)\nApprove the plan to run \(plan.tasks.count) screen task\(plan.tasks.count == 1 ? "" : "s")."))
            context.persistHistory()
        } catch {
            if Task.isCancelled { return }
            context.logger.log(content: "AI multi-agent planning failed: \(error.localizedDescription)")
            context.appendAITrace(title: "PLANNER_ERROR", body: error.localizedDescription)
            context.appendPlannerTrace(title: "Planner error", body: error.localizedDescription)
            context.presentAIErrorToUser(context.userFacingErrorMessage(from: error))
        }
    }

    // MARK: - Guide-mode send

    func performGuideSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async {
        guard let latestUserMessage = context.messages.last(where: { $0.role == .user }) else {
            context.lastError = "Missing user request"
            return
        }

        let pendingGuideStatusMessageID = context.pendingGuideAutoNextStarts.keys.max { lhs, rhs in
            (context.pendingGuideAutoNextStarts[lhs] ?? .distantPast) < (context.pendingGuideAutoNextStarts[rhs] ?? .distantPast)
        }

        do {
            context.currentPlan = nil
            let guideAttachment = await context.latestPlanningAttachmentURL(fallbackAttachmentPath: latestUserMessage.attachmentFilePath)
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
            conversation.append(.text(role: .system, text: context.conversationBuilder.macroInventoryPrompt()))

            let latestUserIndex = context.messages.lastIndex(where: { $0.id == latestUserMessage.id })
            let contextMessages: [ChatMessage] = {
                guard let latestUserIndex else { return context.messages }
                let prefixToLatest = Array(context.messages[...latestUserIndex])
                if let lastCompletionIndex = prefixToLatest.lastIndex(where: { message in
                    message.role == .assistant &&
                    (message.content.hasPrefix("Task Complete") || context.isGuideCompletionText(message.content))
                }) {
                    let start = lastCompletionIndex + 1
                    if start <= latestUserIndex { return Array(context.messages[start...latestUserIndex]) }
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
                    (($0.guideActionRect != nil || $0.guideShortcut != nil) || context.isGuideCompletionText($0.content))
                }
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var userText = latestUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Guide me to the next action on the current screen."
                : latestUserMessage.content

            if context.conversationBuilder.shouldInjectOSConfirmationPrompt(in: context.messages) {
                userText = context.conversationBuilder.firstTurnOSConfirmationInstruction() + "\n\n" + userText
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
            } else if !initialGoalText.isEmpty && initialGoalText != userText {
                userText = "Original Goal: \(initialGoalText)\nCurrent Request: \(userText)"
            }

            if let guideAttachment,
               let imageDataURL = context.conversationBuilder.dataURLForImage(atPath: guideAttachment.path) {
                conversation.append(.multimodal(role: .user, text: userText, imageDataURL: imageDataURL))
            } else {
                conversation.append(.text(role: .user, text: userText))
            }

            let guideResponse = try await context.sendChatCompletion(
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                conversation: conversation,
                traceLabel: "GUIDE"
            )

            let payload = try context.decodeJSONPayload(GuideResponsePayload.self, from: guideResponse.content)
            context.applyGuideOverlay(from: payload.target_box)

            var responseLines: [String] = []
            responseLines.append(payload.next_step.trimmingCharacters(in: .whitespacesAndNewlines))
            if payload.needs_clarification == true {
                let clarification = payload.clarification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Please provide a clearer screenshot of the target area."
                if !clarification.isEmpty { responseLines.append(clarification) }
            }

            let responseText = responseLines.filter { !$0.isEmpty }.joined(separator: "\n\n")

            var guideActionRect: CGRect?
            if let box = payload.target_box {
                let normalizedRect = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
                if normalizedRect.width > 0.001, normalizedRect.height > 0.001 {
                    guideActionRect = normalizedRect
                }
            }

            let guideTool = payload.tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let guideShortcut = payload.tool_input?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedShortcut   = (guideShortcut?.isEmpty == false) ? guideShortcut : nil
            let hasActionableGuidePayload = guideActionRect != nil || sanitizedShortcut != nil
            let baseGuideMessage   = responseText.isEmpty ? payload.next_step : responseText
            let finalGuideMessage  = context.isGuideCompletionText(baseGuideMessage) && !hasActionableGuidePayload
                ? "Task Complete\n\n\(baseGuideMessage)"
                : baseGuideMessage

            let guideMessageID = UUID()
            context.messages.append(ChatMessage(
                id: guideMessageID,
                role: .assistant,
                content: finalGuideMessage,
                guideActionRect: guideActionRect,
                guideShortcut: sanitizedShortcut,
                guideTool: guideTool
            ))
            if let capturePath = guideAttachment?.path {
                context.guideCapturePathsByMessageID[guideMessageID] = capturePath
            }
            context.guidePromptTraces[guideMessageID] = [
                ChatTaskTraceEntry(
                    title: "Input Prompt",
                    body: context.tracing.readableTraceParts(from: conversation)
                ),
                ChatTaskTraceEntry(
                    title: "Output",
                    body: guideResponse.content
                )
            ]
            if let pendingGuideStatusMessageID {
                context.completeGuideAutoNextStatus(for: pendingGuideStatusMessageID)
            }
            context.persistHistory()
        } catch {
            if Task.isCancelled { return }
            context.logger.log(content: "AI guide-mode request failed: \(error.localizedDescription)")
            context.appendAITrace(title: "GUIDE_ERROR", body: error.localizedDescription)
            context.clearGuideOverlay()
            if let pendingGuideStatusMessageID {
                context.failGuideAutoNextStatus(for: pendingGuideStatusMessageID, errorDescription: error.localizedDescription)
            }
            context.presentAIErrorToUser(context.userFacingErrorMessage(from: error))
        }
    }
}
