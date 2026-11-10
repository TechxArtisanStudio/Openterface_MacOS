import Foundation

// MARK: - Type Text Tool

final class MCPTypeTextTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "type_text",
        description: "Type text on the target computer as if typed on a physical keyboard. Supports printable ASCII characters.",
        inputSchema: MCPInputSchema(
            properties: [
                "text": AnyCodable(["type": "string", "description": "The text to type on the target computer"])
            ],
            required: ["text"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return MCPCallToolResult(content: [.text("Invalid arguments: text (non-empty string) required")], isError: true)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                AIInputRouter.sendText(text)
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("Typed \(text.count) characters")], isError: nil)
    }
}

// MARK: - Press Key Tool

final class MCPPressKeyTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "press_key",
        description: "Press a key or key combination on the target computer. Use token format like <Enter>, <Ctrl+C>, <Alt+F4>, <Cmd+Space>. Multiple keys separated by spaces.",
        inputSchema: MCPInputSchema(
            properties: [
                "keys": AnyCodable(["type": "string", "description": "Key tokens, e.g. '<Enter>', '<Ctrl+C>', '<Alt+Tab>', '<Cmd+Shift+4>'"])
            ],
            required: ["keys"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let keys = arguments["keys"] as? String, !keys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPCallToolResult(content: [.text("Invalid arguments: keys (non-empty string) required")], isError: true)
        }

        let tokens = await MacroManager.shared.tokenize(keys)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                MacroExecutionEngine.run(tokens: tokens, intervalMs: 80)
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("Pressed keys: \(keys)")], isError: nil)
    }
}