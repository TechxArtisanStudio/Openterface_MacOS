import Foundation

// MARK: - ChatManager + ScreenCapture
// Stub delegating to ChatScreenCaptureService.

extension ChatManager {

    func captureScreenForAgent(timeoutSeconds: TimeInterval) async -> URL? {
        await screenCapture.captureScreenForAgent(timeoutSeconds: timeoutSeconds)
    }

    func consumePendingCapturePreviewSuppression() -> Bool {
        screenCapture.consumePendingCapturePreviewSuppression()
    }

    func captureAnnotatedClickForChat(absX: Int, absY: Int, actionName: String) async -> URL? {
        await screenCapture.captureAnnotatedClickForChat(absX: absX, absY: absY, actionName: actionName)
    }

    func makeAnnotatedClickImage(from sourceURL: URL, absX: Int, absY: Int, actionName: String) -> URL? {
        screenCapture.makeAnnotatedClickImage(from: sourceURL, absX: absX, absY: absY, actionName: actionName)
    }

    func refineGuideClickTarget(absX: Int, absY: Int, instruction: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        await screenCapture.refineGuideClickTarget(absX: absX, absY: absY, instruction: instruction)
    }

    func refineClickTarget(absX: Int, absY: Int, instruction: String, tracePrefix: String, logPrefix: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        await screenCapture.refineClickTarget(absX: absX, absY: absY, instruction: instruction, tracePrefix: tracePrefix, logPrefix: logPrefix)
    }

    func agenticClickRefinementInstruction(args: [String: Any], isDoubleClick: Bool, button: UInt8) -> String? {
        screenCapture.agenticClickRefinementInstruction(args: args, isDoubleClick: isDoubleClick, button: button)
    }

    func makeClickRefinementCrop(from sourceURL: URL, absX: Int, absY: Int, cropSizePixels: Int) -> ClickRefinementCropResult? {
        screenCapture.makeClickRefinementCrop(from: sourceURL, absX: absX, absY: absY, cropSizePixels: cropSizePixels)
    }
}
