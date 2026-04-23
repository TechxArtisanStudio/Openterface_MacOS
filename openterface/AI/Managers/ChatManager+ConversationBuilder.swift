import Foundation
import AppKit

// MARK: - ChatManager + ConversationBuilder  (delegation stub)
// All logic lives in ChatConversationBuilderService.

extension ChatManager {

    func buildConversation(systemPrompt: String, sourceMessages: [ChatMessage], includeAgentTools: Bool) -> [ChatCompletionsRequest.Message] {
        conversationBuilder.buildConversation(systemPrompt: systemPrompt, sourceMessages: sourceMessages, includeAgentTools: includeAgentTools)
    }

    func macroInventoryPrompt() -> String                                { conversationBuilder.macroInventoryPrompt() }
    func anyMacroMatch(from args: [String: Any]) -> VerifiedMacroMatch?  { conversationBuilder.anyMacroMatch(from: args) }
    func verifiedMacroMatch(from args: [String: Any]) -> VerifiedMacroMatch? { conversationBuilder.verifiedMacroMatch(from: args) }
    func shouldInjectOSConfirmationPrompt(in msgs: [ChatMessage]) -> Bool { conversationBuilder.shouldInjectOSConfirmationPrompt(in: msgs) }
    func firstTurnOSConfirmationInstruction() -> String                  { conversationBuilder.firstTurnOSConfirmationInstruction() }
    func dataURLForImage(atPath path: String) -> String?                 { conversationBuilder.dataURLForImage(atPath: path) }
    func hasTransparency(_ cgImage: CGImage) -> Bool                     { conversationBuilder.hasTransparency(cgImage) }
    func preferredAIImageEncoding(for cgImage: CGImage, quality: Double = 0.92) -> (data: Data, mimeType: String)? { conversationBuilder.preferredAIImageEncoding(for: cgImage, quality: quality) }
    func preparedImagePayload(for url: URL) -> (data: Data, mimeType: String)? { conversationBuilder.preparedImagePayload(for: url) }
}
