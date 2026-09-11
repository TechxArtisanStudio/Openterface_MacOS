import Foundation

// MARK: - ChatOSVerificationService
// Handles target OS detection, confirmation dialogue, and plan gate.
// Previously in ChatManager+OSVerification.swift.
// Accessed through ChatManager's `osVerification` property.

@MainActor
final class ChatOSVerificationService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Chat-level OS confirmation

    func respondToOSConfirmation(confirmed: Bool, suggestedSystem: ChatTargetSystem?) {
        guard !context.isSending else { return }

        let fallbackSystem = UserSettings.shared.chatTargetSystem
        let resolvedSystem = suggestedSystem ?? fallbackSystem

        if confirmed {
            if UserSettings.shared.chatTargetSystem != resolvedSystem {
                applyTargetSystem(resolvedSystem)
            }
            context.sendMessage("Confirmed. Proceed with \(resolvedSystem.displayName)-specific guidance and continue the current task.")
            return
        }

        context.sendMessage("No, the target OS is not \(resolvedSystem.displayName). Please re-identify the OS from the current screen and ask me to confirm the correct target system before continuing.")
    }

    // MARK: - Plan-level OS gate

    func confirmPlanOS(confirmed: Bool, newSystem: ChatTargetSystem?) {
        guard context.osContinuation != nil else { return }

        if confirmed {
            if let system = newSystem, system != UserSettings.shared.chatTargetSystem {
                applyTargetSystem(system)
            }
            if var plan = context.currentPlan, plan.status == .awaitingOSConfirmation {
                plan.status = .running
                context.currentPlan = plan
                context.persistHistory()
            }
        } else {
            if var plan = context.currentPlan {
                plan.status = .cancelled
                context.currentPlan = plan
                context.persistHistory()
            }
            context.isSending = false
        }

        context.pendingPlanDetectedOS = nil
        context.osContinuation?.resume(returning: confirmed)
        context.osContinuation = nil
    }

    // MARK: - Internal: live OS verification

    func verifyAndConfirmTargetOS(baseURL: URL, model: String, apiKey: String) async -> Bool {
        let configured = UserSettings.shared.chatTargetSystem

        guard let screenshotURL = await context.captureScreenForAgent() else {
            context.logger.log(content: "OS verification: no screenshot available, proceeding without check")
            return true
        }

        guard let imageDataURL = context.conversationBuilder.dataURLForImage(atPath: screenshotURL.path) else {
            context.logger.log(content: "OS verification: could not encode screenshot, proceeding without check")
            return true
        }

        let detectionConversation: [ChatCompletionsRequest.Message] = [
            .text(role: .system, text: """
You are a system identification assistant. Your ONLY job is to identify the operating system \
visible in the screenshot. Reply with exactly one word from this list: \
macOS, Windows, Linux, iPhone, iPad, Android. No punctuation, no explanation.
"""),
            .multimodal(role: .user, text: "What OS is shown in this screenshot?", imageDataURL: imageDataURL)
        ]

        let detectionResult = try? await context.sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: detectionConversation,
            traceLabel: "OS_DETECT"
        )

        guard let detectionResult = detectionResult else {
            context.logger.log(content: "OS verification: AI call failed, proceeding without check")
            return true
        }

        let detected = parseOSFromDetectionResponse(detectionResult.content)
        context.logger.log(content: "OS verification: configured=\(configured.displayName), detected=\(detected?.displayName ?? "unknown")")

        guard let detected = detected, detected != configured else {
            return true
        }

        if var plan = context.currentPlan {
            plan.status = .awaitingOSConfirmation
            context.currentPlan = plan
            context.persistHistory()
        }
        context.pendingPlanDetectedOS = detected

        context.messages.append(ChatMessage(
            role: .assistant,
            content: """
⚠️ **Target OS mismatch detected**

The screen currently shows **\(detected.displayName)**, but the configured target OS is **\(configured.displayName)**.

Please confirm which OS to use for this task using the buttons below.
"""
        ))
        context.persistHistory()

        return await withCheckedContinuation { continuation in
            context.osContinuation = continuation
        }
    }

    func parseOSFromDetectionResponse(_ text: String) -> ChatTargetSystem? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("windows") { return .windows }
        if lower.contains("macos") || lower.contains("mac os") || lower.contains("osx") { return .macOS }
        if lower.contains("linux") { return .linux }
        if lower.contains("iphone") { return .iPhone }
        if lower.contains("ipad") { return .iPad }
        if lower.contains("android") { return .android }
        return nil
    }

    func applyTargetSystem(_ system: ChatTargetSystem) {
        UserSettings.shared.chatTargetSystem = system
        switch system {
        case .windows:
            UserSettings.shared.keyboardLayout = .windows
        case .linux:
            UserSettings.shared.keyboardLayout = .linux
        case .macOS, .iPhone, .iPad, .android:
            UserSettings.shared.keyboardLayout = .mac
        }
    }
}
