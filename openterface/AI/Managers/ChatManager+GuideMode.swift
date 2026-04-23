import Foundation

// MARK: - ChatManager + GuideMode
// Stubs delegating to ChatGuideModeService.

extension ChatManager {

    func isGuideCompletionText(_ text: String) -> Bool {
        guideMode.isGuideCompletionText(text)
    }

    func executeGuideAction(messageID: UUID, targetBox: CGRect?, shortcut: String?, tool: String?, messageContent: String, autoNext: Bool) {
        guideMode.executeGuideAction(messageID: messageID, targetBox: targetBox, shortcut: shortcut, tool: tool, messageContent: messageContent, autoNext: autoNext)
    }

    func completeGuideStepAndNext(stepDescription: String) {
        guideMode.completeGuideStepAndNext(stepDescription: stepDescription)
    }

    func executeGuideInputSequence(_ inputSequence: String) -> Bool {
        guideMode.executeGuideInputSequence(inputSequence)
    }

    func executeShortcut(_ shortcut: String) -> Bool {
        guideMode.executeShortcut(shortcut)
    }

    func keyCode(for token: String) -> UInt16? {
        guideMode.keyCode(for: token)
    }
}
