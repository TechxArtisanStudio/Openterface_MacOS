import Foundation

final class MCPEDIDInfoTool: MCPToolHandler {
    let definition = MCPToolDefinition(
        name: "edid_info",
        description: "Read the EDID display name stored in the video chip EEPROM. This is the monitor name that the target computer sees. The name is up to 12 printable ASCII characters. HID polling pauses briefly while the EEPROM is read.",
        inputSchema: MCPInputSchema()
    )

    func execute(arguments: [String: Any]) async -> MCPCallToolResult {
        let firmwareManager = FirmwareManager.shared

        let chipset = await MainActor.run { AppStatus.videoChipsetType }
        guard chipset != .unknown else {
            return MCPCallToolResult(
                content: [.text("No Openterface video chip detected. Connect an Openterface unit first.")],
                isError: true
            )
        }
        guard chipset != .ms2130s else {
            return MCPCallToolResult(
                content: [.text("EDID identity is not available on MS2130S devices. The MS2130S uses external SPI flash and does not expose a simple EDID name field.")],
                isError: true
            )
        }

        HALIntegrationManager.shared.pausePeriodicHALUpdates()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let identity: EdidIdentity? = await firmwareManager.readEdidIdentity()
        HALIntegrationManager.shared.resumePeriodicHALUpdates()

        guard let identity else {
            return MCPCallToolResult(
                content: [.text("Failed to read EDID identity from the device EEPROM.")],
                isError: true
            )
        }

        let chipsetLabel: String
        switch chipset {
        case .ms2109: chipsetLabel = "ms2109"
        case .ms2109s: chipsetLabel = "ms2109s"
        case .ms2130s: chipsetLabel = "ms2130s"
        case .unknown: chipsetLabel = "unknown"
        }

        var info: [String: Any] = [:]
        info["chipset"] = chipsetLabel
        info["display_name"] = identity.displayName ?? ""
        info["manufacturer_id"] = identity.manufacturerId ?? ""
        if let productCode = identity.productCode {
            info["product_code"] = String(format: "0x%04X", productCode)
        }
        if let serialNumber = identity.serialNumber {
            info["serial_number"] = String(format: "0x%08X", serialNumber)
        }
        info["serial_string"] = identity.serialString ?? ""
        info["edid_offset"] = String(format: "0x%04X", identity.edidOffset)
        info["firmware_size"] = identity.firmwareSize
        info["edid_checksum_valid"] = identity.checksumValid

        let hidManager = DependencyContainer.shared.resolve(HIDManagerProtocol.self)
        if let resolution = hidManager.getResolution() {
            info["input_resolution"] = ["width": resolution.width, "height": resolution.height]
        }
        if let version = hidManager.getVersion() {
            info["firmware_version"] = version
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return MCPCallToolResult(content: [.text("Failed to serialize EDID info")], isError: true)
        }

        return MCPCallToolResult(content: [.text(jsonString)], isError: nil)
    }
}
