import Foundation

// MARK: - Tool Handler Protocol

protocol MCPToolHandler {
    var definition: MCPToolDefinition { get }
    func execute(arguments: [String: Any]) async -> MCPCallToolResult
}

// MARK: - Tool Registry

final class MCPToolRegistry {
    private var handlers: [String: MCPToolHandler] = [:]
    private let lock = NSLock()

    func register(_ handler: MCPToolHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[handler.definition.name] = handler
    }

    func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: name)
    }

    func listTools() -> [MCPToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.values.map(\.definition).sorted { $0.name < $1.name }
    }

    func handler(for name: String) -> MCPToolHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name]
    }

    func callTool(name: String, arguments: [String: Any]) async -> MCPCallToolResult {
        guard let handler = handler(for: name) else {
            return MCPCallToolResult(
                content: [.text("Unknown tool: \(name)")],
                isError: true
            )
        }
        return await handler.execute(arguments: arguments)
    }
}