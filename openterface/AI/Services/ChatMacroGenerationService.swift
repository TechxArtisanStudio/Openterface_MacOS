import Foundation

// MARK: - ChatMacroGenerationService
// Owns all AI-assisted macro draft generation logic that previously lived in
// ChatManager+MacroGeneration.swift, including constants, prompts, validation,
// and the MacroAIDraftPayload decode helper.
// Accessed through ChatManager's `macroGeneration` property.

@MainActor
final class ChatMacroGenerationService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Constants

    let supportedTokens: Set<String> = [
        "<CTRL>", "</CTRL>", "<SHIFT>", "</SHIFT>", "<ALT>", "</ALT>", "<CMD>", "</CMD>",
        "<ESC>", "<BACK>", "<ENTER>", "<TAB>", "<SPACE>",
        "<LEFT>", "<RIGHT>", "<UP>", "<DOWN>",
        "<HOME>", "<END>", "<DEL>", "<PGUP>", "<PGDN>",
        "<F1>", "<F2>", "<F3>", "<F4>", "<F5>", "<F6>",
        "<F7>", "<F8>", "<F9>", "<F10>", "<F11>", "<F12>",
        "<DELAY05s>", "<DELAY1S>", "<DELAY2S>", "<DELAY5S>", "<DELAY10S>"
    ]

    let generationInstruction = """
You generate Openterface keyboard macros.

Return ONLY JSON with this schema:
{
  "label": "short macro name",
  "description": "one sentence tooltip",
  "data": "macro sequence using Openterface tokens",
  "intervalMs": 80
}

Macro authoring rules:
- Use only plain characters plus these tokens: <CTRL>, </CTRL>, <SHIFT>, </SHIFT>, <ALT>, </ALT>, <CMD>, </CMD>, <ESC>, <BACK>, <ENTER>, <TAB>, <SPACE>, <LEFT>, <RIGHT>, <UP>, <DOWN>, <HOME>, <END>, <DEL>, <PGUP>, <PGDN>, <F1>..<F12>, <DELAY05s>, <DELAY1S>, <DELAY2S>, <DELAY5S>, <DELAY10S>.
- Do not invent tokens.
- Do not use <MACRO:...> references.
- Use <ENTER> instead of a literal newline.
- Wrap modified key presses with opening and closing modifier tags, for example <CTRL>c</CTRL>.
- Whenever a macro finishes typing a plain-text burst and then continues with another action, insert a short delay such as <DELAY05s> before the next action so visual effects and UI updates can settle.
- Prefer the shortest stable shortcut for the requested target OS.
- Keep label short and description practical.
- Use intervalMs 80 unless the flow is timing-sensitive.
- Return JSON only, with no markdown or explanation.
"""

    // MARK: - Public entry point

    func generateMacroDraft(from request: MacroAIDraftRequest) async throws -> MacroAIDraft {
        let trimmedGoal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            throw NSError(domain: "ChatMacroGenerationService", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "Describe what the macro should do."])
        }

        let baseURLString = UserSettings.shared.chatApiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model         = UserSettings.shared.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt  = UserSettings.shared.resolvedSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredKey = UserSettings.shared.chatApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey        = configuredKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : configuredKey

        guard !baseURLString.isEmpty, let baseURL = URL(string: baseURLString) else {
            throw NSError(domain: "ChatMacroGenerationService", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: "AI base URL is not configured."])
        }
        guard !model.isEmpty else {
            throw NSError(domain: "ChatMacroGenerationService", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "AI model is not configured."])
        }
        guard !apiKey.isEmpty else {
            throw NSError(domain: "ChatMacroGenerationService", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: "AI API key is not configured."])
        }

        var conversation: [ChatCompletionsRequest.Message] = []
        if !systemPrompt.isEmpty {
            conversation.append(.text(role: .system, text: systemPrompt))
        }
        conversation.append(.text(role: .system, text: generationInstruction))
        conversation.append(.text(role: .system, text: targetGuidance(for: request.targetSystem)))
        conversation.append(.text(role: .user,   text: userPrompt(for: request)))

        let response = try await context.sendChatCompletion(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            conversation: conversation,
            traceLabel: "MACRO_GENERATOR"
        )

        let payload = try context.decodeJSONPayload(MacroAIDraftPayload.self, from: response.content)
        return try normalizedDraft(from: payload)
    }

    // MARK: - Prompt builders

    func userPrompt(for request: MacroAIDraftRequest) -> String {
        let label       = request.currentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = request.currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let data        = request.currentData.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
Generate an Openterface macro draft.

Target OS: \(request.targetSystem.displayName)
User goal: \(request.goal)
Current label: \(label.isEmpty ? "(empty)" : label)
Current description: \(description.isEmpty ? "(empty)" : description)
Current sequence: \(data.isEmpty ? "(empty)" : data)

Produce a draft that is ready to save in the Openterface macro editor.
If the macro types text and then continues, add a short delay token such as <DELAY05s> after the typing step so the UI can finish visual effects before the next action.
If timing matters for any other reason, add an explicit delay token and explain why in the description.
"""
    }

    func targetGuidance(for targetSystem: MacroTargetSystem) -> String {
        switch targetSystem {
        case .macOS:
            return "On macOS, treat <CMD> as the Command key. Prefer Command-based shortcuts such as <CMD>c</CMD>, <CMD>v</CMD>, and <CMD><SPACE></CMD> when they match the goal."
        case .windows:
            return "On Windows, treat <CMD> as the Windows key. Prefer Ctrl, Alt, and Windows-key shortcuts such as <CTRL>c</CTRL>, <CMD>r</CMD>, and <ALT><TAB></ALT>."
        case .linux:
            return "On Linux, treat <CMD> as the Super key. Prefer common desktop shortcuts such as <CTRL><ALT>t</ALT></CTRL>, <ALT><TAB></ALT>, and <CMD>l</CMD> when relevant."
        case .iPhone, .iPad:
            return "On iPhone and iPad with a hardware keyboard, treat <CMD> as the Command key. Prefer iPadOS-style shortcuts such as <CMD><SPACE></CMD>, <CMD><TAB></CMD>, and <CMD>h</CMD>."
        case .android:
            return "On Android, treat <CMD> as the Meta key. Prefer combinations that work with external keyboards, such as <ALT><TAB></ALT>, <CTRL>a</CTRL>, and <CTRL>c</CTRL> when relevant."
        }
    }

    // MARK: - Draft normalization & validation

    func normalizedDraft(from payload: MacroAIDraftPayload) throws -> MacroAIDraft {
        let label       = payload.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let data        = payload.data.trimmingCharacters(in: .whitespacesAndNewlines)
        let intervalMs  = min(max(payload.intervalMs ?? 80, 10), 500)

        guard !label.isEmpty else {
            throw NSError(domain: "ChatMacroGenerationService", code: 44,
                          userInfo: [NSLocalizedDescriptionKey: "AI returned an empty macro name."])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "ChatMacroGenerationService", code: 45,
                          userInfo: [NSLocalizedDescriptionKey: "AI returned an empty macro sequence."])
        }

        try validateSequence(data)
        return MacroAIDraft(label: label, description: description, data: data, intervalMs: intervalMs)
    }

    func validateSequence(_ sequence: String) throws {
        let tokens   = MacroManager.shared.tokenize(sequence)
        var balances = ["CTRL": 0, "SHIFT": 0, "ALT": 0, "CMD": 0]

        for token in tokens where token.hasPrefix("<") && token.hasSuffix(">") {
            let normalized = normalizedToken(token)

            if normalized.hasPrefix("<MACRO:") {
                throw NSError(domain: "ChatMacroGenerationService", code: 46,
                              userInfo: [NSLocalizedDescriptionKey: "AI returned a macro reference token, which is not allowed in Magic generation."])
            }
            guard supportedTokens.contains(normalized) else {
                throw NSError(domain: "ChatMacroGenerationService", code: 47,
                              userInfo: [NSLocalizedDescriptionKey: "AI returned an unsupported macro token: \(token)"])
            }

            switch normalized {
            case "<CTRL>":   balances["CTRL", default: 0] += 1
            case "</CTRL>":
                guard balances["CTRL", default: 0] > 0 else {
                    throw NSError(domain: "ChatMacroGenerationService", code: 48,
                                  userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </CTRL> tag."])
                }
                balances["CTRL", default: 0] -= 1
            case "<SHIFT>":  balances["SHIFT", default: 0] += 1
            case "</SHIFT>":
                guard balances["SHIFT", default: 0] > 0 else {
                    throw NSError(domain: "ChatMacroGenerationService", code: 49,
                                  userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </SHIFT> tag."])
                }
                balances["SHIFT", default: 0] -= 1
            case "<ALT>":    balances["ALT", default: 0] += 1
            case "</ALT>":
                guard balances["ALT", default: 0] > 0 else {
                    throw NSError(domain: "ChatMacroGenerationService", code: 50,
                                  userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </ALT> tag."])
                }
                balances["ALT", default: 0] -= 1
            case "<CMD>":    balances["CMD", default: 0] += 1
            case "</CMD>":
                guard balances["CMD", default: 0] > 0 else {
                    throw NSError(domain: "ChatMacroGenerationService", code: 51,
                                  userInfo: [NSLocalizedDescriptionKey: "AI returned an unmatched </CMD> tag."])
                }
                balances["CMD", default: 0] -= 1
            default:
                break
            }
        }

        if let unclosed = balances.first(where: { $0.value != 0 })?.key {
            throw NSError(domain: "ChatMacroGenerationService", code: 52,
                          userInfo: [NSLocalizedDescriptionKey: "AI returned an unclosed <\(unclosed)> modifier tag."])
        }
    }

    func normalizedToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return trimmed }

        let isClosing = trimmed.hasPrefix("</")
        let nameStart = trimmed.index(trimmed.startIndex, offsetBy: isClosing ? 2 : 1)
        let nameEnd   = trimmed.index(before: trimmed.endIndex)
        let rawName   = String(trimmed[nameStart..<nameEnd]).uppercased()

        let canonical: String
        switch rawName {
        case "CTRL", "CONTROL":                                    canonical = "CTRL"
        case "SHIFT":                                               canonical = "SHIFT"
        case "ALT", "OPT", "OPTION":                               canonical = "ALT"
        case "CMD", "COMMAND", "WIN", "WINDOWS", "SUPER", "META":  canonical = "CMD"
        case "DELAY05S":                                            canonical = "DELAY05s"
        default:                                                    canonical = rawName
        }

        return isClosing ? "</\(canonical)>" : "<\(canonical)>"
    }
}

// MARK: - MacroAIDraftPayload (decode helper, scoped to this service file)

struct MacroAIDraftPayload: Decodable {
    let label: String
    let description: String
    let data: String
    let intervalMs: Int?
}
