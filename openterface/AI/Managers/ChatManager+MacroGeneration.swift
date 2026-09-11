import Foundation

// MARK: - ChatManager + MacroGeneration (thin delegation stub)
// Logic lives in ChatMacroGenerationService (AI/Services/ChatMacroGenerationService.swift).
// ChatManager retains these entry points for backward-compatible call sites.

extension ChatManager {

    func generateMacroDraft(from request: MacroAIDraftRequest) async throws -> MacroAIDraft {
        try await macroGeneration.generateMacroDraft(from: request)
    }

    // Helpers still called by ChatManager+ConversationBuilder are forwarded here
    // so callers continue to compile without changes.
    func macroGenerationPrompt(for request: MacroAIDraftRequest) -> String {
        macroGeneration.userPrompt(for: request)
    }

    func macroGenerationTargetGuidance(for targetSystem: MacroTargetSystem) -> String {
        macroGeneration.targetGuidance(for: targetSystem)
    }

    func validateGeneratedMacroSequence(_ sequence: String) throws {
        try macroGeneration.validateSequence(sequence)
    }

    func normalizedGeneratedMacroToken(_ token: String) -> String {
        macroGeneration.normalizedToken(token)
    }
}
