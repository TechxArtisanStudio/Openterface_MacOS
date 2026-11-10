import Foundation
import AppKit

// MARK: - Capture Screen Tool

final class MCPCaptureScreenTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "capture_screen",
        description: "Capture a screenshot of the target computer's current display via the KVM video feed. Returns the image as base64-encoded PNG.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard CameraManager.shared.canTakePicture else {
            return MCPCallToolResult(
                content: [.text("Screen capture unavailable: camera not ready or no video signal")],
                isError: true
            )
        }

        let fileURL: URL? = await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            var timeoutTask: Task<Void, Never>?

            observer = NotificationCenter.default.addObserver(
                forName: .cameraPictureCaptured,
                object: nil,
                queue: .main
            ) { notification in
                timeoutTask?.cancel()
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                let url = notification.userInfo?["fileURL"] as? URL
                continuation.resume(returning: url)
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    continuation.resume(returning: nil)
                }
            }

            DispatchQueue.main.async {
                CameraManager.shared.takePicture()
            }
        }

        guard let url = fileURL, let imageData = try? Data(contentsOf: url) else {
            return MCPCallToolResult(
                content: [.text("Screen capture failed: timed out or file unreadable")],
                isError: true
            )
        }

        let base64 = imageData.base64EncodedString()
        return MCPCallToolResult(
            content: [
                .image(data: base64, mimeType: "image/png"),
                .text("Screenshot captured (\(imageData.count) bytes)")
            ],
            isError: nil
        )
    }
}