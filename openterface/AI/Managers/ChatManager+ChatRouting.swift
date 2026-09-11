import Foundation

// MARK: - ChatManager + ChatRouting  (delegation stub)
// All logic lives in ChatRoutingService (AI/Services/ChatRoutingService.swift).

extension ChatManager {

    func performSend() async                                                                             { await routing.performSend() }
    func performMultiAgentSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async { await routing.performMultiAgentSend(baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt) }
    func performGuideSend(baseURL: URL, model: String, apiKey: String, systemPrompt: String) async      { await routing.performGuideSend(baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: systemPrompt) }

    func applyGuideOverlay(from targetBox: GuideResponsePayload.TargetBox?) {
        guard let targetBox else { clearGuideOverlay(); return }
        let x      = min(max(targetBox.x,      0.0), 1.0)
        let y      = min(max(targetBox.y,      0.0), 1.0)
        let width  = min(max(targetBox.width,  0.0), 1.0)
        let height = min(max(targetBox.height, 0.0), 1.0)
        guard width > 0.001, height > 0.001 else { clearGuideOverlay(); return }
        AppStatus.guideHighlightRectNormalized = CGRect(x: x, y: y, width: width, height: height)
        AppStatus.showGuideOverlay = true
    }

    func clearGuideOverlay() {
        AppStatus.showGuideOverlay = false
        AppStatus.guideHighlightRectNormalized = .zero
    }
}

