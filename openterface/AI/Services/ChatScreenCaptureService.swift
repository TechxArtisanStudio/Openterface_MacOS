import Foundation
import AppKit
import CoreGraphics

// MARK: - ChatScreenCaptureService
// Screen capture, annotated click images, and click-target refinement.
// Previously in ChatManager+ScreenCapture.swift.
// Accessed through ChatManager's `screenCapture` property.

@MainActor
final class ChatScreenCaptureService {

    private let context: any ChatContext

    init(context: any ChatContext) {
        self.context = context
    }

    // MARK: - Helpers

    private static func clamp(_ value: Int) -> Int { max(0, min(4096, value)) }

    // MARK: - Screen capture

    func captureScreenForAgent(timeoutSeconds: TimeInterval = 3.0) async -> URL? {
        guard CameraManager.shared.canTakePicture else {
            context.logger.log(content: "AI Tool capture_screen unavailable: camera not ready")
            return nil
        }

        context.logger.log(content: "AI Tool capture_screen starting")
        context.pendingCapturePreviewSuppressions += 1

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let waiter = CaptureScreenWaiter()
            waiter.continuation = continuation

            waiter.observer = NotificationCenter.default.addObserver(
                forName: .cameraPictureCaptured,
                object: nil,
                queue: .main
            ) { notification in
                Task { @MainActor in
                    waiter.resolve(with: notification.userInfo?["fileURL"] as? URL)
                }
            }

            waiter.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                waiter.resolve(with: nil)
            }

