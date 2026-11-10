import Foundation
import AppKit
import CoreGraphics
import VideoToolbox

// MARK: - OCR Screen Tool

final class MCPOCRTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "ocr_screen",
        description: "Capture the target screen and perform OCR (optical character recognition) to extract visible text. Returns recognized text.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard #available(macOS 12.3, *) else {
            return MCPCallToolResult(content: [.text("OCR requires macOS 12.3 or later")], isError: true)
        }

        guard CameraManager.shared.canTakePicture else {
            return MCPCallToolResult(
                content: [.text("OCR unavailable: camera not ready or no video signal")],
                isError: true
            )
        }

        let cgImage: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let videoManager = DependencyContainer.shared.resolve(VideoManagerProtocol.self)
                if let pixelBuffer = videoManager.outputDelegate?.getLatestFrame() {
                    var cgImage: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil as CFDictionary?, imageOut: &cgImage)
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let image = cgImage else {
            return MCPCallToolResult(
                content: [.text("OCR failed: could not capture video frame")],
                isError: true
            )
        }

        let ocrResult: OCRResult = await withCheckedContinuation { continuation in
            OCRManager.shared.performOCR(on: image) { result in
                continuation.resume(returning: result)
            }
        }

        switch ocrResult {
        case .success(let text):
            return MCPCallToolResult(content: [.text(text)], isError: nil)
        case .noTextFound:
            return MCPCallToolResult(content: [.text("No text found on screen")], isError: nil)
        case .failed(let error):
            return MCPCallToolResult(content: [.text("OCR failed: \(error.localizedDescription)")], isError: true)
        }
    }
}