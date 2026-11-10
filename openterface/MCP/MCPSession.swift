import Foundation

// MARK: - MCP Session

final class MCPSession {
    let id: String
    let createdAt: Date
    private(set) var lastActivityAt: Date
    private(set) var isInitialized = false
    private(set) var clientInfo: MCPImplementation?
    private(set) var negotiatedProtocolVersion: String?

    private let supportedVersions = ["2025-03-26", "2024-11-05"]
    private let idleTimeout: TimeInterval = 300

    init() {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.lastActivityAt = Date()
    }

    func touch() {
        lastActivityAt = Date()
    }

    var isExpired: Bool {
        Date().timeIntervalSince(lastActivityAt) > idleTimeout
    }

    func handleInitialize(params: MCPInitializeParams) -> MCPInitializeResult {
        let version = supportedVersions.contains(params.protocolVersion)
            ? params.protocolVersion
            : supportedVersions[0]

        negotiatedProtocolVersion = version
        clientInfo = params.clientInfo
        isInitialized = true
        touch()

        return MCPInitializeResult(
            protocolVersion: version,
            capabilities: MCPServerCapabilities(
                tools: MCPToolsCapability(listChanged: false),
                resources: nil,
                prompts: nil,
                logging: nil
            ),
            serverInfo: MCPImplementation(name: "openterface", version: "1.0.0"),
            instructions: """
            Openterface MCP Server provides remote control of a target computer via KVM hardware.
            Tools: capture_screen (screenshot), move_mouse, left_click, right_click, double_click,
            type_text, press_key, drag, scroll, ocr_screen, get_device_status, switch_usb.
            Mouse coordinates are normalized 0.0-1.0. Use capture_screen before clicking to see the target screen.
            """
        )
    }

    func handleInitializedNotification() {
        touch()
    }
}