            CameraManager.shared.takePicture()
        }

        if let result {
            context.logger.log(content: "AI Tool capture_screen succeeded -> \(result.path)")
        } else {
            context.logger.log(content: "AI Tool capture_screen timed out waiting for notification")
            if context.pendingCapturePreviewSuppressions > 0 {
                context.pendingCapturePreviewSuppressions -= 1
            }
        }

        return result
    }

    func consumePendingCapturePreviewSuppression() -> Bool {
        guard context.pendingCapturePreviewSuppressions > 0 else { return false }
        context.pendingCapturePreviewSuppressions -= 1
        return true
    }

    // MARK: - Annotated click image

    func captureAnnotatedClickForChat(absX: Int, absY: Int, actionName: String) async -> URL? {
        guard let screenshotURL = await captureScreenForAgent() else { return nil }
        guard let annotatedURL = makeAnnotatedClickImage(from: screenshotURL, absX: absX, absY: absY, actionName: actionName) else {
            context.logger.log(content: "AI Tool \(actionName) annotation failed; using raw screenshot")
            return screenshotURL
        }
        context.logger.log(content: "AI Tool \(actionName) annotation saved -> \(annotatedURL.path)")
        return annotatedURL
    }

    func makeAnnotatedClickImage(from sourceURL: URL, absX: Int, absY: Int, actionName: String) -> URL? {
        guard let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width  = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let drawContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        drawContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let normalizedX    = min(1.0, max(0.0, Double(absX) / 4096.0))
        let normalizedY    = min(1.0, max(0.0, Double(absY) / 4096.0))
        let pixelX         = normalizedX * Double(width)
        let pixelYFromTop  = normalizedY * Double(height)
        let pixelY         = Double(height) - pixelYFromTop

        let radius     = max(12.0, min(Double(width), Double(height)) * 0.03)
        let circleRect = CGRect(x: pixelX - radius, y: pixelY - radius, width: radius * 2.0, height: radius * 2.0)
        drawContext.setStrokeColor(NSColor.systemRed.cgColor)
        drawContext.setLineWidth(max(3.0, radius * 0.2))
        drawContext.strokeEllipse(in: circleRect)

        let centerDotRadius = max(3.0, radius * 0.14)
        let dotRect = CGRect(x: pixelX - centerDotRadius, y: pixelY - centerDotRadius, width: centerDotRadius * 2.0, height: centerDotRadius * 2.0)
        drawContext.setFillColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
        drawContext.fillEllipse(in: dotRect)

        guard let annotatedCGImage = drawContext.makeImage() else { return nil }
        guard let encodedImage = context.conversationBuilder.preferredAIImageEncoding(for: annotatedCGImage) else { return nil }

        let outputDir   = sourceURL.deletingLastPathComponent()
        let stamp       = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let ext         = encodedImage.mimeType == "image/jpeg" ? "jpg" : "png"
        let outputURL   = outputDir.appendingPathComponent("\(actionName)_annotated_\(stamp).\(ext)")

        do {
            try encodedImage.data.write(to: outputURL, options: .atomic)
            return outputURL
        } catch {
            context.logger.log(content: "AI Tool annotation write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Click refinement

    func refineGuideClickTarget(absX: Int, absY: Int, instruction: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        await refineClickTarget(
            absX: absX,
            absY: absY,
            instruction: instruction,
            tracePrefix: "GUIDE_CLICK_REFINE",
            logPrefix: "Guide click refinement"
        )
    }

    func refineClickTarget(absX: Int, absY: Int, instruction: String, tracePrefix: String, logPrefix: String) async -> (x: Int, y: Int, matchedElement: String?)? {
        guard let configuration = context.currentChatAPIConfiguration() else {
            let reason = "\(logPrefix) skipped: chat API configuration is incomplete"
            context.logger.log(content: reason)
            context.appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let screenshotURL = await captureScreenForAgent() else {
            let reason = "\(logPrefix) skipped: screen capture unavailable"
            context.logger.log(content: reason)
            context.appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let crop = makeClickRefinementCrop(from: screenshotURL, absX: absX, absY: absY, cropSizePixels: 200) else {
            let reason = "\(logPrefix) skipped: failed to build crop"
            context.logger.log(content: reason)
            context.appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        guard let imageDataURL = context.conversationBuilder.dataURLForImage(atPath: crop.imageURL.path) else {
            let reason = "\(logPrefix) skipped: failed to encode crop image"
            context.logger.log(content: reason)
            context.appendAITrace(title: "\(tracePrefix)_SKIPPED", body: reason)
            return nil
        }

        context.appendAITrace(
            title: "\(tracePrefix)_CONTEXT",
            body: [
                "instruction: \(instruction)",
                "initialAbsPoint: x=\(absX), y=\(absY)",
                "screenshot: \(screenshotURL.path)",
                "crop: \(crop.imageURL.path)",
                "cropOriginTopLeft: x=\(crop.cropOriginX), y=\(crop.cropOriginYTop)",
                "cropSize: \(crop.cropWidth)x\(crop.cropHeight)",
                "sourceSize: \(crop.sourceWidth)x\(crop.sourceHeight)"
            ].joined(separator: "\n")
        )

        let conversation: [ChatCompletionsRequest.Message] = [
            .text(role: .system, text: """
You refine click targets inside a small screenshot crop.

Return ONLY JSON with this schema:
{
    "found": true,
    "x": 0.50,
    "y": 0.50,
    "matched_element": "short description of the matched icon/button/text",
    "confidence": 0.0
}

Rules:
- `x` and `y` must be normalized 0.0...1.0 within the provided crop image.
- The crop is centered near the initial predicted click point.
- Find the exact visible center of the icon, button, or text that best matches the instruction.
- If the target is not visible or not clear enough, return `found`: false and omit x/y.
- Do not return markdown or extra commentary.
"""),
            .multimodal(role: .user, text: """
Instruction for the target to click:
\(instruction)

This image is a 200x200 pixel crop around the model's initial click estimate.
Locate the exact visible center of the correct icon, button, or text inside this crop.
""", imageDataURL: imageDataURL)
        ]

        do {
            let response = try await context.sendChatCompletion(
                baseURL: configuration.baseURL,
                model: configuration.model,
                apiKey: configuration.apiKey,
                conversation: conversation,
                traceLabel: tracePrefix,
                enableThinking: UserSettings.shared.isClickRefinementThinkingEnabled
            )
            let payload = try context.decodeJSONPayload(ClickTargetRefinementPayload.self, from: response.content)
            guard payload.found != false,
                  let refinedX = payload.x,
                  let refinedY = payload.y else {
                let reason = "\(logPrefix) returned no confident target"
                context.logger.log(content: reason)
                context.appendAITrace(title: "\(tracePrefix)_RESULT", body: reason)
                return nil
            }

            let normalizedX     = min(max(refinedX, 0.0), 1.0)
            let normalizedY     = min(max(refinedY, 0.0), 1.0)
            let globalPixelX    = Double(crop.cropOriginX)    + Double(crop.cropWidth)  * normalizedX
            let globalPixelYTop = Double(crop.cropOriginYTop) + Double(crop.cropHeight) * normalizedY
            let refinedAbsX     = Self.clamp(Int((globalPixelX    / Double(max(crop.sourceWidth,  1))) * 4096.0))
            let refinedAbsY     = Self.clamp(Int((globalPixelYTop / Double(max(crop.sourceHeight, 1))) * 4096.0))

            let resultBody = "refinedAbsPoint: x=\(refinedAbsX), y=\(refinedAbsY)\nmatched: \(payload.matched_element ?? "unknown")\nconfidence: \(payload.confidence ?? -1)"
            context.logger.log(content: "\(logPrefix) succeeded: abs=(\(refinedAbsX), \(refinedAbsY)), matched=\(payload.matched_element ?? "unknown"), confidence=\(payload.confidence ?? -1)")
            context.appendAITrace(title: "\(tracePrefix)_RESULT", body: resultBody)
            return (refinedAbsX, refinedAbsY, payload.matched_element)
        } catch {
            let reason = "\(logPrefix) failed: \(error.localizedDescription)"
            context.logger.log(content: reason)
            context.appendAITrace(title: "\(tracePrefix)_FAILED", body: reason)
            return nil
        }
    }

    func agenticClickRefinementInstruction(args: [String: Any], isDoubleClick: Bool, button: UInt8) -> String? {
        if let instruction = (args["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            return instruction
        }
        if let description = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        if let latestGoal = context.messages.last(where: { $0.role == .user && !$0.content.hasPrefix("TOOL_RESULT:") })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !latestGoal.isEmpty {
            let actionName: String
            if button == 0x02       { actionName = "right click" }
            else if isDoubleClick   { actionName = "double click" }
            else                    { actionName = "click" }
            return "\(actionName) the correct target needed for this task: \(latestGoal)"
        }
        return nil
    }

    func makeClickRefinementCrop(from sourceURL: URL, absX: Int, absY: Int, cropSizePixels: Int) -> ClickRefinementCropResult? {
        guard let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let sourceWidth  = cgImage.width
        let sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let normalizedX    = min(1.0, max(0.0, Double(absX) / 4096.0))
        let normalizedYTop = min(1.0, max(0.0, Double(absY) / 4096.0))
        let pixelX         = Int((normalizedX    * Double(sourceWidth)).rounded())
        let pixelYTop      = Int((normalizedYTop * Double(sourceHeight)).rounded())

        let cropWidth      = min(cropSizePixels, sourceWidth)
        let cropHeight     = min(cropSizePixels, sourceHeight)
        let halfWidth      = cropWidth  / 2
        let halfHeight     = cropHeight / 2

        let cropOriginX    = max(0, min(sourceWidth  - cropWidth,  pixelX    - halfWidth))
        let cropOriginYTop = max(0, min(sourceHeight - cropHeight, pixelYTop - halfHeight))

        // Screen captures use top-left origin; do NOT flip Y here.
        let cropRect = CGRect(x: cropOriginX, y: cropOriginYTop, width: cropWidth, height: cropHeight)

        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return nil }
        guard let encodedCrop = context.conversationBuilder.preferredAIImageEncoding(for: croppedCGImage) else { return nil }

        let outputDir   = sourceURL.deletingLastPathComponent()
        let stamp       = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let ext         = encodedCrop.mimeType == "image/jpeg" ? "jpg" : "png"
        let outputURL   = outputDir.appendingPathComponent("click_refine_crop_\(stamp).\(ext)")

        do {
            try encodedCrop.data.write(to: outputURL, options: .atomic)
            return ClickRefinementCropResult(
                imageURL:       outputURL,
                sourceWidth:    sourceWidth,
                sourceHeight:   sourceHeight,
                cropOriginX:    cropOriginX,
                cropOriginYTop: cropOriginYTop,
                cropWidth:      cropWidth,
                cropHeight:     cropHeight
            )
        } catch {
            context.logger.log(content: "Guide click refinement crop write failed: \(error.localizedDescription)")
            return nil
        }
    }
}
