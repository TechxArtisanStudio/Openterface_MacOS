import Foundation

// MARK: - ChatManager + OSVerification  (delegation stub)
// All logic lives in ChatOSVerificationService (AI/Services/ChatOSVerificationService.swift).

extension ChatManager {

    func respondToOSConfirmation(confirmed: Bool, suggestedSystem: ChatTargetSystem?) {
        osVerification.respondToOSConfirmation(confirmed: confirmed, suggestedSystem: suggestedSystem)
    }

    func confirmPlanOS(confirmed: Bool, newSystem: ChatTargetSystem?) {
        osVerification.confirmPlanOS(confirmed: confirmed, newSystem: newSystem)
    }

    func verifyAndConfirmTargetOS(baseURL: URL, model: String, apiKey: String) async -> Bool {
        await osVerification.verifyAndConfirmTargetOS(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    func parseOSFromDetectionResponse(_ text: String) -> ChatTargetSystem? {
        osVerification.parseOSFromDetectionResponse(text)
    }

    func applyTargetSystem(_ system: ChatTargetSystem) {
        osVerification.applyTargetSystem(system)
    }
}
