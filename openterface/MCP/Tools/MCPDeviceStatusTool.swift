import Foundation

// MARK: - Device Status Tool

final class MCPDeviceStatusTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "get_device_status",
        description: "Get the current status of the Openterface KVM device: connection state, video resolution, FPS, HDMI signal, USB switch position.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        let status: [String: Any] = await MainActor.run {
            var result: [String: Any] = [:]

            result["hdmi_connected"] = AppStatus.isHDMIConnected
            result["target_connected"] = AppStatus.isTargetConnected
            result["keyboard_connected"] = SerialPortStatus.shared.isKeyboardConnected
            result["mouse_connected"] = SerialPortStatus.shared.isMouseConnected
            result["active_protocol"] = AppStatus.activeConnectionProtocol.rawValue

            // Serial port info
            result["serial_port_name"] = SerialPortStatus.shared.serialPortName
            result["serial_port_baudrate"] = SerialPortStatus.shared.serialPortBaudRate

            // Keyboard lock states
            result["num_lock"] = SerialPortStatus.shared.isNumLockOn
            result["caps_lock"] = SerialPortStatus.shared.isCapLockOn
            result["scroll_lock"] = SerialPortStatus.shared.isScrollOn

            let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
            if let resolution = hidManager.getResolution() {
                result["input_resolution"] = ["width": resolution.width, "height": resolution.height]
            }
            if let fps = hidManager.getFps() {
                result["fps"] = fps
            }
            result["hdmi_signal"] = hidManager.getHDMIStatus()

            // Capture resolution (what the KVM is actually capturing)
            let captureDims = VideoManager.shared.dimensions
            if captureDims.width > 0 && captureDims.height > 0 {
                result["capture_resolution"] = ["width": Int(captureDims.width), "height": Int(captureDims.height)]
            }

            if let version = hidManager.getVersion() {
                result["firmware_version"] = version
            }

            result["hardware_switch_on"] = AppStatus.isHardwareSwitchOn
            result["software_switch_on"] = AppStatus.isSoftwareSwitchOn

            return result
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys, .prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return MCPCallToolResult(content: [.text("Failed to serialize device status")], isError: true)
        }

        return MCPCallToolResult(content: [.text(jsonString)], isError: nil)
    }
}