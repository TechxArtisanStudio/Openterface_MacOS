import Foundation

// MARK: - ChatManager + ToolExecution
// Stubs delegating to ChatToolExecutionService.

extension ChatManager {

    func parseToolCalls(from text: String) -> [AgentToolCall]? {
        toolExecution.parseToolCalls(from: text)
    }

    func executeToolCalls(_ calls: [AgentToolCall]) async -> AgentToolExecutionResult {
        await toolExecution.executeToolCalls(calls)
    }

    func runBashCommand(_ command: String) async -> String {
        await toolExecution.runBashCommand(command)
    }

    func intArg(_ value: Any?) -> Int?                  { toolExecution.intArg(value) }
    func doubleArg(_ value: Any?) -> Double?            { toolExecution.doubleArg(value) }
    func dragPoints(from args: [String: Any]) -> (startX: Int, startY: Int, endX: Int, endY: Int)? { toolExecution.dragPoints(from: args) }
    func normalizedToAbsolute(_ value: Double) -> Int   { toolExecution.normalizedToAbsolute(value) }
    func absoluteToNormalized(_ value: Int) -> Double   { toolExecution.absoluteToNormalized(value) }
    func clampAbsoluteCoordinate(_ value: Int) -> Int   { max(0, min(4096, value)) }

    func click(button: UInt8, args: [String: Any], isDoubleClick: Bool = false) async -> (x: Int, y: Int) {
        await toolExecution.click(button: button, args: args, isDoubleClick: isDoubleClick)
    }
}
