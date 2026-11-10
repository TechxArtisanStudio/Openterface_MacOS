import Foundation
import Combine

final class MCPEDIDSetTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "edid_set",
        description: "Write a new EDID display name into the video chip EEPROM (up to 12 printable ASCII characters). Reads the current name, writes the new one, then recalculates firmware checksums. The device only presents the new EDID after a full power cycle (unplug and reconnect all cables); the app keeps running.",
        inputSchema: MCPInputSchema(
            properties: [
                "display_name": AnyCodable([
                    "type": "string",
                    "description": "New EDID display name, 1-12 printable ASCII characters. This is the monitor name the target computer sees."
                ])
            ],
            required: ["display_name"]
        )
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        guard let newName = arguments["display_name"] as? String else {
            return MCPCallToolResult(
                content: [.text("Missing required argument: display_name")],
                isError: true
            )
        }

        guard !newName.isEmpty else {
            return MCPCallToolResult(
                content: [.text("display_name must not be empty")],
                isError: true
            )
        }

        guard newName.count <= 13 else {
            return MCPCallToolResult(
                content: [.text("display_name must be 12 characters or less (got \(newName.count))")],
                isError: true
            )
        }

        guard newName.allSatisfy({ $0.isASCII && $0.asciiValue! >= 32 && $0.asciiValue! <= 126 }) else {
            return MCPCallToolResult(
                content: [.text("display_name must contain only printable ASCII characters (space through tilde)")],
                isError: true
            )
        }

        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset != .unknown else {
            return MCPCallToolResult(
                content: [.text("No Openterface video chip detected. Connect an Openterface unit first.")],
                isError: true
            )
        }
        guard chipset != .ms2130s else {
            return MCPCallToolResult(
                content: [.text("EDID write is not supported on MS2130S devices.")],
                isError: true
            )
        }

        let firmwareManager = FirmwareManager.shared

        // Pause HAL polling so EEPROM reads/writes own the HID device, without
        // tearing down the video session (which would also terminate the app when
        // the main window is the only one open).
        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let oldName = await firmwareManager.getEdidName() ?? "(not set)"

        let result: (success: Bool, message: String) = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = firmwareManager.edidUpdateComplete
                .first()
                .sink { success, message in
                    cancellable?.cancel()
                    continuation.resume(returning: (success, message))
                }

            Task { @MainActor in
                await firmwareManager.setEdidName(newName, stopAllOperations: false)
            }
        }

        HALIntegrationManager.shared.resumePeriodicHALUpdates()

        if result.success {
            return MCPCallToolResult(
                content: [.text("EDID display name updated.\nBefore: \(oldName)\nAfter: \(newName)\n\nNote: The device only presents the new EDID after a full power cycle (unplug and reconnect all cables).")],
                isError: nil
            )
        } else {
            return MCPCallToolResult(
                content: [.text("EDID write failed: \(result.message)")],
                isError: true
            )
        }
    }
}
