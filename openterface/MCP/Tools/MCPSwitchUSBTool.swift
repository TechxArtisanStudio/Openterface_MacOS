import Foundation

// MARK: - Switch USB Tool

final class MCPSwitchUSBTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "switch_usb",
        description: "Switch the USB connection between host (this Mac) and target (the remote computer). Use 'host' to connect peripherals to this Mac, 'target' to connect them to the remote computer.",
        inputSchema: MCPInputSchema(
            properties: [
                "target": AnyCodable(["type": "string", "enum": ["host", "target"], "description": "USB routing destination: 'host' or 'target'"])
            ],
            required: ["target"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let target = arguments["target"] as? String else {
            return MCPCallToolResult(content: [.text("Invalid arguments: target ('host' or 'target') required")], isError: true)
        }

        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)

        switch target.lowercased() {
        case "host":
            hidManager.setUSBtoHost()
            return MCPCallToolResult(content: [.text("USB switched to host")], isError: nil)
        case "target":
            hidManager.setUSBtoTarget()
            return MCPCallToolResult(content: [.text("USB switched to target")], isError: nil)
        default:
            return MCPCallToolResult(content: [.text("Invalid target: must be 'host' or 'target'")], isError: true)
        }
    }
}