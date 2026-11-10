import Foundation
import AppKit

// MARK: - Coordinate Helpers

enum MCPCoordinates {
    static func normalizedToAbsolute(_ value: Double) -> Int {
        max(0, min(4096, Int((min(max(value, 0.0), 1.0) * 4096.0).rounded())))
    }

    static func doubleArg(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    static func intArg(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }
}

// MARK: - Move Mouse Tool

final class MCPMoveMouseTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "move_mouse",
        description: "Move the mouse cursor on the target computer. Coordinates are normalized 0.0-1.0 (top-left origin).",
        inputSchema: MCPInputSchema(
            properties: [
                "x": AnyCodable(["type": "number", "description": "Normalized X coordinate (0.0 = left, 1.0 = right)"]),
                "y": AnyCodable(["type": "number", "description": "Normalized Y coordinate (0.0 = top, 1.0 = bottom)"])
            ],
            required: ["x", "y"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let nx = MCPCoordinates.doubleArg(arguments["x"]),
              let ny = MCPCoordinates.doubleArg(arguments["y"]) else {
            return MCPCallToolResult(content: [.text("Invalid arguments: x and y must be numbers")], isError: true)
        }

        let absX = MCPCoordinates.normalizedToAbsolute(nx)
        let absY = MCPCoordinates.normalizedToAbsolute(ny)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                AIInputRouter.sendMouseMove(absX: absX, absY: absY)
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("Mouse moved to (\(String(format: "%.3f", nx)), \(String(format: "%.3f", ny)))")], isError: nil)
    }
}

// MARK: - Click Tool

enum MCPMouseButton {
    case left, right
}

final class MCPClickTool: MCPToolHandler {
    private let button: MCPMouseButton

    var definition: MCPToolDefinition {
        let name = button == .left ? "left_click" : "right_click"
        let desc = button == .left ? "Left-click" : "Right-click"
        return MCPToolDefinition(
            name: name,
            description: "\(desc) on the target computer at the specified position. If x/y omitted, clicks at current cursor position.",
            inputSchema: MCPInputSchema(
                properties: [
                    "x": AnyCodable(["type": "number", "description": "Normalized X coordinate (0.0-1.0). Optional."]),
                    "y": AnyCodable(["type": "number", "description": "Normalized Y coordinate (0.0-1.0). Optional."])
                ]
            )
        )
    }

    init(button: MCPMouseButton) {
        self.button = button
    }

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        let buttonByte: UInt8 = button == .left ? 0x01 : 0x02
        let name = button == .left ? "left_click" : "right_click"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if let nx = MCPCoordinates.doubleArg(arguments["x"]),
                   let ny = MCPCoordinates.doubleArg(arguments["y"]) {
                    let absX = MCPCoordinates.normalizedToAbsolute(nx)
                    let absY = MCPCoordinates.normalizedToAbsolute(ny)
                    AIInputRouter.animatedClick(button: buttonByte, absX: absX, absY: absY)
                } else {
                    AIInputRouter.animatedClick(button: buttonByte, absX: 2048, absY: 2048)
                }
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("\(name) executed")], isError: nil)
    }
}

// MARK: - Double Click Tool

final class MCPDoubleClickTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "double_click",
        description: "Double-click on the target computer at the specified position.",
        inputSchema: MCPInputSchema(
            properties: [
                "x": AnyCodable(["type": "number", "description": "Normalized X coordinate (0.0-1.0). Optional."]),
                "y": AnyCodable(["type": "number", "description": "Normalized Y coordinate (0.0-1.0). Optional."])
            ]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if let nx = MCPCoordinates.doubleArg(arguments["x"]),
                   let ny = MCPCoordinates.doubleArg(arguments["y"]) {
                    let absX = MCPCoordinates.normalizedToAbsolute(nx)
                    let absY = MCPCoordinates.normalizedToAbsolute(ny)
                    AIInputRouter.animatedClick(button: 0x01, absX: absX, absY: absY, isDoubleClick: true)
                } else {
                    AIInputRouter.animatedClick(button: 0x01, absX: 2048, absY: 2048, isDoubleClick: true)
                }
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("double_click executed")], isError: nil)
    }
}

// MARK: - Drag Tool

final class MCPDragTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "drag",
        description: "Drag from one position to another on the target computer (left button held). All coordinates normalized 0.0-1.0.",
        inputSchema: MCPInputSchema(
            properties: [
                "start_x": AnyCodable(["type": "number", "description": "Start X (0.0-1.0)"]),
                "start_y": AnyCodable(["type": "number", "description": "Start Y (0.0-1.0)"]),
                "end_x": AnyCodable(["type": "number", "description": "End X (0.0-1.0)"]),
                "end_y": AnyCodable(["type": "number", "description": "End Y (0.0-1.0)"])
            ],
            required: ["start_x", "start_y", "end_x", "end_y"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let sx = MCPCoordinates.doubleArg(arguments["start_x"]),
              let sy = MCPCoordinates.doubleArg(arguments["start_y"]),
              let ex = MCPCoordinates.doubleArg(arguments["end_x"]),
              let ey = MCPCoordinates.doubleArg(arguments["end_y"]) else {
            return MCPCallToolResult(content: [.text("Invalid arguments: start_x, start_y, end_x, end_y required")], isError: true)
        }

        let startAbsX = MCPCoordinates.normalizedToAbsolute(sx)
        let startAbsY = MCPCoordinates.normalizedToAbsolute(sy)
        let endAbsX = MCPCoordinates.normalizedToAbsolute(ex)
        let endAbsY = MCPCoordinates.normalizedToAbsolute(ey)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                AIInputRouter.animatedDrag(button: 0x01, startAbsX: startAbsX, startAbsY: startAbsY, endAbsX: endAbsX, endAbsY: endAbsY)
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("Drag from (\(String(format: "%.3f", sx)), \(String(format: "%.3f", sy))) to (\(String(format: "%.3f", ex)), \(String(format: "%.3f", ey)))")], isError: nil)
    }
}

// MARK: - Scroll Tool

final class MCPScrollTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "scroll",
        description: "Scroll the mouse wheel on the target computer. Positive amount scrolls up, negative scrolls down.",
        inputSchema: MCPInputSchema(
            properties: [
                "amount": AnyCodable(["type": "integer", "description": "Scroll amount (positive = up, negative = down)"]),
                "x": AnyCodable(["type": "number", "description": "Normalized X position to scroll at (optional)"]),
                "y": AnyCodable(["type": "number", "description": "Normalized Y position to scroll at (optional)"])
            ],
            required: ["amount"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let amount = MCPCoordinates.intArg(arguments["amount"]) else {
            return MCPCallToolResult(content: [.text("Invalid arguments: amount (integer) required")], isError: true)
        }

        let clampedAmount = max(-127, min(127, amount))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var absX = 2048
                var absY = 2048
                if let nx = MCPCoordinates.doubleArg(arguments["x"]),
                   let ny = MCPCoordinates.doubleArg(arguments["y"]) {
                    absX = MCPCoordinates.normalizedToAbsolute(nx)
                    absY = MCPCoordinates.normalizedToAbsolute(ny)
                }
                HostManager.shared.handleAbsoluteMouseAction(x: absX, y: absY, mouseEvent: 0x00, wheelMovement: clampedAmount)
                continuation.resume()
            }
        }

        return MCPCallToolResult(content: [.text("Scrolled \(clampedAmount > 0 ? "up" : "down") by \(abs(clampedAmount))")], isError: nil)
    }
}