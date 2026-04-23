import Foundation
import AppKit

// MARK: - ChatConversationBuilderService
// Owns conversation construction, image encoding/scaling, macro inventory
// generation, and the OS-confirmation injection helpers.
// Previously split across ChatManager+ConversationBuilder.swift.
// Accessed through ChatManager's `conversationBuilder` property.

@MainActor
final class ChatConversationBuilderService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Agent tool instruction (moved from ChatManager)

    let agentToolInstruction = """
When action is required, you may call tools by returning ONLY JSON (no markdown):
{"tool_calls":[{"tool":"capture_screen"},{"tool":"move_mouse","x":0.5,"y":0.5},{"tool":"left_click"},{"tool":"left_drag","start_x":0.2,"start_y":0.5,"x":0.8,"y":0.5},{"tool":"type_text","text":"hello"},{"tool":"run_verified_macro","macro_id":"UUID-or-label"}]}

The target OS has already been configured by the app. Do not ask the user to confirm the OS again.

Coordinate system:
- All x/y values are normalized floats from 0.0 to 1.0.
- 0.0 means the left/top edge of the screen; 1.0 means the right/bottom edge.
- Estimate the element's position as a fraction of the screenshot width and height.
- Example: if a button is at roughly 45% from left and 30% from top, use x=0.45, y=0.30.
- NEVER output raw pixel coordinates. Always use 0.0-1.0 normalized values.

Available tools:
- capture_screen: Capture latest target screen and use it for next reasoning step.
- move_mouse: Move target mouse. Args: x (Float), y (Float) in 0.0...1.0.
- left_click: Left click at current mouse location. Optional args: x (Float), y (Float) in 0.0...1.0.
- left_drag: Hold left mouse button and drag to a destination. Args: x (Float), y (Float) destination in 0.0...1.0. Optional args: start_x (Float), start_y (Float) to begin from a specific point; otherwise current mouse position is used.
- right_click: Right click at current mouse location. Optional args: x (Float), y (Float) in 0.0...1.0.
- double_click: Double left click. Optional args: x (Float), y (Float) in 0.0...1.0.
- type_text: Type PLAIN TEXT on target. Args: text (String). ONLY use this for literal characters. Do NOT pass token sequences like <DOWN>, <ENTER>, <ESC> here — use press_key instead.
- press_key: Press one or more special keys or a key combination. Args: keys (String) — a sequence of key tokens from this list: <ESC> <ENTER> <TAB> <SPACE> <BACK> <DEL> <UP> <DOWN> <LEFT> <RIGHT> <HOME> <END> <PGUP> <PGDN> <F1>..<F12>. Wrap with modifier tags: <CTRL>c</CTRL> <CMD>a</CMD> <SHIFT><TAB></SHIFT> <ALT><F4></ALT>. Example: {"tool":"press_key","keys":"<DOWN>"} or {"tool":"press_key","keys":"<CTRL>c</CTRL>"}.
- run_verified_macro: Execute one verified macro. Args: macro_id (String, preferred UUID) or macro_label (String).
- run_bash: Run a bash command on the HOST machine (macOS). Args: command (String). Use this to write files to disk, fetch URLs with curl, or perform any host-side task you cannot do otherwise. The stdout+stderr output is returned so you can act on the result. Working directory is ~/Documents/Openterface. Use with care — commands run with the app's sandbox permissions.
- create_macro: Create a new macro. Required args: label (String), data (String, macro key sequence). Optional args: description (String), target_system (String: macOS|Windows|Linux|iPhone|iPad|Android, default = configured target OS), interval_ms (Int, default 80), verified (Bool, default false). Returns the new macro id.
- set_macro_verified: Set or clear the verified flag on an existing macro. Required args: macro_id (String UUID) or macro_label (String). Required args: verified (Bool).

Macro tool rules:
- Prefer run_verified_macro when a verified macro can jump directly to the requested state.
- Before using capture_screen or incremental mouse steps, check whether a verified macro already matches the user's current goal or sub-goal and use it first when it is a strong fit.
- Only call run_verified_macro with a verified macro from the provided macro inventory.
- Prefer macro_id over macro_label when available.
- IMPORTANT: After running a macro, always verify the result in a NEW tool_calls response. Never include capture_screen or any other tool in the same tool_calls array as run_verified_macro, because the macro needs time to complete on the target machine before a screenshot is useful.
- If the macro partially completes the job, continue with more tool calls until the task is actually complete.
- If no verified macro matches, continue with the normal screen-driven tools.

Mouse safety rules:
- Only click when the intended target is clearly visible in the latest screenshot.
- Do not guess hidden Dock icons, hidden windows, or off-screen control locations.
- If a macro or shortcut did not bring the expected app/window to the foreground, prefer another verified macro, keyboard-driven recovery, or another capture_screen step instead of a blind click.
- When the task is a settings change, verify the result from the full visible UI state before choosing another action.

After tool execution, you will receive a TOOL_RESULT message. Continue until task done, then return normal user-facing text (not JSON).
"""

    // MARK: - Conversation building

    func buildConversation(
        systemPrompt: String,
        sourceMessages: [ChatMessage],
        includeAgentTools: Bool
    ) -> [ChatCompletionsRequest.Message] {
        var conversation: [ChatCompletionsRequest.Message] = []

        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        if includeAgentTools {
            conversation.append(.text(role: .system, text: agentToolInstruction + "\n\n" + macroInventoryPrompt()))
        }

        let recent = sourceMessages.suffix(30)
        let shouldInjectFirstTurnConfirmation = !includeAgentTools && shouldInjectOSConfirmationPrompt(in: sourceMessages)

        conversation.append(contentsOf: recent.map { message in
            let shouldPrefixUserMessage = shouldInjectFirstTurnConfirmation && message.role == .user
            if message.role == .user,
               let path = message.attachmentFilePath,
               let imageURL = dataURLForImage(atPath: path) {
                var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Please analyze this screenshot."
                    : message.content
                if shouldPrefixUserMessage {
                    text = firstTurnOSConfirmationInstruction() + "\n\n" + text
                }
                return .multimodal(role: message.role, text: text, imageDataURL: imageURL)
            }
            if shouldPrefixUserMessage {
                return .text(role: message.role, text: firstTurnOSConfirmationInstruction() + "\n\n" + message.content)
            }
            return .text(role: message.role, text: message.content)
        })

        return conversation
    }

    // MARK: - Macro inventory

    func macroInventoryPrompt() -> String {
        let verifiedMacros = MacroManager.shared.macros.filter(\.isVerified)
        var sections: [String] = []

        if verifiedMacros.isEmpty {
            sections.append("Verified executable macros:\n- No verified macros are currently available.")
        } else {
            let verifiedLines = verifiedMacros.map { macro in
                let description = macro.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = description.isEmpty ? macro.data : description
                return "- id=\(macro.id.uuidString), label=\(macro.label), target=\(macro.targetSystem.displayName), detail=\(detail)"
            }
            sections.append("Verified executable macros:\n" + verifiedLines.joined(separator: "\n"))
        }

        sections.append("Macro tool usage:\n- Use run_verified_macro only with a verified macro from the executable list above.\n- Prefer macro_id over macro_label when calling the tool.\n- IMPORTANT: After running a macro, always verify the result in a NEW tool_calls response. Never include capture_screen or any other tool in the same tool_calls array as run_verified_macro.\n- If the macro gets close but does not fully finish the job, continue with additional tool calls instead of assuming success.")

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Macro matching

    /// Match against ALL macros (verified or not) — used by tools that manage macros.
    func anyMacroMatch(from args: [String: Any]) -> VerifiedMacroMatch? {
        let allMacros = MacroManager.shared.macros
        guard !allMacros.isEmpty else { return nil }
        return macroMatch(in: allMacros, from: args)
    }

    /// Match against verified-only macros — used by the run_verified_macro tool.
    func verifiedMacroMatch(from args: [String: Any]) -> VerifiedMacroMatch? {
        let verifiedMacros = MacroManager.shared.macros.filter(\.isVerified)
        guard !verifiedMacros.isEmpty else { return nil }
        return macroMatch(in: verifiedMacros, from: args)
    }

    private func macroMatch(in macros: [Macro], from args: [String: Any]) -> VerifiedMacroMatch? {
        let requestedID = ((args["macro_id"] as? String) ?? (args["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let macroID = UUID(uuidString: requestedID),
           let matched = macros.first(where: { $0.id == macroID }) {
            return VerifiedMacroMatch(macro: matched, matchedBy: "id")
        }

        let requestedLabel = ((args["macro_label"] as? String) ?? (args["label"] as? String) ?? requestedID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedLabel.isEmpty else { return nil }

        let normalized = requestedLabel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let exact = macros.first(where: {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
        }) {
            return VerifiedMacroMatch(macro: exact, matchedBy: "label")
        }

        let partials = macros.filter {
            $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(normalized)
        }
        if partials.count == 1, let matched = partials.first {
            return VerifiedMacroMatch(macro: matched, matchedBy: "partial-label")
        }
        return nil
    }

    // MARK: - OS-confirmation injection

    func shouldInjectOSConfirmationPrompt(in sourceMessages: [ChatMessage]) -> Bool {
        let userCount      = sourceMessages.filter { $0.role == .user }.count
        let assistantCount = sourceMessages.filter { $0.role == .assistant }.count
        return userCount == 1 && assistantCount == 0
    }

    func firstTurnOSConfirmationInstruction() -> String {
        let systemsList = ChatTargetSystem.allCases
            .map { "  - \($0.displayName): \($0.detail)" }
            .joined(separator: "\n")
        let selected = UserSettings.shared.chatTargetSystem
        return """
CRITICAL: Before proceeding with the user's request, examine the screenshot carefully to identify which operating system is running on the target device.

Available systems to identify:
\(systemsList)

After analyzing the screenshot, you MUST explicitly identify which system you detected by stating one of these exact phrases:
- "The target OS appears to be: macOS"
- "The target OS appears to be: Windows"
- "The target OS appears to be: Linux"
- "The target OS appears to be: iPhone"
- "The target OS appears to be: iPad"
- "The target OS appears to be: Android"

Immediately after that line, you MUST include a confirmation sentence in this exact format:
- "Please confirm whether the target system should be set to macOS."
- "Please confirm whether the target system should be set to Windows."
- "Please confirm whether the target system should be set to Linux."
- "Please confirm whether the target system should be set to iPhone."
- "Please confirm whether the target system should be set to iPad."
- "Please confirm whether the target system should be set to Android."

Do not replace that confirmation sentence with paraphrases such as "Shall I proceed" or "Does this match". The response must contain both the exact detection line and the exact confirmation sentence so the app can open the OS selection UI reliably.

Currently configured target system: \(selected.displayName)
"""
    }

    // MARK: - Image encoding

    func dataURLForImage(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let imagePayload = preparedImagePayload(for: url) else { return nil }
        return "data:\(imagePayload.mimeType);base64,\(imagePayload.data.base64EncodedString())"
    }

    func hasTransparency(_ cgImage: CGImage) -> Bool {
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            break
        default:
            return false
        }

        let width  = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }

        let bytesPerPixel    = 4
        let bytesPerRow      = width * bytesPerPixel
        var pixelData        = [UInt8](repeating: 255, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for alphaIndex in stride(from: 3, to: pixelData.count, by: bytesPerPixel) {
            if pixelData[alphaIndex] < 255 { return true }
        }
        return false
    }

    func preferredAIImageEncoding(for cgImage: CGImage, quality: Double = 0.92) -> (data: Data, mimeType: String)? {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let hasAlpha  = hasTransparency(cgImage)

        if !hasAlpha,
           let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
            return (jpegData, "image/jpeg")
        }

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return (pngData, "image/png")
        }
        return nil
    }

    func preparedImagePayload(for url: URL) -> (data: Data, mimeType: String)? {
        guard let originalData = try? Data(contentsOf: url) else { return nil }

        let ext = url.pathExtension.lowercased()
        let originalMimeType: String
        switch ext {
        case "jpg", "jpeg": originalMimeType = "image/jpeg"
        case "webp":        originalMimeType = "image/webp"
        case "gif":         originalMimeType = "image/gif"
        default:            originalMimeType = "image/png"
        }

        guard let image    = NSImage(contentsOf: url),
              let cgImage  = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            context.logger.log(content: "AI image scaling skipped: failed to load image at \(url.path)")
            return (originalData, originalMimeType)
        }

        guard let maxLongEdge = UserSettings.shared.chatImageUploadLimit.maxLongEdge else {
            if originalMimeType == "image/jpeg" { return (originalData, originalMimeType) }
            if let preferred = preferredAIImageEncoding(for: cgImage),
               preferred.mimeType == "image/jpeg" || preferred.data.count < originalData.count {
                context.logger.log(content: "AI image re-encoded for upload: \(url.lastPathComponent) -> \(preferred.mimeType) bytes=\(preferred.data.count) (from \(originalData.count))")
                return preferred
            }
            return (originalData, originalMimeType)
        }

        let width    = CGFloat(cgImage.width)
        let height   = CGFloat(cgImage.height)
        let longEdge = max(width, height)

        guard longEdge > maxLongEdge else {
            if originalMimeType == "image/jpeg" { return (originalData, originalMimeType) }
            if let preferred = preferredAIImageEncoding(for: cgImage),
               preferred.mimeType == "image/jpeg" || preferred.data.count < originalData.count {
                context.logger.log(content: "AI image re-encoded for upload without scaling: \(url.lastPathComponent) -> \(preferred.mimeType) bytes=\(preferred.data.count) (from \(originalData.count))")
                return preferred
            }
            return (originalData, originalMimeType)
        }

        let scale        = maxLongEdge / longEdge
        let targetWidth  = max(1, Int((width  * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let drawContext = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            context.logger.log(content: "AI image scaling skipped: failed to create drawing context for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        drawContext.interpolationQuality = .high
        drawContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let scaledCGImage = drawContext.makeImage() else {
            context.logger.log(content: "AI image scaling skipped: failed to render scaled image for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        guard let scaledPayload = preferredAIImageEncoding(for: scaledCGImage) else {
            context.logger.log(content: "AI image scaling skipped: failed to encode scaled image for \(url.lastPathComponent)")
            return (originalData, originalMimeType)
        }

        context.logger.log(content: "AI image scaled for upload: \(Int(width))x\(Int(height)) -> \(targetWidth)x\(targetHeight) [limit=\(UserSettings.shared.chatImageUploadLimit.rawValue), mime=\(scaledPayload.mimeType), bytes=\(scaledPayload.data.count)]")
        return scaledPayload
    }
}
